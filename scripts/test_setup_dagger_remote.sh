#!/usr/bin/env bash
# Tests for the Dagger verify block in scripts/setup_dagger_remote.sh.
# The verify call wraps `dagger core --help` in a retry-on-timeout loop and
# distinguishes a transient engine timeout (exit 124) from a genuine CLI/engine
# version mismatch. These tests pin both behaviors. See issues #103 and #105.
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
# decrypts secrets and sets up the SSH tunnel — irrelevant for the diagnostic
# and retry behavior under test, and would require real network/SOPS access.
_verify_snippet=$(awk '/^# Verify the connection/,0' "$SCRIPT")
if [ -z "$_verify_snippet" ]; then
    echo "FAIL: could not locate verify block in $SCRIPT"
    exit 1
fi

# Same trick for the SSH tunnel block. Runs from the tunnel comment down to
# (but not including) the `# Export _EXPERIMENTAL_DAGGER_RUNNER_HOST` line that
# follows it — that export writes to $GITHUB_ENV, which we don't want to touch
# from the test.
_tunnel_snippet=$(awk '/^# Create a background SSH tunnel/{p=1} /^# Export _EXPERIMENTAL_DAGGER_RUNNER_HOST/{p=0} p' "$SCRIPT")
if [ -z "$_tunnel_snippet" ]; then
    echo "FAIL: could not locate tunnel block in $SCRIPT"
    exit 1
fi

# Per-test scratch dir holds the stubbed `dagger`/`timeout`/`sleep` binaries
# and an attempts counter that the dagger stub increments on each call. The
# caller resets it via setup_run, runs the snippet, and reads attempts from
# "$SCRATCH/attempts" afterwards.
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

cat >"$SCRATCH/dagger" <<EOF
#!/usr/bin/env bash
# args: version | core --help
case "\$1" in
    version)
        echo "dagger v0.21.7"
        ;;
    core)
        n=\$(cat "$SCRATCH/attempts"); n=\$((n + 1)); echo \$n >"$SCRATCH/attempts"
        if [ -n "\${DAGGER_CORE_OUTPUT:-}" ]; then
            printf '%s\n' "\$DAGGER_CORE_OUTPUT"
        fi
        if [ -n "\${DAGGER_CORE_SUCCEED_ON:-}" ] && [ "\$n" -ge "\$DAGGER_CORE_SUCCEED_ON" ]; then
            exit 0
        fi
        exit "\${DAGGER_CORE_RC:-0}"
        ;;
esac
EOF
chmod +x "$SCRATCH/dagger"
# Stub `timeout` so the script's `timeout 45 dagger ...` simply runs dagger
# and surfaces the configured exit code (including 124 for a "timeout").
cat >"$SCRATCH/timeout" <<'EOF'
#!/usr/bin/env bash
shift  # drop the duration
"$@"
EOF
chmod +x "$SCRATCH/timeout"
# Stub sleep so the 10s pause between retries doesn't slow the test suite.
cat >"$SCRATCH/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SCRATCH/sleep"
# Stub ssh so the tunnel snippet can be exercised without a real remote host.
# Mirrors the dagger stub: increments an attempts counter, prints
# $SSH_STDERR (to stderr, matching how real ssh reports errors), then flips
# to rc=0 on/after $SSH_SUCCEED_ON if set — otherwise returns $SSH_RC.
cat >"$SCRATCH/ssh" <<EOF
#!/usr/bin/env bash
n=\$(cat "$SCRATCH/ssh_attempts"); n=\$((n + 1)); echo \$n >"$SCRATCH/ssh_attempts"
if [ -n "\${SSH_STDERR:-}" ]; then
    printf '%s\n' "\$SSH_STDERR" >&2
fi
if [ -n "\${SSH_SUCCEED_ON:-}" ] && [ "\$n" -ge "\$SSH_SUCCEED_ON" ]; then
    exit 0
fi
exit "\${SSH_RC:-0}"
EOF
chmod +x "$SCRATCH/ssh"

