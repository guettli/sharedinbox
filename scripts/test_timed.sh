#!/usr/bin/env bash
# Tests for scripts/timed.sh.
# Run directly: bash scripts/test_timed.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMED="$SCRIPT_DIR/timed.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); }
_fail() {
    echo "FAIL: $1"
    [ -n "${2:-}" ] && echo "  $2"
    FAIL=$((FAIL + 1))
}

out=$(mktemp)
log=$(mktemp)
trap 'rm -f "$out" "$log"' EXIT

# --- Success prints start/end markers and forwards command stdout ------------
: > "$out"
if "$TIMED" mytask -- sh -c 'echo hello' >"$out" 2>&1; then
    grep -q '^\[mytask\] start' "$out" || _fail "start: missing '[mytask] start' line" "$(cat "$out")"
    grep -qE '^\[mytask\] end \([0-9]+s\)$' "$out" || _fail "end: missing '[mytask] end (Xs)' line" "$(cat "$out")"
    grep -q '^hello$' "$out" || _fail "stdout: command output should be forwarded" "$(cat "$out")"
    grep -q '^\[mytask\] start' "$out" && \
        grep -qE '^\[mytask\] end \([0-9]+s\)$' "$out" && \
        grep -q '^hello$' "$out" && _pass
else
    _fail "success: should exit 0" "$(cat "$out")"
fi

# --- The '--' separator between name and command is optional -----------------
: > "$out"
if "$TIMED" plain sh -c 'echo ok' >"$out" 2>&1; then
    grep -q '^ok$' "$out" && _pass || _fail "no-dashdash: command output missing" "$(cat "$out")"
else
    _fail "no-dashdash: should exit 0" "$(cat "$out")"
fi

# --- Non-zero exit code propagates, and end marker still prints --------------
: > "$out"
if "$TIMED" failing -- sh -c 'exit 7' >"$out" 2>&1; then
    _fail "failure: should not exit 0" "$(cat "$out")"
else
    rc=$?
    if [ "$rc" -ne 7 ]; then
        _fail "failure: expected exit 7 (got $rc)" "$(cat "$out")"
    elif ! grep -qE '^\[failing\] end \([0-9]+s\)$' "$out"; then
        _fail "failure: end marker should still print on failure" "$(cat "$out")"
    else
        _pass
    fi
fi

# --- TASK_TIMING_LOG appends a JSONL row with the task name and duration -----
: > "$out"; : > "$log"
TASK_TIMING_LOG="$log" "$TIMED" logged -- sh -c 'true' >"$out" 2>&1
if [ ! -s "$log" ]; then
    _fail "log: expected JSONL row in TASK_TIMING_LOG"
else
    line=$(cat "$log")
    if ! python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["task"]=="logged" and d["status"]==0 and "duration_s" in d' "$line" 2>/dev/null; then
        _fail "log: JSONL row malformed" "$line"
    else
        _pass
    fi
fi

# --- Missing arguments produce a usage message and exit non-zero -------------
: > "$out"
if "$TIMED" only-one-arg >"$out" 2>&1; then
    _fail "usage: single-arg invocation should fail" "$(cat "$out")"
else
    grep -q 'usage:' "$out" && _pass || _fail "usage: expected 'usage:' hint" "$(cat "$out")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
