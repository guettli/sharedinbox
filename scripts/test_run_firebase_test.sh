#!/usr/bin/env bash
# Tests for the Play-Store APK fetch loop in scripts/run_firebase_test.sh.
#
# The loop polls Play across fresh short-lived Dagger execs until the split
# APKs exist. It has to tell three outcomes apart:
#   - PENDING            → Play is still generating; wait and retry (#414, #432)
#   - timeout (124/137)  → the exec wedged (e.g. a Docker Hub stall while
#                          pulling python:3.12-alpine, see #453); retry on a
#                          fresh exec, and only fail after a run of consecutive
#                          timeouts (#897)
#   - any other non-zero → a real failure (auth, network, Play 5xx); fail now
# These tests pin all three.
#
# Run directly: bash scripts/test_run_firebase_test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/run_firebase_test.sh"

PASS=0
FAIL=0

_pass() { PASS=$((PASS + 1)); }
_fail() {
    echo "FAIL: $1"
    [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/    /'
    FAIL=$((FAIL + 1))
}

# Drive the fetch loop by sourcing the section of run_firebase_test.sh between
# the Step 1 and Step 2 banners. Everything above it validates secrets and
# defines the GitHub-variables helper; everything below it runs Firebase Test
# Lab — neither is under test here, and both would need real credentials.
_fetch_snippet=$(awk '/^# === Step 1: fetch/{p=1} /^# === Step 2: run Firebase/{exit} p' "$SCRIPT")
if [ -z "$_fetch_snippet" ]; then
    echo "FAIL: could not locate the Step 1 fetch block in $SCRIPT"
    exit 1
fi

# Per-test scratch dir holds the stubbed `dagger`/`timeout`/`sleep` binaries,
# an attempts counter and the dest dir the fetch writes into.
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# Stub `dagger` with a per-attempt plan: FETCH_PLAN is a space-separated list
# of outcomes, one per attempt ("ready", "pending", or a numeric exit code —
# 124 stands in for a wedged exec killed by `timeout`). The last entry repeats
# once the plan runs out, so "pending" alone means "PENDING forever".
cat >"$SCRATCH/dagger" <<EOF
#!/usr/bin/env bash
n=\$(cat "$SCRATCH/attempts"); n=\$((n + 1)); echo \$n >"$SCRATCH/attempts"

# The loop passes the dest dir as \`-o <dir>\`; mirror Dagger's export into it.
dest=""
while [ \$# -gt 0 ]; do
    if [ "\$1" = "-o" ]; then dest="\$2"; fi
    shift
done

read -r -a plan <<<"\$FETCH_PLAN"
idx=\$((n - 1))
[ "\$idx" -ge "\${#plan[@]}" ] && idx=\$(( \${#plan[@]} - 1 ))
case "\${plan[\$idx]}" in
    ready)
        echo 1790309773 >"\$dest/versionCode"
        : >"\$dest/base-master.apk"
        ;;
    pending)
        echo 1790309773 >"\$dest/versionCode"
        : >"\$dest/PENDING"
        ;;
    *)
        exit "\${plan[\$idx]}"
        ;;
esac
EOF
chmod +x "$SCRATCH/dagger"
# Stub `timeout` so `timeout --kill-after=10 <secs> dagger ...` just runs dagger
# and surfaces its exit code (including the 124 the plan can ask for).
cat >"$SCRATCH/timeout" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
    case "$1" in
        --kill-after=*) shift ;;
        -*) shift ;;
        *) shift; break ;;   # the duration
    esac
done
"$@"
EOF
chmod +x "$SCRATCH/timeout"
# Stub sleep so the retry interval doesn't slow the suite down.
cat >"$SCRATCH/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SCRATCH/sleep"

# Run the fetch snippet with the stubs above. FETCH_PLAN drives the stub;
# budget defaults to 3600s ("plenty left") and can be overridden to 0 to
# exercise the give-up path. Attempts are counted in $SCRATCH/attempts.
run_fetch() {
    local plan="$1" budget="${2:-3600}"
    echo 0 >"$SCRATCH/attempts"
    rm -rf "$SCRATCH/apks"
    mkdir -p "$SCRATCH/apks"
    PATH="$SCRATCH:$PATH" \
        APK_DIR="$SCRATCH/apks" \
        FETCH_PLAN="$plan" \
        FIREBASE_FETCH_ATTEMPT_TIMEOUT_S=5 \
        FIREBASE_FETCH_TOTAL_BUDGET_S="$budget" \
        FIREBASE_FETCH_RETRY_INTERVAL_S=0 \
        FIREBASE_FETCH_MAX_CONSECUTIVE_TIMEOUTS=3 \
        bash -c "set -uo pipefail
$_fetch_snippet" 2>&1
}

# --- Ready on the first attempt: one exec, no retries, no warnings -------------
out=$(run_fetch "ready")
rc=$?
attempts=$(cat "$SCRATCH/attempts")
if [ "$rc" -ne 0 ]; then
    _fail "ready: should exit 0" "$out"
elif [ "$attempts" -ne 1 ]; then
    _fail "ready: should not retry (got $attempts attempts)" "$out"
elif printf '%s' "$out" | grep -q "::warning::"; then
    _fail "ready: should not warn" "$out"
