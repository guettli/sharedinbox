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

# Export _EXPERIMENTAL_DAGGER_RUNNER_HOST for redirection
export _EXPERIMENTAL_DAGGER_RUNNER_HOST="ssh://dagger-engine"
if [ -n "${GITHUB_ENV:-}" ]; then
    echo "_EXPERIMENTAL_DAGGER_RUNNER_HOST=ssh://dagger-engine" >> "$GITHUB_ENV"
fi

# Verify
echo "Verifying connection to remote Dagger engine..."
if ! timeout 30 dagger query '{ version }' >/dev/null ; then
    echo "Error: Dagger engine unreachable via SSH at $DAGGER_ENGINE_HOST"
    # Debug: try to just run id over ssh
    ssh -F ~/.ssh/config.dagger dagger-engine "id"
    exit 1
fi
echo "Dagger connection verified."
