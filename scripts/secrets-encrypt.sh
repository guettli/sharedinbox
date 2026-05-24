#!/usr/bin/env bash
# Encrypts secrets.env → secrets.age using an age public key.
#
# Usage:
#   scripts/secrets-encrypt.sh [AGE1...]   public key as positional argument
#   AGE_PUBLIC_KEY=AGE1... scripts/secrets-encrypt.sh
#   scripts/secrets-encrypt.sh             reads public key from .age-public-key
#
# The private key never touches this script. Only the public key is needed to
# encrypt. Store the private key in CI as SECRETS_AGE_KEY and keep a local
# copy at ~/.config/age/sharedinbox.key (or wherever you prefer).
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
    || REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SECRETS_ENV="${SECRETS_ENV:-${REPO_ROOT}/secrets.env}"
SECRETS_AGE="${SECRETS_AGE:-${REPO_ROOT}/secrets.age}"
KEY_FILE="${REPO_ROOT}/.age-public-key"

if [ -n "${1:-}" ]; then
    PUBLIC_KEY="$1"
elif [ -n "${AGE_PUBLIC_KEY:-}" ]; then
    PUBLIC_KEY="$AGE_PUBLIC_KEY"
elif [ -f "$KEY_FILE" ]; then
    PUBLIC_KEY=$(cat "$KEY_FILE")
    PUBLIC_KEY="${PUBLIC_KEY%%$'\n'*}"  # take only the first line
else
    echo "ERROR: No age public key provided." >&2
    echo "  Pass it as an argument: scripts/secrets-encrypt.sh AGE1..." >&2
    echo "  Or store it in .age-public-key: age-keygen -y ~/.config/age/sharedinbox.key > .age-public-key" >&2
    exit 1
fi

if [ ! -f "$SECRETS_ENV" ]; then
    echo "ERROR: secrets.env not found at $SECRETS_ENV" >&2
    echo "  Copy secrets.env.example to secrets.env and fill in values." >&2
    exit 1
fi

age --encrypt --recipient "$PUBLIC_KEY" --output "$SECRETS_AGE" "$SECRETS_ENV"
echo "Encrypted $SECRETS_ENV → $SECRETS_AGE"
echo "Commit secrets.age to keep CI in sync."
