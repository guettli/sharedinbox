#!/usr/bin/env bash
# Unit tests for scripts/release_version.sh.
#
# This string becomes the git tag, the GitHub Release name that
# `mise use github:guettli/sharedinbox@latest` resolves, and the
# RELEASE_VERSION dart-define the in-app update check compares. Ordering bugs
# here surface as "@latest stopped advancing", which is invisible until users
# stop getting updates.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/release_version.sh"

failures=0

_assert() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "ok   - $name"
    else
        echo "FAIL - $name: expected '$expected', got '$actual'"
        failures=$((failures + 1))
    fi
}

_at() { RELEASE_VERSION_TS="$1" "$SCRIPT"; }

# 2026-09-29T20:13:00Z
_assert "formats as YYYY.M.D.HHMM in UTC" "2026.9.29.2013" "$(_at 1790712780)"
# 2026-01-05T09:07:00Z — no leading zeros on month/day, kept on HHMM
_assert "drops leading zeros on month and day" "2026.1.5.0907" "$(_at 1767604020)"
# 2026-12-31T23:59:00Z
_assert "handles end of year" "2026.12.31.2359" "$(_at 1798761540)"

# Ordering is what actually matters: sort -V must agree with chronology.
a=$(_at 1767604020)   # 2026-01-05 09:07
b=$(_at 1790712780)   # 2026-09-29 20:13
c=$(_at 1798761540)   # 2026-12-31 23:59
sorted=$(printf '%s\n%s\n%s\n' "$b" "$c" "$a" | sort -V | tr '\n' ' ')
_assert "sorts chronologically under sort -V" "$a $b $c " "$sorted"

# Same day, later time must compare higher (HHMM as an integer).
early=$(_at 1790671620)  # 2026-09-29 08:47
late=$(_at 1790712780)   # 2026-09-29 20:13
_assert "same day orders by time" "$early $late " \
    "$(printf '%s\n%s\n' "$late" "$early" | sort -V | tr '\n' ' ')"

# Every component must be numeric, or mise cannot order the versions.
v=$(_at 1790712780)
if printf '%s' "$v" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "ok   - all four components are numeric"
else
    echo "FAIL - '$v' is not four numeric components"
    failures=$((failures + 1))
fi

# Idempotent: the same commit always yields the same version, so re-running a
# release updates it rather than creating a duplicate.
_assert "is deterministic for a given timestamp" "$(_at 1790712780)" "$(_at 1790712780)"

if ! RELEASE_VERSION_TS="not-a-number" "$SCRIPT" >/dev/null 2>&1; then
    echo "ok   - rejects a non-numeric timestamp"
else
    echo "FAIL - a non-numeric timestamp should exit non-zero"
    failures=$((failures + 1))
fi

# The real repository must produce a usable version.
actual=$("$SCRIPT")
if printf '%s' "$actual" | grep -qE '^[0-9]{4}\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "ok   - HEAD yields a CalVer version ($actual)"
else
    echo "FAIL - HEAD yielded '$actual'"
    failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
    echo "$failures test(s) failed"
    exit 1
fi
echo "All release_version.sh tests passed"
