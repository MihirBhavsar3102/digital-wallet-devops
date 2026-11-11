#!/usr/bin/env bash
# Tests for scripts/ssm-deploy.sh, using a fake aws. The checks that matter most:
#   - a deploy that reaches no instance must FAIL (SSM itself reports success for a command whose tags
#     match nothing, with TargetCount 0, so a stopped environment would otherwise "deploy" fine),
#   - a failure on one instance fails the run, prints that instance's output and does not go on,
#   - a deploy that takes longer than the AWS CLI waiter's 100 seconds is waited for, not failed,
#   - the command asks SSM for one instance at a time and to stop at the first error.
#
# Run it in a container, from the repo root:
#   docker run --rm -v "$PWD:/repo:ro" python:3-slim bash /repo/scripts/tests/ssm-deploy.test.sh
# (From Git Bash on Windows, prefix with MSYS_NO_PATHCONV=1 and use "$(pwd -W)" in place of "$PWD".)

# SC2016 is intended here: several strings hold a literal "$" or JSON.
# shellcheck disable=SC2016
set -uo pipefail

REPO="${REPO:-/repo}"
SCRIPT="$REPO/scripts/ssm-deploy.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# A fresh fake aws. The scenario is set with environment variables, set after setup:
#   INSTANCES        the instances the command reaches (default "i-aaa")
#   FAIL_INSTANCE    that instance's deploy fails (exit 1 on the instance, with output on stderr)
#   WAITER_TIMEOUTS  the first N waits on an instance end like the real waiter's "max attempts exceeded"
#                    (exit 255) while the command is still InProgress
#   NEVER_RUNS       always InProgress (never finishes)
#   NO_TARGETS       the tags match nothing: no invocations, and the command stays Pending
#   NO_TARGETS_SUCCESS  with NO_TARGETS: SSM reports the empty command as Success
#   OVERALL_FAILED   the command as a whole ends Failed, whatever the instances we saw reported
#   LATE_LIST        the first N list-command-invocations calls return nothing yet
#   LAZY             the second instance's invocation only exists once the first one has finished
#   SEND_ERROR       send-command fails with AccessDeniedException
setup() {
  TMP=$(mktemp -d)
  export CALLS="$TMP/calls.log" STATE="$TMP/state"
  BIN="$TMP/bin"
  mkdir -p "$BIN" "$STATE"
  : > "$CALLS"
  unset INSTANCES FAIL_INSTANCE WAITER_TIMEOUTS NEVER_RUNS NO_TARGETS NO_TARGETS_SUCCESS OVERALL_FAILED LATE_LIST LAZY SEND_ERROR
  export POLL_DELAY=0 DEPLOY_TIMEOUT=5 NO_TARGET_GRACE=2

  cat > "$BIN/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >> "$CALLS"
instances() { echo "${INSTANCES:-i-aaa}"; }
first() { instances | awk '{print $1}'; }
arg() { local k="$1"; shift; while [ $# -gt 0 ]; do [ "$1" = "$k" ] && { echo "$2"; return; }; shift; done; }
count() { local f="$STATE/$1"; local n; n=$(cat "$f" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$f"; echo "$n"; }
finished() { [ -e "$STATE/done-$1" ]; }

case "$1 $2" in
  "ssm send-command")
    if [ -n "${SEND_ERROR:-}" ]; then
      echo "An error occurred (AccessDeniedException) when calling the SendCommand operation: simulated" >&2; exit 254
    fi
    echo "cmd-1" ;;
  "ssm list-command-invocations")
    n=$(count list)
    [ -n "${NO_TARGETS:-}" ] && exit 0
    [ "$n" -le "${LATE_LIST:-0}" ] && exit 0
    if [ -n "${LAZY:-}" ]; then
      f=$(first)
      if finished "$f"; then instances | tr ' ' '\t'; echo; else echo "$f"; fi
    else
      instances | tr ' ' '\t'; echo
    fi ;;
  "ssm list-commands")
    if [ -n "${OVERALL_FAILED:-}" ]; then echo "Failed"; exit 0; fi
    if [ -n "${NO_TARGETS_SUCCESS:-}" ]; then echo "Success"; exit 0; fi
    if [ -n "${NO_TARGETS:-}" ] || [ -n "${NEVER_RUNS:-}" ]; then echo "Pending"; exit 0; fi
    for i in $(instances); do
      if [ "$i" = "${FAIL_INSTANCE:-}" ] && finished "$i"; then echo "Failed"; exit 0; fi
    done
    all=1; for i in $(instances); do finished "$i" || all=0; done
    if [ "$all" = 1 ]; then echo "Success"; else echo "InProgress"; fi ;;
  "ssm wait")
    i=$(arg --instance-id "$@")
    n=$(count "wait-$i")
    if [ "$i" = "${FAIL_INSTANCE:-}" ]; then touch "$STATE/done-$i"; exit 255; fi
    if [ -n "${NEVER_RUNS:-}" ] || [ "$n" -le "${WAITER_TIMEOUTS:-0}" ]; then
      echo "Waiter CommandExecuted failed: Max attempts exceeded" >&2; exit 255
    fi
    touch "$STATE/done-$i" ;;
  "ssm get-command-invocation")
    i=$(arg --instance-id "$@")
    q=$(arg --query "$@")
    case "$q" in
      Status)
        if [ "$i" = "${FAIL_INSTANCE:-}" ]; then echo "Failed"
        elif finished "$i"; then echo "Success"
        else echo "InProgress"; fi ;;
      StandardOutputContent)
        if [ "$i" = "${FAIL_INSTANCE:-}" ]; then echo "==> database migrations"; else echo "deployed ${TAG_UNDER_TEST:-abc1234} on $i"; fi ;;
      StandardErrorContent)
        if [ "$i" = "${FAIL_INSTANCE:-}" ]; then echo "migration failed: nothing was restarted"; fi ;;
      *) echo "Failed	1" ;;
    esac ;;
  *) echo "fake aws: unexpected call: $*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$BIN/aws"
}

