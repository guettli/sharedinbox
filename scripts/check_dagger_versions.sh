#!/usr/bin/env bash
# Verify that the Dagger version pins are consistent across the project.
#
# Three "deployment" pins say which Dagger CLI to install. They MUST all be the
# same, and must match the engine they talk to. The engine itself is pinned
# out-of-repo (gitops: ansible/p16/systemd/system/dagger-engine.service) and the
# CLI<->engine match is enforced at runtime by scripts/setup_dagger_remote.sh.
# CLI and engine must be identical -- there is no fallback when they differ.
#   - arc-runner-image/Dockerfile  (CLI baked into the sharedinbox-arc CI runner)
#   - Dockerfile.dev               (CLI in the local dev container)
#   - DAGGER.md                    (engine tag in the example systemd unit)
#
# A fourth pin lives in ci/dagger.json ("engineVersion"): the *minimum* Dagger
# version the module supports. It is allowed to lag the deployment pins (Renovate
# bumps it once the runtime catches up), so we only require:
#   engineVersion (ci/dagger.json) <= deployment pin version
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)

# DAGGER_VERSION=X.Y.Z on the dagger install line (shared by both Dockerfiles).
arc_runner=$(grep -oE 'DAGGER_VERSION=[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/arc-runner-image/Dockerfile" \
  | head -n1 | cut -d= -f2)
dockerfile_dev=$(grep -oE 'DAGGER_VERSION=[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/Dockerfile.dev" \
  | head -n1 | cut -d= -f2)
# DAGGER.md — engine image tag in the example systemd unit.
dagger_md=$(grep -oE 'dagger/nix/v[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/DAGGER.md" \
  | head -n1 | sed -E 's@.*/v@@')
# ci/dagger.json — strip leading "v" for comparison.
dagger_json=$(grep -oE '"engineVersion"[[:space:]]*:[[:space:]]*"[^"]+"' "$ROOT/ci/dagger.json" \
  | sed -E 's/.*"v?([^"]+)"$/\1/')

printf 'arc-runner-image/Dockerfile  DAGGER_VERSION = %s   (CI runner CLI)\n'    "$arc_runner"
printf 'Dockerfile.dev               DAGGER_VERSION = %s   (dev container CLI)\n' "$dockerfile_dev"
printf 'DAGGER.md                    engine tag     = v%s   (example engine)\n'   "$dagger_md"
printf 'ci/dagger.json               engineVersion  = v%s   (module minimum)\n'   "$dagger_json"

for pair in \
  "arc-runner-image/Dockerfile=$arc_runner" \
  "Dockerfile.dev=$dockerfile_dev" \
  "DAGGER.md=$dagger_md" \
  "ci/dagger.json=$dagger_json"; do
  if [ -z "${pair#*=}" ]; then
    echo "ERROR: failed to parse a Dagger version from ${pair%%=*}." >&2
    exit 1
  fi
done

# All three deployment pins must be identical.
if [ "$arc_runner" != "$dockerfile_dev" ] || [ "$arc_runner" != "$dagger_md" ]; then
  {
    echo ""
    echo "ERROR: Dagger deployment pins disagree. The CI runner CLI, the dev"
    echo "       container CLI and the engine must all be the SAME version --"
    echo "       there is no fallback when they differ, CI fails at runtime."
    echo "         arc-runner-image/Dockerfile : $arc_runner"
    echo "         Dockerfile.dev              : $dockerfile_dev"
    echo "         DAGGER.md                   : $dagger_md"
    echo "       When bumping, also update the engine in gitops:"
    echo "         ansible/p16/systemd/system/dagger-engine.service"
  } >&2
  exit 1
fi

# engineVersion in ci/dagger.json must not exceed the deployment pin
# (otherwise CI fails with "module requires dagger vX, but you have vY").
lower=$(printf '%s\n%s\n' "$dagger_json" "$arc_runner" | sort -V | head -n1)
if [ "$lower" != "$dagger_json" ]; then
  {
    echo ""
    echo "ERROR: ci/dagger.json engineVersion (v$dagger_json) is newer than the"
    echo "       deployed CLI/engine pin (v$arc_runner). Bumping engineVersion"
    echo "       before the runtime is upgraded would break CI."
  } >&2
  exit 1
fi

if [ "$dagger_json" = "$arc_runner" ]; then
  echo "Dagger versions aligned (v$arc_runner)."
else
  echo "Dagger versions OK: engineVersion v$dagger_json <= deployment v$arc_runner (staged upgrade)."
fi
