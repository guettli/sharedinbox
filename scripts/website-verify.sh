#!/usr/bin/env bash
set -euo pipefail

VERSION=$(git rev-parse --short HEAD)
URL="https://sharedinbox.de/"

echo "Checking that version ${VERSION} is live at ${URL} ..."

USE_SSH=false
if [ -n "${SSH_PRIVATE_KEY:-}" ] && [ -n "${SSH_USER:-}" ] && [ -n "${SSH_HOST:-}" ]; then
    USE_SSH=true
    echo "SSH credentials found. Will verify website via SSH on the host."
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    SSH_KEY_FILE=$(mktemp)
    echo "$SSH_PRIVATE_KEY" > "$SSH_KEY_FILE"
    chmod 600 "$SSH_KEY_FILE"
    trap 'rm -f "$SSH_KEY_FILE"' EXIT
fi

for i in $(seq 1 6); do
    if [ "$USE_SSH" = true ]; then
        OUT=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$SSH_HOST" "
            HTTP=\$(curl -so /tmp/website-verify.html -w '%{http_code}' '${URL}' 2>/dev/null || echo '000')
            echo \"\$HTTP\"
            cat /tmp/website-verify.html 2>/dev/null || true
        " || true)
        HTTP=$(echo "$OUT" | head -n 1)
        HTML=$(echo "$OUT" | tail -n +2)
    else
        HTTP=$(curl -so /tmp/website-verify.html -w "%{http_code}" "${URL}" 2>/dev/null || true)
        HTML=$(cat /tmp/website-verify.html 2>/dev/null || true)
    fi

    if [ "${HTTP}" != "200" ]; then
        echo "HTTP ${HTTP} (attempt ${i}/6); waiting 10s ..."
    elif echo "$HTML" | grep -q "x-version.*${VERSION}"; then
        echo "OK: version ${VERSION} is live (HTTP ${HTTP})."
        exit 0
    else
        echo "HTTP 200 but version ${VERSION} not found (attempt ${i}/6); waiting 10s ..."
    fi
    sleep 10
done

echo "FAIL: version ${VERSION} not live at ${URL} after 60s"
exit 1
