#!/usr/bin/env bash
set -euo pipefail
START=$(date +%s)
fvm flutter analyze --no-pub
END=$(date +%s)
echo "analyze: $((END - START))s"
