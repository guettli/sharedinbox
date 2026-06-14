#!/usr/bin/env bash
set -euo pipefail

REPO="guettli/sharedinbox"
RUN="${1:-}"
JOB="${2:-0}"

if [ -z "$RUN" ]; then
  RUN=$(curl -sf "https://sialoop.thomas-guettler.de/api/v1/repos/$REPO/actions/tasks?limit=10" \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data.get('workflow_runs', []):
    if r['status'] != 'skipped':
        print(r['run_number'])
        break
")
  echo "Latest non-skipped run: #$RUN" >&2
fi

URL="https://sialoop.thomas-guettler.de/$REPO/actions/runs/$RUN/jobs/$JOB/attempt/1/logs"
echo "Fetching: $URL" >&2
echo "---" >&2
curl -sf "$URL"
