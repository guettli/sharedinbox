#!/usr/bin/env bash
# timed.sh — wrap a command, printing "[<name>] start" / "[<name>] end (<Xs>)".
#
# Usage:
#   scripts/timed.sh <name> [--] <command> [args...]
#
# When TASK_TIMING_LOG points at a writable path, one JSONL row per call is
# appended so a CI job can collect per-subtask wall-times and upload them as
# an artefact. See Taskfile.yml `check` and .github/workflows/ci.yml.
set -o pipefail

if [ $# -lt 2 ]; then
    echo "usage: timed.sh <name> [--] <command> [args...]" >&2
    exit 2
fi

name="$1"; shift
if [ "${1:-}" = "--" ]; then shift; fi

start_epoch=$(date +%s)
printf '[%s] start %s\n' "$name" "$(date -u '+%H:%M:%SZ')"

"$@"
status=$?

end_epoch=$(date +%s)
duration=$((end_epoch - start_epoch))
printf '[%s] end (%ds)\n' "$name" "$duration"

if [ -n "${TASK_TIMING_LOG:-}" ]; then
    # JSONL row so a downstream collector (jq, Python, …) can aggregate cleanly.
    printf '{"task":"%s","start":%s,"end":%s,"duration_s":%s,"status":%s}\n' \
        "$name" "$start_epoch" "$end_epoch" "$duration" "$status" \
        >> "$TASK_TIMING_LOG"
fi

exit "$status"
