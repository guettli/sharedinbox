#!/usr/bin/env bash
# Print the release version from pubspec.yaml: the `version:` field without the
# `+buildNumber` suffix and without surrounding quotes. This is the single
# source of truth for the git tag (`v<version>`) and for the GitHub Release
# asset name that mise resolves.
set -uo pipefail

PUBSPEC="${1:-pubspec.yaml}"

if [ ! -f "$PUBSPEC" ]; then
    echo "ERROR: $PUBSPEC not found (run from the repository root)" >&2
    exit 1
fi

# Take the first `version:` line, drop the +buildNumber suffix, and strip the
# quotes YAML allows around the value.
version=$(awk '/^version:[[:space:]]/ {print $2; exit}' "$PUBSPEC" \
    | cut -d+ -f1 \
    | tr -d "\"'")

if [ -z "$version" ]; then
    echo "ERROR: no version: field in $PUBSPEC" >&2
    exit 1
fi

printf '%s\n' "$version"
