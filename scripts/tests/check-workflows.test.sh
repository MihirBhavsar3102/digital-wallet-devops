#!/usr/bin/env bash
# Tests for scripts/check-workflows.sh, which holds the workflows to the hardening rules of step 2.8. It is
# run on small fixture workflows, one rule at a time, and on this repository's real ones, so a rule that a
# real workflow breaks fails here too.
#
# Run it in a container, from the repo root:
#   docker run --rm -v "$PWD:/repo:ro" python:3-slim bash /repo/scripts/tests/check-workflows.test.sh
# (From Git Bash on Windows, prefix with MSYS_NO_PATHCONV=1 and use "$(pwd -W)" in place of "$PWD".)

# SC2016 is intended here: several strings hold a literal "$".
# shellcheck disable=SC2016
set -uo pipefail

REPO="${REPO:-/repo}"
SCRIPT="$REPO/scripts/check-workflows.sh"
PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); echo "ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

SHA=3d3c42e5aac5ba805825da76410c181273ba90b1

# A fresh directory with .github/workflows and .github/actions.
setup() {
  TMP=$(mktemp -d)
  mkdir -p "$TMP/.github/workflows" "$TMP/.github/actions/mine"
}

# wf <name> <body>: a workflow file with the given text. The default header is a good one.
GOOD_HEAD=$'name: T\non:\n  push:\n    branches: [main]\npermissions:\n  contents: read\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n'
wf() { printf '%s' "$2" > "$TMP/.github/workflows/$1.yml"; }
# step <text>: appended to a good workflow's steps
good_with() { wf "${2:-t}" "$GOOD_HEAD$1"$'\n'; }

run_check() { OUT=$(bash "$SCRIPT" "$TMP/.github" 2>&1); RC=$?; }
rc_is()   { [ "$RC" -eq "$1" ]; }
rc_not()  { [ "$RC" -ne "$1" ]; }
has()     { grep -qF -- "$1" <<< "$OUT"; }
lacks()   { ! grep -qF -- "$1" <<< "$OUT"; }

echo "# a good workflow"
setup; good_with "      - uses: actions/checkout@$SHA # v7.0.1
        with:
          persist-credentials: false
      - run: echo hi"
run_check
check "passes" rc_is 0
check "and says what it checked" has "workflows OK"

echo "# rule 1: every action is pinned to a full commit SHA"
setup; good_with "      - uses: actions/setup-node@v4"; run_check
check "a version tag is refused" rc_not 0
check "naming the file and the line" has "t.yml:11"
check "and the rule" has "not pinned to a full commit SHA"
setup; good_with "      - uses: actions/setup-node@main"; run_check
check "a branch is refused" rc_not 0
setup; good_with "      - uses: actions/setup-node@${SHA:0:39}"; run_check
check "a 39-character SHA is refused" rc_not 0
setup; good_with "      - uses: actions/setup-node@3D3C42E5AAC5BA805825DA76410C181273BA90B1"; run_check
check "an upper-case SHA is refused" rc_not 0
setup; good_with "      - uses: actions/setup-node"; run_check
check "no version at all is refused" rc_not 0
setup; good_with "      - uses: docker://alpine:3.20"; run_check
check "a Docker image by tag is refused" rc_not 0
setup; good_with "      - uses: docker://alpine@sha256:$(printf 'a%.0s' $(seq 64))"; run_check
check "a Docker image by digest passes" rc_is 0
setup; good_with "      - uses: ./.github/actions/mine"; run_check
check "a local action passes" rc_is 0
setup; good_with "      - uses: actions/setup-node@$SHA # v7.1.0"; run_check
check "a pinned action with a version comment passes" rc_is 0
setup; good_with "      # - uses: actions/setup-node@v4
      - run: echo hi"; run_check
check "a commented-out line is ignored" rc_is 0
setup; good_with "      - run: echo hi"
printf 'name: Mine\nruns:\n  using: composite\n  steps:\n    - uses: aws-actions/configure-aws-credentials@v6\n' > "$TMP/.github/actions/mine/action.yml"; run_check
check "a composite action's steps are held to it too" rc_not 0
check "and it is the action file that is named" has "action.yml"
setup; good_with "      - run: echo hi"
printf 'name: Mine\nruns:\n  using: composite\n  steps:\n    - uses: aws-actions/configure-aws-credentials@%s\n' "$SHA" > "$TMP/.github/actions/mine/action.yml"; run_check
check "a pinned composite action passes, and needs no permissions block" rc_is 0

