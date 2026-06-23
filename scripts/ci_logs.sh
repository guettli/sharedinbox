#!/usr/bin/env bash
set -euo pipefail

# Fetch CI job logs from GitHub Actions via the gh CLI.
#
# Usage:
#   scripts/ci_logs.sh [RUN] [JOB]
#     RUN   GitHub Actions run id. If omitted, the most recent non-skipped run
#           on guettli/sharedinbox is used.
#     JOB   Optional job name to filter the log output (substring match).
#
# Requires: gh (authenticated).

REPO="guettli/sharedinbox"
RUN="${1:-}"
JOB="${2:-}"

if [ -z "$RUN" ]; then
  RUN=$(gh run list -R "$REPO" --limit 10 \
    --json databaseId,status,conclusion \
    --jq '[.[] | select(.status != "skipped" and .conclusion != "skipped")][0].databaseId')
  if [ -z "$RUN" ] || [ "$RUN" = "null" ]; then
    echo "No non-skipped runs found for $REPO" >&2
    exit 1
  fi
  echo "Latest non-skipped run: $RUN" >&2
fi

echo "Fetching logs for run $RUN (repo $REPO)" >&2
echo "---" >&2

if [ -n "$JOB" ]; then
  gh run view "$RUN" --log -R "$REPO" --job "$JOB"
else
  gh run view "$RUN" --log -R "$REPO"
fi