# Run the verify snippet with the stubs above. Behavior is controlled by env
# vars set by the caller:
#   DAGGER_CORE_RC          — exit code returned by `dagger core --help`
#   DAGGER_CORE_OUTPUT      — text emitted by `dagger core --help`
#   DAGGER_CORE_SUCCEED_ON  — attempt number on which to flip to rc=0 (optional)
# The attempts counter is reset before each call; read it via $SCRATCH/attempts.
#
# We pin DAGGER_VERIFY_MAX_ATTEMPTS=3 (the production default is 5) and the
# per-attempt timeout to 45s so the assertion strings below stay stable; the
# script's behavior — retry, distinguish 124 from non-124, surface the count
# in the error — is identical at any budget.
run_verify() {
    echo 0 >"$SCRATCH/attempts"
    PATH="$SCRATCH:$PATH" \
        DAGGER_VERIFY_MAX_ATTEMPTS=3 \
        DAGGER_VERIFY_TIMEOUT_S=45 \
        DAGGER_VERIFY_RETRY_WAIT_S=0 \
        bash -c "$_verify_snippet" 2>&1
}

# --- Empty verify_out after 3 timeouts prints engine-down error ----------------
out=$(DAGGER_CORE_RC=124 DAGGER_CORE_OUTPUT="" run_verify)
rc=$?
attempts=$(cat "$SCRATCH/attempts")
if [ "$rc" -eq 0 ]; then
    _fail "timeout: should exit non-zero" "$out"
elif [ "$attempts" -ne 3 ]; then
    _fail "timeout: should retry to 3 attempts (got $attempts)" "$out"
elif ! printf '%s' "$out" | grep -q "did not respond within 45s on 3 attempts"; then
    _fail "timeout: engine-timeout error message missing" "$out"
elif ! printf '%s' "$out" | grep -q "verify exit code: 124"; then
    _fail "timeout: diagnostics should include the verify exit code" "$out"
elif ! printf '%s' "$out" | grep -q "no output captured"; then
    _fail "timeout: should note that no output was captured" "$out"
else
    _pass
fi

# --- Transient timeout that recovers on attempt 2 succeeds silently ------------
out=$(DAGGER_CORE_RC=124 DAGGER_CORE_OUTPUT="" DAGGER_CORE_SUCCEED_ON=2 run_verify)
rc=$?
attempts=$(cat "$SCRATCH/attempts")
if [ "$rc" -ne 0 ]; then
    _fail "transient: should exit 0 after retry succeeds" "$out"
elif [ "$attempts" -ne 2 ]; then
    _fail "transient: expected 2 attempts (got $attempts)" "$out"
elif printf '%s' "$out" | grep -q "::error::"; then
    _fail "transient: should not print ::error:: lines after recovery" "$out"
elif ! printf '%s' "$out" | grep -q "::warning::Dagger verify attempt 1/3 timed out"; then
    _fail "transient: should warn about the timed-out first attempt" "$out"
elif ! printf '%s' "$out" | grep -q "Dagger connection verified successfully"; then
    _fail "transient: should print the verified confirmation line" "$out"
else
    _pass
fi

# --- Version mismatch (rc!=124) does NOT retry; prints mismatch error ----------
mismatch_output='Error: dagger engine v0.20.5 is incompatible with CLI v0.21.7'
out=$(DAGGER_CORE_RC=1 DAGGER_CORE_OUTPUT="$mismatch_output" run_verify)
rc=$?
attempts=$(cat "$SCRATCH/attempts")
if [ "$rc" -eq 0 ]; then
    _fail "mismatch: should exit non-zero" "$out"
elif [ "$attempts" -ne 1 ]; then
    _fail "mismatch: should not retry (got $attempts attempts)" "$out"
elif ! printf '%s' "$out" | grep -q "version mismatch"; then
    _fail "mismatch: should print version-mismatch error" "$out"
elif ! printf '%s' "$out" | grep -q "v0.20.5"; then
    _fail "mismatch: should surface the engine version it parsed" "$out"
elif ! printf '%s' "$out" | grep -q "v0.21.7"; then
    _fail "mismatch: should surface the runner CLI version" "$out"
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

# --- Success on first attempt: silent about errors and verified-line printed ---
out=$(DAGGER_CORE_RC=0 DAGGER_CORE_OUTPUT="usage: dagger core ..." run_verify)
rc=$?
attempts=$(cat "$SCRATCH/attempts")
if [ "$rc" -ne 0 ]; then
    _fail "success: should exit 0" "$out"
elif [ "$attempts" -ne 1 ]; then
    _fail "success: should not retry (got $attempts attempts)" "$out"
elif printf '%s' "$out" | grep -q "::error::"; then
    _fail "success: should not print ::error:: lines" "$out"
