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
        # Ask the remote to run curl under `set -e` so a curl network error
        # propagates as a non-zero ssh exit — distinct from HTTP != 200.
        set +e
        OUT=$(ssh -i "$SSH_KEY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$SSH_USER@$SSH_HOST" "
            set -e
            HTTP=\$(curl -so /tmp/website-verify.html -w '%{http_code}' '${URL}')
            echo \"\$HTTP\"
            cat /tmp/website-verify.html
        ")
        rc=$?
        set -e
        if [ $rc -ne 0 ]; then
            echo "FAIL: ssh/curl network error (exit $rc) at attempt ${i}/6 for ${URL}"
            exit 1
        fi
        HTTP=$(head -n 1 <<<"$OUT")
        HTML=$(tail -n +2 <<<"$OUT")
    else
        set +e
        HTTP=$(curl -so /tmp/website-verify.html -w "%{http_code}" "${URL}")
        rc=$?
        set -e
        if [ $rc -ne 0 ]; then
            echo "FAIL: curl network error (exit $rc) at attempt ${i}/6 for ${URL}"
            exit 1
        fi
        HTML=$(cat /tmp/website-verify.html)
    fi

    if [ "${HTTP}" != "200" ]; then
        echo "HTTP status ${HTTP} (attempt ${i}/6); waiting 10s ..."
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
