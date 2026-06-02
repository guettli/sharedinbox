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

# Setup SSH directory and keys
mkdir -p ~/.ssh
chmod 700 ~/.ssh
echo "$DAGGER_SSH_KEY" > ~/.ssh/dagger_key
chmod 600 ~/.ssh/dagger_key

# Add remote host to known_hosts
ssh-keyscan -H "$DAGGER_ENGINE_HOST" >> ~/.ssh/known_hosts 2>/dev/null

# Create a background SSH tunnel to the Dagger engine.
# We map local port 8080 to remote port 1774 (where our socat bridge is listening).
echo "Establishing SSH tunnel to $DAGGER_ENGINE_HOST..."
ssh -i ~/.ssh/dagger_key -o StrictHostKeyChecking=no -f -N -L 8080:localhost:1774 "dagger@$DAGGER_ENGINE_HOST"

# Export _EXPERIMENTAL_DAGGER_RUNNER_HOST to use the tunnel.
export _EXPERIMENTAL_DAGGER_RUNNER_HOST="tcp://localhost:8080"
if [ -n "${GITHUB_ENV:-}" ]; then
    echo "_EXPERIMENTAL_DAGGER_RUNNER_HOST=tcp://localhost:8080" >> "$GITHUB_ENV"
fi

# Verify the connection
echo "Verifying connection to Dagger engine via SSH tunnel..."
# Use a simple command that doesn't require complex GraphQL operations.
if ! timeout 45 dagger core --help >/dev/null 2>&1 ; then
    echo "Error: Dagger engine unreachable via tunnel at localhost:8080"
    # Debug
    ps aux | grep ssh
    exit 1
fi
echo "Dagger connection verified successfully."
