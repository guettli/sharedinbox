#!/usr/bin/env bash
# Tests for the pure helpers in scripts/ci-monitor.sh.
# Run directly: bash scripts/test_ci_monitor.sh

set -uo pipefail

# shellcheck source=ci-monitor.sh
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/ci-monitor.sh"

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

# --- classify_failure ---

_assert "A: workspace permission" A "$(classify_failure 'Permission denied: /workspace')"
_assert "A: EACCES on workspace" A "$(classify_failure 'open /workspace/foo: EACCES')"
_assert "A: no matching runner" A "$(classify_failure 'job failed: no matching runner for label sharedinbox-arc')"
_assert "A: runs-on not found" A "$(classify_failure 'runs-on: sharedinbox-arc not found in runner pool')"

_assert "B: dagger no server response" B "$(classify_failure 'Error: No Dagger server responded within the timeout window')"
_assert "B: dagger connection refused" B "$(classify_failure 'dial tcp 127.0.0.1:1774: dagger: connection refused')"
_assert "B: dagger engine not ready" B "$(classify_failure 'dagger engine is not ready yet, retrying')"

_assert "C: ci/main.go syntax error" C "$(classify_failure '/ci/main.go:42:7: syntax error: unexpected newline')"
_assert "C: go build ci/main.go" C "$(classify_failure 'go build ci/main.go: exit status 1')"
_assert "C: undefined symbol in ci" C "$(classify_failure 'undefined: Foo (in ci/main.go)')"

_assert "D: dart lib file syntax error" D "$(classify_failure 'lib/data/db/database.dart:120:3: Expected ; here')"
_assert "D: flutter build failed" D "$(classify_failure 'flutter build apk failed with exit code 1')"
_assert "D: dart analyze error" D "$(classify_failure 'dart analyze: 3 errors found')"

_assert "U: empty input" U "$(classify_failure '')"
_assert "U: generic apt error" U "$(classify_failure 'E: Unable to locate package some-pkg')"
_assert "U: unrelated stack trace" U "$(classify_failure 'panic: runtime error: index out of range')"

# B beats C when both signals are present (transient masking compile noise).
_assert "B before C precedence" B \
    "$(classify_failure $'No Dagger server responded\nci/main.go:1:1: stale trace line')"

# --- locate_workflow_file ---

tmp_root=$(mktemp -d)
trap 'rm -rf "$tmp_root"' EXIT

mkdir -p "$tmp_root/.github/workflows"

# .yml is found.
: >"$tmp_root/.github/workflows/ci.yml"
_assert "locate: github yml" "$tmp_root/.github/workflows/ci.yml" \
    "$(locate_workflow_file "$tmp_root" ci)"

# .yaml extension also recognised.
rm "$tmp_root/.github/workflows/ci.yml"
: >"$tmp_root/.github/workflows/ci.yaml"
_assert "locate: yaml extension" "$tmp_root/.github/workflows/ci.yaml" \
    "$(locate_workflow_file "$tmp_root" ci)"

# Nothing matches.
rm "$tmp_root/.github/workflows/ci.yaml"
_assert "locate: nothing found" "" \
    "$(locate_workflow_file "$tmp_root" ci)"

# --- patch_runs_on ---

wf="$tmp_root/wf.yml"
cat >"$wf" <<'YAML'
name: CI
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
YAML

# Diff applied: rc=0.
patch_runs_on "$wf" "sharedinbox-arc"
rc=$?
_assert "patch: rc=0 on change" 0 "$rc"
_assert "patch: file contains new label" 1 \
    "$(grep -c '^    runs-on: sharedinbox-arc$' "$wf")"

# No-op when already at the wanted label: rc=1.
patch_runs_on "$wf" "sharedinbox-arc"
rc=$?
_assert "patch: rc=1 on no-op" 1 "$rc"

# Missing runs-on line: rc=2.
cat >"$wf" <<'YAML'
name: CI
jobs:
  check:
    steps:
      - run: echo hi
YAML
patch_runs_on "$wf" "ubuntu-latest"
rc=$?
_assert "patch: rc=2 when missing" 2 "$rc"

# Quoted labels are tolerated.
cat >"$wf" <<'YAML'
name: CI
jobs:
  check:
    runs-on: "ubuntu-latest"
YAML
patch_runs_on "$wf" "self-hosted"
rc=$?
_assert "patch: quoted current label still detected" 0 "$rc"
_assert "patch: quoted -> bare new label" 1 \
    "$(grep -c '^    runs-on: self-hosted$' "$wf")"

# --- discover_runner_label ---
# Stub gh_api so the function can be exercised without a real GitHub token.
# discover_runner_label must return non-zero (no silent 'ubuntu-latest'
# fallback) if the API errors OR if no online, non-generic label exists.

gh_api() { printf '%s' "$__STUB_JSON"; return "$__STUB_RC"; }

__STUB_JSON=''
__STUB_RC=1
if discover_runner_label anything >/dev/null 2>&1; then
    echo "FAIL: discover: expected non-zero on API failure"
    FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
fi

__STUB_JSON='{"runners": []}'
__STUB_RC=0
if discover_runner_label anything >/dev/null 2>&1; then
    echo "FAIL: discover: expected non-zero when no runners"
    FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
fi

__STUB_JSON='{"runners": [{"status":"offline","labels":[{"name":"sharedinbox-arc"}]}]}'
__STUB_RC=0
if discover_runner_label anything >/dev/null 2>&1; then
    echo "FAIL: discover: expected non-zero when all runners offline"
    FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
fi

__STUB_JSON='{"runners": [{"status":"online","labels":[{"name":"self-hosted"},{"name":"Linux"},{"name":"X64"}]}]}'
__STUB_RC=0
if discover_runner_label anything >/dev/null 2>&1; then
    echo "FAIL: discover: expected non-zero when only generic labels present"
    FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
fi

__STUB_JSON='{"runners": [{"status":"online","labels":[{"name":"self-hosted"},{"name":"sharedinbox-arc"}]}]}'
__STUB_RC=0
_assert "discover: emits first non-generic label" "sharedinbox-arc" \
    "$(discover_runner_label anything 2>/dev/null)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
