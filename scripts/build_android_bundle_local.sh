#!/usr/bin/env bash
set -euo pipefail

if [ -z "${ANDROID_HOME:-}" ]; then
    echo "ERROR: ANDROID_HOME is not set. Add it to your ~/.zshrc or ~/.bashrc:" >&2
    echo "  export ANDROID_HOME=\"\$HOME/Android/Sdk\"" >&2
    exit 1
fi

tmp=$(mktemp /dev/shm/keystore.XXXXXX.jks)
trap 'rm -f "$tmp"' EXIT

printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 -d > "$tmp"

ANDROID_KEYSTORE_PATH="$tmp" \
fvm flutter build appbundle --release --no-pub \
  --build-number "$(date +%s)" \
  --build-name "$(date +%y%m%d-%H%M)" \
  --dart-define="GIT_HASH=$(git rev-parse --short HEAD)" \
  | grep -Ev "was tree-shaken|Tree-shaking can be disabled"
