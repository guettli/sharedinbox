#!/usr/bin/env bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Add task from nix store if not already in PATH
if ! command -v task &>/dev/null; then
    TASK_BIN=$(ls -d /nix/store/*go-task-*/bin/task 2>/dev/null | sort -V | tail -1)
    [ -n "$TASK_BIN" ] && export PATH="$(dirname "$TASK_BIN"):$PATH"
fi

exec python3 "$REPO_DIR/deploy_cron.py"
