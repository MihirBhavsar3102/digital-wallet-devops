#!/usr/bin/env bash
# Tests for scripts/promote-image.sh, using a fake aws and a fake docker. What matters most:
#   - nothing is copied unless BOTH images exist in the source, so a missing image cannot leave
#     production with a backend of one release and no frontend,
#   - the copy must be the same image (same digest), not a look-alike,
#   - an image that is already in the target is left alone (ECR tags are immutable), so a re-run works,
#   - an AWS error is a failure, never "not there".
#
# Run it in a container, from the repo root:
#   docker run --rm -v "$PWD:/repo:ro" python:3-slim bash /repo/scripts/tests/promote-image.test.sh
# (From Git Bash on Windows, prefix with MSYS_NO_PATHCONV=1 and use "$(pwd -W)" in place of "$PWD".)

# SC2016 is intended here: several strings hold a literal "$".
# shellcheck disable=SC2016
set -uo pipefail

REPO="${REPO:-/repo}"
SCRIPT="$REPO/scripts/promote-image.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

SRC=digital-wallet-staging
DST=digital-wallet-prod
REG=123456789012.dkr.ecr.ap-south-1.amazonaws.com

# A fresh fake aws and docker. The scenario is set with environment variables, set after setup:
#   IN_SOURCE       repositories that hold the tag at the start (default: both source repositories)
#   IN_TARGET       target repositories that already hold the tag (default: none)
#   AWS_ERROR       every describe-images call fails with this error code
#   COPY_FAILS      docker buildx imagetools create exits 1
#   DIGEST_DIFFERS  a copy ends up with a different digest than its source
setup() {
  TMP=$(mktemp -d)
  export CALLS="$TMP/calls.log" STATE="$TMP/state"
  BIN="$TMP/bin"
  mkdir -p "$BIN" "$STATE"
  : > "$CALLS"
  unset IN_SOURCE IN_TARGET AWS_ERROR COPY_FAILS DIGEST_DIFFERS
  export REGISTRY="$REG"

  cat > "$BIN/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >> "$CALLS"
[ "$1 $2" = "ecr describe-images" ] || { echo "fake aws: unexpected call: $*" >&2; exit 99; }
repo=""; tag=""
while [ $# -gt 0 ]; do
  case "$1" in --repository-name) repo="$2" ;; --image-ids) tag="${2#imageTag=}" ;; esac
  shift
done
if [ -n "${AWS_ERROR:-}" ]; then
  echo "An error occurred (${AWS_ERROR}) when calling the DescribeImages operation: simulated" >&2; exit 254
fi
img="${repo##*-}"   # backend or frontend
in_list() { local r; for r in $2; do [ "$r" = "$1" ] && return 0; done; return 1; }
source_repos="${IN_SOURCE:-digital-wallet-staging-backend digital-wallet-staging-frontend}"
if [[ "$repo" == digital-wallet-staging-* ]]; then
  if in_list "$repo" "$source_repos"; then echo "sha256:source-$img-$tag"; exit 0; fi
else
  if in_list "$repo" "${IN_TARGET:-}"; then echo "sha256:source-$img-$tag"; exit 0; fi
  if [ -e "$STATE/copied-$repo" ]; then
    if [ -n "${DIGEST_DIFFERS:-}" ]; then echo "sha256:different-$img-$tag"; else echo "sha256:source-$img-$tag"; fi
    exit 0
  fi
fi
echo "An error occurred (ImageNotFoundException) when calling the DescribeImages operation: not found" >&2; exit 254
STUB
  cat > "$BIN/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >> "$CALLS"
if [ "$1 $2 $3" = "buildx imagetools create" ]; then
  [ -n "${COPY_FAILS:-}" ] && { echo "ERROR: failed to copy" >&2; exit 1; }
  # imagetools create [--prefer-index=false] --tag <dest> <source>
  dest=""; prev=""
  for a in "$@"; do [ "$prev" = "--tag" ] && dest="$a"; prev="$a"; done
  dest="${dest#*/}"; dest="${dest%%:*}"
  touch "$STATE/copied-$dest"
  exit 0
