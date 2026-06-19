#!/usr/bin/env bash
# Runs the Firebase Test Lab Dagger pipeline with Gradle/Dagger noise filtered out.
# Retries up to 3 times on transient Dagger engine connectivity errors, and on
# "No space left on device" after pruning the Dagger cache.
set -uo pipefail

OUT=$(mktemp)
RC_FILE=$(mktemp)
trap 'rm -f "$OUT" "$RC_FILE"' EXIT

_strip_ansi() {
    sed 's/\x1b\[[0-9;]*[mGKHFJ]//g'
}

_filter_noise() {
    grep -vE \
        '> Task :.+(UP-TO-DATE|NO-SOURCE|SKIPPED)'\
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
'|Starting a Gradle Daemon'\
'|Have questions, feedback, or issues'\
'|https://firebase\.google\.com/support'\
'|^\s*[┆│]\s*$' \
    || true
}

_run() {
    : > "$OUT" ; : > "$RC_FILE"
    {
        timeout --kill-after=10 2400 dagger call --progress=plain -q -m ci --source=. test-android-firebase \
            --service-account-key env:FIREBASE_TEST_LAB_SERVICE_ACCOUNT_KEY \
            --project-id "$FIREBASE_PROJECT_ID"
        echo $? > "$RC_FILE"
    } 2>&1 | tee "$OUT" | _strip_ansi | _filter_noise
}

for attempt in 1 2 3; do
    _run && break
    RC=$(cat "$RC_FILE" 2>/dev/null || echo 1)
    if [ "$RC" -eq 124 ]; then
        echo "::warning::[firebase] attempt $attempt/3 timed out after 2400s" >&2
        exit 124
    fi
    if [ "$attempt" -lt 3 ] && grep -qE "connection reset|context canceled|connection refused|No Dagger server responded" "$OUT"; then
        echo "[firebase] dagger connectivity error on attempt $attempt/3, retrying..." >&2
    elif [ "$attempt" -lt 3 ] && grep -q "No space left on device" "$OUT"; then
        echo "[firebase] dagger disk space error on attempt $attempt/3, pruning Dagger cache..." >&2
        timeout 120 dagger query '{ engine { localCache { prune(targetSpace: "20gb") } } }' 2>/dev/null || true
        echo "[firebase] waiting 90s for freed space to settle..." >&2
        sleep 90
    else
        exit "$RC"
    fi
done

exit "$(cat "$RC_FILE" 2>/dev/null || echo 0)"
