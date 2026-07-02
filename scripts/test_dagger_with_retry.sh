#!/usr/bin/env bash
# Tests for scripts/dagger_with_retry.sh.
# Run directly: bash scripts/test_dagger_with_retry.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RETRY="$SCRIPT_DIR/dagger_with_retry.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); }
_fail() {
    echo "FAIL: $1"
    [ -n "${2:-}" ] && echo "  $2"
    FAIL=$((FAIL + 1))
}

# --- Success on first attempt is silent --------------------------------------
out=$(mktemp); trap 'rm -f "$out"' EXIT
if "$RETRY" true >"$out" 2>&1; then
    [ -s "$out" ] && _fail "success: output should be empty" "$(cat "$out")" || _pass
else
    _fail "success: should exit 0"
fi

# --- Non-retryable failure replays captured output and propagates exit code --
fakebin=$(mktemp -d)
cat >"$fakebin/cmd" <<'EOF'
#!/usr/bin/env bash
echo "unexpected fatal error"
exit 7
EOF
chmod +x "$fakebin/cmd"

if "$RETRY" "$fakebin/cmd" >"$out" 2>&1; then
    _fail "non-retryable: should fail"
else
    rc=$?
    if [ "$rc" -ne 7 ]; then
        _fail "non-retryable: should propagate exit code 7 (got $rc)"
    elif ! grep -q "unexpected fatal error" "$out"; then
        _fail "non-retryable: should replay captured stdout" "$(cat "$out")"
    else
        _pass
    fi
fi

# --- Disk-space failure triggers prune+retry; after 3 attempts, fail ---------
attempts=$(mktemp)
echo 0 >"$attempts"
cat >"$fakebin/cmd" <<EOF
#!/usr/bin/env bash
n=\$(cat $attempts); n=\$((n + 1)); echo \$n >$attempts
echo "Creation of temporary directory failed: No space left on device"
exit 1
EOF
chmod +x "$fakebin/cmd"

# Stub the dagger binary so the prune call is a no-op (no real engine needed).
PATH_SAVED="$PATH"
echo -e '#!/usr/bin/env bash\nexit 0' >"$fakebin/dagger"
chmod +x "$fakebin/dagger"

# Stub sleep so the test isn't slow (90s × 2 retries = 180s otherwise).
echo -e '#!/usr/bin/env bash\nexit 0' >"$fakebin/sleep"
chmod +x "$fakebin/sleep"
export PATH="$fakebin:$PATH"

if "$RETRY" "$fakebin/cmd" >"$out" 2>&1; then
    _fail "disk space: should fail after exhausting retries"
else
    n=$(cat "$attempts")
    [ "$n" -eq 3 ] || _fail "disk space: expected 3 attempts, got $n"
    grep -q "disk space error on attempt 1/3" "$out" || _fail "disk space: missing attempt-1 notice" "$(cat "$out")"
    grep -q "disk space error on attempt 2/3" "$out" || _fail "disk space: missing attempt-2 notice" "$(cat "$out")"
    [ "$n" -eq 3 ] && grep -q "disk space error on attempt 1/3" "$out" && grep -q "disk space error on attempt 2/3" "$out" && _pass
fi

# --- Disk-space failure that recovers on retry returns success silently ------
echo 0 >"$attempts"
cat >"$fakebin/cmd" <<EOF
#!/usr/bin/env bash
n=\$(cat $attempts); n=\$((n + 1)); echo \$n >$attempts
if [ "\$n" -lt 2 ]; then
    echo "Creation of temporary directory failed: No space left on device"
    exit 1
fi
echo "recovered output"
exit 0
EOF
chmod +x "$fakebin/cmd"

if "$RETRY" "$fakebin/cmd" >"$out" 2>&1; then
    if grep -q "recovered output" "$out"; then
        _fail "recovery: success output should not leak" "$(cat "$out")"
    elif ! grep -q "disk space error on attempt 1/3" "$out"; then
        _fail "recovery: prune-retry notice should appear on stderr" "$(cat "$out")"
    else
        _pass
    fi
else
    _fail "recovery: should exit 0 after retry succeeds" "$(cat "$out")"
fi

# --- Module bootstrap "inner env file: not found" retries and recovers -------
# Dagger occasionally fails module load with a blob-not-found reference:
#   "load user defaults: failed to check for inner env file in <path>:
#    <session-id>: not found"
# Re-invoking clears it, so treat it like a network blip (see #207).
echo 0 >"$attempts"
cat >"$fakebin/cmd" <<EOF
#!/usr/bin/env bash
n=\$(cat $attempts); n=\$((n + 1)); echo \$n >$attempts
if [ "\$n" -lt 2 ]; then
    echo "Error: query module objects: loading modules: loading extra module \"ci\": resolving module source \"ci\": load user defaults: failed to check for inner env file in /src/ci: dy0t62zt68srtw6tglzpgdf8a: not found"
    exit 1
fi
echo "OK: version verified on alpha track"
exit 0
EOF
chmod +x "$fakebin/cmd"

if "$RETRY" "$fakebin/cmd" >"$out" 2>&1; then
    if grep -q "OK: version verified" "$out"; then
        _fail "bootstrap: success output should not leak" "$(cat "$out")"
    elif ! grep -q "module bootstrap error on attempt 1/3" "$out"; then
        _fail "bootstrap: retry notice should appear on stderr" "$(cat "$out")"
    else
        _pass
    fi
else
    _fail "bootstrap: should exit 0 after retry succeeds" "$(cat "$out")"
fi

export PATH="$PATH_SAVED"
rm -rf "$fakebin" "$attempts"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