fi
echo "fake docker: unexpected call: $*" >&2; exit 99
STUB
  chmod +x "$BIN/aws" "$BIN/docker"
}

run_script() {
  OUT=$(PATH="$BIN:$PATH" bash "$SCRIPT" "$@" 2>"$TMP/err"); RC=$?
  ERR=$(cat "$TMP/err")
  ALL="$OUT"$'\n'"$ERR"
}

rc_is()      { [ "$RC" -eq "$1" ]; }
rc_not()     { [ "$RC" -ne "$1" ]; }
all_has()    { grep -qF -- "$1" <<< "$ALL"; }
copied()     { grep -qxF -- "docker buildx imagetools create --prefer-index=false --tag $REG/$1 $REG/$2" "$CALLS"; }
carbon()     { [ "$(grep -F -- "imagetools create" "$CALLS" | grep -vcF -- "--prefer-index=false")" -eq 0 ]; }
copy_count() { grep -c -F -- "imagetools create" "$CALLS"; }

echo "# a release that passed staging is copied to production"
setup; run_script "$SRC" "$DST" abc1234
check "exits 0" rc_is 0
check "copies the backend, source to target, same tag" copied "$DST-backend:abc1234" "$SRC-backend:abc1234"
check "copies the frontend, source to target, same tag" copied "$DST-frontend:abc1234" "$SRC-frontend:abc1234"
check "copies exactly two images" test "$(copy_count)" -eq 2
check "as carbon copies: buildx would otherwise wrap a single image in a new index, with a new digest" carbon
check "says the digests match" all_has "sha256:source-backend-abc1234"

echo "# re-running a promotion"
setup; export IN_TARGET="$DST-backend $DST-frontend"; run_script "$SRC" "$DST" abc1234
check "exits 0 when both images are already in production" rc_is 0
check "copies nothing" test "$(copy_count)" -eq 0
check "says they were already there" all_has "$DST-backend:abc1234 is already in ECR"
setup; export IN_TARGET="$DST-backend"; run_script "$SRC" "$DST" abc1234
check "a half-promoted release is completed" copied "$DST-frontend:abc1234" "$SRC-frontend:abc1234"
check "without copying the one that is there" test "$(copy_count)" -eq 1

echo "# the release must have passed staging"
setup; export IN_SOURCE="$SRC-backend"; run_script "$SRC" "$DST" abc1234
check "a tag that is not in the source fails" rc_not 0
check "names the missing image" all_has "$SRC-frontend:abc1234"
check "copies nothing, not even the image that is there" test "$(copy_count)" -eq 0
setup; export IN_SOURCE="none"; run_script "$SRC" "$DST" abc1234
check "no source images at all fails" rc_not 0

echo "# the copy must be the same image"
setup; export DIGEST_DIFFERS=1; run_script "$SRC" "$DST" abc1234
check "a digest that differs from the source fails" rc_not 0
check "and says so" all_has "digest"
setup; export COPY_FAILS=1; run_script "$SRC" "$DST" abc1234
check "a failed copy fails" rc_not 0

echo "# AWS errors are failures"
setup; export AWS_ERROR=AccessDeniedException; run_script "$SRC" "$DST" abc1234
check "an AWS error fails the run" rc_not 0
check "with AWS's message" all_has "AccessDeniedException"
check "and copies nothing" test "$(copy_count)" -eq 0

echo "# usage"
setup; run_script
check "no arguments is refused with exit 2" rc_is 2
check "and shows the usage" all_has "usage:"
setup; run_script "$SRC" "$DST"
check "a missing tag is refused with exit 2" rc_is 2
setup; unset REGISTRY; run_script "$SRC" "$DST" abc1234
check "a missing REGISTRY is refused with exit 2" rc_is 2
check "and says what to set" all_has "REGISTRY"
setup; run_script "$SRC" "$DST" 'abc;rm -rf /'
check "a bad tag is refused with exit 2" rc_is 2
setup; run_script "$SRC" "$SRC" abc1234
check "promoting an environment onto itself is refused with exit 2" rc_is 2
check "and copies nothing" test "$(copy_count)" -eq 0

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
