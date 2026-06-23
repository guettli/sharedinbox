#!/usr/bin/env bash
# Fetch the latest alpha APK from Play, then exercise it on Firebase Test Lab
# via the Dagger pipeline. The Play artefact is what users actually install,
# so any launch-time crash visible in production shows up here too.
#
# Caches the last successfully-tested versionCode in the GitHub Actions repo
# variable LAST_TESTED_ALPHA_VERSION_CODE so the daily cron is cheap when
# nothing has shipped. The variable write needs a token with Variables:write
# (the default GITHUB_TOKEN cannot manage variables), so the cache is best
# effort and silently degrades to "always run" when the write is rejected.
# Retries up to 3 times on transient Dagger engine
# connectivity errors, and on "No space left on device" after pruning the
# Dagger cache.
set -uo pipefail

OUT=$(mktemp)
RC_FILE=$(mktemp)
APK_DIR=$(mktemp -d /tmp/playstore-apks-XXXXXX)
trap 'rm -rf "$OUT" "$RC_FILE" "$APK_DIR"' EXIT

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

if [ -z "${PLAY_STORE_CONFIG_JSON:-}" ]; then
    echo "ERROR: PLAY_STORE_CONFIG_JSON is not set — cannot fetch alpha APK" >&2
    exit 1
fi

echo "[firebase] fetching latest alpha APK set from Play Store via Dagger…" >&2
# Run inside a Dagger container so the runner host does not need google-auth /
# requests installed. The Dagger function writes the resolved versionCode to
# <dest>/versionCode in addition to the APKs.
if ! timeout --kill-after=10 600 dagger call --progress=plain -q -m ci --source=. fetch-play-store-apks \
        --play-store-config env:PLAY_STORE_CONFIG_JSON -o "$APK_DIR"; then
    echo "ERROR: dagger fetch-play-store-apks failed" >&2
    exit 1
fi
# fetch_playstore_apks.py writes this marker (instead of erroring) when Play
# is still processing the latest alpha and every older bundle has aged past
# Play's ~60-day generatedApks retention. Skip the run in that case so the
# daily cron does not file a noisy issue against a transient Play state.
if [ -f "$APK_DIR/no_apks_available" ]; then
    echo "::notice::[firebase] $(cat "$APK_DIR/no_apks_available")" >&2
    echo "::notice::[firebase] skipping run — no Play-generated APKs available yet" >&2
    exit 0
fi
if [ ! -f "$APK_DIR/versionCode" ]; then
    echo "ERROR: $APK_DIR/versionCode missing after fetch" >&2
    exit 1
fi
VERSION_CODE=$(tr -d '[:space:]' < "$APK_DIR/versionCode")
if [ -z "$VERSION_CODE" ]; then
    echo "ERROR: $APK_DIR/versionCode is empty" >&2
    exit 1
fi
echo "[firebase] downloaded APKs for versionCode=$VERSION_CODE to $APK_DIR" >&2
ls -1 "$APK_DIR" >&2

# Cache check: if the GitHub repo variable LAST_TESTED_ALPHA_VERSION_CODE matches,
# the alpha hasn't shipped a new build since last success, so skip the test.
_gh_cache_lookup() {
    if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_REPOSITORY:-}" ]; then
        echo ""
        return 0
    fi
    python3 - <<'PYEOF'
import json, os, urllib.error, urllib.request

token = os.environ["GITHUB_TOKEN"]
api_base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
repo = os.environ["GITHUB_REPOSITORY"]
api = f"{api_base}/repos/{repo}/actions/variables/LAST_TESTED_ALPHA_VERSION_CODE"
headers = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
}
req = urllib.request.Request(api, headers=headers)
try:
    with urllib.request.urlopen(req) as r:
        print(json.loads(r.read()).get("value", ""))
except urllib.error.HTTPError as e:
    if e.code == 404:
        print("")
    else:
        # Don't fail the whole job on a cache lookup error; treat as a miss.
        print(f"[firebase] cache lookup HTTP {e.code}: {e.reason}", file=__import__("sys").stderr)
        print("")
PYEOF
}

_gh_cache_write() {
    local value="$1"
    if [ -z "${GITHUB_TOKEN:-}" ] || [ -z "${GITHUB_REPOSITORY:-}" ]; then
        return 0
    fi
    VALUE="$value" python3 - <<'PYEOF'
import json, os, sys, urllib.error, urllib.request

token = os.environ["GITHUB_TOKEN"]
api_base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
repo = os.environ["GITHUB_REPOSITORY"]
value = os.environ["VALUE"]
name = "LAST_TESTED_ALPHA_VERSION_CODE"
base = f"{api_base}/repos/{repo}/actions/variables"
headers = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "Content-Type": "application/json",
}

def request(url, method, body):
    return urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method=method)

# GitHub: PATCH an existing variable, POST to create a missing one.
try:
    with urllib.request.urlopen(request(f"{base}/{name}", "PATCH", {"name": name, "value": value})) as r:
        r.read()
    print(f"[firebase] updated {name}={value}", file=sys.stderr)
    sys.exit(0)
except urllib.error.HTTPError as e:
    if e.code != 404:
        print(f"[firebase] PATCH cache failed HTTP {e.code}: {e.reason} — trying POST", file=sys.stderr)
try:
    with urllib.request.urlopen(request(base, "POST", {"name": name, "value": value})) as r:
        r.read()
    print(f"[firebase] created {name}={value}", file=sys.stderr)
except urllib.error.HTTPError as e:
    print(f"[firebase] WARNING: cache write failed HTTP {e.code}: {e.reason}", file=sys.stderr)
PYEOF
}

CACHED=$(_gh_cache_lookup)
if [ -n "$CACHED" ] && [ "$CACHED" = "$VERSION_CODE" ]; then
    echo "::notice::[firebase] alpha unchanged (versionCode=$VERSION_CODE) — skipping" >&2
    exit 0
fi
if [ -n "$CACHED" ]; then
    echo "[firebase] cached versionCode=$CACHED differs from current $VERSION_CODE — running" >&2
else
    echo "[firebase] no cached versionCode found — running" >&2
fi

_run() {
    : > "$OUT" ; : > "$RC_FILE"
    {
        timeout --kill-after=10 2400 dagger call --progress=plain -q -m ci --source=. test-android-firebase \
            --apks "$APK_DIR" \
            --service-account-key env:FIREBASE_TEST_LAB_SERVICE_ACCOUNT_KEY
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

FINAL_RC=$(cat "$RC_FILE" 2>/dev/null || echo 0)
if [ "$FINAL_RC" -eq 0 ]; then
    _gh_cache_write "$VERSION_CODE"
fi
exit "$FINAL_RC"
