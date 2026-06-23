#!/usr/bin/env bash
# Print the time the job spent queued before a runner picked it up.
# Reads GITHUB_API_URL, GITHUB_REPOSITORY, GITHUB_RUN_ID, and GITHUB_TOKEN
# from the environment. Centralised here so the heredoc lives in one file
# instead of being inlined (and verbosely re-expanded) across every workflow job.
set -uo pipefail

runner_start=$(date +%s)
created=$(curl -sf --max-time 30 \
    -H "Authorization: Bearer ${GITHUB_TOKEN:-}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('created_at',''))" 2>/dev/null) || true
if [ -n "$created" ]; then
    queued_epoch=$(date -d "$created" +%s)
    echo "Runner wait time: $((runner_start - queued_epoch))s (queued at $created)"
else
    echo "Runner wait time: unknown (API lookup failed)"
fi
