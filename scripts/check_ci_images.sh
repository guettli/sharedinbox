#!/usr/bin/env bash
# Verify that every container image referenced in ci/main.go is reachable, and
# that the Flutter SDK archive URL derived from .fvmrc responds. Runs skopeo
# inspect (manifest-only, no layer pull) for each From("...") call, then a
# curl HEAD for the Flutter tarball.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
FILE="$ROOT/ci/main.go"

# Static images from From("...") literals in ci/main.go
static_images=$(grep -oP 'From\("\K[^"]+' "$FILE" | grep -v ':$' | sort -u)

fail=0

if [ -z "$static_images" ]; then
  echo "check-ci-images: no From() image references found in $FILE"
else
  while IFS= read -r image; do
    printf "check-ci-images: %-55s" "$image"
    if skopeo inspect --no-creds "docker://$image" > /dev/null 2>&1; then
      echo "OK"
    else
      echo "NOT FOUND"
      fail=1
    fi
  done <<< "$static_images"
fi

# Flutter SDK is installed from the official archive at the .fvmrc version
# (see ci/main.go toolchain()). Probe the tarball URL so a bad .fvmrc bump
# fails pre-commit instead of during a CI run (#394).
FVMRC="$ROOT/.fvmrc"
if [ ! -f "$FVMRC" ]; then
  echo "check-ci-images: ERROR: $FVMRC not found"
  exit 1
fi
flutter_version=$(python3 -c "import json; print(json.load(open('$FVMRC'))['flutter'])")
flutter_url="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${flutter_version}-stable.tar.xz"
printf "check-ci-images: %-55s" "$flutter_url"
if curl -fsSLI --max-time 30 "$flutter_url" > /dev/null 2>&1; then
  echo "OK"
else
  echo "NOT FOUND"
  fail=1
fi

if [ "$fail" -eq 1 ]; then
  echo ""
  echo "ERROR: one or more container images or archives referenced by ci/main.go"
  echo "       could not be resolved. Fix the reference before committing."
  exit 1
fi
