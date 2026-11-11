#!/usr/bin/env bash
# Usage: smoke-test.sh <base-url> [api-base-url]
#
# Checks that the deployed app answers: the frontend serves the app's page, and the backend's
# /api/health reports ok. Both are retried, because a freshly deployed app takes a few seconds.
#
# The checks look at what comes back, not just at the status code. The first-boot placeholder also
# answers 200 on / and on /api, so a status-only check would pass before any real deploy.
#
# <base-url>      the load balancer, e.g. http://digital-wallet-staging-alb-123.ap-south-1.elb.amazonaws.com
# [api-base-url]  only when the backend is on another address (local compose: the frontend is on
#                 :8080 and the backend on :8081). Defaults to <base-url>.
#
# SMOKE_RETRIES (default 20) and SMOKE_DELAY in seconds (default 5) set how long to keep trying.
# Tests: scripts/tests/smoke-test.test.sh
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: smoke-test.sh <base-url> [api-base-url]" >&2
  exit 2
fi

BASE="${1%/}"
API="${2:-$1}"
API="${API%/}"
RETRIES="${SMOKE_RETRIES:-20}"
DELAY="${SMOKE_DELAY:-5}"

# retry <name> <command...>: run the command until it succeeds or the attempts run out.
retry() {
  local name="$1" attempt
  shift
  for ((attempt = 1; attempt <= RETRIES; attempt++)); do
    if "$@" > /dev/null 2>&1; then
      echo "PASS ${name} (attempt ${attempt})"
      return 0
    fi
    echo "wait ${name} (${attempt}/${RETRIES})"
    if [ "$attempt" -lt "$RETRIES" ]; then sleep "$DELAY"; fi
  done
  echo "FAIL ${name}" >&2
  return 1
}

# The two check functions are called by name through retry, which shellcheck cannot see.
# shellcheck disable=SC2329
# The Vite build's index.html has this element; the placeholder page does not.
frontend_ok() { curl -fsS --max-time 5 "$BASE/" | grep -qi '<div id="root"'; }

# The backend answers {"status":"ok"}; the placeholder answers the text "placeholder ok".
# shellcheck disable=SC2329
health_ok() {
  local body
  body=$(curl -fsS --max-time 5 "$API/api/health") && [[ "$body" == *'"status":"ok"'* ]]
}

# Run both checks even if the first one fails, so one run reports everything that is wrong.
status=0
retry frontend frontend_ok || status=1
retry backend-health health_ok || status=1
exit "$status"
