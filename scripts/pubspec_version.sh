#!/usr/bin/env bash
# Print the release version from pubspec.yaml: the `version:` field without the
# `+buildNumber` suffix. This is the single source of truth for the git tag
# (`v<version>`) and for the GitHub Release asset name that mise resolves.
set -euo pipefail

version=$(awk '/^version:[[:space:]]/ {print $2; exit}' pubspec.yaml | cut -d+ -f1)
[ -n "$version" ] || { echo "ERROR: no version: field in pubspec.yaml" >&2; exit 1; }
printf '%s\n' "$version"
