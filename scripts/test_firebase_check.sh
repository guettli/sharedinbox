#!/usr/bin/env bash
# Tests for Firebase CI check patterns used in ci/main.go TestAndroidFirebase.
# Run directly: bash scripts/test_firebase_check.sh

PASS=0
FAIL=0

_assert() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name"
        echo "  expected: '$expected'"
        echo "  actual:   '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

# --- auth stderr filter ---
# Lines ignored: "Activated service account credentials for: [...]"
#                "Updated property [core/project]."
_filter_auth() {
    grep -vF "Activated service account credentials for:" \
    | grep -vF "Updated property [core/project]." \
    | grep -v "^$" \
    || true
}

_assert "auth: both known messages produce empty output" "" \
    "$(printf 'Activated service account credentials for: [ci@sa.iam.gserviceaccount.com]\nUpdated property [core/project].\n' | _filter_auth)"

_assert "auth: only credentials line produces empty output" "" \
    "$(printf 'Activated service account credentials for: [ci@sa.iam.gserviceaccount.com]\n' | _filter_auth)"

_assert "auth: only property line produces empty output" "" \
    "$(printf 'Updated property [core/project].\n' | _filter_auth)"

_assert "auth: empty input produces empty output" "" \
    "$(printf '' | _filter_auth)"

_assert "auth: unexpected line passes through" "some unexpected error" \
    "$(printf 'some unexpected error\n' | _filter_auth)"

_assert "auth: unknown line kept alongside known messages" "unexpected line" \
    "$(printf 'Activated service account credentials for: [x]\nunexpected line\nUpdated property [core/project].\n' | _filter_auth)"

# --- robo crash markers ---
# The check fails the run if any of these appear anywhere in gcloud output.
_has_crash() {
    printf '%s\n' "$1" | grep -qE "FATAL EXCEPTION|Process .* has died|Crashed|Error: Robo test failed" \
        && echo yes || echo no
}

_assert "crash: FATAL EXCEPTION matched"                yes "$(_has_crash 'E AndroidRuntime: FATAL EXCEPTION: main')"
_assert "crash: process has died matched"               yes "$(_has_crash 'I ActivityManager: Process de.sharedinbox.mua has died: pid 1234')"
_assert "crash: 'Crashed' outcome detail matched"       yes "$(_has_crash '│ Failed  │ oriole-33-en-portrait │ Crashed     │')"
_assert "crash: Robo test failed matched"               yes "$(_has_crash 'Error: Robo test failed: robo script exception')"
_assert "crash: clean robo output not matched"          no  "$(_has_crash 'Robo script executed 12 actions. Crawling complete.')"
_assert "crash: outcome=Passed not matched"             no  "$(_has_crash '│ Passed  │ oriole-33-en-portrait │ --           │')"
_assert "crash: 'stderr' word not falsely matched"      no  "$(_has_crash 'some stderr: gcloud output')"

# --- outcome row detection ---
# The check requires exactly one Passed outcome row and zero Failed/Inconclusive ones.
TABLE_PASS="┌─────────┬───────────────────────┬──────────────┐
│ OUTCOME │    TEST_AXIS_VALUE    │ TEST_DETAILS │
├─────────┼───────────────────────┼──────────────┤
│ Passed  │ oriole-33-en-portrait │ --           │
└─────────┴───────────────────────┴──────────────┘"

TABLE_FAIL="┌─────────┬───────────────────────┬──────────────┐
│ OUTCOME │    TEST_AXIS_VALUE    │ TEST_DETAILS │
├─────────┼───────────────────────┼──────────────┤
│ Failed  │ oriole-33-en-portrait │ Crashed      │
└─────────┴───────────────────────┴──────────────┘"

TABLE_INCONCLUSIVE="┌──────────────┬───────────────────────┬──────────────┐
│   OUTCOME    │    TEST_AXIS_VALUE    │ TEST_DETAILS │
├──────────────┼───────────────────────┼──────────────┤
│ Inconclusive │ oriole-33-en-portrait │ Timed out    │
└──────────────┴───────────────────────┴──────────────┘"

_count_outcomes() {
    local n
    n=$(printf '%s' "$1" | grep "│" | grep -cE "(Passed|Failed|Inconclusive|Skipped)") || n=0
    printf '%s' "$n"
}

_has_bad_outcome() {
    printf '%s\n' "$1" | grep "│" | grep -qE "(Failed|Inconclusive)" && echo yes || echo no
}

_has_passed() {
    printf '%s\n' "$1" | grep "│" | grep -q "Passed" && echo yes || echo no
}

_assert "outcome: one passing device counted"   1   "$(_count_outcomes "$TABLE_PASS")"
_assert "outcome: one failing device counted"   1   "$(_count_outcomes "$TABLE_FAIL")"
_assert "outcome: empty output counted 0"       0   "$(_count_outcomes 'Test is Pending')"
_assert "outcome: Passed table has no bad row"  no  "$(_has_bad_outcome "$TABLE_PASS")"
_assert "outcome: Failed table has bad row"     yes "$(_has_bad_outcome "$TABLE_FAIL")"
_assert "outcome: Inconclusive table flagged"   yes "$(_has_bad_outcome "$TABLE_INCONCLUSIVE")"
_assert "outcome: Passed row detected"          yes "$(_has_passed "$TABLE_PASS")"
_assert "outcome: Failed table has no Passed"   no  "$(_has_passed "$TABLE_FAIL")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
