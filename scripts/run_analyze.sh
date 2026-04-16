#!/usr/bin/env bash
set -euo pipefail
START=$(date +%s)
flutter analyze
END=$(date +%s)
echo "analyze: $((END - START))s"
