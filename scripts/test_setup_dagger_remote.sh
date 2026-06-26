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

# -----------------------------------------------------------------------------
# Tests for the ssh-keyscan retry block.
# Mirrors the verify-block strategy: extract just the keyscan section of
# setup_dagger_remote.sh and drive it with stubbed `ssh-keyscan`/`timeout`/
# `sleep` binaries on PATH. See issue #171 — the original keyscan call sent
# stderr to /dev/null, so a transient failure exited the script with no log.
# -----------------------------------------------------------------------------
_keyscan_snippet=$(awk '/^# Add remote host to known_hosts/{flag=1} /^# Create a background SSH tunnel/{flag=0} flag' "$SCRIPT")
if [ -z "$_keyscan_snippet" ]; then
    echo "FAIL: could not locate keyscan block in $SCRIPT"
    exit 1
fi

# Stub ssh-keyscan. Behavior is controlled by env vars set by the caller:
#   KEYSCAN_RC          — exit code to return
#   KEYSCAN_STDOUT      — text to write to stdout (host keys)
#   KEYSCAN_STDERR      — text to write to stderr
#   KEYSCAN_SUCCEED_ON  — attempt number on which to flip to rc=0+keys (optional)
# Each invocation increments an attempts counter at $SCRATCH/keyscan_attempts.
cat >"$SCRATCH/ssh-keyscan" <<EOF
#!/usr/bin/env bash
n=\$(cat "$SCRATCH/keyscan_attempts"); n=\$((n + 1)); echo \$n >"$SCRATCH/keyscan_attempts"
if [ -n "\${KEYSCAN_SUCCEED_ON:-}" ] && [ "\$n" -ge "\$KEYSCAN_SUCCEED_ON" ]; then
    printf '%s\n' "\${KEYSCAN_SUCCEED_STDOUT:-host ssh-ed25519 AAAAFAKE}"
    exit 0
fi
[ -n "\${KEYSCAN_STDOUT:-}" ] && printf '%s\n' "\$KEYSCAN_STDOUT"
[ -n "\${KEYSCAN_STDERR:-}" ] && printf '%s\n' "\$KEYSCAN_STDERR" >&2
exit "\${KEYSCAN_RC:-0}"
EOF
chmod +x "$SCRATCH/ssh-keyscan"

# Run the keyscan snippet with the stubs above. Pin the budget to keep
# assertion strings stable; the script behaves identically with the
# production defaults (3 attempts, 5s wait, 30s per attempt).
run_keyscan() {
    echo 0 >"$SCRATCH/keyscan_attempts"
    # The snippet appends to ~/.ssh/known_hosts; redirect HOME to a scratch
    # dir so the test does not touch the real known_hosts.
    fake_home="$SCRATCH/home"
    mkdir -p "$fake_home/.ssh"
    PATH="$SCRATCH:$PATH" \
        HOME="$fake_home" \
        SECRETS_JSON=/dev/null \
        DAGGER_ENGINE_HOST=engine.test \
        DAGGER_KEYSCAN_MAX_ATTEMPTS=3 \
        DAGGER_KEYSCAN_TIMEOUT_S=5 \
        DAGGER_KEYSCAN_RETRY_WAIT_S=0 \
        bash -c "$_keyscan_snippet" 2>&1
}

# --- All attempts return rc!=0 + stderr: snippet exits with diagnostics --------
out=$(KEYSCAN_RC=1 KEYSCAN_STDERR='getaddrinfo engine.test: Name or service not known' run_keyscan)
rc=$?
attempts=$(cat "$SCRATCH/keyscan_attempts")
if [ "$rc" -eq 0 ]; then
    _fail "keyscan-fail: should exit non-zero" "$out"
elif [ "$attempts" -ne 3 ]; then
    _fail "keyscan-fail: should retry to 3 attempts (got $attempts)" "$out"
elif ! printf '%s' "$out" | grep -q "ssh-keyscan failed to fetch SSH host keys"; then
    _fail "keyscan-fail: should print final-failure error" "$out"
elif ! printf '%s' "$out" | grep -q "getaddrinfo engine.test"; then
    _fail "keyscan-fail: should replay captured stderr in diagnostics" "$out"
else
    _pass
fi

# --- rc=0 but empty stdout still counts as failure (host refused mid-handshake)
out=$(KEYSCAN_RC=0 KEYSCAN_STDOUT='' run_keyscan)
rc=$?
attempts=$(cat "$SCRATCH/keyscan_attempts")
if [ "$rc" -eq 0 ]; then
    _fail "keyscan-empty: should exit non-zero on empty output" "$out"
elif [ "$attempts" -ne 3 ]; then
    _fail "keyscan-empty: should retry empty-output attempts (got $attempts)" "$out"
elif ! printf '%s' "$out" | grep -q "ssh-keyscan failed to fetch SSH host keys"; then
    _fail "keyscan-empty: should print final-failure error" "$out"
else
    _pass
fi

# --- Transient failure that recovers on attempt 2 succeeds silently ------------
out=$(KEYSCAN_RC=1 KEYSCAN_STDERR='connection refused' KEYSCAN_SUCCEED_ON=2 run_keyscan)
rc=$?
attempts=$(cat "$SCRATCH/keyscan_attempts")
if [ "$rc" -ne 0 ]; then
    _fail "keyscan-transient: should exit 0 after retry succeeds" "$out"
elif [ "$attempts" -ne 2 ]; then
    _fail "keyscan-transient: expected 2 attempts (got $attempts)" "$out"
elif printf '%s' "$out" | grep -q "::error::"; then
    _fail "keyscan-transient: should not print ::error:: after recovery" "$out"
elif ! printf '%s' "$out" | grep -q "::warning::ssh-keyscan attempt 1/3 failed"; then
    _fail "keyscan-transient: should warn about the failed first attempt" "$out"
else
    _pass
fi

# --- Success on first attempt: silent + appends key to known_hosts -------------
out=$(KEYSCAN_RC=0 KEYSCAN_STDOUT='host ssh-ed25519 AAAAREAL' run_keyscan)
rc=$?
attempts=$(cat "$SCRATCH/keyscan_attempts")
if [ "$rc" -ne 0 ]; then
    _fail "keyscan-success: should exit 0" "$out"
elif [ "$attempts" -ne 1 ]; then
    _fail "keyscan-success: should not retry (got $attempts attempts)" "$out"
elif printf '%s' "$out" | grep -q "::warning::"; then
    _fail "keyscan-success: should not print ::warning::" "$out"
elif printf '%s' "$out" | grep -q "::error::"; then
    _fail "keyscan-success: should not print ::error::" "$out"
elif ! grep -q "AAAAREAL" "$SCRATCH/home/.ssh/known_hosts"; then
    _fail "keyscan-success: should append captured key to ~/.ssh/known_hosts" "$out"
else
    _pass
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
