#!/usr/bin/env bash
# Tests for scripts/deploy.sh, using fake aws, docker and curl commands. They check what matters
# when deploying: the order of the steps, that a failed migration stops before anything is
# restarted, that a failed health check fails the deploy, and that secrets never reach the disk.
#
# deploy.sh needs Linux tools (bash, python3, flock), so run this in a container, from the repo root:
#   docker run --rm -v "$PWD:/repo:ro" python:3-slim bash /repo/scripts/tests/deploy.test.sh
# (From Git Bash on Windows, prefix with MSYS_NO_PATHCONV=1 and use "$(pwd -W)" in place of "$PWD".)

# SC2016 is intended here: several strings hold a literal "$" (a secret value, compose syntax).
# shellcheck disable=SC2016
set -uo pipefail

REPO="${REPO:-/repo}"
DEPLOY="$REPO/scripts/deploy.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# Values chosen to break naive handling: URL-special characters in the password, and shell-special
# characters in the JWT key.
export DB_PASSWORD='p@ss:w/rd#1&%'
export JWT_VALUE='jwt-$ecret"with!chars'
EXPECTED_URL='postgresql://pgadmin:p%40ss%3Aw%2Frd%231%26%25@db.test:5432/digital_wallet?sslmode=require'
REGISTRY="123456789012.dkr.ecr.ap-south-1.amazonaws.com"

# A fresh fake instance in a temp dir. deploy.sh reads APP_DIR (default /opt/app) for its files.
setup() {
  TMP=$(mktemp -d)
  export APP_DIR="$TMP/app" CALLS="$TMP/calls.log"
  BIN="$TMP/bin"
  mkdir -p "$APP_DIR" "$BIN"
  : > "$CALLS"
  unset FAIL_MIGRATE FAIL_HEALTH

  cat > "$APP_DIR/instance.env" <<'ENV'
REGION=ap-south-1
ACCOUNT_ID=123456789012
NAME_PREFIX=digital-wallet-staging
FRONTEND_PORT=80
BACKEND_PORT=8081
DB_HOST="db.test"
DB_PORT="5432"
DB_NAME="digital_wallet"
DB_SECRET_ARN="arn:aws:secretsmanager:ap-south-1:123456789012:secret:rds!db-abc-AbCdEf"
ENV

  cat > "$BIN/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >> "$CALLS"
case "$1 $2" in
  "ecr get-login-password") echo "ecr-token" ;;
  "secretsmanager get-secret-value")
    id=""
    while [ $# -gt 0 ]; do [ "$1" = "--secret-id" ] && id="$2"; shift; done
    case "$id" in
      *rds!db*)      printf '{"username":"pgadmin","password":"%s"}\n' "$DB_PASSWORD" ;;
      *-jwt-secret)  printf '%s\n' "$JWT_VALUE" ;;
      *) echo "unexpected secret: $id" >&2; exit 1 ;;
    esac ;;
  *) echo "unexpected aws call: $*" >&2; exit 1 ;;
esac
STUB

  cat > "$BIN/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $* | DATABASE_URL=${DATABASE_URL:-} | JWT=${JWT_SECRET_KEY:-}" >> "$CALLS"
case "$1" in
  login) cat > /dev/null ;;
  run) if [ "${FAIL_MIGRATE:-}" = 1 ]; then echo "P3009 migrate found failed migrations" >&2; exit 1; fi ;;
esac
exit 0
STUB

  cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS"
[ "${FAIL_HEALTH:-}" = 1 ] && exit 22
case "$*" in
  *"/api/health"*) echo '{"status":"ok"}' ;;
  *) echo '<html></html>' ;;
esac
STUB
  chmod +x "$BIN"/aws "$BIN"/docker "$BIN"/curl
}

# run_deploy <args...>: runs deploy.sh against the fake instance; sets OUT and RC.
run_deploy() { OUT=$(PATH="$BIN:$PATH" bash "$DEPLOY" "$@" 2>&1); RC=$?; }

