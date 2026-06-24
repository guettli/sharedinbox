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

# Run the verify snippet with a stubbed `dagger` (and `timeout` if needed) so we
# control the exit code and captured output it sees.
run_verify() {
    local fakebin
    fakebin=$(mktemp -d)
    cat >"$fakebin/dagger" <<'EOF'
#!/usr/bin/env bash
# args: version | core --help
case "$1" in
    version)
        echo "dagger v0.21.7"
        ;;
    core)
        if [ -n "${DAGGER_CORE_OUTPUT:-}" ]; then
            printf '%s\n' "$DAGGER_CORE_OUTPUT"
        fi
        exit "${DAGGER_CORE_RC:-0}"
        ;;
esac
EOF
    chmod +x "$fakebin/dagger"
    # Stub `timeout` so the script's `timeout 45 dagger ...` simply runs dagger
    # and surfaces the configured exit code (including 124 for a "timeout").
    cat >"$fakebin/timeout" <<'EOF'
#!/usr/bin/env bash
shift  # drop the duration
"$@"
EOF
    chmod +x "$fakebin/timeout"

    PATH="$fakebin:$PATH" bash -c "$_verify_snippet" 2>&1
    local rc=$?
    rm -rf "$fakebin"
    return "$rc"
}

# --- Empty verify_out (engine never replied) prints transient-timeout error ----
out=$(DAGGER_CORE_RC=124 DAGGER_CORE_OUTPUT="" run_verify)
rc=$?
if [ "$rc" -eq 0 ]; then
    _fail "timeout: should exit non-zero" "$out"
elif ! printf '%s' "$out" | grep -q "did not respond within 45s"; then
    _fail "timeout: transient-timeout error message missing" "$out"
elif ! printf '%s' "$out" | grep -q "verify exit code: 124"; then
    _fail "timeout: diagnostics should include the verify exit code" "$out"
elif ! printf '%s' "$out" | grep -q "no output captured"; then
    _fail "timeout: should note that no output was captured" "$out"
else
    _pass
fi

# --- Version mismatch (engine names its version) prints mismatch error ---------
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
else
    _pass
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
