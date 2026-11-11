#!/usr/bin/env bash
# Tests for scripts/notify.sh, using a fake aws. What matters most:
#   - the e-mail says which jobs failed, on which branch or pull request, who triggered it, the commit and
#     the run URL, because that is what someone reading it on a phone needs;
#   - branch names, pull request branches and actor names are chosen by whoever opens the pull request, so
#     they must not be able to forge lines in the message or break the subject (SNS refuses a subject that
#     is longer than 100 characters, has a line break or is not printable ASCII);
#   - a notification that cannot be sent must FAIL, so a broken channel is seen and not silently lost.
#
# Run it in a container, from the repo root:
#   docker run --rm -v "$PWD:/repo:ro" python:3-slim bash /repo/scripts/tests/notify.test.sh
# (From Git Bash on Windows, prefix with MSYS_NO_PATHCONV=1 and use "$(pwd -W)" in place of "$PWD".)

# SC2016 is intended here: several strings hold a literal "$".
# shellcheck disable=SC2016
set -uo pipefail

REPO="${REPO:-/repo}"
SCRIPT="$REPO/scripts/notify.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

TOPIC="arn:aws:sns:ap-south-1:123456789012:digital-wallet-pipeline-alerts"

# A fresh fake aws that records what sns publish was asked to send. AWS_ERROR makes it fail.
setup() {
  TMP=$(mktemp -d)
  export CALLS="$TMP/calls.log" STATE="$TMP"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  : > "$CALLS"
  unset AWS_ERROR PR_NUMBER JOB_RESULTS IMAGE_TAG DEPLOYED_TO
  export TOPIC_ARN="$TOPIC" WORKFLOW="CI" REPOSITORY="octo/digital-wallet-devops" REF_NAME="feat/login" \
    EVENT_NAME="push" ACTOR="octocat" SHA="0123456789abcdef0123456789abcdef01234567" \
    RUN_URL="https://github.com/octo/digital-wallet-devops/actions/runs/42"
  cat > "$BIN/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >> "$CALLS"
[ "$1 $2" = "sns publish" ] || { echo "fake aws: unexpected call: $*" >&2; exit 99; }
if [ -n "${AWS_ERROR:-}" ]; then
  echo "An error occurred (${AWS_ERROR}) when calling the Publish operation: simulated" >&2; exit 254
fi
while [ $# -gt 0 ]; do
  case "$1" in
    --subject) printf '%s' "$2" > "$STATE/subject" ;;
    --message) printf '%s' "$2" > "$STATE/message" ;;
    --topic-arn) printf '%s' "$2" > "$STATE/topic" ;;
    --region) printf '%s' "$2" > "$STATE/region" ;;
  esac
  shift
done
echo "11111111-2222-3333-4444-555555555555"
STUB
  chmod +x "$BIN/aws"
}

failing_results() {
  export JOB_RESULTS=$'changes success\nlint failure\nunit-tests failure\nintegration-tests success\niac-checks skipped'
}

run_script() {
  OUT=$(PATH="$BIN:$PATH" bash "$SCRIPT" "$@" 2>"$TMP/err"); RC=$?
  ERR=$(cat "$TMP/err")
  ALL="$OUT"$'\n'"$ERR"
}

rc_is()        { [ "$RC" -eq "$1" ]; }
rc_not()       { [ "$RC" -ne "$1" ]; }
all_has()      { grep -qF -- "$1" <<< "$ALL"; }
published()    { [ -s "$TMP/subject" ]; }
subject()      { cat "$TMP/subject"; }
message()      { cat "$TMP/message"; }
subject_is()   { [ "$(subject)" = "$1" ]; }
subject_has()  { grep -qF -- "$1" "$TMP/subject"; }
subject_max()  { [ "$(wc -c < "$TMP/subject")" -le "$1" ]; }
message_has()  { grep -qF -- "$1" "$TMP/message"; }
message_lacks() { ! grep -qF -- "$1" "$TMP/message"; }
line_count()   { grep -c -- "$1" "$TMP/message"; }
publish_count() { grep -c -F -- "sns publish" "$CALLS"; }

