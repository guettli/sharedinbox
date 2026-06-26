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
trap 'rm -f "$SECRETS_JSON"' EXIT

sops --decrypt --output-type json secrets.enc.yaml > "$SECRETS_JSON"

DAGGER_SSH_KEY=$(jq -r '.DAGGER_SSH_KEY' "$SECRETS_JSON")
DAGGER_ENGINE_HOST=$(jq -r '.DAGGER_ENGINE_HOST' "$SECRETS_JSON")

# Register inline secrets for log redaction. Multiline values (e.g. SSH keys)
# must be masked line-by-line because ::add-mask:: covers one line at a time.
printf '::add-mask::%s\n' "$DAGGER_ENGINE_HOST"
while IFS= read -r line; do
    [ -n "$line" ] && printf '::add-mask::%s\n' "$line"
done <<< "$DAGGER_SSH_KEY"

# Export all CI secrets to the GitHub Actions environment so subsequent steps
# can use them without referencing the SOPS store directly.
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
export_secret "GITHUB_TOKEN"
export_secret "AGENTLOOP_OTEL_TOKEN"

# The Dagger remote engine lives on a private network reachable only from the
# self-hosted sharedinbox-arc runners. There is deliberately no github-hosted
# escape hatch: every workflow pins `runs-on: sharedinbox-arc`, so if this ever
# runs anywhere else the SSH tunnel below must fail loudly rather than silently
# fall back to a local engine. See guettli/otelhouse#33.

# Setup SSH directory and keys
mkdir -p ~/.ssh
chmod 700 ~/.ssh
rm -f ~/.ssh/dagger_key
echo "$DAGGER_SSH_KEY" > ~/.ssh/dagger_key
chmod 600 ~/.ssh/dagger_key

# Try to pre-populate known_hosts via ssh-keyscan. This is best-effort: the
# actual SSH tunnel below uses `-o StrictHostKeyChecking=no`, so a missing
# known_hosts entry is not blocking — ssh will accept the host key on first
# connection and append it to known_hosts itself. We still attempt ssh-keyscan
# (with retries and stderr capture) because populating known_hosts up front
# keeps the connection log tidy and makes later runs in the same job re-use the
# same pinned key. Previously this call silently aborted the whole script when
# the engine host refused a probe (rc=1, empty stderr) — see issue #171 and
# run 28249726890.
KEYSCAN_TIMEOUT_S="${DAGGER_KEYSCAN_TIMEOUT_S:-30}"
KEYSCAN_MAX_ATTEMPTS="${DAGGER_KEYSCAN_MAX_ATTEMPTS:-3}"
KEYSCAN_RETRY_WAIT_S="${DAGGER_KEYSCAN_RETRY_WAIT_S:-5}"
keyscan_out=$(mktemp)
keyscan_err=$(mktemp)
trap 'rm -f "$SECRETS_JSON" "$keyscan_out" "$keyscan_err"' EXIT
_t0=$SECONDS
keyscan_rc=0
for attempt in $(seq 1 "$KEYSCAN_MAX_ATTEMPTS"); do
    : > "$keyscan_out"
    : > "$keyscan_err"
    keyscan_rc=0
    timeout "$KEYSCAN_TIMEOUT_S" ssh-keyscan -H "$DAGGER_ENGINE_HOST" \
        >"$keyscan_out" 2>"$keyscan_err" || keyscan_rc=$?
    # ssh-keyscan can report rc=0 even when it produced no keys (e.g. host
    # reachable but refused the connection mid-handshake), so require both a
    # clean exit AND non-empty output before accepting the result.
    if [ "$keyscan_rc" -eq 0 ] && [ -s "$keyscan_out" ]; then
        break
    fi
    if [ "$attempt" -eq "$KEYSCAN_MAX_ATTEMPTS" ]; then
        break
    fi
    echo "::warning::ssh-keyscan attempt ${attempt}/${KEYSCAN_MAX_ATTEMPTS} failed for $DAGGER_ENGINE_HOST (rc=${keyscan_rc}); retrying in ${KEYSCAN_RETRY_WAIT_S}s..."
    sleep "$KEYSCAN_RETRY_WAIT_S"
done
if [ "$keyscan_rc" -eq 0 ] && [ -s "$keyscan_out" ]; then
    cat "$keyscan_out" >> ~/.ssh/known_hosts
    _elapsed=$(( SECONDS - _t0 ))
    if [ "$_elapsed" -gt 10 ]; then
        echo "::warning::ssh-keyscan took ${_elapsed}s — Dagger engine host may be slow to respond"
    fi
else
    # Don't abort: the ssh command below uses StrictHostKeyChecking=no and will
    # accept the host key on first connection. Surface the diagnostic so the
    # underlying probe failure stays visible if the tunnel itself also fails.
    echo "::warning::ssh-keyscan could not fetch a host key for $DAGGER_ENGINE_HOST after ${KEYSCAN_MAX_ATTEMPTS} attempts (rc=${keyscan_rc}); continuing — the SSH tunnel below uses StrictHostKeyChecking=no and will accept the host key on first connection."
    if [ -s "$keyscan_err" ]; then
        echo "--- ssh-keyscan stderr ---"
        cat "$keyscan_err"
    fi
fi

