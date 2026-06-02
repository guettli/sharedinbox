#!/usr/bin/env bash
set -euo pipefail

if [ -z "${SOPS_AGE_KEY:-}" ]; then
    echo "Error: SOPS_AGE_KEY must be set."
    exit 1
fi

echo "Decrypting secrets with SOPS..."
export SOPS_AGE_KEY="$SOPS_AGE_KEY"
SECRETS_JSON=$(mktemp)
trap "rm -f $SECRETS_JSON" EXIT

sops --decrypt --output-type json secrets.enc.yaml > "$SECRETS_JSON"

DAGGER_SSH_KEY=$(jq -r '.DAGGER_SSH_KEY' "$SECRETS_JSON")
DAGGER_ENGINE_HOST=$(jq -r '.DAGGER_ENGINE_HOST' "$SECRETS_JSON")

# Setup SSH
mkdir -p ~/.ssh
chmod 700 ~/.ssh
echo "$DAGGER_SSH_KEY" > ~/.ssh/dagger_key
chmod 600 ~/.ssh/dagger_key

cat << SSHEOF > ~/.ssh/config.dagger
Host dagger-engine
    HostName $DAGGER_ENGINE_HOST
    User dagger
    IdentityFile ~/.ssh/dagger_key
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
SSHEOF

if ! grep -q "Include ~/.ssh/config.dagger" ~/.ssh/config 2>/dev/null; then
    echo "Include ~/.ssh/config.dagger" >> ~/.ssh/config
fi

# Use absolute path for dagger on the remote side to avoid PATH issues in non-interactive SSH
cat << 'WRAPPER' > /usr/local/bin/dagger-remote
#!/bin/bash
ssh -F ~/.ssh/config.dagger dagger-engine /usr/local/bin/dagger "$@"
WRAPPER
chmod +x /usr/local/bin/dagger-remote

# Verify
echo "Verifying connection via dagger-remote wrapper..."
if ! dagger-remote query '{ version }' >/dev/null 2>&1; then
    echo "Error: Dagger engine unreachable via dagger-remote wrapper (tried /usr/local/bin/dagger)"
    # Debug: try to just run id
    ssh -F ~/.ssh/config.dagger dagger-engine "id"
    exit 1
fi

# Path management
mkdir -p ~/bin
ln -sf /usr/local/bin/dagger-remote ~/bin/dagger
if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$HOME/bin" >> "$GITHUB_PATH"
fi

echo "Dagger remote configured successfully."