echo "# a failed pipeline on a branch"
setup; failing_results; run_script failure
check "exits 0" rc_is 0
check "publishes once" test "$(publish_count)" -eq 1
check "to the topic, in the topic's region" test "$(cat "$TMP/topic") $(cat "$TMP/region")" = "$TOPIC ap-south-1"
check "the subject names the repository, the workflow, the failed jobs and the branch" subject_is "[digital-wallet-devops] CI failed: lint, unit-tests (feat/login)"
check "the message lists the failed jobs" message_has "Failed jobs: lint, unit-tests"
check "and every job with its result" message_has "  integration-tests: success"
check "and the skipped ones too" message_has "  iac-checks: skipped"
check "names the branch" message_has "Branch: feat/login"
check "names who triggered it, and how" message_has "Triggered by: octocat (push)"
check "gives the commit, short and as a link" message_has "Commit: 0123456789ab https://github.com/octo/digital-wallet-devops/commit/0123456789abcdef0123456789abcdef01234567"
check "gives the run URL" message_has "Run: https://github.com/octo/digital-wallet-devops/actions/runs/42"
check "has no pull request line when it is not one" message_lacks "Pull request:"

echo "# a failed pull request"
setup; failing_results; export EVENT_NAME=pull_request PR_NUMBER=12 REF_NAME="fix/typo"; run_script failure
check "the subject says which pull request" subject_is "[digital-wallet-devops] CI failed: lint, unit-tests (PR #12)"
check "the message has the pull request, with a link" message_has "Pull request: #12 https://github.com/octo/digital-wallet-devops/pull/12"
check "and the branch" message_has "Branch: fix/typo"

echo "# the subject always fits what SNS accepts"
setup; export JOB_RESULTS=$'image-build-scan failure\nintegration-tests failure\ndependency-scan failure\nsecret-scan failure\nscript-tests failure\nunit-tests failure'; run_script failure
check "a long list of failed jobs is cut to 100 characters" subject_max 100
check "and says it was cut" subject_has "..."
check "but the message still has every job" message_has "Failed jobs: image-build-scan, integration-tests, dependency-scan, secret-scan, script-tests, unit-tests"
setup; failing_results; export REF_NAME=$'feat/\xc3\xa9\nBcc: someone'; run_script failure
check "a branch name with a line break and a non-ASCII character leaves a one-line ASCII subject" test "$(subject | LC_ALL=C grep -c '^[ -~]*$')" -eq 1

echo "# nobody can forge lines in the message"
setup; failing_results; export REF_NAME=$'main\nRun: https://evil.example/login' ACTOR=$'octocat\nCommit: forged'; run_script failure
check "a branch name cannot add a Run line" test "$(line_count '^Run: ')" -eq 1
check "the real run URL is the one" message_has "Run: https://github.com/octo/digital-wallet-devops/actions/runs/42"
check "an actor name cannot add a Commit line" test "$(line_count '^Commit: ')" -eq 1

echo "# a failure with no failed job named"
setup; export JOB_RESULTS=$'lint cancelled\nunit-tests skipped'; run_script failure
check "is still sent" published
check "and does not pretend a job is named" message_has "Failed jobs: none reported"

echo "# a production deploy"
setup; export WORKFLOW="CD" EVENT_NAME=push REF_NAME=main IMAGE_TAG=3e8bbd8 DEPLOYED_TO=production; run_script deployed
check "exits 0" rc_is 0
check "the subject says what runs where" subject_is "[digital-wallet-devops] production now runs 3e8bbd8"
check "the message gives the tag, the commit and the run" message_has "Run: https://github.com/octo/digital-wallet-devops/actions/runs/42"
check "and does not talk about failures" message_lacks "Failed jobs"
setup; export IMAGE_TAG='3e8;rm' DEPLOYED_TO=production; run_script deployed
check "a tag with odd characters is refused with exit 2" rc_is 2
check "and nothing is sent" test "$(publish_count)" -eq 0

echo "# a notification that cannot be sent fails"
setup; failing_results; export AWS_ERROR=AccessDeniedException; run_script failure
check "an AWS error fails the run" rc_not 0
check "with AWS's message" all_has "AccessDeniedException"

echo "# usage"
setup; run_script
check "no kind is refused with exit 2" rc_is 2
check "and shows the usage" all_has "usage:"
setup; run_script explode
check "an unknown kind is refused with exit 2" rc_is 2
setup; failing_results; unset TOPIC_ARN; run_script failure
check "a missing TOPIC_ARN is refused with exit 2" rc_is 2
check "and names it" all_has "TOPIC_ARN"
setup; unset JOB_RESULTS; run_script failure
check "a failure notice without JOB_RESULTS is refused with exit 2" rc_is 2
setup; failing_results; export TOPIC_ARN="not-an-arn"; run_script failure
check "a topic that is not an SNS ARN is refused with exit 2" rc_is 2
check "and nothing is sent" test "$(publish_count)" -eq 0

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
