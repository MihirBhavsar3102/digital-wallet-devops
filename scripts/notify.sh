#!/usr/bin/env bash
# Usage: notify.sh <failure|deployed>
#
# Sends one e-mail about a pipeline run, by publishing to the SNS topic that has the e-mail subscription
# (infra/bootstrap). The workflows call it through .github/actions/notify:
#   failure   a job of the workflow failed: names the failed jobs and lists every job's result
#   deployed  a release reached an environment (production): names the tag
#
# The environment says what happened. All of it is required unless it says otherwise:
#   TOPIC_ARN     the SNS topic
#   WORKFLOW      the workflow's name, e.g. CI
#   REPOSITORY    owner/name
#   REF_NAME      the branch (for a pull request, the pull request's branch)
#   EVENT_NAME    push, pull_request, workflow_dispatch
#   PR_NUMBER     optional: the pull request's number
#   ACTOR         who triggered the run
#   SHA           the commit
#   RUN_URL       the run's page
#   JOB_RESULTS   (failure) one "<job> <result>" per line, from the "needs" of the notify job
#   IMAGE_TAG     (deployed) the release's tag
#   DEPLOYED_TO   (deployed) the environment, e.g. production
# The AWS credentials come from the environment, as for any aws command; the region is the topic's.
#
# Two things matter here:
# - Branch names, pull request branches and actor names are chosen by whoever opens the pull request.
#   Line breaks and control characters are replaced before they go into the message, so they cannot forge
#   a line such as "Run: <their link>", and the subject (which SNS limits to 100 characters of printable
#   ASCII on one line) is made safe and cut to fit.
# - A notification that cannot be sent is a failure of this script, so that a broken channel is seen.
#
# Tests: scripts/tests/notify.test.sh
set -euo pipefail

usage() {
  echo "usage: notify.sh <failure|deployed>   (the details come from the environment, see the top of the script)" >&2
  exit 2
}

KIND="${1:-}"
case "$KIND" in
  failure | deployed) ;;
  *) usage ;;
esac

require() {
  local name
  for name in "$@"; do
    [ -n "${!name:-}" ] || { echo "$name is not set" >&2; exit 2; }
  done
}
require TOPIC_ARN WORKFLOW REPOSITORY REF_NAME EVENT_NAME ACTOR SHA RUN_URL
if [ "$KIND" = failure ]; then
  require JOB_RESULTS
else
  require IMAGE_TAG DEPLOYED_TO
fi

PR_NUMBER="${PR_NUMBER:-}"
[[ "$TOPIC_ARN" =~ ^arn:aws:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$ ]] || { echo "TOPIC_ARN is not an SNS topic ARN: $TOPIC_ARN" >&2; exit 2; }
[[ "$REPOSITORY" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "invalid REPOSITORY: $REPOSITORY" >&2; exit 2; }
[[ "$SHA" =~ ^[0-9a-f]{7,64}$ ]] || { echo "invalid SHA: $SHA" >&2; exit 2; }
[[ "$RUN_URL" =~ ^https://[A-Za-z0-9./_-]+$ ]] || { echo "invalid RUN_URL: $RUN_URL" >&2; exit 2; }
[[ "$EVENT_NAME" =~ ^[a-z_]+$ ]] || { echo "invalid EVENT_NAME: $EVENT_NAME" >&2; exit 2; }
[[ -z "$PR_NUMBER" || "$PR_NUMBER" =~ ^[0-9]+$ ]] || { echo "invalid PR_NUMBER: $PR_NUMBER" >&2; exit 2; }
if [ "$KIND" = deployed ]; then
  [[ "$IMAGE_TAG" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "invalid IMAGE_TAG: $IMAGE_TAG" >&2; exit 2; }
  [[ "$DEPLOYED_TO" =~ ^[a-z0-9-]+$ ]] || { echo "invalid DEPLOYED_TO: $DEPLOYED_TO" >&2; exit 2; }
fi

REGION=$(cut -d: -f4 <<< "$TOPIC_ARN")
REPO_NAME="${REPOSITORY##*/}"

# clean <text>: one line, with no control characters.
clean() { printf '%s' "$1" | LC_ALL=C tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177'; }
# ascii <text>: printable ASCII only, anything else becomes "?".
ascii() { printf '%s' "$1" | LC_ALL=C tr -c ' -~' '?'; }

# REF_NAME comes from the environment (checked by require above), which shellcheck cannot see.
# shellcheck disable=SC2153
REF_CLEAN=$(clean "$REF_NAME")
ACTOR_CLEAN=$(clean "$ACTOR")
WORKFLOW_CLEAN=$(clean "$WORKFLOW")
if [ -n "$PR_NUMBER" ]; then
  LABEL="PR #${PR_NUMBER}"
else
  LABEL="$REF_CLEAN"
fi

if [ "$KIND" = failure ]; then
  FAILED=()
  JOB_LINES=""
  while read -r job result _; do
    [ -n "$job" ] || continue
    job=$(clean "$job")
    result=$(clean "$result")
    JOB_LINES+="  ${job}: ${result}"$'\n'
    if [ "$result" = failure ]; then
      FAILED+=("$job")
    fi
  done <<< "$JOB_RESULTS"
  FAILED_LIST=""
  if [ "${#FAILED[@]}" -gt 0 ]; then
    printf -v FAILED_LIST '%s, ' "${FAILED[@]}"
    FAILED_LIST="${FAILED_LIST%, }"
    SUBJECT="[${REPO_NAME}] ${WORKFLOW_CLEAN} failed: ${FAILED_LIST} (${LABEL})"
  else
    SUBJECT="[${REPO_NAME}] ${WORKFLOW_CLEAN} failed (${LABEL})"
  fi
  HEADLINE="${WORKFLOW_CLEAN} failed."
  DETAIL="Failed jobs: ${FAILED_LIST:-none reported}

Jobs:
${JOB_LINES}"
else
  SUBJECT="[${REPO_NAME}] ${DEPLOYED_TO} now runs ${IMAGE_TAG}"
  HEADLINE="${DEPLOYED_TO} now runs ${IMAGE_TAG}."
  DETAIL=""
fi

SUBJECT=$(ascii "$SUBJECT")
if [ "${#SUBJECT}" -gt 100 ]; then
  SUBJECT="${SUBJECT:0:97}..."
fi

MESSAGE="${HEADLINE}

${DETAIL}"
[ -z "$DETAIL" ] || MESSAGE+=$'\n'
MESSAGE+="Repository: ${REPOSITORY}"$'\n'
if [ -n "$PR_NUMBER" ]; then
  MESSAGE+="Pull request: #${PR_NUMBER} https://github.com/${REPOSITORY}/pull/${PR_NUMBER}"$'\n'
fi
MESSAGE+="Branch: ${REF_CLEAN}"$'\n'
MESSAGE+="Triggered by: ${ACTOR_CLEAN} (${EVENT_NAME})"$'\n'
MESSAGE+="Commit: ${SHA:0:12} https://github.com/${REPOSITORY}/commit/${SHA}"$'\n'
MESSAGE+="Run: ${RUN_URL}"

MESSAGE_ID=$(aws sns publish --region "$REGION" --topic-arn "$TOPIC_ARN" \
  --subject "$SUBJECT" --message "$MESSAGE" --query MessageId --output text)
echo "sent \"${SUBJECT}\" to ${TOPIC_ARN} (message ${MESSAGE_ID})"
