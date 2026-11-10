#!/usr/bin/env bash
# Usage: deploy.sh <image-tag>
#
# Copied to /opt/app/deploy.sh on every instance by the launch template's user_data,
# and run there through SSM Run Command by the pipeline. This is a skeleton: it logs in
# to ECR and stops. The pipeline step fills in the rest.
set -euo pipefail

TAG="${1:?usage: deploy.sh <image-tag>}"
source /opt/app/instance.env          # REGION, ACCOUNT_ID, NAME_PREFIX (written by user_data)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

# TODO (pipeline step): read the database secret "${NAME_PREFIX}-db-credentials",
# render /opt/app/docker-compose.yml, then:
#   docker rm -f placeholder || true      # frees ports 80 and 8081
#   docker compose -f /opt/app/docker-compose.yml up -d
echo "deploy.sh is a skeleton: nothing deployed (tag ${TAG})"
