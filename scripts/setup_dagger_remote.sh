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

# Append config directly to avoid 'Include' issues in some Go-based SSH clients
cat << SSHEOF >> ~/.ssh/config
Host dagger-engine
    HostName $DAGGER_ENGINE_HOST
    User dagger
    IdentityFile ~/.ssh/dagger_key
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
SSHEOF

# Export _EXPERIMENTAL_DAGGER_RUNNER_HOST for redirection
# Use the full SSH URL format to ensure Dagger has everything it needs
export _EXPERIMENTAL_DAGGER_RUNNER_HOST="ssh://dagger@$DAGGER_ENGINE_HOST?identityFile=~/.ssh/dagger_key&strictHostKeyChecking=no"
if [ -n "${GITHUB_ENV:-}" ]; then
    echo "_EXPERIMENTAL_DAGGER_RUNNER_HOST=ssh://dagger@$DAGGER_ENGINE_HOST?identityFile=~/.ssh/dagger_key&strictHostKeyChecking=no" >> "$GITHUB_ENV"
fi

# Verify
echo "Verifying connection to remote Dagger engine..."
# Use --progress=plain to see what's happening if it hangs/fails
if ! timeout 45 dagger query --progress=plain '{ version }' ; then
    echo "Error: Dagger engine unreachable via SSH at $DAGGER_ENGINE_HOST"
    # Debug: try to just run id over ssh
    ssh -i ~/.ssh/dagger_key -o StrictHostKeyChecking=no "dagger@$DAGGER_ENGINE_HOST" "id"
    exit 1
fi
echo "Dagger connection verified."
