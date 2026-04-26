#!/usr/bin/env bash
# Uploads the release APK to MobSF and checks for required Android permissions.
# MobSF is started via Docker automatically if not already running.
#
# Usage: scripts/mobsf_scan.sh [path/to/app.apk]
#
# Environment variables:
#   MOBSF_URL      — MobSF base URL (default: http://localhost:8000)
#   MOBSF_API_KEY  — REST API key (default: sharedinbox-dev; must match the
#                    value used when starting the container)
#
# First run pulls the MobSF Docker image (~1 GB); subsequent runs reuse it.
set -Eeuo pipefail

APK="${1:-build/app/outputs/flutter-apk/app-release.apk}"
MOBSF_URL="${MOBSF_URL:-http://localhost:8000}"
MOBSF_API_KEY="${MOBSF_API_KEY:-sharedinbox-dev}"
CONTAINER_NAME="mobsf-sharedinbox"

[[ -f "$APK" ]] || { echo "APK not found: $APK"; exit 1; }

command -v docker >/dev/null 2>&1 || { echo "docker not found — install Docker to run MobSF scans"; exit 1; }

# Start MobSF if not already running.
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    echo "Starting MobSF Docker container (this may take a moment on first run)..."
    # Pull quietly first so progress-bar noise doesn't overwrite other output.
    docker pull -q opensecurity/mobile-security-framework-mobsf:latest >/dev/null 2>&1
    docker run -d --rm \
        --name "$CONTAINER_NAME" \
        -p 8000:8000 \
        -e MOBSF_API_KEY="$MOBSF_API_KEY" \
        opensecurity/mobile-security-framework-mobsf:latest >/dev/null
fi

# Wait up to 90 s for MobSF to become ready.
echo "Waiting for MobSF to be ready..."
READY=0
for _i in $(seq 1 90); do
    curl -s --max-time 2 "$MOBSF_URL/" >/dev/null 2>&1 && READY=1 && break
    sleep 1
done
[[ "$READY" -eq 1 ]] || { echo "MobSF did not become ready at $MOBSF_URL within 90 s"; exit 1; }

# Upload APK.
echo "Uploading $(basename "$APK") to MobSF..."
UPLOAD=$(curl -s -F "file=@$APK" -H "Authorization: $MOBSF_API_KEY" "$MOBSF_URL/api/v1/upload")
HASH=$(echo "$UPLOAD" | jq -r '.hash // empty')
[[ -n "$HASH" ]] || { echo "Upload failed — response: $UPLOAD"; exit 1; }
echo "Scan hash: $HASH"

# Trigger scan.
echo "Scanning..."
curl -s -X POST \
    --data "hash=$HASH&re_scan=0" \
    -H "Authorization: $MOBSF_API_KEY" \
    "$MOBSF_URL/api/v1/scan" >/dev/null

# Fetch JSON report.
REPORT_FILE=$(mktemp /tmp/mobsf-report-XXXXXX.json)
trap 'rm -f "$REPORT_FILE"' EXIT
curl -s -X POST \
    --data "hash=$HASH" \
    -H "Authorization: $MOBSF_API_KEY" \
    "$MOBSF_URL/api/v1/report_json" >"$REPORT_FILE"

# ── Permission checks ─────────────────────────────────────────────────────────

FAIL=0

check_permission() {
    local perm="$1"
    # MobSF returns permissions as an object keyed by permission name.
    if jq -e --arg p "$perm" '.permissions | has($p)' "$REPORT_FILE" >/dev/null 2>&1; then
        echo "  OK : $perm"
    else
        echo "  FAIL: $perm missing from AndroidManifest.xml"
        FAIL=1
    fi
}

echo "Checking required permissions..."
check_permission "android.permission.INTERNET"

[[ "$FAIL" -eq 0 ]] || { echo "MobSF scan failed — fix the issues above."; exit 1; }
echo "MobSF scan passed."
