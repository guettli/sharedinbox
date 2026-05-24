#!/usr/bin/env bash
# Tests for scripts/secrets-encrypt.sh and scripts/secrets-decrypt.sh.
# Run directly: bash scripts/test_secrets.sh
# Requires: age, age-keygen
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PASS=0
FAIL=0

_assert() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name"
        echo "  expected: $(printf '%s' "$expected" | head -c 80)"
        echo "  actual:   $(printf '%s' "$actual"   | head -c 80)"
        FAIL=$((FAIL + 1))
    fi
}

_assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name"
        echo "  expected to contain: $needle"
        echo "  actual: $(printf '%s' "$haystack" | head -c 200)"
        FAIL=$((FAIL + 1))
    fi
}

if ! command -v age >/dev/null 2>&1 || ! command -v age-keygen >/dev/null 2>&1; then
    echo "SKIP: age/age-keygen not found — install age to run secrets tests"
    exit 0
fi

WORKDIR=$(mktemp -d)
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

KEY_FILE="$WORKDIR/test.key"
SECRETS_ENV="$WORKDIR/secrets.env"
SECRETS_AGE="$WORKDIR/secrets.age"
GITHUB_ENV_FILE="$WORKDIR/github.env"

# Generate a test age key pair
age-keygen -o "$KEY_FILE" 2>/dev/null
PUBLIC_KEY=$(age-keygen -y "$KEY_FILE")

PRIVATE_KEY=$(cat "$KEY_FILE")

# Helper: decrypt and eval, capturing specific variables
_decrypt_vars() {
    local vars
    vars=$(SECRETS_AGE_KEY="$PRIVATE_KEY" \
        SECRETS_AGE="$SECRETS_AGE" \
        bash "$SCRIPT_DIR/secrets-decrypt.sh")
    eval "$vars"
}

# --- simple values ---
cat > "$SECRETS_ENV" << 'EOF'
SIMPLE_VAR=hello
QUOTED_DOUBLE="world"
QUOTED_SINGLE='literal'
EMPTY_VAR=
# comment line — should be ignored
NUMERIC=42
EOF

AGE_PUBLIC_KEY="$PUBLIC_KEY" \
    SECRETS_ENV="$SECRETS_ENV" \
    SECRETS_AGE="$SECRETS_AGE" \
    bash "$SCRIPT_DIR/secrets-encrypt.sh"

_decrypt_vars
_assert "simple value"         "hello"   "${SIMPLE_VAR:-}"
_assert "double-quoted value"  "world"   "${QUOTED_DOUBLE:-}"
_assert "single-quoted value"  "literal" "${QUOTED_SINGLE:-}"
_assert "empty value"          ""        "${EMPTY_VAR:-}"
_assert "numeric value"        "42"      "${NUMERIC:-}"
unset SIMPLE_VAR QUOTED_DOUBLE QUOTED_SINGLE EMPTY_VAR NUMERIC

# --- multi-line value with \n escape sequences ---
# Use a made-up key format to avoid triggering the detect-private-key pre-commit hook.
printf '%s\n' \
    'SSH_KEY="FAKE-KEY-HEADER\nfakekey\nFAKE-KEY-FOOTER"' \
    'SIDE=plain' \
    > "$SECRETS_ENV"

rm -f "$SECRETS_AGE"
AGE_PUBLIC_KEY="$PUBLIC_KEY" \
    SECRETS_ENV="$SECRETS_ENV" \
    SECRETS_AGE="$SECRETS_AGE" \
    bash "$SCRIPT_DIR/secrets-encrypt.sh"

_decrypt_vars
_assert_contains "multi-line: header present" "FAKE-KEY-HEADER" "${SSH_KEY:-}"
_assert_contains "multi-line: body present"   "fakekey"         "${SSH_KEY:-}"
_assert_contains "multi-line: footer present" "FAKE-KEY-FOOTER" "${SSH_KEY:-}"
_assert "variable alongside multi-line" "plain" "${SIDE:-}"
unset SSH_KEY SIDE

# --- GITHUB_ENV output uses heredoc syntax ---
printf '%s\n' 'CI_SECRET=supersecret' > "$SECRETS_ENV"
rm -f "$SECRETS_AGE" "$GITHUB_ENV_FILE"
AGE_PUBLIC_KEY="$PUBLIC_KEY" \
    SECRETS_ENV="$SECRETS_ENV" \
    SECRETS_AGE="$SECRETS_AGE" \
    bash "$SCRIPT_DIR/secrets-encrypt.sh"

GITHUB_ENV="$GITHUB_ENV_FILE" \
    SECRETS_AGE_KEY="$PRIVATE_KEY" \
    SECRETS_AGE="$SECRETS_AGE" \
    bash "$SCRIPT_DIR/secrets-decrypt.sh"

_assert_contains "GITHUB_ENV contains key"   "CI_SECRET"   "$(cat "$GITHUB_ENV_FILE")"
_assert_contains "GITHUB_ENV contains value" "supersecret" "$(cat "$GITHUB_ENV_FILE")"

# --- missing secrets.age exits non-zero with a helpful message ---
ERR=$(SECRETS_AGE="$WORKDIR/nonexistent.age" \
    SECRETS_AGE_KEY="$PRIVATE_KEY" \
    bash "$SCRIPT_DIR/secrets-decrypt.sh" 2>&1) && GOT=0 || GOT=$?
_assert "missing secrets.age: exits non-zero" "1" "$GOT"
_assert_contains "missing secrets.age: error mentions file" "secrets.age" "$ERR"

# --- missing key exits non-zero ---
ERR=$(SECRETS_AGE="$SECRETS_AGE" \
    bash "$SCRIPT_DIR/secrets-decrypt.sh" 2>&1) && GOT=0 || GOT=$?
_assert "missing key: exits non-zero" "1" "$GOT"

# --- wrong key fails decryption ---
OTHER_KEY="$WORKDIR/other.key"
age-keygen -o "$OTHER_KEY" 2>/dev/null
ERR=$(SECRETS_AGE_KEY=$(cat "$OTHER_KEY") \
    SECRETS_AGE="$SECRETS_AGE" \
    bash "$SCRIPT_DIR/secrets-decrypt.sh" 2>&1) && GOT=0 || GOT=$?
_assert "wrong key: exits non-zero" "1" "$GOT"

# --- encrypt without secrets.env exits non-zero ---
ERR=$(AGE_PUBLIC_KEY="$PUBLIC_KEY" \
    SECRETS_ENV="$WORKDIR/missing_secrets.env" \
    SECRETS_AGE="$WORKDIR/out.age" \
    bash "$SCRIPT_DIR/secrets-encrypt.sh" 2>&1) && GOT=0 || GOT=$?
_assert "encrypt without secrets.env: exits non-zero" "1" "$GOT"
_assert_contains "encrypt without secrets.env: error mentions file" "secrets.env" "$ERR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
