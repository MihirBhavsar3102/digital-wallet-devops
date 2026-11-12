#!/usr/bin/env bash
# Tests for monitoring/cloudwatch-agent.json, the CloudWatch agent's configuration.
#
# The file is a Terraform template: ${syslog_log_group} and ${auth_log_group} are filled in by templatefile(),
# and the agent's own variables are written $${aws:...} so that Terraform leaves them alone. This test renders
# the file the way Terraform does, reads the result as JSON, and checks the things the dashboards and alarms
# depend on: a wrong dimension or a wrong metric name would not fail anything until a dashboard stayed empty.
#
# Run it in a container, from the repo root:
#   docker run --rm -v "$PWD:/repo:ro" python:3-slim bash /repo/scripts/tests/agent-config.test.sh
# (From Git Bash on Windows, prefix with MSYS_NO_PATHCONV=1 and use "$(pwd -W)" in place of "$PWD".)

# SC2016 is intended here: the sed and python programs hold a literal "$".
# shellcheck disable=SC2016
set -uo pipefail

REPO="${REPO:-/repo}"
CONFIG="${CONFIG:-$REPO/monitoring/cloudwatch-agent.json}"   # CONFIG is overridden only to try a broken copy
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# What templatefile() would produce, with test values for the two log groups.
render() {
  sed -e 's|\${syslog_log_group}|/test/syslog|g' \
      -e 's|\${auth_log_group}|/test/auth|g' \
      -e 's|\$\${|${|g' "$CONFIG"
}

# True when the python expression holds for the rendered configuration, available as c.
holds() { render | python3 -c 'import json, sys; c = json.load(sys.stdin); sys.exit(0 if ('"$1"') else 1)' 2> /dev/null; }

check "the file exists" test -f "$CONFIG"
check "it renders to valid JSON" holds 'True'

# Anything still written ${...} after rendering must be one of the agent's own variables.
# (The file must exist: without that, "found nothing wrong" would pass on a missing file.)
check "only the agent's own variables are left after rendering" bash -c '
  test -f "$0" && ! { sed -e "s|\${syslog_log_group}|x|g" -e "s|\${auth_log_group}|x|g" -e "s|\$\${|@AGENT@{|g" "$0" | grep -q "\${"; }' "$CONFIG"

check "every value is collected every 60 seconds" holds 'c["agent"]["metrics_collection_interval"] == 60'
check "metrics go to the CWAgent namespace" holds 'c["metrics"]["namespace"] == "CWAgent"'
check "metrics carry the Auto Scaling group name, and nothing else, as their dimension" \
  holds 'c["metrics"]["append_dimensions"] == {"AutoScalingGroupName": "${aws:AutoScalingGroupName}"}'
check "disk is rolled up to the group name alone, so one alarm dimension fits every instance" \
  holds 'c["metrics"]["aggregation_dimensions"] == [["AutoScalingGroupName"]]'
check "it collects cpu, memory and disk, and nothing more" \
  holds 'set(c["metrics"]["metrics_collected"]) == {"cpu", "mem", "disk"}'
check "memory is reported as a percentage" holds 'c["metrics"]["metrics_collected"]["mem"]["measurement"] == ["used_percent"]'
check "disk is reported as a percentage" holds 'c["metrics"]["metrics_collected"]["disk"]["measurement"] == ["used_percent"]'
check "disk is limited to the root filesystem" holds 'c["metrics"]["metrics_collected"]["disk"]["resources"] == ["/"]'

check "syslog and auth.log go to their own log groups" holds '
  {e["file_path"]: e["log_group_name"] for e in c["logs"]["logs_collected"]["files"]["collect_list"]}
  == {"/var/log/syslog": "/test/syslog", "/var/log/auth.log": "/test/auth"}'
check "the log stream is named after the instance" holds '
  all(e["log_stream_name"] == "{instance_id}" for e in c["logs"]["logs_collected"]["files"]["collect_list"])'
# Terraform owns the retention. If the agent also set one and the two ever differed, the agent would stop.
check "the agent does not set a retention period" bash -c 'test -f "$0" && ! grep -q retention_in_days "$0"' "$CONFIG"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
