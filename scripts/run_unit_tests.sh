#!/usr/bin/env bash
set -euo pipefail
START=$(date +%s)
flutter test test/unit/ --coverage
dart run scripts/check_coverage.dart
END=$(date +%s)
echo "test: $((END - START))s"
