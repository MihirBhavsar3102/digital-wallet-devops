#!/usr/bin/env bash
# Usage: ecr-tag-status.sh <repository> <tag>
#
# Prints "present" if the tag is in the ECR repository and "absent" if it is not, and exits 0 for both.
# The pipeline (cd.yml) asks this before building, because the repositories have immutable tags: a
# second push of the same commit's tag is rejected, so a re-run of a commit that was already pushed has
# to skip the push and not fail on it.
#
# Only "the image does not exist" counts as absent. Every other failure (an expired login, a missing
# permission, a repository that does not exist) stops here with AWS's message and prints nothing to
# stdout, because reading one of those as "absent" would send the pipeline on to a push that cannot
# work. The AWS region and credentials come from the environment, as for any aws command.
#
# Tests: scripts/tests/ecr-tag-status.test.sh
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: ecr-tag-status.sh <repository> <tag>" >&2
  exit 2
fi

REPOSITORY="$1"
TAG="$2"
# The characters Docker allows in a tag, the same check deploy.sh makes.
[[ "$TAG" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "invalid image tag: $TAG" >&2; exit 2; }

if OUTPUT=$(aws ecr describe-images --repository-name "$REPOSITORY" --image-ids "imageTag=$TAG" \
    --query 'imageDetails[0].imageDigest' --output text 2>&1); then
  echo "present"
elif [[ "$OUTPUT" == *ImageNotFoundException* ]]; then
  echo "absent"
else
  echo "$OUTPUT" >&2
  exit 1
fi
