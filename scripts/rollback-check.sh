#!/usr/bin/env bash
# Usage: rollback-check.sh <name-prefix> <image-tag>
#
# Checks, before anything is deployed, that a release can be rolled back to: that BOTH of its images,
# <name-prefix>-backend:<tag> and <name-prefix>-frontend:<tag>, are in ECR. deploy.sh pulls both, so a
# release that has only one would fail half way through the pulls, in an emergency, after the first
# instance was already touched.
#
# When an image is missing it says which, and lists the releases that ARE in that repository, newest
# first. The usual reasons are a typo, and a release that the lifecycle policy has expired (ECR keeps the
# last 10 images of each repository), and whoever reads the message is in a hurry.
#
# An AWS error (an expired login, a missing permission) is a failure and is never read as "not there"
# (scripts/ecr-tag-status.sh). The region and credentials come from the environment.
#
# Tests: scripts/tests/rollback-check.test.sh
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: rollback-check.sh <name-prefix> <image-tag>" >&2
  exit 2
fi

PREFIX="$1"
TAG="$2"
[[ "$PREFIX" =~ ^[a-z0-9-]+$ ]] || { echo "invalid name prefix: $PREFIX" >&2; exit 2; }
[[ "$TAG" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "invalid image tag: $TAG" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MISSING=0

for image in backend frontend; do
  repo="${PREFIX}-${image}"
  state=$("$HERE/ecr-tag-status.sh" "$repo" "$TAG")
  if [ "$state" != "present" ]; then
    MISSING=1
    echo "ERROR: ${repo}:${TAG} is not in ECR." >&2
    echo "Releases in ${repo}, newest first:" >&2
    # Best effort: the refusal does not depend on being able to list. The backticks are JMESPath's string
    # literal, not a shell command substitution.
    # shellcheck disable=SC2016
    aws ecr describe-images --repository-name "$repo" \
      --query 'reverse(sort_by(imageDetails[?imageTags], &imagePushedAt))[:10].[imagePushedAt, join(`, `, imageTags)]' \
      --output text 2>/dev/null | sed 's/\t/  /; s/^/  /' >&2 || true
  fi
done

if [ "$MISSING" -ne 0 ]; then
  echo "ECR keeps the last 10 images of each repository, so an older release may have expired." >&2
  exit 1
fi
echo "${TAG} is in ${PREFIX}-backend and ${PREFIX}-frontend"
