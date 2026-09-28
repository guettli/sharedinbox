#!/usr/bin/env bash
# Unit tests for scripts/pubspec_version.sh.
#
# Worth testing despite the script's size: its output names the git tag and the
# release asset that `mise use github:guettli/sharedinbox` resolves, and it
# gates `task release-linux` via an equality precondition. A stray quote or a
# swallowed error surfaces as "VERSION does not match pubspec.yaml" with no hint
# why.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/pubspec_version.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

failures=0

_assert_out() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "ok   - $name"
    else
        echo "FAIL - $name: expected '$expected', got '$actual'"
        failures=$((failures + 1))
    fi
}

_assert_fails() {
    local name="$1" file="$2"
    if "$SCRIPT" "$file" >/dev/null 2>&1; then
        echo "FAIL - $name: expected a non-zero exit"
        failures=$((failures + 1))
    else
        echo "ok   - $name"
    fi
}

_write() {
    printf '%s\n' "$2" > "$TMP/$1"
    printf '%s\n' "$TMP/$1"
}

_assert_out "plain version" "0.1.1" \
    "$("$SCRIPT" "$(_write plain.yaml 'name: sharedinbox
version: 0.1.1
environment:')")"

_assert_out "strips the +buildNumber suffix" "0.1.2" \
    "$("$SCRIPT" "$(_write build.yaml 'version: 0.1.2+47')")"

_assert_out "strips double quotes" "1.0.0" \
    "$("$SCRIPT" "$(_write dq.yaml 'version: "1.0.0"')")"

_assert_out "strips single quotes" "1.0.0" \
    "$("$SCRIPT" "$(_write sq.yaml "version: '1.0.0'")")"

# A `version:` inside a dependency block must not win over the top-level one.
_assert_out "takes the first top-level version" "0.1.1" \
    "$("$SCRIPT" "$(_write nested.yaml 'version: 0.1.1
dependencies:
  foo:
    version: 9.9.9')")"

_assert_fails "missing version field" "$(_write noversion.yaml 'name: sharedinbox')"
_assert_fails "missing file" "$TMP/does-not-exist.yaml"

# The real pubspec must parse — this is what the Taskfile precondition compares.
actual=$("$SCRIPT" "$ROOT/pubspec.yaml")
if printf '%s' "$actual" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "ok   - repository pubspec.yaml yields a SemVer version ($actual)"
else
    echo "FAIL - repository pubspec.yaml yielded '$actual', not a SemVer version"
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures test(s) failed"
    exit 1
fi
echo "All pubspec_version.sh tests passed"
