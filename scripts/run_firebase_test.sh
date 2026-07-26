#!/usr/bin/env bash
# Fetch the latest alpha APK from Play, then exercise it on Firebase Test Lab
# via the Dagger pipeline. The Play artefact is what users actually install,
# so any launch-time crash visible in production shows up here too.
#
# Cron policy (see .github/workflows/firebase-tests.yml — fires hourly):
#   1. If LAST_SUCCESSFUL_FIREBASE_RUN was less than SKIP_WINDOW_SECONDS ago
#      (any versionCode), skip. Keeps hourly polling cheap on a stable alpha.
#   2. Resolve the latest alpha versionCode. If Play has not yet generated
#      split APKs for it, skip — no fallback to older bundles, the next
#      cron tick will retry. (Generation can take an hour or more after
#      upload.)
#   3. If that versionCode equals LAST_TESTED_ALPHA_VERSION_CODE, skip — the
#      build was already exercised, no point retesting the same binary.
#   4. Otherwise download the APKs and run Firebase Test Lab.
#   5. On success, update both repo variables. Only an actual test failure
#      propagates to the workflow so an issue can be opened.
#
# GITHUB_TOKEN must have Variables:write on GITHUB_REPOSITORY (the default
# workflow token cannot manage variables; the workflow injects a PAT). Any
# GitHub API error other than 404-on-read fails the job so a broken
# skip-window can't silently degrade to "always run". Retries up to 3 times
# on transient Dagger engine connectivity errors, and on "No space left on
# device" after pruning the Dagger cache.
set -uo pipefail

# Hourly polling is cheap when broken (catches a fix within ~1h); the 12h
# window gates the real Firebase Test Lab spend on a stable alpha to ~2
# runs/day even if no new build ships.
SKIP_WINDOW_SECONDS=$((12 * 60 * 60))

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

# === GitHub Actions repo-variables helpers ======================================
# GITHUB_TOKEN and GITHUB_REPOSITORY are hard requirements: without them the
# skip-window/last-tested checks would silently degrade to "always run", which
# would blow through the Firebase Test Lab quota.

: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set (needs Variables:write on GITHUB_REPOSITORY)}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set (owner/repo)}"

_gh_var_get() {
    local name="$1"
    NAME="$name" python3 - <<'PYEOF'
import json, os, sys, urllib.error, urllib.request
name = os.environ["NAME"]
token = os.environ["GITHUB_TOKEN"]
api_base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
repo = os.environ["GITHUB_REPOSITORY"]
api = f"{api_base}/repos/{repo}/actions/variables/{name}"
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
        # 404 means "variable not set yet" — expected on the first run.
        print("")
    else:
        body = ""
        try:
            body = e.read().decode("utf-8", "replace")
        except Exception:
            pass
        print(f"[firebase] {name} lookup HTTP {e.code}: {e.reason}\n{body}", file=sys.stderr)
        sys.exit(1)
PYEOF
}

_gh_var_set() {
    local name="$1"
    local value="$2"
    NAME="$name" VALUE="$value" python3 - <<'PYEOF'
import json, os, sys, urllib.error, urllib.request

name = os.environ["NAME"]
value = os.environ["VALUE"]
token = os.environ["GITHUB_TOKEN"]
api_base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
repo = os.environ["GITHUB_REPOSITORY"]
base = f"{api_base}/repos/{repo}/actions/variables"
headers = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/vnd.github+json",
    "X-GitHub-Api-Version": "2022-11-28",
    "Content-Type": "application/json",
}

def request(url, method, body):
    return urllib.request.Request(url, data=json.dumps(body).encode(), headers=headers, method=method)

def die(prefix, err):
    body = ""
    try:
        body = err.read().decode("utf-8", "replace")
    except Exception:
        pass
    print(f"[firebase] {prefix} HTTP {err.code}: {err.reason}\n{body}", file=sys.stderr)
    sys.exit(1)

# GitHub: PATCH an existing variable; only fall through to POST on 404
# ("variable does not exist yet"). Any other status is a hard failure.
try:
    with urllib.request.urlopen(request(f"{base}/{name}", "PATCH", {"name": name, "value": value})) as r:
        r.read()
    print(f"[firebase] updated {name}={value}", file=sys.stderr)
    sys.exit(0)
except urllib.error.HTTPError as e:
    if e.code != 404:
        die(f"PATCH {name} failed", e)

try:
    with urllib.request.urlopen(request(base, "POST", {"name": name, "value": value})) as r:
        r.read()
    print(f"[firebase] created {name}={value}", file=sys.stderr)
except urllib.error.HTTPError as e:
    die(f"POST {name} failed", e)
PYEOF
}

# === Step 1: early skip when a successful run is recent =========================

NOW=$(date +%s)
LAST_OK=$(_gh_var_get "LAST_SUCCESSFUL_FIREBASE_RUN")
if [ -n "$LAST_OK" ] && [ "$LAST_OK" -eq "$LAST_OK" ] 2>/dev/null; then
    AGE=$(( NOW - LAST_OK ))
    if [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$SKIP_WINDOW_SECONDS" ]; then
        printf '::notice::[firebase] last successful run %dh%02dm ago — skipping (window=%dh)\n' \
            $((AGE / 3600)) $(((AGE % 3600) / 60)) $((SKIP_WINDOW_SECONDS / 3600)) >&2
        exit 0
    fi
fi

# === Steps 2–3: fetch (or skip when not ready / already tested) =================

ALREADY_TESTED_VERSION_CODE=$(_gh_var_get "LAST_TESTED_ALPHA_VERSION_CODE")

echo "[firebase] fetching latest alpha APK set from Play Store via Dagger…" >&2
# The Dagger function writes <dest>/versionCode and the APKs when there is
# work to do, or <dest>/.skip when the latest alpha is not ready yet or has
# already been tested. No fallback to older bundles — the next cron tick
# picks up whichever build Play has finished processing.
if ! timeout --kill-after=10 600 dagger call --progress=plain -q -m ci --source=. fetch-play-store-apks \
        --play-store-config env:PLAY_STORE_CONFIG_JSON \
        --already-tested-version-code "$ALREADY_TESTED_VERSION_CODE" \
        -o "$APK_DIR"; then
    echo "ERROR: dagger fetch-play-store-apks failed" >&2
    exit 1
fi
if [ -f "$APK_DIR/.skip" ]; then
    reason=$(tr -d '\n' < "$APK_DIR/.skip")
    echo "::notice::[firebase] skipping: $reason" >&2
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

# === Step 4: run Firebase Test Lab ==============================================

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

# === Step 5: on success, update both repo variables =============================

FINAL_RC=$(cat "$RC_FILE" 2>/dev/null || echo 0)
if [ "$FINAL_RC" -eq 0 ]; then
    _gh_var_set "LAST_TESTED_ALPHA_VERSION_CODE" "$VERSION_CODE"
    _gh_var_set "LAST_SUCCESSFUL_FIREBASE_RUN" "$NOW"
fi
exit "$FINAL_RC"
