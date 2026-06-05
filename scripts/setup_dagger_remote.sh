#!/usr/bin/env bash
set -euo pipefail
[ "${CI:-}" = "true" ] || [ "$(id -u)" != "0" ] || { echo "ERROR: Do not run as root. See DEVELOPMENT.md."; exit 1; }

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

# Export all CI secrets to the GitHub Actions environment so subsequent steps
# can use them without referencing Forgejo secrets directly.
export_secret() {
    local name="$1"
    local value
    value=$(jq -r --arg k "$name" '.[$k] // empty' "$SECRETS_JSON")
    if [ -n "${GITHUB_ENV:-}" ]; then
        # Use heredoc syntax for multiline-safe export.
        # Avoid adding a second trailing newline for values that already end with one
        # (e.g. SSH private keys), which can corrupt PEM parsing.
        {
            printf '%s<<__EOF__\n' "$name"
            printf '%s' "$value"
            [ "${value%$'\n'}" = "$value" ] && printf '\n'
            printf '__EOF__\n'
        } >> "$GITHUB_ENV"
    fi
    printf '[secrets] exported %s (%d chars)\n' "$name" "${#value}"
}

export_secret "SSH_PRIVATE_KEY"
export_secret "SSH_KNOWN_HOSTS"
export_secret "SSH_USER"
export_secret "SSH_HOST"
export_secret "WEBSITE_SSH_HOST"
export_secret "PLAY_STORE_CONFIG_JSON"
export_secret "ANDROID_KEYSTORE_BASE64"
export_secret "ANDROID_KEYSTORE_PASSWORD"
export_secret "FIREBASE_TEST_LAB_SERVICE_ACCOUNT_KEY"
export_secret "RENOVATE_FORGEJO_TOKEN"

# Setup SSH directory and keys
mkdir -p ~/.ssh
chmod 700 ~/.ssh
rm -f ~/.ssh/dagger_key
echo "$DAGGER_SSH_KEY" > ~/.ssh/dagger_key
chmod 600 ~/.ssh/dagger_key

# Add remote host to known_hosts
_t0=$SECONDS
timeout 30 ssh-keyscan -H "$DAGGER_ENGINE_HOST" >> ~/.ssh/known_hosts 2>/dev/null
_elapsed=$(( SECONDS - _t0 ))
if [ "$_elapsed" -gt 10 ]; then
    echo "::warning::ssh-keyscan took ${_elapsed}s — Dagger engine host may be slow to respond"
fi

# Create a background SSH tunnel to the Dagger engine.
# We map local port 8080 to remote port 1774 (where our socat bridge is listening).
echo "Establishing SSH tunnel to $DAGGER_ENGINE_HOST..."
_t0=$SECONDS
timeout 30 ssh -i ~/.ssh/dagger_key -o StrictHostKeyChecking=no -f -N -L 8080:localhost:1774 "dagger@$DAGGER_ENGINE_HOST"
_elapsed=$(( SECONDS - _t0 ))
if [ "$_elapsed" -gt 10 ]; then
    echo "::warning::SSH tunnel setup took ${_elapsed}s"
fi

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
