#!/usr/bin/env bash
# Verify that the Dagger version pins are consistent across the project.
#
# Two "deployment" pins tell the operator which Dagger to install:
#   - Dockerfile.dev         (CLI in the local dev container)
#   - DAGGER.md              (engine systemd unit on the shared host)
# These must agree with each other.
#
# The third pin lives in ci/dagger.json (the module's "engineVersion").
# It is the *minimum* Dagger version the module supports.  Engine and CLI
# upgrades are deployed manually first, so engineVersion is allowed to lag
# behind the deployment pins; Renovate bumps engineVersion in a follow-up
# PR once the runtime catches up.  We therefore require:
#   engineVersion (ci/dagger.json) <= deployment pin version
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)

# ci/dagger.json — strip leading "v" for comparison.
dagger_json=$(grep -oE '"engineVersion"[[:space:]]*:[[:space:]]*"[^"]+"' "$ROOT/ci/dagger.json" \
  | sed -E 's/.*"v?([^"]+)"$/\1/')

# Dockerfile.dev — DAGGER_VERSION env on the install line.
dockerfile_dev=$(grep -oE 'DAGGER_VERSION=[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/Dockerfile.dev" \
  | head -n1 \
  | cut -d= -f2)

# DAGGER.md — engine image tag in the example systemd unit.
dagger_md=$(grep -oE 'dagger/nix/v[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/DAGGER.md" \
  | head -n1 \
  | sed -E 's@.*/v@@')

printf 'ci/dagger.json    engineVersion = v%s\n' "$dagger_json"
printf 'Dockerfile.dev    DAGGER_VERSION= %s\n'  "$dockerfile_dev"
printf 'DAGGER.md         engine tag    = v%s\n' "$dagger_md"

for v in "$dagger_json" "$dockerfile_dev" "$dagger_md"; do
  if [ -z "$v" ]; then
    echo "ERROR: failed to parse a Dagger version reference." >&2
    exit 1
  fi
done

# The two deployment pins must agree with each other.
if [ "$dagger_md" != "$dockerfile_dev" ]; then
  echo "" >&2
  echo "ERROR: deployment-side Dagger pins are out of sync." >&2
  echo "  Align Dockerfile.dev and DAGGER.md to the same version." >&2
  exit 1
fi

# engineVersion in ci/dagger.json must not exceed the deployment pin
# (otherwise CI would fail with "module requires dagger vX, but you have vY").
lower=$(printf '%s\n%s\n' "$dagger_json" "$dockerfile_dev" | sort -V | head -n1)
if [ "$lower" != "$dagger_json" ]; then
  echo "" >&2
  echo "ERROR: ci/dagger.json engineVersion (v$dagger_json) is newer than the" >&2
  echo "       deployed CLI/engine pin (v$dockerfile_dev).  Bumping engineVersion" >&2
  echo "       before the runtime is upgraded would break CI." >&2
  exit 1
fi

if [ "$dagger_json" = "$dockerfile_dev" ]; then
  echo "Dagger versions aligned (v$dagger_json)."
else
  echo "Dagger versions OK: engineVersion v$dagger_json <= deployment v$dockerfile_dev (staged upgrade)."
fi
