#!/usr/bin/env bash
# Tests for the retry blocks in scripts/setup_dagger_remote.sh.
#
# The verify call wraps `dagger core --help` in a retry-on-timeout loop and
# distinguishes a transient engine timeout (exit 124) from a genuine CLI/engine
# version mismatch. These tests pin both behaviors. See issues #103 and #105.
#
# The SSH tunnel call also retries on transient connection failures — the
# engine host's sshd occasionally resets the TCP connection during key
# exchange (issue #221), or the host briefly hangs and the wrapping `timeout`
# kills ssh with rc=124 (issue #243). Additional tests below pin that
# retry behavior.
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

# --- SSH tunnel retry block --------------------------------------------------
# Drive the tunnel block by extracting the section that starts at the
# `# Create a background SSH tunnel` comment and stops just before the
# `# Export _EXPERIMENTAL_DAGGER_RUNNER_HOST` line. Everything above that is
# secret decryption and known_hosts priming — not under test here — and
# everything below it is the verify block already covered above.
_tunnel_snippet=$(awk '/^# Create a background SSH tunnel/{p=1} /^# Export _EXPERIMENTAL_DAGGER_RUNNER_HOST/{exit} p' "$SCRIPT")
if [ -z "$_tunnel_snippet" ]; then
    echo "FAIL: could not locate SSH tunnel block in $SCRIPT"
    exit 1
fi

# Stub `ssh` to count attempts and honor SSH_RC / SSH_SUCCEED_ON / SSH_STDERR_MSG.
# The real ssh command uses `-f -N -L ...`; the stub ignores every argument and
# just returns the configured exit code, which is what the retry loop keys off.
cat >"$SCRATCH/ssh" <<EOF
#!/usr/bin/env bash
n=\$(cat "$SCRATCH/ssh_attempts"); n=\$((n + 1)); echo \$n >"$SCRATCH/ssh_attempts"
if [ -n "\${SSH_STDERR_MSG:-}" ]; then
    printf '%s\n' "\$SSH_STDERR_MSG" >&2
fi
if [ -n "\${SSH_SUCCEED_ON:-}" ] && [ "\$n" -ge "\$SSH_SUCCEED_ON" ]; then
    exit 0
fi
exit "\${SSH_RC:-0}"
EOF
chmod +x "$SCRATCH/ssh"

# Run the tunnel snippet with the stubs above. Behavior is controlled by:
#   SSH_RC             — exit code returned by ssh
#   SSH_SUCCEED_ON     — attempt number on which to flip to rc=0 (optional)
#   SSH_STDERR_MSG     — stderr line the stub emits (simulates the real ssh error)
# The attempts counter is reset before each call; read via $SCRATCH/ssh_attempts.
#
# Pinning DAGGER_TUNNEL_MAX_ATTEMPTS=3 to keep assertion strings stable and
# DAGGER_TUNNEL_RETRY_WAIT_S=0 so retries don't slow the test suite.
run_tunnel() {
    echo 0 >"$SCRATCH/ssh_attempts"
    PATH="$SCRATCH:$PATH" \
        DAGGER_TUNNEL_MAX_ATTEMPTS=3 \
        DAGGER_TUNNEL_TIMEOUT_S=30 \
        DAGGER_TUNNEL_RETRY_WAIT_S=0 \
        DAGGER_ENGINE_HOST="engine.example" \
        bash -c "$_tunnel_snippet" 2>&1
}

# --- Success on first attempt: silent, one ssh call, no retry warning ---------
out=$(SSH_RC=0 run_tunnel)
rc=$?
attempts=$(cat "$SCRATCH/ssh_attempts")
if [ "$rc" -ne 0 ]; then
    _fail "tunnel success: should exit 0" "$out"
elif [ "$attempts" -ne 1 ]; then
    _fail "tunnel success: should call ssh exactly once (got $attempts)" "$out"
elif printf '%s' "$out" | grep -q "::error::"; then
    _fail "tunnel success: should not print ::error:: lines" "$out"
elif printf '%s' "$out" | grep -q "::warning::SSH tunnel attempt"; then
    _fail "tunnel success: should not print retry warnings" "$out"
elif ! printf '%s' "$out" | grep -q "Establishing SSH tunnel to engine.example"; then
    _fail "tunnel success: should print the establishing line" "$out"
else
    _pass
fi

# --- Transient reset that recovers on attempt 2: warning + exit 0 -------------
kex_msg='kex_exchange_identification: read: Connection reset by peer'
out=$(SSH_RC=255 SSH_STDERR_MSG="$kex_msg" SSH_SUCCEED_ON=2 run_tunnel)
rc=$?
attempts=$(cat "$SCRATCH/ssh_attempts")
if [ "$rc" -ne 0 ]; then
    _fail "tunnel transient: should exit 0 after retry succeeds" "$out"