line_of()    { grep -nF -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
called()     { grep -qF -- "$1" "$CALLS"; }
not_called() { ! grep -qF -- "$1" "$CALLS"; }
rc_is()      { [ "$RC" -eq "$1" ]; }
rc_not()     { [ "$RC" -ne "$1" ]; }
in_order() {   # in_order <needle> <needle> ...: each needle first appears after the previous one
  local prev=0 n
  for needle in "$@"; do
    n=$(line_of "$needle"); [ -n "$n" ] && [ "$n" -gt "$prev" ] || return 1
    prev=$n
  done
}
no_secrets_on_disk() { ! grep -rqF -e "$DB_PASSWORD" -e "$JWT_VALUE" -e 'p%40ss' "$APP_DIR"; }
compose_has_env() {   # compose_has_env <database-url> <jwt-key>: seen in the environment of "docker compose"
  grep -F "docker compose" "$CALLS" | grep -qF -- "| DATABASE_URL=$1 | JWT=$2"
}

BACKEND="$REGISTRY/digital-wallet-staging-backend:v1"
FRONTEND="$REGISTRY/digital-wallet-staging-frontend:v1"

echo "# happy path"
setup; run_deploy v1
check "exits 0" rc_is 0
check "reports the deployed tag" grep -q "deployed v1" <<< "$OUT"
check "steps run in order: login, pulls, migrate, remove placeholder, compose up" \
  in_order "docker login" "docker pull $BACKEND" "docker pull $FRONTEND" "prisma migrate deploy" "docker rm -f placeholder" "docker compose"
check "migrations run from the new backend image" called "$BACKEND node_modules/.bin/prisma migrate deploy"
check "DATABASE_URL is URL-encoded and ends with sslmode=require" called "DATABASE_URL=$EXPECTED_URL | JWT="
check "the secrets reach compose through the environment, unmangled" compose_has_env "$EXPECTED_URL" "$JWT_VALUE"
check "the JWT secret is read by name" called "--secret-id digital-wallet-staging-jwt-secret"
check "the database secret is read by ARN" called "--secret-id arn:aws:secretsmanager:ap-south-1:123456789012:secret:rds!db-abc-AbCdEf"
check "no secret value is written to disk" no_secrets_on_disk
check "compose file references the images through variables" grep -q 'image: ${BACKEND_IMAGE}' "$APP_DIR/docker-compose.yml"
check "compose file uses the ports from instance.env" grep -q '${BACKEND_PORT}' "$APP_DIR/docker-compose.yml"
check "the tag is recorded" grep -qx v1 "$APP_DIR/current-tag"
check "the backend is checked on its health route" called "/api/health"

echo "# a failed migration stops before anything is restarted"
setup; export FAIL_MIGRATE=1; run_deploy v1
check "exits non-zero" rc_not 0
check "the migration was attempted" called "prisma migrate deploy"
check "the running placeholder or app is not touched" not_called "docker rm -f placeholder"
check "containers are not restarted" not_called "docker compose"
check "no tag is recorded" test ! -e "$APP_DIR/current-tag"

echo "# a failed health check fails the deploy"
setup; export FAIL_HEALTH=1; run_deploy v1
check "exits non-zero" rc_not 0
check "no tag is recorded" test ! -e "$APP_DIR/current-tag"

echo "# input checks"
setup; run_deploy 'v1;rm -rf /'
check "an unsafe tag is refused with exit 2" rc_is 2
check "nothing is called for an unsafe tag" test ! -s "$CALLS"
setup; run_deploy
check "a missing tag is refused" rc_not 0

echo "# two deploys cannot overlap"
setup
( flock -n 9 && sleep 4 ) 9> "$APP_DIR/deploy.lock" &
sleep 1
run_deploy v1
check "a second deploy is refused while one holds the lock" rc_not 0
check "and says why" grep -q "another deploy" <<< "$OUT"
check "and does nothing" test ! -s "$CALLS"
wait

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
