#!/usr/bin/env bash
set -euo pipefail

VERSION=$(git rev-parse --short HEAD)
URL="https://sharedinbox.de/"

echo "Checking that version ${VERSION} is live at ${URL} ..."
for i in $(seq 1 6); do
    if curl -sf "${URL}" | grep -q "x-version.*${VERSION}"; then
        echo "OK: version ${VERSION} is live."
        exit 0
    fi
    echo "Not yet (attempt ${i}/6); waiting 10s ..."
    sleep 10
done

echo "FAIL: version ${VERSION} not found at ${URL}"
exit 1
