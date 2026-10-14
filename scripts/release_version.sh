#!/usr/bin/env bash
# Print the release version for a commit: CalVer derived from the commit's
# timestamp, in UTC, e.g. 2026.9.29.2013.
#
# Auto-derived on purpose. Every other version in this project increments
# itself from the clock (the Play Store versionCode is int(time.Now().Unix()),
# the APK build number is the commit timestamp), so a release channel that
# needed a hand-edited pubspec.yaml would be the odd one out and would make
# every release cost a PR.
#
# The last component is HHMM as an integer, which is monotonic within a day,
# and the leading components are numeric, so versions order correctly both for
# mise and for compareVersions() in lib/core/services/update_service.dart.
# Re-running for the same commit yields the same version, which makes
# publishing idempotent (ReleaseLinux then just re-uploads the asset).
#
# Caveat: this tracks *commit* timestamps, so a rebase that rewrites history
# with older timestamps could produce a version below one already published.
# Releases are cut from main in commit order, where that does not arise.
set -euo pipefail

# Testing seam: an explicit epoch wins over the commit lookup.
ts="${RELEASE_VERSION_TS:-}"
if [ -z "$ts" ]; then
    ts=$(git log -1 --format=%ct "${1:-HEAD}")
fi

case "$ts" in
    '' | *[!0-9]*)
        echo "ERROR: could not determine a commit timestamp (got '$ts')" >&2
        exit 1
        ;;
esac

date -u -d "@$ts" +%Y.%-m.%-d.%H%M