elif [ "$attempts" -ne 2 ]; then
    _fail "tunnel transient: expected 2 attempts (got $attempts)" "$out"
elif printf '%s' "$out" | grep -q "::error::"; then
    _fail "tunnel transient: should not print ::error:: lines after recovery" "$out"
elif ! printf '%s' "$out" | grep -q "::warning::SSH tunnel attempt 1/3 failed (rc=255)"; then
    _fail "tunnel transient: should warn about the failed first attempt" "$out"
else
    _pass
fi

# --- Persistent failure through all attempts: retries then errors and exits ---
out=$(SSH_RC=255 SSH_STDERR_MSG="$kex_msg" run_tunnel)
rc=$?
attempts=$(cat "$SCRATCH/ssh_attempts")
if [ "$rc" -eq 0 ]; then
    _fail "tunnel persistent: should exit non-zero" "$out"
elif [ "$attempts" -ne 3 ]; then
    _fail "tunnel persistent: should retry to 3 attempts (got $attempts)" "$out"
elif ! printf '%s' "$out" | grep -q "SSH tunnel to the Dagger engine host failed after 3 attempts"; then
    _fail "tunnel persistent: should print the final failure error" "$out"
elif ! printf '%s' "$out" | grep -q "last rc=255"; then
    _fail "tunnel persistent: should surface the last rc in the error" "$out"
elif ! printf '%s' "$out" | grep -q "::warning::SSH tunnel attempt 2/3 failed"; then
    _fail "tunnel persistent: should print an intermediate retry warning" "$out"
elif printf '%s' "$out" | grep -q "::warning::SSH tunnel attempt 3/3 failed"; then
    _fail "tunnel persistent: should not warn on the final attempt (error prints instead)" "$out"
else
    _pass
fi

# --- Timeout (rc=124) recovers on attempt 3: issue #243 case ------------------
# The engine host briefly hangs and ssh is killed by the wrapping `timeout`.
# The retry loop treats rc=124 the same as rc=255 — retry until success or
# max attempts. This mirrors the real-world blip that lasted ~2 minutes.
out=$(SSH_RC=124 SSH_STDERR_MSG="" SSH_SUCCEED_ON=3 run_tunnel)
rc=$?
attempts=$(cat "$SCRATCH/ssh_attempts")
if [ "$rc" -ne 0 ]; then
    _fail "tunnel timeout-recovery: should exit 0 after retry succeeds" "$out"
elif [ "$attempts" -ne 3 ]; then
    _fail "tunnel timeout-recovery: expected 3 attempts (got $attempts)" "$out"
elif printf '%s' "$out" | grep -q "::error::"; then
    _fail "tunnel timeout-recovery: should not print ::error:: lines after recovery" "$out"
elif ! printf '%s' "$out" | grep -q "::warning::SSH tunnel attempt 1/3 failed (rc=124)"; then
    _fail "tunnel timeout-recovery: should warn about the first timed-out attempt" "$out"
elif ! printf '%s' "$out" | grep -q "::warning::SSH tunnel attempt 2/3 failed (rc=124)"; then
    _fail "tunnel timeout-recovery: should warn about the second timed-out attempt" "$out"
else
    _pass
fi

# --- Default budget is generous (issue #243): 5 attempts, 15s wait ------------
# Regression guard so a future edit doesn't quietly tighten the retry loop
# back down below what we need to ride out ~2-minute engine-host blips.
_defaults=$(awk '/^TUNNEL_TIMEOUT_S=/{t=$0} /^TUNNEL_MAX_ATTEMPTS=/{a=$0} /^TUNNEL_RETRY_WAIT_S=/{w=$0; print t; print a; print w; exit}' "$SCRIPT")
if ! printf '%s' "$_defaults" | grep -qE 'TUNNEL_MAX_ATTEMPTS="\$\{DAGGER_TUNNEL_MAX_ATTEMPTS:-5\}"'; then
    _fail "defaults: TUNNEL_MAX_ATTEMPTS default should be 5" "$_defaults"
elif ! printf '%s' "$_defaults" | grep -qE 'TUNNEL_RETRY_WAIT_S="\$\{DAGGER_TUNNEL_RETRY_WAIT_S:-15\}"'; then
    _fail "defaults: TUNNEL_RETRY_WAIT_S default should be 15" "$_defaults"
else
    _pass
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
