#!/usr/bin/env bash
# Fetch the latest alpha APK from Play, then exercise it on Firebase Test Lab
# via the Dagger pipeline. The Play artefact is what users actually install,
# so any launch-time crash visible in production shows up here too.
#
# Cron policy (see .github/workflows/firebase-tests.yml — controls cadence):
#   1. Resolve the latest alpha versionCode and download its split APKs from
#      Play. Each fetch attempt is a short-lived Dagger exec; we retry across
#      fresh execs (see the loop below) until Play has generated the split
#      APKs. If Play has not finished within the total budget, we skip this
#      cycle (see #414 — Play-side delay is not a red build; #432 — why the
#      wait no longer lives inside one long exec). Every other failure (auth,
#      network, Play API 5xx) still exits non-zero.
#   2. Run Firebase Test Lab against the fetched APKs.
#   3. On success, record the versionCode in LAST_TESTED_ALPHA_VERSION_CODE
#      so callers can tell which alpha was last exercised green. Written
#      best-effort: GITHUB_TOKEN needs Variables:write (the default workflow
#      token cannot manage variables) so a 403 degrades to "no cache write".
#
# GITHUB_TOKEN must have Variables:write on GITHUB_REPOSITORY (the default
# workflow token cannot manage variables; the workflow injects a PAT). Any
# GitHub API error fails the job so a broken write can't silently degrade to
# "cache stays stale". Retries up to 3 times on transient Dagger engine
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

# === GitHub Actions repo-variables helpers ======================================
# GITHUB_TOKEN and GITHUB_REPOSITORY are hard requirements: without them the
# LAST_TESTED_ALPHA_VERSION_CODE write below would silently no-op and callers
# would lose track of which alpha was last exercised green.

: "${GITHUB_TOKEN:?GITHUB_TOKEN must be set (needs Variables:write on GITHUB_REPOSITORY)}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set (owner/repo)}"

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

# === Step 1: fetch the latest alpha APK set =====================================

echo "[firebase] fetching latest alpha APK set from Play Store via Dagger…" >&2
# Play-side split APK generation is asynchronous and can take from minutes to
# well over an hour after an AAB upload (see #402, #409). We used to poll for
# that whole window *inside a single Dagger exec*. That exec then sat idle for
# up to 90 minutes — long enough for the Dagger/buildkit engine to
# garbage-collect its snapshot, so the in-container marker writes died with
# FileNotFoundError and, decisively, `Directory.export` failed with "commit
# output … snapshot does not exist". A benign Play-side delay became a red
# build and a spurious "Firebase Tests failed" issue (see #422, #424, #425,
# #432), and no amount of Python-side dest-dir re-creation could fix it because
# the export failure is at the buildkit layer.
#
# Instead, poll from HERE: each attempt is a short-lived Dagger fetch (the
# Python script polls Play only briefly, then drops a PENDING marker), and we
# retry across FRESH execs until Play catches up or the overall budget elapses.
# No single exec idles long enough to be reclaimed. On the final give-up we
# skip with a ::notice:: so the workflow stays green and no issue is filed —
# the next scheduled cron tick retries.
#
# The per-attempt timeout must exceed the Python script's internal poll budget
# (`_POLL_TIMEOUT_SECONDS`, default 300s in scripts/fetch_playstore_apks.py)
# plus time to download the split APKs; otherwise a short Play-side delay is
# killed here with a bare "fetch failed" (see #396, #398).
FETCH_ATTEMPT_TIMEOUT_SECONDS=900
FETCH_MIN_BUFFER_SECONDS=300
FETCH_TOTAL_BUDGET_SECONDS=5400
FETCH_RETRY_INTERVAL_SECONDS=60
INTERNAL_POLL_SECONDS=$(python3 -c '
import re, sys
with open("scripts/fetch_playstore_apks.py") as f:
    m = re.search(r"PLAY_APKS_POLL_TIMEOUT_SECONDS[^,]+,\s*\"(\d+)\"", f.read())
sys.stdout.write(m.group(1) if m else "")
')
if [ -z "$INTERNAL_POLL_SECONDS" ]; then
    echo "ERROR: could not parse _POLL_TIMEOUT_SECONDS default from scripts/fetch_playstore_apks.py" >&2
    exit 1
fi
if [ "$FETCH_ATTEMPT_TIMEOUT_SECONDS" -lt "$((INTERNAL_POLL_SECONDS + FETCH_MIN_BUFFER_SECONDS))" ]; then
    echo "ERROR: per-attempt fetch timeout ${FETCH_ATTEMPT_TIMEOUT_SECONDS}s must exceed inner poll ${INTERNAL_POLL_SECONDS}s + ${FETCH_MIN_BUFFER_SECONDS}s buffer (see #396, #398)" >&2
    exit 1
fi

FETCH_DEADLINE=$(( $(date +%s) + FETCH_TOTAL_BUDGET_SECONDS ))
FETCH_ATTEMPT=0
while :; do
    FETCH_ATTEMPT=$((FETCH_ATTEMPT + 1))
    # Start each attempt from a clean dest dir so a stale PENDING (or partial
    # download) from a previous attempt can't be misread.
    rm -rf "$APK_DIR"
    mkdir -p "$APK_DIR"
    # A distinct --cache-buster per attempt forces the Dagger fetch exec to
    # re-run and re-check Play; otherwise the engine would serve the first
    # attempt's cached PENDING directory and the retry loop would never make
    # progress (see #432).
    if ! timeout --kill-after=10 "$FETCH_ATTEMPT_TIMEOUT_SECONDS" dagger call --progress=plain -q -m ci --source=. fetch-play-store-apks \
            --play-store-config env:PLAY_STORE_CONFIG_JSON \
            --cache-buster "${FETCH_ATTEMPT}-$(date +%s)" \
            -o "$APK_DIR"; then
        echo "ERROR: dagger fetch-play-store-apks failed" >&2
        exit 1
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
    # No PENDING marker means the split APKs were downloaded — proceed to test.
    if [ ! -f "$APK_DIR/PENDING" ]; then
        break
    fi
    NOW=$(date +%s)
    if [ "$NOW" -ge "$FETCH_DEADLINE" ]; then
        echo "::notice::[firebase] skipping: Play has not generated split APKs for versionCode $VERSION_CODE within ${FETCH_TOTAL_BUDGET_SECONDS}s (generation can take an hour or more after upload; next scheduled run will retry)" >&2
        exit 0
    fi
    echo "[firebase] Play still generating split APKs for versionCode $VERSION_CODE; retrying in ${FETCH_RETRY_INTERVAL_SECONDS}s ($(( FETCH_DEADLINE - NOW ))s left)" >&2
    sleep "$FETCH_RETRY_INTERVAL_SECONDS"
done

echo "[firebase] downloaded APKs for versionCode=$VERSION_CODE to $APK_DIR" >&2
ls -1 "$APK_DIR" >&2

# === Step 2: run Firebase Test Lab ==============================================

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

# === Step 3: on success, record which versionCode was last exercised green ======

FINAL_RC=$(cat "$RC_FILE" 2>/dev/null || echo 0)
if [ "$FINAL_RC" -eq 0 ]; then
    _gh_var_set "LAST_TESTED_ALPHA_VERSION_CODE" "$VERSION_CODE"
fi
exit "$FINAL_RC"
