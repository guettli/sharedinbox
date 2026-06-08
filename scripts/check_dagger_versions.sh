#!/usr/bin/env bash
# Verify that the Dagger version is consistent across the project.
#
# The Dagger CLI must speak the same protocol as the engine it talks to.  We
# pin the version in four places (engine image in DAGGER.md, the CLI in
# flake.nix, the CLI in the Forgejo runner Dockerfile, and the module
# engineVersion in ci/dagger.json).  This script fails if any of them drift.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)

# ci/dagger.json — strip leading "v" for comparison.
dagger_json=$(grep -oE '"engineVersion"[[:space:]]*:[[:space:]]*"[^"]+"' "$ROOT/ci/dagger.json" \
  | sed -E 's/.*"v?([^"]+)"$/\1/')

# flake.nix — the dagger021 derivation's CLI download URL.
flake_nix=$(grep -oE 'dagger_v[0-9]+\.[0-9]+\.[0-9]+_linux' "$ROOT/flake.nix" \
  | head -n1 \
  | sed -E 's/dagger_v([0-9.]+)_linux/\1/')

# .forgejo/Dockerfile — DAGGER_VERSION env on the install line.
dockerfile=$(grep -oE 'DAGGER_VERSION=[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/.forgejo/Dockerfile" \
  | head -n1 \
  | cut -d= -f2)

# DAGGER.md — engine image tag in the example systemd unit.
dagger_md=$(grep -oE 'dagger/nix/v[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/DAGGER.md" \
  | head -n1 \
  | sed -E 's@.*/v@@')

printf 'ci/dagger.json    engineVersion = v%s\n' "$dagger_json"
printf 'flake.nix         dagger021     = %s\n'  "$flake_nix"
printf '.forgejo/Dockerf. DAGGER_VERSION= %s\n'  "$dockerfile"
printf 'DAGGER.md         engine tag    = v%s\n' "$dagger_md"

for v in "$flake_nix" "$dockerfile" "$dagger_md"; do
  if [ -z "$v" ]; then
    echo "ERROR: failed to parse a Dagger version reference." >&2
    exit 1
  fi
  if [ "$v" != "$dagger_json" ]; then
    echo "" >&2
    echo "ERROR: Dagger versions are out of sync." >&2
    echo "  Align ci/dagger.json, flake.nix, .forgejo/Dockerfile and DAGGER.md to the same version." >&2
    exit 1
  fi
done

echo "Dagger versions aligned (v$dagger_json)."
