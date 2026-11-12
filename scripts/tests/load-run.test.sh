#!/usr/bin/env bash
# Tests for scripts/load/run.sh, using a fake docker. What matters: bad input is refused before anything is
# started (a typo must not turn into a long run against the wrong address), the image is the pinned one, every
# setting reaches k6 as an environment variable, the script is the one in the repository, and the background
# mode creates, fills and starts a container (a background container cannot read the script from stdin).
#
# Run it in a container, from the repo root:
#   docker run --rm -v "$PWD:/repo:ro" python:3-slim bash /repo/scripts/tests/load-run.test.sh
# (From Git Bash on Windows, prefix with MSYS_NO_PATHCONV=1 and use "$(pwd -W)" in place of "$PWD".)

# SC2016 is intended here: the bash -c programs are single-quoted so that they, not this shell, expand "$1".
# shellcheck disable=SC2016
set -uo pipefail

REPO="${REPO:-/repo}"
RUN="$REPO/scripts/load/run.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# A fresh fake docker. It records every call, keeps what "docker run" was given on stdin, and answers
# "docker create" with a container name.
setup() {
  TMP=$(mktemp -d)
  export CALLS="$TMP/calls.log" STDIN_COPY="$TMP/stdin.txt"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  : > "$CALLS"
  unset DETACH
  cat > "$BIN/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$CALLS"
case "$1" in
  run) cat > "$STDIN_COPY" ;;
  create) echo "fake-container-1" ;;
esac
exit 0
STUB
  chmod +x "$BIN/docker"
}

run_it() { OUT=$(PATH="$BIN:$PATH" bash "$RUN" "$@" 2>"$TMP/err" < /dev/null); RC=$?; ERR=$(cat "$TMP/err"); }

rc_is()     { [ "$RC" -eq "$1" ]; }
no_calls()  { [ ! -s "$CALLS" ]; }
called()    { grep -qF -- "$1" "$CALLS"; }
line()      { grep -F -- "$1" "$CALLS" | head -1; }
has_arg()   { line "$1" | grep -qF -- "$2"; }   # has_arg <start of the call> <argument>
IMAGE='grafana/k6@sha256:'

echo "# input that is refused before anything starts"
setup; run_it
check "no address: exit 1 and says how to use it" bash -c '[ "$1" -ne 0 ] && grep -q usage <<< "$2"' _ "$RC" "$ERR"
check "...and docker was not called" no_calls
setup; run_it "http://alb.example.com/api"
check "an address with a path is refused with exit 2" rc_is 2
check "...and docker was not called" no_calls
setup; run_it "ftp://alb.example.com"
check "an address that is not http or https is refused" rc_is 2
setup; run_it "http://alb.example.com" ten
check "a rate that is not a number is refused" rc_is 2
setup; run_it "http://alb.example.com" 10 5
check "a duration without a unit is refused" rc_is 2
setup; run_it "http://alb.example.com" 10 5m x
check "an error percentage that is not a number is refused" rc_is 2
setup; run_it "http://alb.example.com" 10 5m 0 many
check "a user count that is not a number is refused" rc_is 2
check "...and docker was not called for any of them" no_calls

echo "# a normal run"
setup; run_it "http://alb.example.com" 25 8m 10 3
check "exits 0" rc_is 0
check "runs k6 once, removed afterwards, with stdin open" has_arg "docker run" "run --rm -i"
check "uses the pinned image, by digest" has_arg "docker run" "$IMAGE"
check "tells k6 to read the script from stdin" has_arg "docker run" " run -"
check "passes the address" has_arg "docker run" "BASE_URL=http://alb.example.com"
check "passes the rate" has_arg "docker run" "RATE=25"
check "passes the duration" has_arg "docker run" "DURATION=8m"
check "passes the error percentage" has_arg "docker run" "ERROR_PERCENT=10"
check "passes the user count" has_arg "docker run" "USERS=3"
check "sends the script from the repository on stdin" cmp -s "$STDIN_COPY" "$REPO/scripts/load/traffic.js"

echo "# defaults"
setup; run_it "https://alb.example.com"
check "an https address is accepted" rc_is 0
check "10 requests a second by default" has_arg "docker run" "RATE=10"
check "5 minutes by default" has_arg "docker run" "DURATION=5m"
check "no deliberate errors by default" has_arg "docker run" "ERROR_PERCENT=0"
check "5 users by default" has_arg "docker run" "USERS=5"

echo "# in the background (DETACH=1)"
setup; export DETACH=1; run_it "http://alb.example.com" 1 2h
check "exits 0" rc_is 0
check "creates a container with the settings and the script's path inside it" has_arg "docker create" "RATE=1"
check "...from the pinned image" has_arg "docker create" "$IMAGE"
check "...that runs /traffic.js" has_arg "docker create" "run /traffic.js"
check "copies the script into that container" has_arg "docker cp" "fake-container-1:/traffic.js"
check "starts it" called "docker start fake-container-1"
check "prints the container name, so it can be stopped" bash -c '[ "$1" = "fake-container-1" ]' _ "$OUT"
check "does not use docker run, whose stdin a background container cannot read" bash -c '! grep -q "^docker run" "$1"' _ "$CALLS"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
