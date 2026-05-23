#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load .env into environment
set -a
# shellcheck source=.env
source "$REPO_DIR/.env"
set +a

# Add task and dagger from nix store if not already in PATH
for pkg in "*go-task-*/bin/task" "*dagger-*/bin/dagger"; do
    bin=$(ls -d /nix/store/$pkg 2>/dev/null | sort -V | tail -1)
    [ -n "$bin" ] && export PATH="$(dirname "$bin"):$PATH"
done

exec python3 "$REPO_DIR/deploy_cron.py"
