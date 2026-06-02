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
echo "Decrypting secrets with SOPS..."
export SOPS_AGE_KEY="$SOPS_AGE_KEY"
SECRETS_JSON=$(mktemp)
trap "rm -f $SECRETS_JSON" EXIT

sops --decrypt --output-type json secrets.enc.yaml > "$SECRETS_JSON"

DAGGER_SSH_KEY=$(jq -r '.DAGGER_SSH_KEY' "$SECRETS_JSON")
DAGGER_ENGINE_HOST=$(jq -r '.DAGGER_ENGINE_HOST' "$SECRETS_JSON")

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

if ! grep -q "Include ~/.ssh/config.dagger" ~/.ssh/config 2>/dev/null; then
    echo "Include ~/.ssh/config.dagger" >> ~/.ssh/config
fi

# 4. Debug SSH
echo "Testing SSH connection to $DAGGER_ENGINE_HOST..."
if ! ssh -F ~/.ssh/config.dagger dagger-engine "id && dagger version" ; then
    echo "Error: Basic SSH connection to dagger-engine failed."
    exit 1
fi

# 5. Export environment
export DAGGER_HOST="ssh://dagger-engine"
if [ -n "${GITHUB_ENV:-}" ]; then
    echo "DAGGER_HOST=ssh://dagger-engine" >> "$GITHUB_ENV"
fi

# 6. Verify connection
echo "Verifying Dagger connection..."
if ! dagger query '{ version }' >/dev/null ; then
    echo "Error: Dagger engine is unreachable via SSH at $DAGGER_ENGINE_HOST"
    # Try one more thing: explicit socket if we suspect something
    exit 1
fi
echo "Dagger connection verified."
