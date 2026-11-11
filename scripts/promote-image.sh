#!/usr/bin/env bash
# Usage: REGISTRY=<registry host> promote-image.sh <source-name-prefix> <target-name-prefix> <image-tag>
#
# Copies the two images of a release (<prefix>-backend and <prefix>-frontend, tag <image-tag>) from one
# environment's ECR repositories to another's, for example from digital-wallet-staging to
# digital-wallet-prod. The two environments have separate repositories, and production gets the image that
# passed staging and not a second build of the same commit, so what runs in production is exactly what
# was tested.
#
# - The copy is made inside the registry with "docker buildx imagetools create --prefer-index=false", and
#   the script then checks that both repositories report the same digest. Without the flag, a single
#   source image is wrapped in a new image index, which is a different image with a different digest
#   (found by trying it on staging): the flag makes it a carbon copy.
# - Nothing is copied unless every image that has to be copied exists in the source. A release that did
#   not pass staging is refused before anything reaches the target, so the target never holds a backend
#   of one release and no frontend.
# - An image that is already in the target is left alone. ECR tags are immutable, so a second push of the
#   tag would be rejected, and this makes a re-run of a deploy work.
# - An AWS error (an expired login, a missing permission) is a failure and not "not there"
#   (scripts/ecr-tag-status.sh).
#
# REGISTRY is the host, <account>.dkr.ecr.<region>.amazonaws.com, which aws-actions/amazon-ecr-login
# outputs. The caller has to be logged in to it, and the AWS region and credentials come from the
# environment, as for any aws command.
#
# Tests: scripts/tests/promote-image.test.sh
set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: REGISTRY=<registry host> promote-image.sh <source-name-prefix> <target-name-prefix> <image-tag>" >&2
  exit 2
fi

SOURCE_PREFIX="$1"
TARGET_PREFIX="$2"
TAG="$3"
[[ "$SOURCE_PREFIX" =~ ^[a-z0-9-]+$ && "$TARGET_PREFIX" =~ ^[a-z0-9-]+$ ]] \
  || { echo "invalid name prefix" >&2; exit 2; }
[[ "$TAG" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "invalid image tag: $TAG" >&2; exit 2; }
[ "$SOURCE_PREFIX" != "$TARGET_PREFIX" ] || { echo "the source and the target are the same environment: $SOURCE_PREFIX" >&2; exit 2; }
[ -n "${REGISTRY:-}" ] || {
  echo "REGISTRY is not set (the registry host, <account>.dkr.ecr.<region>.amazonaws.com)" >&2
  exit 2
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGES=(backend frontend)

# digest_of <repository>: the digest of the tag in that repository.
digest_of() {
  aws ecr describe-images --repository-name "$1" --image-ids "imageTag=${TAG}" \
    --query 'imageDetails[0].imageDigest' --output text
}

# Decide first, copy afterwards.
TO_COPY=()
for image in "${IMAGES[@]}"; do
  if [ "$("$HERE/ecr-tag-status.sh" "${TARGET_PREFIX}-${image}" "$TAG")" = "present" ]; then
    echo "${TARGET_PREFIX}-${image}:${TAG} is already in ECR, left as it is"
  else
    TO_COPY+=("$image")
  fi
done

MISSING=0
for image in ${TO_COPY[@]+"${TO_COPY[@]}"}; do
  if [ "$("$HERE/ecr-tag-status.sh" "${SOURCE_PREFIX}-${image}" "$TAG")" != "present" ]; then
    echo "ERROR: ${SOURCE_PREFIX}-${image}:${TAG} is not in ECR, so this release never passed ${SOURCE_PREFIX}." >&2
    MISSING=1
  fi
done
[ "$MISSING" -eq 0 ] || exit 1

for image in ${TO_COPY[@]+"${TO_COPY[@]}"}; do
  source_repo="${SOURCE_PREFIX}-${image}"
  target_repo="${TARGET_PREFIX}-${image}"
  echo "==> copying ${source_repo}:${TAG} to ${target_repo}:${TAG}"
  docker buildx imagetools create --prefer-index=false     --tag "${REGISTRY}/${target_repo}:${TAG}" "${REGISTRY}/${source_repo}:${TAG}"
  source_digest=$(digest_of "$source_repo")
  target_digest=$(digest_of "$target_repo")
  if [ "$source_digest" != "$target_digest" ]; then
    echo "ERROR: the copy is not the same image: the digest of ${source_repo} is ${source_digest} and of ${target_repo} ${target_digest}" >&2
    exit 1
  fi
  echo "${target_repo}:${TAG} has the digest ${target_digest}, the same as ${source_repo}"
done

echo "promoted ${TAG} from ${SOURCE_PREFIX} to ${TARGET_PREFIX}"
