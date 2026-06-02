#!/usr/bin/env bash
# Establishes a secure tunnel to a remote Dagger Engine via SSH using SOPS secrets.
set -euo pipefail

# 0. Check for old environment variables
if [ -n "${DAGGER_STUNNEL_URL:-}" ] || [ -n "${DAGGER_CA_CERT:-}" ] || [ -n "${DAGGER_SSH_KEY:-}" ]; then
    echo "ERROR: Old environment variables (DAGGER_STUNNEL_URL, DAGGER_CA_CERT, or DAGGER_SSH_KEY) are present in the environment."
    echo "Only SOPS_AGE_KEY should be set in Codeberg secrets."
    exit 1
fi

if [ -z "${SOPS_AGE_KEY:-}" ]; then
    echo "Error: SOPS_AGE_KEY must be set."
    exit 1
fi

# 1. Decrypt secrets using SOPS
# We assume sops is available in the nix environment
echo "Decrypting secrets with SOPS..."
# Exporting for SOPS
export SOPS_AGE_KEY="$SOPS_AGE_KEY"

# Create a temporary file to store decrypted secrets
SECRETS_JSON=$(mktemp)
trap "rm -f $SECRETS_JSON" EXIT

# Decrypt the SOPS file (must be in the repo root)
sops --decrypt secrets.enc.yaml > "$SECRETS_JSON"

DAGGER_SSH_KEY=$(jq -r '.DAGGER_SSH_KEY' "$SECRETS_JSON")
DAGGER_ENGINE_HOST=$(jq -r '.DAGGER_ENGINE_HOST' "$SECRETS_JSON")

if [ "$DAGGER_SSH_KEY" == "null" ] || [ -z "$DAGGER_SSH_KEY" ]; then
    echo "Error: DAGGER_SSH_KEY not found in secrets.enc.yaml"
    exit 1
fi

if [ "$DAGGER_ENGINE_HOST" == "null" ] || [ -z "$DAGGER_ENGINE_HOST" ]; then
    echo "Error: DAGGER_ENGINE_HOST not found in secrets.enc.yaml"
    exit 1
fi

# 2. Setup SSH key
mkdir -p ~/.ssh
chmod 700 ~/.ssh
echo "$DAGGER_SSH_KEY" > ~/.ssh/dagger_key
chmod 600 ~/.ssh/dagger_key

# 3. Configure SSH for Dagger
cat << SSHEOF > ~/.ssh/config.dagger
Host dagger-engine
    HostName $DAGGER_ENGINE_HOST
    User dagger
    IdentityFile ~/.ssh/dagger_key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ControlMaster auto
    ControlPath ~/.ssh/dagger-%r@%h:%p
    ControlPersist 10m
SSHEOF

# Append to main ssh config if not already there
if ! grep -q "config.dagger" ~/.ssh/config 2>/dev/null; then
    echo "Include ~/.ssh/config.dagger" >> ~/.ssh/config
fi

# 4. Export environment for subsequent CI steps
export DAGGER_HOST="ssh://dagger-engine"

if [ -n "${GITHUB_ENV:-}" ]; then
    echo "DAGGER_HOST=ssh://dagger-engine" >> "$GITHUB_ENV"
    echo "Tunnel established via SSH. Dagger is configured to use the remote engine at $DAGGER_ENGINE_HOST"
else
    echo "Dagger configured at ssh://dagger-engine"
fi

# 5. Verify connection
echo "Verifying Dagger connection..."
if ! timeout 30 dagger query '{ version }' >/dev/null 2>&1; then
    echo "Error: Dagger engine is unreachable via SSH at $DAGGER_ENGINE_HOST"
    exit 1
fi
echo "Dagger connection verified."
