#!/usr/bin/env bash
# Tests for the Dagger verify/diagnostic block in scripts/setup_dagger_remote.sh.
# The verify block has historically swallowed errors: under `set -e` + pipefail,
# an empty `verify_out` made the engine-version grep return non-zero and the
# script exited silently before any of the diagnostic ::error:: lines printed.
# These tests pin the diagnostic-output contract so that regression doesn't
# happen again. See issue #103.
#
# Run directly: bash scripts/test_setup_dagger_remote.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/setup_dagger_remote.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); }
_fail() {
    echo "FAIL: $1"
    [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
}

# Drive the verify block by sourcing the section of setup_dagger_remote.sh that
# starts at the `# Verify the connection` comment. Everything above that line
# decrypts secrets and sets up the SSH tunnel — irrelevant for diagnostic-output
# behavior, and would require real network/SOPS access to run.
_verify_snippet=$(awk '/^# Verify the connection/,0' "$SCRIPT")
if [ -z "$_verify_snippet" ]; then
    echo "FAIL: could not locate verify block in $SCRIPT"
    exit 1
fi

# Run the verify snippet with a stubbed `dagger`, `timeout` and `sleep` so we
# control the exit code and captured output it sees. DAGGER_CORE_RC may be a
# single rc applied to every call, or a space-separated sequence (e.g.
# "124 0 0") for testing retry behavior across attempts. The total number of
# `dagger core` invocations is appended to stdout as `__ATTEMPTS__=N`.
run_verify() {
    local fakebin attempt_state
    fakebin=$(mktemp -d)
    attempt_state=$(mktemp)
    echo 0 >"$attempt_state"
    cat >"$fakebin/dagger" <<EOF
#!/usr/bin/env bash
case "\$1" in
    version)
        echo "dagger v0.21.7"
        ;;
    core)
        if [ -n "\${DAGGER_CORE_OUTPUT:-}" ]; then
            printf '%s\n' "\$DAGGER_CORE_OUTPUT"
        fi
        n=\$(cat $attempt_state); n=\$((n + 1)); echo \$n >$attempt_state
        read -ra rcs <<<"\${DAGGER_CORE_RC:-0}"
        idx=\$(( n - 1 ))
        if [ "\$idx" -ge "\${#rcs[@]}" ]; then
            idx=\$(( \${#rcs[@]} - 1 ))
        fi
        exit "\${rcs[\$idx]}"
        ;;
esac
EOF
    chmod +x "$fakebin/dagger"
    cat >"$fakebin/timeout" <<'EOF'
#!/usr/bin/env bash
shift  # drop the duration
"$@"
EOF
    chmod +x "$fakebin/timeout"
    cat >"$fakebin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fakebin/sleep"

    PATH="$fakebin:$PATH" bash -c "$_verify_snippet" 2>&1
    local rc=$? attempts
    attempts=$(cat "$attempt_state")
    rm -rf "$fakebin" "$attempt_state"
    printf '__ATTEMPTS__=%s\n' "$attempts"
    return "$rc"
}

# Extract the attempt count from the marker line run_verify appends.
_attempts() { printf '%s' "$1" | sed -n 's/^__ATTEMPTS__=//p'; }

# --- Persistent timeout (engine never replies) exhausts retries with transient error
out=$(DAGGER_CORE_RC=124 DAGGER_CORE_OUTPUT="" run_verify)
rc=$?
if [ "$rc" -eq 0 ]; then
    _fail "timeout: should exit non-zero" "$out"
elif ! printf '%s' "$out" | grep -q "did not respond after 3 attempts"; then
    _fail "timeout: transient-timeout error message missing" "$out"
elif ! printf '%s' "$out" | grep -q "verify exit code: 124"; then
    _fail "timeout: diagnostics should include the verify exit code" "$out"
elif ! printf '%s' "$out" | grep -q "no output captured"; then
    _fail "timeout: should note that no output was captured" "$out"
elif [ "$(_attempts "$out")" != "3" ]; then
    _fail "timeout: should attempt 3 times before giving up (got $(_attempts "$out"))" "$out"
else
    _pass
fi

# --- Version mismatch fails immediately, no retries ----------------------------
mismatch_output='Error: dagger engine v0.20.5 is incompatible with CLI v0.21.7'
out=$(DAGGER_CORE_RC=1 DAGGER_CORE_OUTPUT="$mismatch_output" run_verify)
rc=$?
if [ "$rc" -eq 0 ]; then
    _fail "mismatch: should exit non-zero" "$out"
elif ! printf '%s' "$out" | grep -q "version mismatch"; then
    _fail "mismatch: should print version-mismatch error" "$out"
elif ! printf '%s' "$out" | grep -q "v0.20.5"; then
    _fail "mismatch: should surface the engine version it parsed" "$out"
elif ! printf '%s' "$out" | grep -q "v0.21.7"; then
    _fail "mismatch: should surface the runner CLI version" "$out"
elif [ "$(_attempts "$out")" != "1" ]; then
    _fail "mismatch: should fail fast (no retries), got $(_attempts "$out") attempts" "$out"
else
    _pass
fi

# --- Non-empty output with no parseable engine version still prints diagnostics
out=$(DAGGER_CORE_RC=1 DAGGER_CORE_OUTPUT='connection refused' run_verify)
rc=$?
if [ "$rc" -eq 0 ]; then
    _fail "unparseable: should exit non-zero" "$out"
elif ! printf '%s' "$out" | grep -q "::error::"; then
    _fail "unparseable: should print at least one ::error:: line" "$out"
elif ! printf '%s' "$out" | grep -q "connection refused"; then
    _fail "unparseable: should include captured output in diagnostics" "$out"
else
    _pass
fi

# --- Success path stays silent about errors and prints the verified line -------
out=$(DAGGER_CORE_RC=0 DAGGER_CORE_OUTPUT="usage: dagger core ..." run_verify)
rc=$?
if [ "$rc" -ne 0 ]; then
    _fail "success: should exit 0" "$out"
elif printf '%s' "$out" | grep -q "::error::"; then
    _fail "success: should not print ::error:: lines" "$out"
elif ! printf '%s' "$out" | grep -q "Dagger connection verified successfully"; then
    _fail "success: should print the verified confirmation line" "$out"
elif [ "$(_attempts "$out")" != "1" ]; then
    _fail "success: should not retry when first attempt succeeds, got $(_attempts "$out") attempts" "$out"
else
    _pass
fi

# --- Transient timeout that recovers on retry succeeds silently ----------------
out=$(DAGGER_CORE_RC="124 0" DAGGER_CORE_OUTPUT="usage: dagger core ..." run_verify)
rc=$?
if [ "$rc" -ne 0 ]; then
    _fail "recovery: should exit 0 after retry succeeds" "$out"
elif ! printf '%s' "$out" | grep -q "Dagger connection verified successfully"; then
    _fail "recovery: should print the verified confirmation line" "$out"
elif ! printf '%s' "$out" | grep -q "attempt 1/3 failed"; then
    _fail "recovery: should print a warning about the first attempt failing" "$out"
elif printf '%s' "$out" | grep -q "::error::"; then
    _fail "recovery: should not print ::error:: after recovery" "$out"
elif [ "$(_attempts "$out")" != "2" ]; then
    _fail "recovery: should take 2 attempts, got $(_attempts "$out")" "$out"
else
    _pass
fi

# --- ssh transport failure (rc=255) is also treated as transient ---------------
out=$(DAGGER_CORE_RC="255 0" DAGGER_CORE_OUTPUT="" run_verify)
rc=$?
if [ "$rc" -ne 0 ]; then
    _fail "ssh-transient: should exit 0 after retry succeeds" "$out"
elif [ "$(_attempts "$out")" != "2" ]; then
    _fail "ssh-transient: should take 2 attempts, got $(_attempts "$out")" "$out"
else
    _pass
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
