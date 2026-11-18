#!/usr/bin/env bash
# Verify that the Dagger version pins are consistent across the project.
#
# Three "deployment" pins say which Dagger CLI to install. They MUST all be the
# same, and must match the engine they talk to. The engine itself is pinned
# out-of-repo (gitops: dagger_version in ansible/group_vars/all.yml and the image
# in k8s/plain/tc/dagger/dagger/apps_Deployment/dagger-engine.yaml) and the
# CLI<->engine match is enforced at runtime by scripts/setup_dagger_remote.sh.
# CLI and engine must be identical -- there is no fallback when they differ.
#   - arc-runner-image/Dockerfile  (CLI baked into the sharedinbox-arc CI runner)
#   - Dockerfile.dev               (CLI in the local dev container)
#   - DAGGER.md                    (engine Docker image tag)
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
arc_runner=$(grep -oE 'DAGGER_VERSION=[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' "$ROOT/arc-runner-image/Dockerfile" \
  | head -n1 | cut -d= -f2)
dockerfile_dev=$(grep -oE 'DAGGER_VERSION=[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' "$ROOT/Dockerfile.dev" \
  | head -n1 | cut -d= -f2)
# DAGGER.md — the engine's Docker image tag (registry.dagger.io/engine:vX.Y.Z).
dagger_md=$(grep -oE 'registry\.dagger\.io/engine:v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' "$ROOT/DAGGER.md" \
  | head -n1 | sed -E 's@.*:v@@')
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
    echo "         dagger_version in ansible/group_vars/all.yml and the image in"
    echo "         k8s/plain/tc/dagger/dagger/apps_Deployment/dagger-engine.yaml"
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

# ---------------------------------------------------------------------------
# Secret references must name their provider with a scheme. Dagger v1.0 rejects
# the old `--flag env:NAME` form ("must name its provider with a scheme"); it
# needs `env://NAME` (same for file:// and cmd://). On 2026-11-15 the bump to
# v1.0.0-beta.27 left 28 old-form refs behind and broke deploy, release and the
# website pipeline until #1258. Static, so pre-commit catches it too.
# ---------------------------------------------------------------------------
old_refs=$(git -C "$ROOT" grep -nE -- '--[a-z][a-z0-9-]*[= ]+["'"'"']?(env|file|cmd):[^/[:space:]]' \
  -- '.github/workflows/*.yml' '.github/workflows/*.yaml' 'Taskfile.yml' '*.sh' ':!scripts/check_dagger_versions.sh' || true)
if [ -n "$old_refs" ]; then
  {
    echo ""
    echo "ERROR: Dagger secret references without a scheme. Dagger v1.0 needs"
    echo "       env://NAME (or file://PATH, cmd://CMD); env:NAME fails at runtime with"
    echo "       \"must name its provider with a scheme\":"
    printf '%s\n' "$old_refs" | sed 's/^/         /'
  } >&2
  exit 1
fi
echo "Dagger secret references use env:// (Dagger v1.0 scheme)."

# ---------------------------------------------------------------------------
# Engine selection uses DAGGER_ENGINE (Dagger 1.0). The old runner-host
# variable is a deprecated fallback in 1.0; every client moved off it on
# 2026-11-18 (gitops#1084). Lines that say "deprecated" may name it.
# ---------------------------------------------------------------------------
old_var="_EXPERIMENTAL_DAGGER_""RUNNER_HOST"
old_uses=$(git -C "$ROOT" grep -nF -- "$old_var" | grep -iv deprecated || true)
if [ -n "$old_uses" ]; then
  {
    echo ""
    echo "ERROR: use DAGGER_ENGINE (Dagger 1.0) instead of the deprecated $old_var:"
    printf '%s\n' "$old_uses" | sed 's/^/         /'
  } >&2
  exit 1
fi
echo "Engine selected with DAGGER_ENGINE (Dagger v1.0 name)."

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

if [ -z "${DAGGER_ENGINE:-}" ]; then
  {
    echo ""
    echo "ERROR: --engine was requested but DAGGER_ENGINE is unset,"
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

engine=$(printf '%s' "$engine_out" | grep -oE '"version"[[:space:]]*:[[:space:]]*"v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?(\+[0-9A-Za-z.]+)?"' \
  | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' | head -n1 || true)

if [ "$query_rc" -ne 0 ] || [ -z "$engine" ]; then
  {
    echo ""
    echo "ERROR: could not read the version of the running Dagger engine"
    echo "       (DAGGER_ENGINE=${DAGGER_ENGINE})."
    echo "       Refusing to continue: without the engine version this check would"
    echo "       silently degrade to comparing in-repo files to each other, which is"
    echo "       precisely the blind spot it exists to close."
    echo "       query exit code: $query_rc"
    echo "--- output ---"
    printf '%s\n' "${engine_out:-(no output captured from \`dagger query\`)}" | tail -8
  } >&2
  exit 1
fi

cli=$(dagger version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' | head -n1 || true)
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
    echo "       (dagger_version in ansible/group_vars/all.yml and the engine"
    echo "       Deployment image; Flux rolls the pod). See guettli/gitops#1011."
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
    echo "         gitops:      dagger_version in ansible/group_vars/all.yml, re-run tc.yml, then restart dagger-engine"
  } >&2
  exit 1
fi

# 3. The CLI on this runner must equal the engine. setup_dagger_remote.sh fetches
#    the engine's CLI when the runner image's differs, so a mismatch here means
#    that switch did not happen (or this ran without setup_dagger_remote.sh).
if [ -n "$cli" ] && [ "$cli" != "$engine" ]; then
  {
    echo ""
    echo "ERROR: the Dagger CLI on this runner (v$cli) does not match the engine"
    echo "       (v$engine). scripts/setup_dagger_remote.sh should have fetched the"
    echo "       engine's CLI (scripts/dagger_cli_for_engine.sh) and put it on PATH;"
    echo "       look for its \"fetching CLI\" line or warning in the setup step."
  } >&2
  exit 1
fi

echo "Dagger live check OK: engine v$engine, CLI v${cli:-?}, engineVersion v$dagger_json."
