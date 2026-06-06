#!/usr/bin/env bash
set -euo pipefail

tmp=$(mktemp /dev/shm/keystore.XXXXXX.jks)
trap "rm -f $tmp" EXIT

printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 -d > "$tmp"

ANDROID_KEYSTORE_PATH="$tmp" \
ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}" \
fvm flutter build appbundle --release --no-pub \
  --build-number "$(date +%s)" \
  --build-name "$(date +%y%m%d-%H%M)" \
  --dart-define="GIT_HASH=$(git rev-parse --short HEAD)" \
  | grep -Ev "was tree-shaken|Tree-shaking can be disabled"
