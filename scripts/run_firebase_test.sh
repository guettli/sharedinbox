#!/usr/bin/env bash
# Fetch the latest alpha APK from Play, then exercise it on Firebase Test Lab
# via the Dagger pipeline. The Play artefact is what users actually install,
# so any launch-time crash visible in production shows up here too.
#
# Caches the last successfully-tested versionCode in the Gitea Actions repo
# variable LAST_TESTED_ALPHA_VERSION_CODE so the daily cron is cheap when
# nothing has shipped. Retries up to 3 times on transient Dagger engine
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

echo "[firebase] fetching latest alpha APK set from Play Store…" >&2
if ! VERSION_CODE=$(python3 scripts/fetch_playstore_apks.py "$APK_DIR"); then
    echo "ERROR: fetch_playstore_apks.py failed" >&2
    exit 1
fi
echo "[firebase] downloaded APKs for versionCode=$VERSION_CODE to $APK_DIR" >&2
ls -1 "$APK_DIR" >&2

# Cache check: if the Gitea repo variable LAST_TESTED_ALPHA_VERSION_CODE matches,
# the alpha hasn't shipped a new build since last success, so skip the test.
_gitea_cache_lookup() {
    if [ -z "${FORGEJO_TOKEN:-}" ] || [ -z "${FORGEJO_URL:-}" ]; then
        echo ""
        return 0
    fi
    FORGEJO_TOKEN="$FORGEJO_TOKEN" FORGEJO_URL="$FORGEJO_URL" python3 - <<'PYEOF'
import json, os, urllib.error, urllib.request

token = os.environ["FORGEJO_TOKEN"]
url_base = os.environ["FORGEJO_URL"].rstrip("/")
api = f"{url_base}/api/v1/repos/guettli/sharedinbox/actions/variables/LAST_TESTED_ALPHA_VERSION_CODE"
req = urllib.request.Request(api, headers={"Authorization": f"token {token}"})
try:
    with urllib.request.urlopen(req) as r:
        print(json.loads(r.read()).get("value", ""))
except urllib.error.HTTPError as e:
    if e.code == 404:
        print("")
    else:
        # Don't fail the whole job on a cache lookup error; treat as a miss.
        print("", file=__import__("sys").stderr)
        print(f"[firebase] cache lookup HTTP {e.code}: {e.reason}", file=__import__("sys").stderr)
        print("")
PYEOF
}

_gitea_cache_write() {
    local value="$1"
    if [ -z "${FORGEJO_TOKEN:-}" ] || [ -z "${FORGEJO_URL:-}" ]; then
        return 0
    fi
    FORGEJO_TOKEN="$FORGEJO_TOKEN" FORGEJO_URL="$FORGEJO_URL" VALUE="$value" python3 - <<'PYEOF'
import json, os, sys, urllib.error, urllib.request

token = os.environ["FORGEJO_TOKEN"]
url_base = os.environ["FORGEJO_URL"].rstrip("/")
value = os.environ["VALUE"]
api = f"{url_base}/api/v1/repos/guettli/sharedinbox/actions/variables/LAST_TESTED_ALPHA_VERSION_CODE"
headers = {"Authorization": f"token {token}", "Content-Type": "application/json"}

def request(method, body):
    return urllib.request.Request(api, data=json.dumps(body).encode(), headers=headers, method=method)

try:
    with urllib.request.urlopen(request("PUT", {"name": "LAST_TESTED_ALPHA_VERSION_CODE", "value": value})) as r:
        r.read()
    print(f"[firebase] updated LAST_TESTED_ALPHA_VERSION_CODE={value}", file=sys.stderr)
    sys.exit(0)
except urllib.error.HTTPError as e:
    if e.code != 404:
        print(f"[firebase] PUT cache failed HTTP {e.code}: {e.reason} — trying POST", file=sys.stderr)
try:
    with urllib.request.urlopen(request("POST", {"name": "LAST_TESTED_ALPHA_VERSION_CODE", "value": value})) as r:
        r.read()
    print(f"[firebase] created LAST_TESTED_ALPHA_VERSION_CODE={value}", file=sys.stderr)
except urllib.error.HTTPError as e:
    print(f"[firebase] WARNING: cache write failed HTTP {e.code}: {e.reason}", file=sys.stderr)
PYEOF
}

CACHED=$(_gitea_cache_lookup)
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

FINAL_RC=$(cat "$RC_FILE" 2>/dev/null || echo 0)
if [ "$FINAL_RC" -eq 0 ]; then
    _gitea_cache_write "$VERSION_CODE"
fi
exit "$FINAL_RC"
