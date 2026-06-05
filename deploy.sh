#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" != "0" ] || { echo "ERROR: Do not run as root. See DEVELOPMENT.md."; exit 1; }
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load .env into environment
set -a
# shellcheck source=.env
source "$REPO_DIR/.env"
set +a

# SSH_PRIVATE_KEY must not live in .env (dagger parses .env and chokes on multiline values)
export SSH_PRIVATE_KEY=$(cat "$HOME/.ssh/id_ed25519")

# Add nix profile and nix store tools (task, dagger) to PATH
export PATH="$HOME/.nix-profile/bin:$PATH"
for pkg in "*go-task-*/bin/task" "*dagger-*/bin/dagger" "*fgj-*/bin/fgj"; do
    bin=$(ls -d /nix/store/$pkg 2>/dev/null | sort -V | tail -1)
    [ -n "$bin" ] && export PATH="$(dirname "$bin"):$PATH"
done

exec python3 "$REPO_DIR/deploy_cron.py"