echo "# rule 2 and 3: permissions are declared, and read-only at the top"
setup; wf t $'name: T\non: push\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n'; run_check
check "a workflow with no top-level permissions is refused" rc_not 0
check "and the message says so" has "no top-level permissions"
setup; wf t $'name: T\non: push\npermissions: write-all\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n'; run_check
check "write-all at the top is refused" rc_not 0
setup; wf t $'name: T\non: push\npermissions:\n  contents: write\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n'; run_check
check "a write permission at the top is refused" rc_not 0
setup; wf t $'name: T\non: push\npermissions:\n  id-token: write\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n'; run_check
check "id-token: write at the top is refused: it belongs on the jobs that need it" rc_not 0
setup; wf t $'name: T\non: push\npermissions: {}\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n'; run_check
check "an empty permissions mapping passes" rc_is 0
setup; wf t $'name: T\non: push\npermissions:\n  contents: read\njobs:\n  j:\n    runs-on: ubuntu-latest\n    permissions:\n      id-token: write\n      contents: read\n    steps:\n      - run: echo hi\n'; run_check
check "id-token: write on a job passes" rc_is 0
setup; wf t $'name: T\non: push\npermissions:\n  contents: read\njobs:\n  j:\n    runs-on: ubuntu-latest\n    permissions: write-all\n    steps:\n      - run: echo hi\n'; run_check
check "write-all on a job is refused" rc_not 0

echo "# rule 4: no pull_request_target"
setup; wf t $'name: T\non:\n  pull_request_target:\npermissions:\n  contents: read\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n'; run_check
check "the trigger is refused" rc_not 0
setup; wf t $'name: T\non:\n  pull_request:\n  # pull_request_target is not used: it runs with secrets on code from a fork\npermissions:\n  contents: read\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n'; run_check
check "a comment that names it is not" rc_is 0

echo "# rule 5: no long-lived AWS keys"
setup; good_with "      - uses: aws-actions/configure-aws-credentials@$SHA
        with:
          aws-access-key-id: x
          aws-region: ap-south-1"; run_check
check "the key input is refused" rc_not 0
setup; good_with "      - run: echo hi
        env:
          AWS_SECRET_ACCESS_KEY: \${{ secrets.AWS_SECRET_ACCESS_KEY }}"; run_check
check "a key from a secret is refused" rc_not 0
setup; good_with "      - run: echo hi
        env:
          MY_CREDENTIAL: \${{ secrets.AWS_PROD_CREDENTIAL }}"; run_check
check "an AWS secret is refused even under another name" rc_not 0
setup; good_with "      - uses: aws-actions/configure-aws-credentials@$SHA
        with:
          role-to-assume: arn:aws:iam::1:role/x
          aws-region: ap-south-1"; run_check
check "assuming a role passes" rc_is 0

echo "# rule 6: a checkout does not leave the token in the repository's git config"
setup; good_with "      - uses: actions/checkout@$SHA"; run_check
check "a checkout without persist-credentials: false is refused" rc_not 0
setup; good_with "      - uses: actions/checkout@$SHA
        with:
          fetch-depth: 0
          persist-credentials: false"; run_check
check "persist-credentials: false after other inputs passes" rc_is 0
setup; good_with "      - uses: actions/checkout@$SHA
        with:
          persist-credentials: true"; run_check
check "persist-credentials: true is refused" rc_not 0

echo "# every problem is reported, not just the first"
setup; wf t $'name: T\non: push\njobs:\n  j:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: a/b@v1\n      - uses: c/d@v2\n'; run_check
check "two unpinned actions and a missing block are all listed" test "$(grep -c 't.yml' <<< "$OUT")" -ge 3

echo "# this repository's own workflows"
OUT=$(bash "$SCRIPT" "$REPO/.github" 2>&1); RC=$?
check "pass every rule" rc_is 0
check "and are all found" has "workflows OK"

echo "# usage"
OUT=$(bash "$SCRIPT" /no/such/dir 2>&1); RC=$?
check "a directory that does not exist is refused with exit 2" rc_is 2
setup; OUT=$(bash "$SCRIPT" "$TMP/.github" 2>&1); RC=$?
check "a directory with no workflows is refused with exit 2" rc_is 2

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
