#!/usr/bin/env bash
# Thin shell wrapper around scripts/detect_duplication.py. Matches the
# convention used by the other scripts/*.sh entrypoints in this repo.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
exec python3 scripts/detect_duplication.py "$@"
