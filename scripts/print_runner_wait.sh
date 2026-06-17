#!/usr/bin/env bash
# Print the time the job spent queued before a runner picked it up.
# Reads GITHUB_SERVER_URL, GITHUB_REPOSITORY, FORGEJO_TOKEN, and RUN_NUMBER
# from the environment. Centralised here so the heredoc lives in one file
# instead of being inlined (and verbosely re-expanded by the act runner)
# across every workflow job.
set -uo pipefail

runner_start=$(date +%s)
created=$(curl -sf --max-time 30 \
    -H "Authorization: token ${FORGEJO_TOKEN:-}" \
    "${GITHUB_SERVER_URL:-}/api/v1/repos/${GITHUB_REPOSITORY:-}/actions/runs?run_number=${RUN_NUMBER:-}" \
    | python3 -c "import sys,json;rs=json.load(sys.stdin).get('workflow_runs',[]);print(rs[0]['created'] if rs else '')" 2>/dev/null) || true
if [ -n "$created" ]; then
    queued_epoch=$(date -d "$created" +%s)
    echo "Runner wait time: $((runner_start - queued_epoch))s (queued at $created)"
else
    echo "Runner wait time: unknown (API lookup failed)"
fi
