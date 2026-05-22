#!/usr/bin/env bash
# Tests for Firebase CI check patterns used in ci/main.go.
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

# --- "error" word detection: grep -qwi 'error' ---
# Matches "error" as a whole word (case-insensitive).
# Must NOT match "error" as part of another word (e.g. "stderr", "AssertionError").
_has_err() { printf '%s\n' "$1" | grep -qwi 'error' && echo yes || echo no; }

_assert "error: non-retryable error line matched"  yes "$(_has_err 'A non-retryable error occurred.')"
_assert "error: uppercase ERROR matched"           yes "$(_has_err 'ERROR: infrastructure_failure')"
_assert "error: mixed-case Error matched"          yes "$(_has_err 'Error: something went wrong')"
_assert "error: normal pending line not matched"   no  "$(_has_err 'Test is Pending')"
_assert "error: timing line not matched"           no  "$(_has_err 'Done. Test time = 183 (secs)')"
_assert "error: completion line not matched"       no  "$(_has_err 'Instrumentation testing complete.')"
_assert "error: 'stderr' word not matched"         no  "$(_has_err 'some stderr: gcloud output')"
_assert "error: 'AssertionError' not matched"      no  "$(_has_err 'java.lang.AssertionError: expected true')"

# --- device count from result table ---
# Counts data rows by looking for lines with "│" that contain an outcome word.
TABLE_PASS="┌─────────┬───────────────────────┬──────────────┐
│ OUTCOME │    TEST_AXIS_VALUE    │ TEST_DETAILS │
├─────────┼───────────────────────┼──────────────┤
│ Passed  │ oriole-33-en-portrait │ --           │
└─────────┴───────────────────────┴──────────────┘"

TABLE_FAIL="┌─────────┬───────────────────────┬──────────────┐
│ OUTCOME │    TEST_AXIS_VALUE    │ TEST_DETAILS │
├─────────┼───────────────────────┼──────────────┤
│ Failed  │ oriole-33-en-portrait │ --           │
└─────────┴───────────────────────┴──────────────┘"

_count() {
    local n
    n=$(printf '%s' "$1" | grep "│" | grep -cE "(Passed|Failed|Inconclusive|Skipped)") || n=0
    printf '%s' "$n"
}

_assert "count: one passing device gives 1"  1 "$(_count "$TABLE_PASS")"
_assert "count: one failing device gives 1"  1 "$(_count "$TABLE_FAIL")"
_assert "count: no table gives 0"            0 "$(_count 'Test is Pending\nDone.')"
_assert "count: plain output gives 0"        0 "$(_count 'Instrumentation testing complete.')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
