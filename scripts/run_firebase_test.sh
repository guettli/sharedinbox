#!/usr/bin/env bash
# Runs the Firebase Test Lab Dagger pipeline with Gradle/Dagger noise filtered out.
set -uo pipefail

RC_FILE=$(mktemp)
trap 'rm -f "$RC_FILE"' EXIT

_strip_ansi() {
    sed 's/\x1b\[[0-9;]*[mGKHFJ]//g'
}

_filter_noise() {
    grep -vE \
        '> Task :.+(UP-TO-DATE|NO-SOURCE)'\
'|[0-9]+ files found for path '\''lib/'\
'|^Inputs:'\
'|^[[:space:]]+-[[:space:]]/'\
'|\[Incubating\]'\
'|Deprecated Gradle features'\
'|warning-mode all'\
'|please refer to https://docs\.gradle'\
'|[0-9]+ actionable tasks'\
'|^warning: \[options\]'\
'|^Note: Some input files'\
'|^\s*[┆│]\s*$' \
    || true
}

{
    dagger call --progress=plain -q -m ci --source=. test-android-firebase \
        --service-account-key env:FIREBASE_TEST_LAB_SERVICE_ACCOUNT_KEY \
        --project-id "$FIREBASE_PROJECT_ID"
    echo $? > "$RC_FILE"
} 2>&1 | _strip_ansi | _filter_noise

exit "$(cat "$RC_FILE" 2>/dev/null || echo 1)"
