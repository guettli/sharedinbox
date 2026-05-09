#!/usr/bin/env bash
# Single nix develop session: format first (autofix), then check-fast.
# Flutter's startup lock prevents true parallelism between dart format and flutter analyze.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

fvm dart format lib test
task check-fast
