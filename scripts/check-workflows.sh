#!/usr/bin/env bash
# Usage: check-workflows.sh [<.github directory>]     (default: .github)
#
# Holds every workflow (.github/workflows/*.yml) and composite action (.github/actions/*/action.yml) to
# the hardening rules of step 2.8, so that they stay true as the files change. It reports every problem,
# as <file>:<line>: <what is wrong>, and exits 1 if there is one. The CI lint job runs it.
#
#  1. Every "uses:" is a local action (./...), a Docker image by digest, or an action pinned to a full
#     40-character commit SHA. A tag or a branch can be moved to other code after you have reviewed it: in
#     March 2025 the attackers behind the tj-actions/changed-files compromise repointed existing version
#     tags to a malicious commit, and every workflow that used a tag ran it. A commit SHA cannot be moved.
#     (GitHub's own "require actions to be pinned" setting enforces this at run time. This check says so in
#     the pull request, before anything runs, and covers local action files too.)
#  2. Every workflow declares top-level permissions, so that the token is never given the repository's
#     default silently.
#  3. Those top-level permissions grant no write access (and no write-all anywhere): a job that needs more,
#     such as id-token: write for the AWS login, asks for exactly that on the job.
#  4. No pull_request_target trigger: it runs with secrets and a write token on code from a fork.
#  5. No long-lived AWS keys: the pipeline reaches AWS through OIDC with a role, never a stored key.
#  6. Every actions/checkout sets persist-credentials: false, so that the token is not left in the
#     repository's git config for the later steps to read.
#
# It reads the files line by line and does not parse YAML, which is enough because they are regular, and
# it needs only bash and awk. Tests: scripts/tests/check-workflows.test.sh
set -uo pipefail
shopt -s nullglob

DIR="${1:-.github}"
if [ ! -d "$DIR" ]; then
  echo "no such directory: $DIR" >&2
  exit 2
fi

WORKFLOWS=("$DIR"/workflows/*.yml "$DIR"/workflows/*.yaml)
ACTIONS=("$DIR"/actions/*/action.yml "$DIR"/actions/*/action.yaml)
if [ "${#WORKFLOWS[@]}" -eq 0 ]; then
  echo "no workflows in $DIR/workflows" >&2
  exit 2
fi

PROBLEMS=0
problem() { # <file> <line> <message>
  echo "$1:$2: $3"
  PROBLEMS=$((PROBLEMS + 1))
}

# uncommented <file>: the file's lines as "<number>:<text>", with comment-only lines dropped and trailing
# comments cut off.
uncommented() {
  awk '{ t = $0; sub(/^[ \t]*#.*/, "", t); sub(/[ \t]+#.*/, "", t); if (t ~ /[^ \t]/) print NR ":" t }' "$1"
}

# --- rule 1, in every workflow and every action file
for f in "${WORKFLOWS[@]}" "${ACTIONS[@]}"; do
  while IFS= read -r entry; do
    n="${entry%%:*}"
    value="${entry#*uses:}"
    value="${value#"${value%%[![:space:]]*}"}"   # trim leading blanks
    value="${value%"${value##*[![:space:]]}"}"   # trim trailing blanks
    value="${value//\"/}"
    value="${value//\'/}"
    if [[ "$value" == ./* ]]; then
      continue
    elif [[ "$value" == docker://* ]]; then
      [[ "$value" =~ @sha256:[0-9a-f]{64}$ ]] || problem "$f" "$n" "uses: $value is a Docker image that is not pinned by digest (@sha256:...)"
    elif [[ ! "$value" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._/-]+@[0-9a-f]{40}$ ]]; then
      problem "$f" "$n" "uses: $value is not pinned to a full commit SHA (40 lower-case hex characters)"
    fi
  done < <(uncommented "$f" | grep -E '^[0-9]+:[[:space:]]*-?[[:space:]]*uses:' || true)
done

# --- rules 4 and 5, in every workflow and every action file
for f in "${WORKFLOWS[@]}" "${ACTIONS[@]}"; do
  while IFS= read -r entry; do
    problem "$f" "${entry%%:*}" "pull_request_target runs with secrets and a write token on code from a fork: use pull_request"
  done < <(uncommented "$f" | grep -E 'pull_request_target' || true)
  while IFS= read -r entry; do
    problem "$f" "${entry%%:*}" "a long-lived AWS key: use OIDC and role-to-assume instead"
  done < <(uncommented "$f" | grep -iE 'aws-access-key-id|aws-secret-access-key|aws-session-token|aws_access_key_id|aws_secret_access_key|aws_session_token|secrets\.AWS_' || true)
done

# --- rules 2 and 3, in the workflows
for f in "${WORKFLOWS[@]}"; do
  if ! grep -qE '^permissions:' "$f"; then
    problem "$f" 1 "no top-level permissions: declare them, read-only, and let each job ask for more"
    continue
  fi
  # the top-level block, and an inline value such as "permissions: write-all"
  while IFS= read -r n; do
    problem "$f" "$n" "write access in the top-level permissions: grant it on the job that needs it"
  done < <(awk '
    /^permissions:/ { inb = 1; if ($0 ~ /write/) print NR; next }
    inb && /^[^ #\t]/ { inb = 0 }
    inb && $0 !~ /^[ \t]*#/ && /write/ { print NR }
  ' "$f")
  while IFS= read -r entry; do
    problem "$f" "${entry%%:*}" "permissions: write-all gives a job every write permission"
  done < <(uncommented "$f" | grep -E '^[0-9]+:[[:space:]]+permissions:[[:space:]]*write-all' || true)
done

# --- rule 6, in every workflow and every action file: the checkout step has to set persist-credentials: false
for f in "${WORKFLOWS[@]}" "${ACTIONS[@]}"; do
  while IFS= read -r n; do
    problem "$f" "$n" "actions/checkout without persist-credentials: false leaves the token in the git config"
  done < <(awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function flush() { if (pending && !ok) print pending_line; pending = 0 }
    {
      line = $0
      if (pending) {
        if (line ~ /^[ \t]*$/) next
        if (line !~ /^[ \t]*#/ && (indent(line) < pending_indent || (indent(line) == pending_indent && line ~ /^[ \t]*-/))) flush()
        else if (line ~ /persist-credentials:[ \t]*false/) ok = 1
      }
      if (line ~ /^[ \t]*-?[ \t]*uses:[ \t]*actions\/checkout@/ && line !~ /^[ \t]*#/) {
        flush()
        pending = 1; ok = 0; pending_line = NR; pending_indent = indent(line)
      }
    }
    END { flush() }
  ' "$f")
done

if [ "$PROBLEMS" -gt 0 ]; then
  echo "$PROBLEMS problem(s) in the workflows"
  exit 1
fi
echo "workflows OK: ${#WORKFLOWS[@]} workflow(s) and ${#ACTIONS[@]} action(s) follow the hardening rules"
