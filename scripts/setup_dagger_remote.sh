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
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
SSHEOF

if ! grep -q "Include ~/.ssh/config.dagger" ~/.ssh/config 2>/dev/null; then
    echo "Include ~/.ssh/config.dagger" >> ~/.ssh/config
fi

# The docker exec wrapper approach on the server expects we run 'dagger' command there.
# We can use a trick: set _EXPERIMENTAL_DAGGER_RUNNER_HOST to a script that runs ssh.
# But simpler: write a local wrapper script that runs ssh ... dagger.

cat << 'WRAPPER' > /usr/local/bin/dagger-remote
#!/bin/bash
ssh -F ~/.ssh/config.dagger dagger-engine dagger "$@"
WRAPPER
chmod +x /usr/local/bin/dagger-remote

# Verify
echo "Verifying connection via dagger-remote wrapper..."
if ! dagger-remote query '{ version }' >/dev/null 2>&1; then
    echo "Error: Dagger engine unreachable via dagger-remote wrapper"
    exit 1
fi

# To make 'task' and other steps work, we alias dagger to dagger-remote
# Or we use _EXPERIMENTAL_DAGGER_RUNNER_HOST=ssh://dagger-engine if it worked.
# Since it hung, let's try the alias approach by putting it in PATH.
mkdir -p ~/bin
ln -sf /usr/local/bin/dagger-remote ~/bin/dagger
if [ -n "${GITHUB_PATH:-}" ]; then
    echo "$HOME/bin" >> "$GITHUB_PATH"
fi

echo "Dagger remote configured via SSH wrapper."