elif ! printf '%s' "$out" | grep -q "downloaded APKs for versionCode=1790309773"; then
    _fail "ready: should report the downloaded versionCode" "$out"
else
    _pass
fi

# --- PENDING then ready: waits for Play, then proceeds -------------------------
out=$(run_fetch "pending pending ready")
rc=$?
attempts=$(cat "$SCRATCH/attempts")
if [ "$rc" -ne 0 ]; then
    _fail "pending: should exit 0 once Play catches up" "$out"
elif [ "$attempts" -ne 3 ]; then
    _fail "pending: expected 3 attempts (got $attempts)" "$out"
elif ! printf '%s' "$out" | grep -q "Play still generating split APKs"; then
    _fail "pending: should log that Play is still generating" "$out"
else
    _pass
fi

# --- PENDING past the budget: skip the cycle green, no issue filed (#414) ------
out=$(run_fetch "pending" 0)
rc=$?
if [ "$rc" -ne 0 ]; then
    _fail "budget: should exit 0 so the workflow stays green" "$out"
elif ! printf '%s' "$out" | grep -q "::notice::.*skipping"; then
    _fail "budget: should emit the ::notice:: skip line" "$out"
else
    _pass
fi

# --- A wedged attempt (124) recovers on the next exec (#897) -------------------
out=$(run_fetch "124 ready")
rc=$?
attempts=$(cat "$SCRATCH/attempts")
if [ "$rc" -ne 0 ]; then
    _fail "timeout-recovers: should exit 0 after retrying the wedged exec" "$out"
elif [ "$attempts" -ne 2 ]; then
    _fail "timeout-recovers: expected 2 attempts (got $attempts)" "$out"
elif ! printf '%s' "$out" | grep -q "::warning::.*timed out after 5s (1/3 consecutive)"; then
    _fail "timeout-recovers: should warn about the wedged attempt" "$out"
elif ! printf '%s' "$out" | grep -q "downloaded APKs for versionCode=1790309773"; then
    _fail "timeout-recovers: should proceed to the downloaded APKs" "$out"
else
    _pass
fi

# --- A SIGKILLed attempt (137) is treated the same as 124 ----------------------
out=$(run_fetch "137 ready")
rc=$?
attempts=$(cat "$SCRATCH/attempts")
if [ "$rc" -ne 0 ]; then
    _fail "sigkill: should exit 0 after retrying the wedged exec" "$out"
elif [ "$attempts" -ne 2 ]; then
    _fail "sigkill: expected 2 attempts (got $attempts)" "$out"
else
    _pass
fi

# --- The consecutive-timeout counter resets after a live answer ---------------
# 124, PENDING, 124, ready: never 3 in a row, so the run must survive even
# though it saw as many timeouts as the give-up threshold.
out=$(run_fetch "124 pending 124 ready")
rc=$?
attempts=$(cat "$SCRATCH/attempts")
if [ "$rc" -ne 0 ]; then
    _fail "reset: non-consecutive timeouts should not fail the run" "$out"
elif [ "$attempts" -ne 4 ]; then
    _fail "reset: expected 4 attempts (got $attempts)" "$out"
elif ! printf '%s' "$out" | grep -q "timed out after 5s (1/3 consecutive)"; then
    _fail "reset: second timeout should be counted as the first again" "$out"
elif printf '%s' "$out" | grep -q "2/3 consecutive"; then
    _fail "reset: counter should have been reset by the PENDING answer" "$out"
else
    _pass
fi

# --- A genuinely wedged engine (3 consecutive timeouts) still fails -----------
out=$(run_fetch "124")
rc=$?
attempts=$(cat "$SCRATCH/attempts")
if [ "$rc" -eq 0 ]; then
    _fail "wedged: should exit non-zero" "$out"
elif [ "$attempts" -ne 3 ]; then
    _fail "wedged: should stop after 3 attempts (got $attempts)" "$out"
elif ! printf '%s' "$out" | grep -q "timed out after 5s on 3 consecutive attempt"; then
    _fail "wedged: error should name the consecutive-timeout run" "$out"
else
    _pass
fi

# --- A real failure (auth, Play 5xx) fails immediately, without retrying -------
out=$(run_fetch "1 ready")
rc=$?
attempts=$(cat "$SCRATCH/attempts")
if [ "$rc" -eq 0 ]; then
    _fail "hard-failure: should exit non-zero" "$out"
elif [ "$attempts" -ne 1 ]; then
    _fail "hard-failure: should not retry (got $attempts attempts)" "$out"
elif ! printf '%s' "$out" | grep -q "fetch-play-store-apks failed (exit 1)"; then
    _fail "hard-failure: error should surface the exit code" "$out"
else
    _pass
fi

# --- A fetch that exports nothing is a hard failure, not a retry --------------
out=$(run_fetch "0 ready")
rc=$?
attempts=$(cat "$SCRATCH/attempts")
if [ "$rc" -eq 0 ]; then
    _fail "no-versioncode: should exit non-zero" "$out"
elif [ "$attempts" -ne 1 ]; then
    _fail "no-versioncode: should not retry (got $attempts attempts)" "$out"
elif ! printf '%s' "$out" | grep -q "versionCode missing after fetch"; then
    _fail "no-versioncode: should name the missing marker" "$out"
else
    _pass
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
