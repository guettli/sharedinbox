#!/usr/bin/env bash
# Establishes a secure tunnel to a remote Dagger Engine via SSH using SOPS secrets.
set -euo pipefail

# 0. Check for old environment variables
if [ -n "${DAGGER_STUNNEL_URL:-}" ] || [ -n "${DAGGER_CA_CERT:-}" ]; then
    echo "ERROR: Old environment variables (DAGGER_STUNNEL_URL or DAGGER_CA_CERT) are present."
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

# 4. Export environment
# We use _EXPERIMENTAL_DAGGER_RUNNER_HOST for Dagger v0.20.x SSH redirection
export _EXPERIMENTAL_DAGGER_RUNNER_HOST="ssh://dagger-engine"

if [ -n "${GITHUB_ENV:-}" ]; then
    echo "_EXPERIMENTAL_DAGGER_RUNNER_HOST=ssh://dagger-engine" >> "$GITHUB_ENV"
fi

# 5. Verify connection
echo "Verifying Dagger connection to $DAGGER_ENGINE_HOST..."
if ! timeout 30 dagger query '{ version }' >/dev/null 2>&1; then
    echo "Error: Dagger engine is unreachable via SSH at $DAGGER_ENGINE_HOST"
    exit 1
fi
echo "Dagger connection verified."
