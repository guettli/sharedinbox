#!/usr/bin/env bash
# Decrypts secrets.age and exports all KEY=VALUE pairs as environment variables.
#
# In CI (GITHUB_ENV set): writes to $GITHUB_ENV so subsequent job steps can
# read the variables. Multi-line values use the heredoc syntax required by
# Forgejo/GitHub Actions.
#
# Locally: prints an eval-safe export block to stdout. Source it with:
#   eval "$(SECRETS_AGE_KEY=$(cat ~/.config/age/sharedinbox.key) scripts/secrets-decrypt.sh)"
#   or pass a key file:
#   eval "$(scripts/secrets-decrypt.sh ~/.config/age/sharedinbox.key)"
#
# Private key sources (first match wins):
#   1. Path to a key file passed as $1
#   2. SECRETS_AGE_KEY env var (the raw private key content — used in CI)
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
    || REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SECRETS_AGE="${SECRETS_AGE:-${REPO_ROOT}/secrets.age}"

if [ ! -f "$SECRETS_AGE" ]; then
    echo "ERROR: secrets.age not found at $SECRETS_AGE" >&2
    echo "  Run: scripts/secrets-encrypt.sh to create it." >&2
    exit 1
fi

TMP_KEY=""
cleanup() { [ -n "$TMP_KEY" ] && rm -f "$TMP_KEY"; }
trap cleanup EXIT

if [ -n "${1:-}" ]; then
    KEY_FILE="$1"
elif [ -n "${SECRETS_AGE_KEY:-}" ]; then
    TMP_KEY=$(mktemp)
    chmod 600 "$TMP_KEY"
    printf '%s\n' "$SECRETS_AGE_KEY" > "$TMP_KEY"
    KEY_FILE="$TMP_KEY"
else
    echo "ERROR: No age private key provided." >&2
    echo "  Pass a key file: scripts/secrets-decrypt.sh ~/.config/age/sharedinbox.key" >&2
    echo "  Or set SECRETS_AGE_KEY env var (CI: store as SECRETS_AGE_KEY secret)." >&2
    exit 1
fi

DECRYPTED=$(age --decrypt -i "$KEY_FILE" "$SECRETS_AGE")

# Process each KEY=VALUE line.
# Double-quoted values have \n escape sequences converted to real newlines.
process_secrets() {
    local line key raw_value value
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue

        key="${line%%=*}"
        raw_value="${line#*=}"

        # Double-quoted: strip quotes and expand \n → newline
        if [[ "$raw_value" == '"'*'"' ]]; then
            raw_value="${raw_value:1:${#raw_value}-2}"
            value=$(printf '%b' "$raw_value")
        # Single-quoted: strip quotes, no expansion
        elif [[ "$raw_value" == "'"*"'" ]]; then
            value="${raw_value:1:${#raw_value}-2}"
        else
            value="$raw_value"
        fi

        if [ -n "${GITHUB_ENV:-}" ]; then
            # Heredoc syntax handles multi-line values safely
            local delim="EOF_${key}_$$"
            printf '%s<<%s\n%s\n%s\n' "$key" "$delim" "$value" "$delim" >> "$GITHUB_ENV"
        else
            # Print as export statements for eval
            printf "export %s=%q\n" "$key" "$value"
        fi
    done <<< "$DECRYPTED"
}

process_secrets

if [ -n "${GITHUB_ENV:-}" ]; then
    echo "Secrets written to \$GITHUB_ENV." >&2
fi
