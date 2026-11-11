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
#   COLLATERAL       that instance was stopped by SSM ("Terminated", no output) because FAIL_INSTANCE failed
#                    first: SSM runs the instances in an order of its own, and with --max-errors 0 the first
#                    failure terminates the rest
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
  unset INSTANCES FAIL_INSTANCE COLLATERAL WAITER_TIMEOUTS NEVER_RUNS NO_TARGETS NO_TARGETS_SUCCESS OVERALL_FAILED LATE_LIST LAZY SEND_ERROR
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
    case "$(arg --query "$@")" in
      *StatusDetails*)
        for i in $(instances); do
          if [ "$i" = "${FAIL_INSTANCE:-}" ]; then printf '%s\tFailed\tFailed\n' "$i"
          elif [ "$i" = "${COLLATERAL:-}" ]; then printf '%s\tFailed\tTerminated\n' "$i"
          elif finished "$i"; then printf '%s\tSuccess\tSuccess\n' "$i"
          else printf '%s\tInProgress\tInProgress\n' "$i"; fi
        done
        exit 0 ;;
    esac
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
    if [ "$i" = "${COLLATERAL:-}" ]; then exit 255; fi
    if [ -n "${NEVER_RUNS:-}" ] || [ "$n" -le "${WAITER_TIMEOUTS:-0}" ]; then
      echo "Waiter CommandExecuted failed: Max attempts exceeded" >&2; exit 255
    fi
    touch "$STATE/done-$i" ;;
  "ssm get-command-invocation")
    i=$(arg --instance-id "$@")
    q=$(arg --query "$@")
    case "$q" in
      Status)
        if [ "$i" = "${FAIL_INSTANCE:-}" ] || [ "$i" = "${COLLATERAL:-}" ]; then echo "Failed"
        elif finished "$i"; then echo "Success"
        else echo "InProgress"; fi ;;
      StandardOutputContent)
        if [ "$i" = "${FAIL_INSTANCE:-}" ]; then echo "==> database migrations"; else echo "deployed ${TAG_UNDER_TEST:-abc1234} on $i"; fi ;;
      StandardErrorContent)
        if [ "$i" = "${FAIL_INSTANCE:-}" ]; then echo "migration failed: nothing was restarted"; fi ;;
      *) if [ "$i" = "${COLLATERAL:-}" ]; then printf 'Terminated\t-1\n'; else printf 'Failed\t1\n'; fi ;;
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

# remote_command: the shell command that was sent to the instances, out of the recorded send-command call.
remote_command() {
  python -I -c '
import json, re, sys
line = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"--parameters (\{.*\}) --max-concurrency", line)
print(json.loads(m.group(1))["commands"][0])
' "$CALLS"
}

# run_remote <app dir> [cloud-init exit status]: runs that command here, with the app directory moved to a
# temporary one, a fake cloud-init that logs its call and exits with the given status, and a stub deploy.sh
# (when the directory has one). The result is in RRC, and the order of the calls is in $TMP/remote.log.
run_remote() {
  local appdir="$1" ci_status="${2:-0}" cmd
  : > "$TMP/remote.log"
  mkdir -p "$TMP/rbin"
  printf '#!/usr/bin/env bash\necho "cloud-init $*" >> "%s/remote.log"\nexit %s\n' "$TMP" "$ci_status" > "$TMP/rbin/cloud-init"
  chmod +x "$TMP/rbin/cloud-init"
  cmd=$(remote_command | sed "s#/opt/app#${appdir}#g")
  ROUT=$(PATH="$TMP/rbin:$PATH" bash -c "$cmd" 2>&1); RRC=$?
}
make_deploy_stub() {
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\necho "deploy.sh $*" >> "%s/remote.log"\n' "$TMP" > "$1/deploy.sh"
  chmod +x "$1/deploy.sh"
}
remote_rc_is()  { [ "$RRC" -eq "$1" ]; }
remote_has()    { grep -qF -- "$1" <<< "$ROUT"; }
remote_log_is() { [ "$(cat "$TMP/remote.log")" = "$1" ]; }

echo "# one healthy instance"
setup; run_script staging abc1234
check "exits 0" rc_is 0
check "ends with deploy.sh and the tag on the instance" sent '; /opt/app/deploy.sh abc1234"]'
check "first waits for the instance to finish booting" sent 'cloud-init status --wait'
check "targets the environment tag" sent "Key=tag:environment,Values=staging"
check "targets the Role=app tag" sent "Key=tag:Role,Values=app"
check "uses the AWS-RunShellScript document" sent "--document-name AWS-RunShellScript"
check "asks for one instance at a time" sent "--max-concurrency 1"
check "asks to stop at the first error" sent "--max-errors 0"
check "limits how long deploy.sh may run on an instance" sent '"executionTimeout":["600"]'
check "waits with aws ssm wait command-executed" waited_on i-aaa
check "shows what deploy.sh printed" all_has "deployed abc1234 on i-aaa"
check "says it succeeded" all_has "deployed abc1234 to staging"

echo "# the command that runs on the instance"
# The first deploy to hit an instance that is still booting (its SSM agent is up and its tags are set, but
# user_data has not written /opt/app/deploy.sh yet) failed with "deploy.sh: not found", status 127.
setup; run_script staging abc1234
make_deploy_stub "$TMP/app"; run_remote "$TMP/app"
check "waits for cloud-init, then runs deploy.sh with the tag" remote_log_is $'cloud-init status --wait\ndeploy.sh abc1234'
check "and succeeds when deploy.sh does" remote_rc_is 0
setup; run_script staging abc1234
mkdir -p "$TMP/empty"; run_remote "$TMP/empty"
check "an instance that finished booting without deploy.sh fails" remote_rc_is 1
check "and says the boot did not finish, not 'not found'" remote_has "has not finished booting"
check "and points at the boot log" remote_has "cloud-init-output.log"
check "and runs nothing" remote_log_is "cloud-init status --wait"
setup; run_script staging abc1234
make_deploy_stub "$TMP/app"; run_remote "$TMP/app" 1
check "a cloud-init error elsewhere in the boot does not stop a deploy that can run" remote_log_is $'cloud-init status --wait\ndeploy.sh abc1234'

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

echo "# SSM runs the instances in its own order, and stops the rest at the first failure"
# Seen on staging: the instance that failed was not the one the script waited on first. The one it waited
# on was reported "Terminated", which was SSM stopping it after the other failed, and the real error was
# not shown.
setup; export INSTANCES="i-aaa i-bbb" FAIL_INSTANCE=i-bbb COLLATERAL=i-aaa; run_script staging abc1234
check "the run fails" rc_not 0
check "shows the output of the instance that really failed, though it was not the one waited on" all_has "migration failed: nothing was restarted"
check "names the instance that really failed" all_has "i-bbb: Failed (Failed)"
check "says the other one was stopped, and not that it failed" all_has "i-aaa: Failed (Terminated)"
check "does not print output for the instance SSM only stopped" all_lacks "stdout of i-aaa"
check "does not say it succeeded" all_lacks "deployed abc1234 to staging"

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
