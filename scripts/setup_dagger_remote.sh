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

# Use ssh-agent to manage the key for Dagger's internal SSH client
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/dagger_key

# Export _EXPERIMENTAL_DAGGER_RUNNER_HOST for redirection
# Dagger's Go SSH client will now use the agent to find the key
export _EXPERIMENTAL_DAGGER_RUNNER_HOST="ssh://dagger@$DAGGER_ENGINE_HOST"
if [ -n "${GITHUB_ENV:-}" ]; then
    echo "_EXPERIMENTAL_DAGGER_RUNNER_HOST=ssh://dagger@$DAGGER_ENGINE_HOST" >> "$GITHUB_ENV"
    # Also pass the agent socket if needed, though Dagger usually handles this if exported
    echo "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" >> "$GITHUB_ENV"
    echo "SSH_AGENT_PID=$SSH_AGENT_PID" >> "$GITHUB_ENV"
fi

# Verify
echo "Verifying connection to remote Dagger engine..."
# Ensure remote dagger knows which socket to use
if ! timeout 45 dagger query --progress=plain '{ version }' ; then
    echo "Error: Dagger engine unreachable via SSH at $DAGGER_ENGINE_HOST"
    # Debug: try to just run id over ssh
    ssh -i ~/.ssh/dagger_key -o StrictHostKeyChecking=no "dagger@$DAGGER_ENGINE_HOST" "id"
    exit 1
fi
echo "Dagger connection verified."
