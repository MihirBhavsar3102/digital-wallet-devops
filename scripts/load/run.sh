#!/usr/bin/env bash
# Usage: scripts/load/run.sh <load-balancer-url> [rate-per-second] [duration] [error-percent] [users]
#
# Runs scripts/load/traffic.js with k6 in Docker (nothing to install), against the load balancer, and prints
# k6's summary. Examples, from the repository root:
#   scripts/load/run.sh http://<alb>                 # 10 requests a second for 5 minutes, no errors
#   scripts/load/run.sh http://<alb> 10 8m 10        # 10% of the requests are deliberate 500s: fires the 5xx alarm
#   scripts/load/run.sh http://<alb> 1 2h            # a slow loop, to keep the charts alive
# Setting DETACH=1 runs it in the background (docker run -d) and prints the container name; stop it with
# `docker stop <name>`. The image is pinned by digest (k6 v2.3.0), like the other tools.
set -euo pipefail

URL="${1:?usage: run.sh <load-balancer-url> [rate] [duration] [error-percent] [users]}"
RATE="${2:-10}"
DURATION="${3:-5m}"
ERROR_PERCENT="${4:-0}"
USERS="${5:-5}"
K6_IMAGE="grafana/k6@sha256:3e4186aea62e11a45560bfc51e19eeafe82fc07ce069c78aff44b7ff893d9a5e"

[[ "$URL" =~ ^https?://[^[:space:]/]+$ ]] || { echo "the URL must look like http://host, without a path: $URL" >&2; exit 2; }
[[ "$RATE" =~ ^[0-9]+$ && "$USERS" =~ ^[0-9]+$ && "$ERROR_PERCENT" =~ ^[0-9]+$ ]] || { echo "rate, error-percent and users must be whole numbers" >&2; exit 2; }
[[ "$DURATION" =~ ^[0-9]+[smh]$ ]] || { echo "duration must look like 90s, 5m or 2h: $DURATION" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_ARGS=(-e "BASE_URL=$URL" -e "RATE=$RATE" -e "DURATION=$DURATION" -e "ERROR_PERCENT=$ERROR_PERCENT" -e "USERS=$USERS")

if [ "${DETACH:-0}" = 1 ]; then
  # A background container cannot read the script from this shell's stdin, so create it, copy the script in, start it.
  # Git Bash rewrites paths that start with / in arguments, which would mangle "<container>:/traffic.js".
  host_path="$HERE/traffic.js"
  if command -v cygpath > /dev/null 2>&1; then host_path="$(cygpath -m "$host_path")"; fi
  container="$(docker create "${ENV_ARGS[@]}" "$K6_IMAGE" run /traffic.js)"
  MSYS_NO_PATHCONV=1 docker cp "$host_path" "$container:/traffic.js"
  docker start "$container" > /dev/null
  echo "$container"
else
  # Read from stdin, so nothing has to be mounted into the container.
  docker run --rm -i "${ENV_ARGS[@]}" "$K6_IMAGE" run - < "$HERE/traffic.js"
fi
