#!/usr/bin/env bash
# Usage: deploy.sh <image-tag>
#
# Copied to /opt/app/deploy.sh on every instance by the launch template's user_data, and run
# there as root through SSM Run Command (by hand in step 1.14, by the pipeline in Part 2).
#
# What it does, in order: log in to ECR, pull both images, read the secrets into memory,
# apply database migrations from the NEW backend image, restart the containers, then check that
# the app answers on this instance. Every failure exits non-zero. A failed migration stops the
# deploy before anything is restarted, so the running version stays up.
#
# Tests: scripts/tests/deploy.test.sh
set -euo pipefail

TAG="${1:?usage: deploy.sh <image-tag>}"
[[ "$TAG" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "invalid image tag: $TAG" >&2; exit 2; }

APP_DIR="${APP_DIR:-/opt/app}"   # overridden only by the tests
# shellcheck source=/dev/null
source "$APP_DIR/instance.env"   # REGION ACCOUNT_ID NAME_PREFIX FRONTEND_PORT BACKEND_PORT DB_HOST DB_PORT DB_NAME DB_SECRET_ARN INSTANCE_ID BACKEND_LOG_GROUP FRONTEND_LOG_GROUP
# SSM Run Command starts with a minimal environment: set what the AWS CLI and docker need.
export HOME=/root AWS_DEFAULT_REGION="$REGION"

# Where the containers' output goes (the compose file below). Checked first, by name, so that an instance.env
# without them fails here and not halfway through a deploy with "unbound variable".
: "${INSTANCE_ID:?instance.env has no INSTANCE_ID}"
: "${BACKEND_LOG_GROUP:?instance.env has no BACKEND_LOG_GROUP}"
: "${FRONTEND_LOG_GROUP:?instance.env has no FRONTEND_LOG_GROUP}"

# Two deploys must never overlap on one instance.
exec 9> "$APP_DIR/deploy.lock"
flock -n 9 || { echo "another deploy is already running on this instance" >&2; exit 1; }

REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
export BACKEND_IMAGE="${REGISTRY}/${NAME_PREFIX}-backend:${TAG}"
export FRONTEND_IMAGE="${REGISTRY}/${NAME_PREFIX}-frontend:${TAG}"
export BACKEND_PORT FRONTEND_PORT
export REGION INSTANCE_ID BACKEND_LOG_GROUP FRONTEND_LOG_GROUP   # substituted into the compose file below
COMPOSE_FILE="$APP_DIR/docker-compose.yml"

echo "==> ECR login and pull (${TAG})"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY" > /dev/null
docker pull "$BACKEND_IMAGE"
docker pull "$FRONTEND_IMAGE"

# The secrets are only ever held in this shell's environment. They are passed to containers by
# name, never written to a file, so nothing on disk holds them.
echo "==> reading secrets"
DB_SECRET_JSON=$(aws secretsmanager get-secret-value --secret-id "$DB_SECRET_ARN" --query SecretString --output text)
# RDS keeps only the username and password in its secret, so the URL is built here. The
# password is generated and can contain characters that must be percent-encoded.
DATABASE_URL=$(printf '%s' "$DB_SECRET_JSON" | python3 -c '
import json, sys, urllib.parse as u
secret = json.load(sys.stdin)
host, port, name = sys.argv[1:4]
print("postgresql://%s:%s@%s:%s/%s?sslmode=require" % (
    u.quote(secret["username"], safe=""), u.quote(secret["password"], safe=""), host, port, name))
' "$DB_HOST" "$DB_PORT" "$DB_NAME")
JWT_SECRET_KEY=$(aws secretsmanager get-secret-value --secret-id "${NAME_PREFIX}-jwt-secret" --query SecretString --output text)
export DATABASE_URL JWT_SECRET_KEY

# Migrations are a deploy step, not something the app does when it starts. They run from the
# new image, before the old containers are touched. migrate deploy is idempotent, so on a second
# instance it finds nothing to apply. Migrations must work for the old and the new code at once.
echo "==> database migrations"
docker run --rm -e DATABASE_URL "$BACKEND_IMAGE" node_modules/.bin/prisma migrate deploy \
  || { echo "migration failed: nothing was restarted, the running version is unchanged" >&2; exit 1; }

echo "==> restarting the application"
cat > "$COMPOSE_FILE.tmp" <<'YAML'
services:
  backend:
    image: ${BACKEND_IMAGE}
    restart: unless-stopped
    ports:
      - "${BACKEND_PORT}:${BACKEND_PORT}"
    environment:
      NODE_ENV: production
      PORT: "${BACKEND_PORT}"
      # No value: compose takes these from the environment of this script, so they are never in a file.
      DATABASE_URL:
      JWT_SECRET_KEY:
    # Container output goes to CloudWatch Logs through Docker's awslogs driver. The driver runs in the Docker
    # daemon on the host, so it uses the instance role (CloudWatchAgentServerPolicy allows CreateLogStream and
    # PutLogEvents); no container has credentials. The groups are created by Terraform, with a retention.
    # "mode: non-blocking" matters: the default is blocking, and then a container that writes to stdout while
    # CloudWatch cannot be reached would stall. Non-blocking buffers up to max-buffer-size and drops messages
    # when that is full, which is the right trade for a log. The stream is the instance ID, like the agent's.
    logging:
      driver: awslogs
      options:
        awslogs-region: ${REGION}
        awslogs-group: ${BACKEND_LOG_GROUP}
        awslogs-stream: ${INSTANCE_ID}
        mode: non-blocking
        max-buffer-size: 4m
  frontend:
    image: ${FRONTEND_IMAGE}
    restart: unless-stopped
    ports:
      - "${FRONTEND_PORT}:80"
    logging:
      driver: awslogs
      options:
        awslogs-region: ${REGION}
        awslogs-group: ${FRONTEND_LOG_GROUP}
        awslogs-stream: ${INSTANCE_ID}
        mode: non-blocking
        max-buffer-size: 4m
YAML
mv "$COMPOSE_FILE.tmp" "$COMPOSE_FILE"
# The placeholder from first boot holds the same ports until the first real deploy.
docker rm -f placeholder > /dev/null 2>&1 || true
docker compose -f "$COMPOSE_FILE" up -d --remove-orphans

fail() {
  echo "ERROR: $*" >&2
  docker compose -f "$COMPOSE_FILE" logs --tail 50 >&2 || true
  exit 1
}

echo "==> checking the application on this instance"
health=$(curl -fsS --retry 20 --retry-delay 3 --retry-connrefused --retry-all-errors \
  "http://localhost:${BACKEND_PORT}/api/health") && [[ "$health" == *'"status":"ok"'* ]] \
  || fail "the backend did not report healthy on /api/health"
curl -fsS --retry 10 --retry-delay 2 --retry-connrefused --retry-all-errors \
  "http://localhost:${FRONTEND_PORT}/" > /dev/null \
  || fail "the frontend did not answer"

echo "$TAG" > "$APP_DIR/current-tag"
# Keep recent images for a fast rollback, drop unused ones older than a week.
docker image prune -af --filter "until=168h" > /dev/null || true
echo "deployed ${TAG}"
