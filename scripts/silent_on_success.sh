#!/usr/bin/env bash
# Run a command silently. On failure, replay captured output and exit with the original code.
# When DEBUG is set, print start time, command, end time, and duration.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

if [ -n "${DEBUG:-}" ]; then
    start=$(date +%s)
    echo "[$(date '+%H:%M:%S')] + $*"
fi

if "$@" > "$tmp" 2>&1; then
    code=0
else
    code=$?
    cat "$tmp"
fi

if [ -n "${DEBUG:-}" ]; then
    end=$(date +%s)
    echo "[$(date '+%H:%M:%S')] = $* (${code}) $((end - start))s"
fi

exit $code
