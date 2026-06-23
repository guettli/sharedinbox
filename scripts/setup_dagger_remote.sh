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

# Export all CI secrets to the GitHub Actions environment so subsequent steps
# can use them without referencing Forgejo secrets directly.
export_secret() {
    local name="$1"
    local value
    value=$(jq -r --arg k "$name" '.[$k] // empty' "$SECRETS_JSON")
    # Register each non-empty line for log redaction in the Actions runner.
    if [ -n "$value" ] && [ -n "${GITHUB_ENV:-}" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && printf '::add-mask::%s\n' "$line"
        done <<< "$value"
    fi
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
export_secret "GITHUB_TOKEN"
export_secret "AGENTLOOP_OTEL_TOKEN"

# The legacy remote Dagger engine on the sialoop private network is gone:
# both the sharedinbox-arc Kubernetes runner and GitHub-hosted ubuntu-latest
# reach it via no route. With _EXPERIMENTAL_DAGGER_RUNNER_HOST left unset the
# Dagger CLI starts a local engine via the runner's container engine — Docker
# on ubuntu-latest, dind on the ARC runner pod. Shared cache is lost, but
# ephemeral runners have nothing to share anyway.