run_script() {
  OUT=$(PATH="$BIN:$PATH" bash "$SCRIPT" "$@" 2>"$TMP/err"); RC=$?
  ERR=$(cat "$TMP/err")
  ALL="$OUT"$'\n'"$ERR"
}

rc_is()      { [ "$RC" -eq "$1" ]; }
rc_not()     { [ "$RC" -ne "$1" ]; }
all_has()    { grep -qF -- "$1" <<< "$ALL"; }
all_lacks()  { ! grep -qF -- "$1" <<< "$ALL"; }
sent()       { grep -F -- "ssm send-command" "$CALLS" | grep -qF -- "$1"; }
sent_count() { grep -c -F -- "ssm send-command" "$CALLS"; }
waited_on()  { grep -F -- "ssm wait command-executed" "$CALLS" | grep -qF -- "--instance-id $1"; }
not_waited() { ! waited_on "$1"; }
no_waits()   { ! grep -qF -- "ssm wait" "$CALLS"; }

echo "# one healthy instance"
setup; run_script staging abc1234
check "exits 0" rc_is 0
check "runs deploy.sh with the tag on the instance" sent '"commands":["/opt/app/deploy.sh abc1234"]'
check "targets the environment tag" sent "Key=tag:environment,Values=staging"
check "targets the Role=app tag" sent "Key=tag:Role,Values=app"
check "uses the AWS-RunShellScript document" sent "--document-name AWS-RunShellScript"
check "asks for one instance at a time" sent "--max-concurrency 1"
check "asks to stop at the first error" sent "--max-errors 0"
check "limits how long deploy.sh may run on an instance" sent '"executionTimeout":["600"]'
check "waits with aws ssm wait command-executed" waited_on i-aaa
check "shows what deploy.sh printed" all_has "deployed abc1234 on i-aaa"
check "says it succeeded" all_has "deployed abc1234 to staging"

echo "# two instances, one at a time"
setup; export INSTANCES="i-aaa i-bbb"; run_script prod abc1234
check "exits 0" rc_is 0
check "waits on the first" waited_on i-aaa
check "waits on the second" waited_on i-bbb
check "targets the prod environment tag" sent "Key=tag:environment,Values=prod"
check "sends one command, not one per instance" test "$(sent_count)" -eq 1
setup; export INSTANCES="i-aaa i-bbb" LAZY=1; run_script staging abc1234
check "an invocation that only appears later is still waited for" waited_on i-bbb
check "and the run still succeeds" rc_is 0

echo "# a failure stops the run"
setup; export INSTANCES="i-aaa i-bbb" FAIL_INSTANCE=i-aaa; run_script staging abc1234
check "the run fails" rc_not 0
check "prints the failing instance's stdout" all_has "==> database migrations"
check "prints the failing instance's stderr" all_has "migration failed: nothing was restarted"
check "names the instance" all_has "i-aaa"
check "does not go on to the second instance" not_waited i-bbb
check "does not say it succeeded" all_lacks "deployed abc1234 to staging"
setup; export INSTANCES="i-aaa i-bbb" FAIL_INSTANCE=i-bbb; run_script staging abc1234
check "a failure on the second instance fails the run too" rc_not 0
check "after the first one succeeded" waited_on i-aaa

echo "# a deploy that reaches no instance fails"
setup; export NO_TARGETS=1; run_script staging abc1234
check "no matching instance is a failure" rc_not 0
check "that says what to look at" all_has "no instance"
check "and names the tags" all_has "environment=staging"
setup; export NO_TARGETS=1 NO_TARGETS_SUCCESS=1; run_script staging abc1234
check "an empty command that SSM calls a success is still a failure" rc_not 0
check "that says what to look at" all_has "no instance"
check "and does not say it deployed" all_lacks "deployed abc1234 to staging"
setup; export LATE_LIST=2; run_script staging abc1234
check "invocations that take a moment to appear are waited for" rc_is 0

echo "# the command as a whole"
setup; export OVERALL_FAILED=1; run_script staging abc1234
check "a command that SSM ends as Failed fails the run, even if the instances we saw looked fine" rc_not 0
check "and says so" all_has "ended with status Failed"

echo "# slow deploys"
setup; export WAITER_TIMEOUTS=3; run_script staging abc1234
check "a deploy longer than one waiter round is waited for" rc_is 0
check "by waiting again" test "$(grep -c -F -- 'ssm wait command-executed' "$CALLS")" -eq 4
setup; export NEVER_RUNS=1 DEPLOY_TIMEOUT=2 POLL_DELAY=1; run_script staging abc1234
check "a deploy that never finishes fails at the deadline" rc_not 0
check "and says it timed out" all_has "did not finish"

echo "# AWS errors"
setup; export SEND_ERROR=1; run_script staging abc1234
check "a failed send-command fails the run" rc_not 0
check "with AWS's message" all_has "AccessDeniedException"
check "and waits for nothing" no_waits

echo "# usage"
setup; run_script
check "no arguments is refused with exit 2" rc_is 2
check "and shows the usage" all_has "usage:"
setup; run_script staging
check "a missing tag is refused with exit 2" rc_is 2
setup; run_script staging 'abc;rm -rf /'
check "a tag with characters Docker does not allow is refused with exit 2" rc_is 2
check "and sends nothing" test "$(sent_count)" -eq 0
setup; run_script 'staging" ; x' abc1234
check "an environment with odd characters is refused with exit 2" rc_is 2
check "and sends nothing" test "$(sent_count)" -eq 0

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