# Create a background SSH tunnel to the Dagger engine Unix socket.
# Forwards local TCP port 8080 directly to /run/dagger/engine.sock on the remote host,
# eliminating the need for a socat bridge on the server side.
echo "Establishing SSH tunnel to $DAGGER_ENGINE_HOST..."
_t0=$SECONDS
timeout 30 ssh -i ~/.ssh/dagger_key -o StrictHostKeyChecking=no -f -N -L 8080:/run/dagger/engine.sock "dagger@$DAGGER_ENGINE_HOST"
_elapsed=$(( SECONDS - _t0 ))
if [ "$_elapsed" -gt 10 ]; then
    echo "::warning::SSH tunnel setup took ${_elapsed}s"
fi

# Export _EXPERIMENTAL_DAGGER_RUNNER_HOST to use the tunnel.
export _EXPERIMENTAL_DAGGER_RUNNER_HOST="tcp://localhost:8080"
if [ -n "${GITHUB_ENV:-}" ]; then
    echo "_EXPERIMENTAL_DAGGER_RUNNER_HOST=tcp://localhost:8080" >> "$GITHUB_ENV"
fi

# Verify the connection AND that the runner's Dagger CLI matches the engine.
# The Dagger CLI and engine must run the exact same version. When they differ,
# the engine looks "unreachable" even though the SSH tunnel itself is healthy
# (it authenticated and the forward is up) — the failure is the CLI/engine
# protocol handshake, not the network. There is deliberately no fallback: a
# mismatch must fail the job loudly rather than silently degrade.
CLI_VERSION=$(dagger version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)
echo "Verifying connection to Dagger engine via SSH tunnel (runner CLI ${CLI_VERSION:-unknown})..."
# `dagger core` forces a real engine connection without a complex GraphQL query.
# Capture rc separately because an `if !` clause flips $? to 0 in its then-block,
# which would hide the timeout (124) vs mismatch distinction the retry depends on.
# The remote engine occasionally fails to answer in time due to a transient
# blip (engine restart, network, queue backlog); retry the verify before failing
# the job. Real CLI/engine version mismatches are consistent and won't recover
# from waiting, so we retry only on timeout (exit 124).
# Budget: 5 × 60s timeout + 4 × 15s wait ≈ 6 min — generous because the engine
# occasionally takes minutes to recover from a restart, and a re-run costs more.
VERIFY_TIMEOUT_S="${DAGGER_VERIFY_TIMEOUT_S:-60}"
VERIFY_MAX_ATTEMPTS="${DAGGER_VERIFY_MAX_ATTEMPTS:-5}"
VERIFY_RETRY_WAIT_S="${DAGGER_VERIFY_RETRY_WAIT_S:-15}"
verify_rc=0
verify_out=""
for attempt in $(seq 1 "$VERIFY_MAX_ATTEMPTS"); do
    verify_rc=0
    verify_out=$(timeout "$VERIFY_TIMEOUT_S" dagger core --help 2>&1) || verify_rc=$?
    if [ "$verify_rc" -eq 0 ]; then
        break
    fi
    if [ "$attempt" -eq "$VERIFY_MAX_ATTEMPTS" ] || [ "$verify_rc" -ne 124 ]; then
        break
    fi
    echo "::warning::Dagger verify attempt ${attempt}/${VERIFY_MAX_ATTEMPTS} timed out after ${VERIFY_TIMEOUT_S}s; retrying in ${VERIFY_RETRY_WAIT_S}s..."
    sleep "$VERIFY_RETRY_WAIT_S"
done
if [ "$verify_rc" -ne 0 ]; then
    # Dagger's handshake error usually names the engine version it found; surface
    # it so the mismatch is concrete (CLI X vs engine Y) instead of a guess.
    # `|| true` keeps the diagnostics below running even when verify_out is empty
    # (the engine-timeout case) — otherwise set -e + pipefail exits silently the
    # moment grep returns "no match" and the user sees nothing.
    ENGINE_VERSION=$(printf '%s' "$verify_out" \
        | grep -ioE 'engine[^0-9]*v?[0-9]+\.[0-9]+\.[0-9]+' \
        | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [ "$verify_rc" = 124 ] && [ -z "$ENGINE_VERSION" ]; then
        echo "::error::Dagger engine did not respond within ${VERIFY_TIMEOUT_S}s on ${VERIFY_MAX_ATTEMPTS} attempts via the SSH tunnel."
        echo "::error::The tunnel authenticated and the port forward is up, but"
        echo "::error::\`dagger core --help\` timed out before the engine replied."
        echo "::error::This usually means the engine is down or unreachable; check"
        echo "::error::the engine on the remote host (gitops:"
        echo "::error::ansible/p16/systemd/system/dagger-engine.service)."
    else
        echo "::error::Dagger CLI/engine version mismatch — the SSH tunnel authenticated"
        echo "::error::and the port forward is up, so this is NOT a network problem."
        echo "::error::  runner CLI    : ${CLI_VERSION:-unknown}   <- sharedinbox: arc-runner-image/Dockerfile (DAGGER_VERSION), republish the runner image"
        echo "::error::  remote engine : ${ENGINE_VERSION:-unreadable, see diagnostics}   <- gitops: ansible/p16/systemd/system/dagger-engine.service, then restart dagger-engine"
        echo "::error::FIX: set BOTH to the exact same version. They are lock-stepped; there is no fallback. See DAGGER.md."
    fi
    echo "--- diagnostics ---"
    echo "verify exit code: $verify_rc"
    if [ -n "$verify_out" ]; then
        printf '%s\n' "$verify_out" | tail -8
    else
        echo "(no output captured from \`dagger core --help\`)"
    fi
    ps aux | grep -F ssh | grep -v grep || true
    exit 1
fi
echo "Dagger connection verified successfully (CLI ${CLI_VERSION:-unknown})."