elif printf '%s' "$out" | grep -q "::warning::"; then
    _fail "success: should not print ::warning:: lines" "$out"
elif ! printf '%s' "$out" | grep -q "Dagger connection verified successfully"; then
    _fail "success: should print the verified confirmation line" "$out"
else
    _pass
fi

# Run the SSH-tunnel snippet with the stubs above. Behavior is controlled by:
#   SSH_RC          — exit code returned by `ssh` when it doesn't succeed
#   SSH_STDERR      — text emitted by `ssh` on stderr (e.g. "Connection reset")
#   SSH_SUCCEED_ON  — attempt number on which to flip to rc=0 (optional)
# Pin MAX_ATTEMPTS=3 to keep the "failed after N attempts" assertion stable.
# DAGGER_ENGINE_HOST is a normal env var inside the snippet, not a secret in
# this test path — just something for the ssh stub to receive as an argument.
run_tunnel() {
    echo 0 >"$SCRATCH/ssh_attempts"
    PATH="$SCRATCH:$PATH" \
        DAGGER_ENGINE_HOST=engine.test \
        DAGGER_TUNNEL_MAX_ATTEMPTS=3 \
        DAGGER_TUNNEL_TIMEOUT_S=5 \
        DAGGER_TUNNEL_RETRY_WAIT_S=0 \
        bash -c "$_tunnel_snippet" 2>&1
}

# --- Tunnel: success on first attempt is silent about errors/warnings ---------
out=$(SSH_RC=0 run_tunnel)
rc=$?
attempts=$(cat "$SCRATCH/ssh_attempts")
if [ "$rc" -ne 0 ]; then
    _fail "tunnel success: should exit 0" "$out"
elif [ "$attempts" -ne 1 ]; then
    _fail "tunnel success: should not retry (got $attempts attempts)" "$out"
elif printf '%s' "$out" | grep -q "::error::"; then
    _fail "tunnel success: should not print ::error:: lines" "$out"
elif printf '%s' "$out" | grep -q "::warning::"; then
    _fail "tunnel success: should not print ::warning:: lines" "$out"
elif ! printf '%s' "$out" | grep -q "Establishing SSH tunnel"; then
    _fail "tunnel success: should log the establishing line" "$out"
else
    _pass
fi

# --- Tunnel: transient connection-reset that recovers on attempt 2 ------------
out=$(SSH_RC=255 SSH_STDERR="kex_exchange_identification: read: Connection reset by peer" SSH_SUCCEED_ON=2 run_tunnel)
rc=$?
attempts=$(cat "$SCRATCH/ssh_attempts")
if [ "$rc" -ne 0 ]; then
    _fail "tunnel transient: should exit 0 after retry succeeds" "$out"
elif [ "$attempts" -ne 2 ]; then
    _fail "tunnel transient: expected 2 attempts (got $attempts)" "$out"
elif printf '%s' "$out" | grep -q "::error::"; then
    _fail "tunnel transient: should not print ::error:: lines after recovery" "$out"
elif ! printf '%s' "$out" | grep -q "::warning::SSH tunnel attempt 1/3 failed"; then
    _fail "tunnel transient: should warn about the failed first attempt" "$out"
elif ! printf '%s' "$out" | grep -q "kex_exchange_identification"; then
    _fail "tunnel transient: should surface the captured ssh stderr" "$out"
else
    _pass
fi

# --- Tunnel: all three attempts fail — surfaces error, exits non-zero ---------
out=$(SSH_RC=255 SSH_STDERR="kex_exchange_identification: read: Connection reset by peer" run_tunnel)
rc=$?
attempts=$(cat "$SCRATCH/ssh_attempts")
if [ "$rc" -eq 0 ]; then
    _fail "tunnel fail: should exit non-zero" "$out"
elif [ "$attempts" -ne 3 ]; then
    _fail "tunnel fail: should retry to 3 attempts (got $attempts)" "$out"
elif ! printf '%s' "$out" | grep -q "SSH tunnel to engine.test failed after 3 attempts"; then
    _fail "tunnel fail: final error should name host + attempt count" "$out"
elif ! printf '%s' "$out" | grep -q "rc=255"; then
    _fail "tunnel fail: should surface the ssh exit code" "$out"
elif ! printf '%s' "$out" | grep -q "kex_exchange_identification"; then
    _fail "tunnel fail: should include ssh stderr in diagnostics" "$out"
else
    _pass
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
