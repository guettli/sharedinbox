#!/usr/bin/env bash
# End-to-end smoke test for scripts/detect_duplication.py.
#
# Sets up a throwaway fixture repo with known duplicates, seeds a baseline,
# adds a NEW duplicate that is not in the baseline, and asserts that
# --against-baseline exits non-zero and names the new clone.
#
# Requires: python3, pylint on PATH.
# Optional: npx (for jscpd) and dupl on PATH.
#
# Run directly: bash scripts/test_detect_duplication.sh

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT

# Mirror the layout detect_duplication.py expects. Only need enough for the
# Python detector — that is fully self-contained on a stock python3+pylint.
mkdir -p "$FIXTURE/scripts" "$FIXTURE/build/duplication"
cp "$SCRIPT_DIR/detect_duplication.py" "$FIXTURE/scripts/"
cp "$SCRIPT_DIR/detect_duplication.sh" "$FIXTURE/scripts/"

# Minimal .jscpd.json so run_jscpd sees a valid config even if npx skips it.
cat >"$FIXTURE/.jscpd.json" <<'EOF'
{ "minLines": 10, "reporters": ["json"],
  "output": "./build/duplication/jscpd",
  "format": ["dart", "bash"], "mode": "strict",
  "ignore": ["build/**", "**/.dart_tool/**"], "gitignore": false }
EOF

# Two Python files with an intentional shared block that pylint recognises.
cat >"$FIXTURE/scripts/mod_a.py" <<'EOF'
"""Baseline module A."""

def process(items):
    """Process items with a common recipe."""
    result = []
    for item in items:
        value = item * 2
        if value > 100:
            value = value - 10
        else:
            value = value + 5
        result.append(value)
    return result
EOF
cp "$FIXTURE/scripts/mod_a.py" "$FIXTURE/scripts/mod_b.py"

PASS=0
FAIL=0
_pass() { PASS=$((PASS + 1)); }
_fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "  $2"; FAIL=$((FAIL + 1)); }

cd "$FIXTURE"

# --- Step 1: --baseline captures the pre-existing duplicate -------------------
if ! python3 scripts/detect_duplication.py --baseline >/tmp/dd.out 2>&1; then
    _fail "--baseline exited non-zero" "$(cat /tmp/dd.out)"
else
    _pass
fi
if [ ! -f duplication-baseline.json ]; then
    _fail "--baseline did not write duplication-baseline.json"
else
    _pass
fi
BASELINE_COUNT=$(python3 -c "import json; print(len({c['key'] for c in json.load(open('duplication-baseline.json'))['clones']}))")
if [ "$BASELINE_COUNT" -lt 1 ]; then
    _fail "--baseline captured 0 clones, expected >=1"
else
    _pass
fi

# --- Step 2: --against-baseline passes when no new duplicates exist -----------
if python3 scripts/detect_duplication.py --against-baseline >/tmp/dd.out 2>&1; then
    _pass
else
    _fail "--against-baseline failed with no new duplicates" "$(cat /tmp/dd.out)"
fi

# --- Step 3: --against-baseline fails when a new duplicate is introduced -----
# Genuinely NEW block content — copying mod_a into mod_c would merely add a
# third occurrence of an already-known clone (same block hash, same key), and
# the baseline diff intentionally suppresses those.
cat >scripts/mod_c.py <<'EOF'
"""Fresh module C."""

def bump(items):
    """Bump items with a different recipe."""
    output = {}
    for label, value in items:
        adjusted = value * 3
        if adjusted < 50:
            adjusted = adjusted + 25
        else:
            adjusted = adjusted - 10
        output[label] = adjusted
    return output
EOF
cp scripts/mod_c.py scripts/mod_d.py
if python3 scripts/detect_duplication.py --against-baseline >/tmp/dd.out 2>&1; then
    _fail "--against-baseline should exit non-zero after new duplicate" "$(cat /tmp/dd.out)"
else
    if grep -q "NEW duplicated code detected" /tmp/dd.out; then
        _pass
    else
        _fail "expected 'NEW duplicated code detected' message" "$(cat /tmp/dd.out)"
    fi
fi

# --- Step 4: findings.json artifact is always written ------------------------
if [ ! -f build/duplication/findings.json ]; then
    _fail "findings.json artifact missing"
else
    _pass
fi

echo "----"
echo "PASSED: $PASS"
echo "FAILED: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
