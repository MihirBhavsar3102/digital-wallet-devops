#!/usr/bin/env bash
# Tests for scripts/ecr-tag-status.sh, using a fake aws. What matters most: only "the tag does not
# exist" may be read as "absent". An expired login, a missing permission or a missing repository must
# stop the pipeline, because reading them as "absent" would send it on to a push that cannot work.
#
# Run it in a container, from the repo root:
#   docker run --rm -v "$PWD:/repo:ro" python:3-slim bash /repo/scripts/tests/ecr-tag-status.test.sh
# (From Git Bash on Windows, prefix with MSYS_NO_PATHCONV=1 and use "$(pwd -W)" in place of "$PWD".)

set -uo pipefail

REPO="${REPO:-/repo}"
SCRIPT="$REPO/scripts/ecr-tag-status.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# A fresh fake aws. AWS_RESULT picks the answer: found (exit 0 with a digest), or an AWS error code,
# which it prints the way the CLI does, on stderr, and exits 254 like the CLI.
setup() {
  TMP=$(mktemp -d)
  export CALLS="$TMP/calls.log"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  : > "$CALLS"
  unset AWS_RESULT
  cat > "$BIN/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >> "$CALLS"
case "${AWS_RESULT:-found}" in
  found) echo "sha256:0123abcd"; exit 0 ;;
  *) echo "An error occurred (${AWS_RESULT}) when calling the DescribeImages operation: simulated" >&2; exit 254 ;;
esac
STUB
  chmod +x "$BIN/aws"
}

run_script() {
  OUT=$(PATH="$BIN:$PATH" bash "$SCRIPT" "$@" 2>"$TMP/err"); RC=$?
  ERR=$(cat "$TMP/err")
}

rc_is()    { [ "$RC" -eq "$1" ]; }
rc_not()   { [ "$RC" -ne "$1" ]; }
out_is()   { [ "$OUT" = "$1" ]; }
err_has()  { grep -qF -- "$1" <<< "$ERR"; }
called()   { grep -qxF -- "$1" "$CALLS"; }

echo "# a tag that is in the repository"
setup; run_script digital-wallet-staging-backend abc1234
check "exits 0" rc_is 0
check "prints present, and only that" out_is "present"
check "asks ECR for exactly that repository and tag" called "aws ecr describe-images --repository-name digital-wallet-staging-backend --image-ids imageTag=abc1234 --query imageDetails[0].imageDigest --output text"

echo "# a tag that is not in the repository"
setup; export AWS_RESULT=ImageNotFoundException; run_script digital-wallet-staging-backend abc1234
check "exits 0, because absent is an answer and not a failure" rc_is 0
check "prints absent, and only that" out_is "absent"

echo "# anything else stops the pipeline"
setup; export AWS_RESULT=RepositoryNotFoundException; run_script digital-wallet-staging-backend abc1234
check "a missing repository fails" rc_not 0
check "and prints nothing a caller could read as an answer" out_is ""
check "and says what AWS said" err_has "RepositoryNotFoundException"
setup; export AWS_RESULT=AccessDeniedException; run_script digital-wallet-staging-backend abc1234
check "a missing permission fails" rc_not 0
check "and prints nothing a caller could read as an answer" out_is ""
check "and says what AWS said" err_has "AccessDeniedException"
setup; export AWS_RESULT=ExpiredTokenException; run_script digital-wallet-staging-backend abc1234
check "an expired login fails" rc_not 0
check "and does not print absent" out_is ""

echo "# usage"
setup; run_script
check "no arguments is refused with exit 2" rc_is 2
check "and shows the usage" err_has "usage:"
check "and asks AWS nothing" test ! -s "$CALLS"
setup; run_script digital-wallet-staging-backend
check "a missing tag is refused with exit 2" rc_is 2
setup; run_script digital-wallet-staging-backend 'abc;rm -rf /'
check "a tag with characters Docker does not allow is refused with exit 2" rc_is 2
check "and asks AWS nothing" test ! -s "$CALLS"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
