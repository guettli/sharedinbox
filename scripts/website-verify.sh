#!/usr/bin/env bash
set -euo pipefail

VERSION=$(git rev-parse --short HEAD)
URL="https://sharedinbox.de/"

echo "Checking that version ${VERSION} is live at ${URL} ..."
for i in $(seq 1 6); do
    HTTP=$(curl -so /tmp/website-verify.html -w "%{http_code}" "${URL}" 2>/dev/null || true)
    if [ "${HTTP}" != "200" ]; then
        echo "HTTP ${HTTP} (attempt ${i}/6); waiting 10s ..."
    elif grep -q "x-version.*${VERSION}" /tmp/website-verify.html; then
        echo "OK: version ${VERSION} is live (HTTP ${HTTP})."
        exit 0
    else
        echo "HTTP 200 but version ${VERSION} not found (attempt ${i}/6); waiting 10s ..."
    fi
    sleep 10
done

echo "FAIL: version ${VERSION} not live at ${URL} after 60s"
exit 1
