#!/usr/bin/env bash
# Install task, dagger and sops on a GitHub-hosted runner.
#
# Versions are pinned to match the dev container so workflow runs and local
# `task` invocations behave identically:
#   - task   v3.48.0  (also pinned in Dockerfile.dev)
#   - dagger 0.21.6   (also pinned in Dockerfile.dev; see scripts/check_dagger_versions.sh)
#   - sops   3.13.1   (also pinned in .github/workflows/publish-dev-container.yml)
#
# This script is a no-op on self-hosted runners where the tools are baked into
# the image — each tool is only installed if not already on PATH.
set -euo pipefail

TASK_VERSION=v3.48.0
DAGGER_VERSION=0.21.6
SOPS_VERSION=3.13.1

if ! command -v task >/dev/null 2>&1; then
    curl -fsSL https://taskfile.dev/install.sh \
        | sudo sh -s -- -b /usr/local/bin "$TASK_VERSION"
fi

if ! command -v dagger >/dev/null 2>&1; then
    curl -fsSL https://dl.dagger.io/dagger/install.sh \
        | sudo DAGGER_VERSION="$DAGGER_VERSION" BIN_DIR=/usr/local/bin sh
fi

if ! command -v sops >/dev/null 2>&1; then
    sudo curl -fsSL \
        "https://github.com/getsops/sops/releases/download/v${SOPS_VERSION}/sops-v${SOPS_VERSION}.linux.amd64" \
        -o /usr/local/bin/sops
    sudo chmod +x /usr/local/bin/sops
fi

command -v task   >/dev/null 2>&1 || { echo "ERROR: task install failed.";   exit 1; }
command -v dagger >/dev/null 2>&1 || { echo "ERROR: dagger install failed."; exit 1; }
command -v sops   >/dev/null 2>&1 || { echo "ERROR: sops install failed.";   exit 1; }

printf 'task:   %s\n' "$(task --version)"
printf 'dagger: %s\n' "$(dagger version | head -n1)"
printf 'sops:   %s\n' "$(sops --version | head -n1)"
