#!/usr/bin/env bash
# Verify that every container image referenced in ci/main.go is reachable.
# Runs skopeo inspect (manifest-only, no layer pull) for each From("...") call.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
FILE="$ROOT/ci/main.go"

images=$(grep -oP 'From\("\K[^"]+' "$FILE" | sort -u)

if [ -z "$images" ]; then
  echo "check-ci-images: no From() image references found in $FILE"
  exit 0
fi

fail=0
while IFS= read -r image; do
  printf "check-ci-images: %-55s" "$image"
  if skopeo inspect --no-creds "docker://$image" > /dev/null 2>&1; then
    echo "OK"
  else
    echo "NOT FOUND"
    fail=1
  fi
done <<< "$images"

if [ "$fail" -eq 1 ]; then
  echo ""
  echo "ERROR: one or more container images in ci/main.go could not be resolved."
  echo "Fix the image tag before committing."
  exit 1
fi
