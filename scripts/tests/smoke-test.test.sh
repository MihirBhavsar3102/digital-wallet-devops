#!/usr/bin/env bash
# Tests for scripts/smoke-test.sh, using a fake curl. The check that matters most: the smoke test must
# not pass against the first-boot placeholder, which also answers 200 on /api, so it has to look at what
# comes back and not only at the status code.
#
# Run it in a container, from the repo root:
#   docker run --rm -v "$PWD:/repo:ro" python:3-slim bash /repo/scripts/tests/smoke-test.test.sh
# (From Git Bash on Windows, prefix with MSYS_NO_PATHCONV=1 and use "$(pwd -W)" in place of "$PWD".)

# SC2016 is intended here: several strings hold a literal "$" or JSON.
# shellcheck disable=SC2016
set -uo pipefail

REPO="${REPO:-/repo}"
SMOKE="$REPO/scripts/smoke-test.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# A fresh fake curl. It answers by URL: anything ending /api/health is the backend, the rest the frontend.
setup() {
  TMP=$(mktemp -d)
  export CALLS="$TMP/calls.log" COUNT_FILE="$TMP/health-count"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  : > "$CALLS"
  rm -f "$COUNT_FILE"
  unset HEALTH_BODY HEALTH_STATUS HEALTH_FAILS_FIRST FRONTEND_BODY FRONTEND_DOWN
  export SMOKE_RETRIES=3 SMOKE_DELAY=0

  cat > "$BIN/curl" <<'STUB'
#!/usr/bin/env bash
url="${*: -1}"
echo "curl $url" >> "$CALLS"
case "$url" in
  */api/health)
    n=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
    echo $((n + 1)) > "$COUNT_FILE"
    [ "$n" -lt "${HEALTH_FAILS_FIRST:-0}" ] && exit 7           # connection refused while starting
    [ "${HEALTH_STATUS:-200}" != 200 ] && exit 22               # curl -f on an HTTP error
    body="${HEALTH_BODY:-}"; [ -z "$body" ] && body='{"status":"ok"}'
    printf '%s' "$body" ;;
  *)
    [ "${FRONTEND_DOWN:-}" = 1 ] && exit 7
    body="${FRONTEND_BODY:-}"; [ -z "$body" ] && body='<!doctype html><html><body><div id="root"></div></body></html>'
    printf '%s' "$body" ;;
esac
STUB
  chmod +x "$BIN/curl"
}

run_smoke() { OUT=$(PATH="$BIN:$PATH" bash "$SMOKE" "$@" 2>&1); RC=$?; }

called()       { grep -qxF -- "curl $1" "$CALLS"; }
not_called()   { ! grep -qxF -- "curl $1" "$CALLS"; }
health_calls() { grep -c '/api/health$' "$CALLS"; }
rc_is()        { [ "$RC" -eq "$1" ]; }
rc_not()       { [ "$RC" -ne "$1" ]; }
out_has()      { grep -qF -- "$1" <<< "$OUT"; }

echo "# a healthy app passes"
setup; run_smoke http://app.test
check "exits 0" rc_is 0
check "checks the frontend at the root" called "http://app.test/"
check "checks the backend on /api/health" called "http://app.test/api/health"
check "reports both checks as passed" out_has "PASS backend-health"

echo "# addresses"
setup; run_smoke http://app.test/
check "a trailing slash is not doubled" called "http://app.test/api/health"
setup; run_smoke http://front.test http://api.test
check "the frontend is checked on the first address" called "http://front.test/"
check "the backend is checked on the second address" called "http://api.test/api/health"
check "the backend is not checked on the frontend address" not_called "http://front.test/api/health"

echo "# it must not pass against the wrong thing"
setup; export HEALTH_BODY='placeholder ok'; run_smoke http://app.test
check "the first-boot placeholder's /api answer fails the backend check" rc_not 0
setup; export HEALTH_BODY='{"status":"error"}'; run_smoke http://app.test
check "a health answer that is not ok fails" rc_not 0
setup; export HEALTH_STATUS=401; run_smoke http://app.test
check "a 401 from the health route fails" rc_not 0
setup; export FRONTEND_BODY='<h1>Digital Wallet: placeholder</h1>'; run_smoke http://app.test
check "a page without the app's root element fails the frontend check" rc_not 0

echo "# retries"
setup; export HEALTH_FAILS_FIRST=2; run_smoke http://app.test
check "an app that is still starting passes once it answers" rc_is 0
check "and says on which attempt" out_has "PASS backend-health (attempt 3)"
setup; export HEALTH_FAILS_FIRST=99; run_smoke http://app.test
check "an app that never answers fails" rc_not 0
check "after exactly SMOKE_RETRIES attempts" test "$(health_calls)" -eq 3
check "and names what failed" out_has "FAIL backend-health"

echo "# both checks always run"
setup; export FRONTEND_DOWN=1; run_smoke http://app.test
check "a dead frontend fails the run" rc_not 0
check "but the backend is still checked and reported" out_has "PASS backend-health"

echo "# usage"
setup; run_smoke
check "no address is refused with exit 2" rc_is 2
check "and shows the usage" out_has "usage:"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
