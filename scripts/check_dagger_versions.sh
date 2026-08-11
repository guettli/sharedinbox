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
# version the module supports. It is allowed to lag the deployment pins, so we
# only require:
#   engineVersion (ci/dagger.json) <= deployment pin version
# Renovate deliberately does NOT manage engineVersion -- Dagger rejects a module
# only when engineVersion is NEWER than the running engine, so raising it can
# only ever break CI (issue #445). Raise it by hand after the engine moves.
#
# TWO MODES
#
#   (no args)   Static mode. Compares the in-repo pins to each other. This is
#               what pre-commit runs. It cannot see the engine, so every pin it
#               compares is a *proxy* for the version that actually decides
#               pass/fail.
#
#   --engine    Live mode, used by CI after scripts/setup_dagger_remote.sh has
#               opened the tunnel. Queries the running engine and checks the
#               pins against it. This is the only check that can catch #445,
#               where all in-repo pins agreed with each other and disagreed with
#               the engine.
#
# --engine REQUIRES a reachable engine: if the query fails, the script fails.
# It never quietly degrades to static mode -- a check that silently stops
# checking is worse than no check.
set -euo pipefail

WITH_ENGINE=0
for arg in "$@"; do
  case "$arg" in
    --engine) WITH_ENGINE=1 ;;
    -h|--help)
      sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "ERROR: unknown argument: $arg (expected --engine)" >&2
      exit 2 ;;
  esac
done

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

[ "$WITH_ENGINE" = "1" ] || exit 0

# ---------------------------------------------------------------------------
# Live mode: check the pins against the engine that will actually run the job.
#
# Everything above compares files to other files. All four can agree and CI can
# still fail, because the version that decides is the one running on the engine
# host -- which lives in another repo and is bumped by Ansible, not by a PR
# here. That is exactly how #445 got past the static check.
#
# The engine reports its own version over the tunnel that setup_dagger_remote.sh
# has already established:  echo '{version}' | dagger query  ->  {"version": "v0.21.7"}
# ---------------------------------------------------------------------------

if [ -z "${_EXPERIMENTAL_DAGGER_RUNNER_HOST:-}" ]; then
  {
    echo ""
    echo "ERROR: --engine was requested but _EXPERIMENTAL_DAGGER_RUNNER_HOST is unset,"
    echo "       so there is no engine to query. Run scripts/setup_dagger_remote.sh"
    echo "       first (CI does this in the 'Setup Dagger Remote Engine' step)."
  } >&2
  exit 1
fi

# The engine occasionally blips (restart, queue backlog). Retry a few times so a
# transient hiccup does not fail the job; budget ~2 min, well under the tunnel
# verify that ran immediately before this.
QUERY_TIMEOUT_S="${DAGGER_QUERY_TIMEOUT_S:-30}"
QUERY_MAX_ATTEMPTS="${DAGGER_QUERY_MAX_ATTEMPTS:-3}"
QUERY_RETRY_WAIT_S="${DAGGER_QUERY_RETRY_WAIT_S:-10}"
engine_out=""
query_rc=0
for attempt in $(seq 1 "$QUERY_MAX_ATTEMPTS"); do
  query_rc=0
  engine_out=$(echo '{version}' | DAGGER_NO_NAG=1 timeout "$QUERY_TIMEOUT_S" dagger query 2>&1) || query_rc=$?
  if [ "$query_rc" -eq 0 ]; then
    break
  fi
  if [ "$attempt" -eq "$QUERY_MAX_ATTEMPTS" ]; then
    break
  fi
  echo "::warning::Engine version query attempt ${attempt}/${QUERY_MAX_ATTEMPTS} failed (rc=${query_rc}); retrying in ${QUERY_RETRY_WAIT_S}s..."
  sleep "$QUERY_RETRY_WAIT_S"
done

engine=$(printf '%s' "$engine_out" | grep -oE '"version"[[:space:]]*:[[:space:]]*"v?[0-9]+\.[0-9]+\.[0-9]+"' \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)

if [ "$query_rc" -ne 0 ] || [ -z "$engine" ]; then
  {
    echo ""
    echo "ERROR: could not read the version of the running Dagger engine"
    echo "       (_EXPERIMENTAL_DAGGER_RUNNER_HOST=${_EXPERIMENTAL_DAGGER_RUNNER_HOST})."
    echo "       Refusing to continue: without the engine version this check would"
    echo "       silently degrade to comparing in-repo files to each other, which is"
    echo "       precisely the blind spot it exists to close."
    echo "       query exit code: $query_rc"
    echo "--- output ---"
    printf '%s\n' "${engine_out:-(no output captured from \`dagger query\`)}" | tail -8
  } >&2
  exit 1
fi

cli=$(dagger version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
printf 'live engine                  version        = v%s   (queried over the tunnel)\n' "$engine"
printf 'runner CLI                   version        = v%s   (dagger version)\n' "${cli:-unknown}"

# 1. The module floor must not exceed the engine. This is the check that #445
#    needed: engineVersion v0.21.8 against a v0.21.7 engine.
lower=$(printf '%s\n%s\n' "$dagger_json" "$engine" | sort -V | head -n1)
if [ "$lower" != "$dagger_json" ]; then
  {
    echo ""
    echo "ERROR: ci/dagger.json engineVersion (v$dagger_json) is newer than the"
    echo "       engine actually running (v$engine). Dagger will refuse to load the"
    echo "       module with:"
    echo "         module requires dagger v$dagger_json, but you have v$engine"
    echo "       FIX: either lower engineVersion, or bump the engine first in gitops"
    echo "       (ansible/p16/systemd/system/dagger-engine.service, then"
    echo "       systemctl restart dagger-engine). See guettli/gitops#112."
  } >&2
  exit 1
fi

# 2. The runner-image pin must equal the engine. If it does not, either the
#    engine moved without the image being republished, or the image was
#    republished against a version the engine does not have yet.
if [ "$arc_runner" != "$engine" ]; then
  {
    echo ""
    echo "ERROR: the CI runner image pin (v$arc_runner, arc-runner-image/Dockerfile)"
    echo "       does not match the running engine (v$engine). CLI and engine are"
    echo "       lock-stepped; there is no fallback when they differ."
    echo "       FIX: set both to the same version --"
    echo "         sharedinbox: arc-runner-image/Dockerfile, then republish the runner image"
    echo "         gitops:      ansible/p16/systemd/system/dagger-engine.service, then restart dagger-engine"
  } >&2
  exit 1
fi

# 3. The CLI on this runner must equal the engine. Catches a stale runner image
#    that still ships an older CLI than its Dockerfile now claims.
if [ -n "$cli" ] && [ "$cli" != "$engine" ]; then
  {
    echo ""
    echo "ERROR: the Dagger CLI on this runner (v$cli) does not match the engine"
    echo "       (v$engine), even though arc-runner-image/Dockerfile pins v$arc_runner."
    echo "       The runner image is stale: it was built before the pin changed."
    echo "       FIX: republish ghcr.io/guettli/sharedinbox-ci-runner"
    echo "       (.github/workflows/publish-ci-runner.yml)."
  } >&2
  exit 1
fi

echo "Dagger live check OK: engine v$engine, CLI v${cli:-?}, engineVersion v$dagger_json."
