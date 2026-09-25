#!/usr/bin/env bash
# Tests for the Play-APK fetch retry loop in scripts/run_firebase_test.sh.
# Run directly: bash scripts/test_run_firebase_test.sh
#
# `dagger` (and `python3`, used only by the repo-variable write in step 3) are
# stubbed on PATH, and the loop's timing knobs are turned down via the
# environment, so the whole suite runs in a couple of seconds without an engine.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/run_firebase_test.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); }
_fail() {
    echo "FAIL: $1"
    [ -n "${2:-}" ] && echo "  $2"
    FAIL=$((FAIL + 1))
}

fakebin=$(mktemp -d)
out=$(mktemp)
attempts=$(mktemp)
trap 'rm -rf "$fakebin" "$out" "$attempts"' EXIT

# Stub the dagger CLI. Behaviour per fetch attempt is driven by $BEHAVIOUR:
#   wedge   — sleep past the per-attempt timeout so `timeout` kills us (124)
#   pending — drop versionCode + PENDING, as Play does while it generates splits
#   ready   — drop versionCode + a split APK, i.e. a successful fetch
#   boom    — fail fast with a non-timeout exit code (auth / Play API error)
# A comma-separated list gives one behaviour per attempt; the last entry
# repeats. `test-android-firebase` (step 2) always succeeds.
cat >"$fakebin/dagger" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
    [ "$arg" = "test-android-firebase" ] && exit 0
done
n=$(cat "$ATTEMPTS_FILE"); n=$((n + 1)); echo "$n" >"$ATTEMPTS_FILE"
dest=""
prev=""
for arg in "$@"; do
    [ "$prev" = "-o" ] && dest="$arg"
    prev="$arg"
done
IFS=',' read -ra behaviours <<<"$BEHAVIOUR"
idx=$((n - 1))
[ "$idx" -ge "${#behaviours[@]}" ] && idx=$(( ${#behaviours[@]} - 1 ))
case "${behaviours[$idx]}" in
    wedge)   sleep 30 ;;
    pending) echo 1790309773 >"$dest/versionCode"; : >"$dest/PENDING" ;;
    ready)   echo 1790309773 >"$dest/versionCode"; : >"$dest/base-master.apk" ;;
    boom)    echo "auth error" >&2; exit 3 ;;
esac
EOF
chmod +x "$fakebin/dagger"

# Step 3 writes LAST_TESTED_ALPHA_VERSION_CODE through the GitHub API with a
# python3 heredoc; stub it so a green run never touches the network.
cat >"$fakebin/python3" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo "[firebase] stub: variable write skipped" >&2
EOF
chmod +x "$fakebin/python3"

export PATH="$fakebin:$PATH"
export ATTEMPTS_FILE="$attempts"
export PLAY_STORE_CONFIG_JSON='{"type":"service_account"}'
export FIREBASE_TEST_LAB_SERVICE_ACCOUNT_KEY='{"type":"service_account"}'
export GITHUB_TOKEN=token
export GITHUB_REPOSITORY=guettli/sharedinbox
export FETCH_ATTEMPT_TIMEOUT_SECONDS=1
export FETCH_RETRY_INTERVAL_SECONDS=0

_run_fetch() {
    BEHAVIOUR="$1" FETCH_TOTAL_BUDGET_SECONDS="$2" "$RUNNER" >"$out" 2>&1
}

# --- A wedged attempt is retried, not fatal (#898) ---------------------------
echo 0 >"$attempts"
if _run_fetch wedge,ready 60; then
    n=$(cat "$attempts")
    if [ "$n" -ne 2 ]; then
        _fail "wedge: expected 2 fetch attempts, got $n" "$(cat "$out")"
    elif ! grep -q "fetch attempt 1 wedged" "$out"; then
        _fail "wedge: missing retry warning" "$(cat "$out")"
    elif ! grep -q "downloaded APKs for versionCode=1790309773" "$out"; then
        _fail "wedge: should proceed to the Firebase run after the retry" "$(cat "$out")"
    else
        _pass
    fi
else
    _fail "wedge: should recover and exit 0" "$(cat "$out")"
fi

# --- A wedge that outlasts the budget still fails loudly ---------------------
echo 0 >"$attempts"
if _run_fetch wedge 0; then
    _fail "wedge budget: should exit non-zero once the budget is gone" "$(cat "$out")"
else
    n=$(cat "$attempts")
    if [ "$n" -ne 1 ]; then
        _fail "wedge budget: expected 1 fetch attempt, got $n" "$(cat "$out")"
    elif ! grep -q "kept timing out" "$out"; then
        _fail "wedge budget: missing give-up error" "$(cat "$out")"
    else
        _pass
    fi
fi

# --- A non-timeout fetch failure still aborts immediately --------------------
echo 0 >"$attempts"
if _run_fetch boom 60; then
    _fail "hard failure: should exit non-zero" "$(cat "$out")"
else
    n=$(cat "$attempts")
    if [ "$n" -ne 1 ]; then
        _fail "hard failure: should not retry (attempts: $n)" "$(cat "$out")"
    elif ! grep -q "fetch-play-store-apks failed (exit 3)" "$out"; then
        _fail "hard failure: missing error with exit code" "$(cat "$out")"
    else
        _pass
    fi
fi

# --- Play still generating within the budget: retry across fresh execs -------
echo 0 >"$attempts"
if _run_fetch pending,ready 60; then
    n=$(cat "$attempts")
    if [ "$n" -ne 2 ]; then
        _fail "pending: expected 2 fetch attempts, got $n" "$(cat "$out")"
    elif ! grep -q "still generating split APKs" "$out"; then
        _fail "pending: missing retry notice" "$(cat "$out")"
    else
        _pass
    fi
else
    _fail "pending: should exit 0 once Play catches up" "$(cat "$out")"
fi

# --- Play still generating past the budget: skip green, no issue filed -------
echo 0 >"$attempts"
if _run_fetch pending 0; then
    grep -q "::notice::" "$out" && _pass \
        || _fail "pending budget: expected a ::notice:: skip" "$(cat "$out")"
else
    _fail "pending budget: should exit 0 so no failure issue is filed" "$(cat "$out")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
