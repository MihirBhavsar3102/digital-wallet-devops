#!/usr/bin/env bash
# Tests for scripts/rollback-check.sh, using a fake aws. What matters most:
#   - a release is only accepted when BOTH of its images are in the environment's repositories, because
#     deploy.sh pulls both, and a rollback that fails half way through the pulls, in an emergency, is worse
#     than one that is refused up front;
#   - when it is refused, the message lists the releases that ARE there, because the usual reasons are a
#     typo and a release that the lifecycle policy has expired, and the person reading it is in a hurry;
#   - an AWS error is never read as "not there".
#
# Run it in a container, from the repo root:
#   docker run --rm -v "$PWD:/repo:ro" python:3-slim bash /repo/scripts/tests/rollback-check.test.sh
# (From Git Bash on Windows, prefix with MSYS_NO_PATHCONV=1 and use "$(pwd -W)" in place of "$PWD".)

# SC2016 is intended here: several strings hold a literal "$".
# shellcheck disable=SC2016
set -uo pipefail

REPO="${REPO:-/repo}"
SCRIPT="$REPO/scripts/rollback-check.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

PREFIX=digital-wallet-staging

# A fresh fake aws. Scenario variables, set after setup:
#   IN_REPOS     repositories that hold the tag (default: both)
#   AWS_ERROR    every describe-images call fails with this error code
#   LIST_FAILS   listing the releases fails (the tag check itself is fine)
setup() {
  TMP=$(mktemp -d)
  export CALLS="$TMP/calls.log"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  : > "$CALLS"
  unset IN_REPOS AWS_ERROR LIST_FAILS
  cat > "$BIN/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >> "$CALLS"
[ "$1 $2" = "ecr describe-images" ] || { echo "fake aws: unexpected call: $*" >&2; exit 99; }
repo=""; has_ids=0
while [ $# -gt 0 ]; do
  case "$1" in --repository-name) repo="$2" ;; --image-ids) has_ids=1 ;; esac
  shift
done
if [ -n "${AWS_ERROR:-}" ]; then
  echo "An error occurred (${AWS_ERROR}) when calling the DescribeImages operation: simulated" >&2; exit 254
fi
if [ "$has_ids" = 1 ]; then
  # the tag check: present only in the repositories listed in IN_REPOS
  for r in ${IN_REPOS-digital-wallet-staging-backend digital-wallet-staging-frontend}; do
    [ "$r" = "$repo" ] && { echo "sha256:abc"; exit 0; }
  done
  echo "An error occurred (ImageNotFoundException) when calling the DescribeImages operation: not found" >&2; exit 254
fi
# the listing of what is there: date and tags, newest first, as the --query would print it
[ -n "${LIST_FAILS:-}" ] && { echo "An error occurred (AccessDeniedException) when calling the DescribeImages operation: simulated" >&2; exit 254; }
printf '2026-11-11T19:33:03+05:30\tf4b62f0, 1dae033\n2026-11-11T15:03:40+05:30\t70f912e, 70f912e-2\n'
STUB
  chmod +x "$BIN/aws"
}

run_script() {
  OUT=$(PATH="$BIN:$PATH" bash "$SCRIPT" "$@" 2>"$TMP/err"); RC=$?
  ERR=$(cat "$TMP/err")
  ALL="$OUT"$'\n'"$ERR"
}

rc_is()    { [ "$RC" -eq "$1" ]; }
rc_not()   { [ "$RC" -ne "$1" ]; }
all_has()  { grep -qF -- "$1" <<< "$ALL"; }
all_lacks() { ! grep -qF -- "$1" <<< "$ALL"; }

echo "# a release that is in both repositories"
setup; run_script "$PREFIX" 70f912e
check "is accepted" rc_is 0
check "and says so" all_has "70f912e is in $PREFIX-backend and $PREFIX-frontend"
check "without listing anything" all_lacks "Releases in"

echo "# a release that is missing"
setup; export IN_REPOS="$PREFIX-backend"; run_script "$PREFIX" 70f912e
check "is refused when the frontend image is missing" rc_not 0
check "and names the missing image" all_has "$PREFIX-frontend:70f912e is not in ECR"
check "and not the one that is there" all_lacks "$PREFIX-backend:70f912e is not in ECR"
check "and lists the releases that are in that repository" all_has "f4b62f0, 1dae033"
check "with the older ones" all_has "70f912e, 70f912e-2"
check "and says why an older one may be gone" all_has "keeps the last 10 images"
setup; export IN_REPOS=""; run_script "$PREFIX" typo123
check "a release that is in neither is refused" rc_not 0
check "and both images are named" test "$(grep -c 'is not in ECR' <<< "$ALL")" -eq 2
setup; export IN_REPOS=""; export LIST_FAILS=1; run_script "$PREFIX" typo123
check "when the listing fails the refusal still stands" rc_not 0
check "and still says which image is missing" all_has "$PREFIX-backend:typo123 is not in ECR"

echo "# AWS errors are not 'not there'"
setup; export AWS_ERROR=AccessDeniedException; run_script "$PREFIX" 70f912e
check "an AWS error fails the run" rc_not 0
check "with AWS's message" all_has "AccessDeniedException"
check "and does not say the image is missing" all_lacks "is not in ECR"

echo "# usage"
setup; run_script
check "no arguments is refused with exit 2" rc_is 2
check "and shows the usage" all_has "usage:"
setup; run_script "$PREFIX"
check "a missing tag is refused with exit 2" rc_is 2
setup; run_script "$PREFIX" 'abc;rm -rf /'
check "a bad tag is refused with exit 2" rc_is 2
check "and asks AWS nothing" test ! -s "$CALLS"
setup; run_script 'Bad Prefix' 70f912e
check "a bad name prefix is refused with exit 2" rc_is 2

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
