#!/usr/bin/env bash
# Open a background SSH tunnel from this agentloop worker to the remote Dagger
# engine on tc, so `dagger call` (task test-backend / analyze / … and the Gmail
# probe) runs on tc instead of this memory-constrained worker node. Flutter/Dart
# are not installed here — everything Dagger-shaped goes over this tunnel.
#
# Reads DAGGER_ENGINE_HOST + DAGGER_SSH_KEY from the environment, injected by the
# repo-scoped Secret `agentloop-repo-sharedinbox-secrets` (agentloop #1082/#1085).
# `_EXPERIMENTAL_DAGGER_RUNNER_HOST=tcp://localhost:8080` is baked into the image
# ENV, so once this tunnel is up every shell's `dagger`/`task` uses it.
#
# Idempotent: a no-op if the tunnel is already up. The tunnel is a detached
# background ssh, so it persists across the agent's separate shells for the life
# of the Pod — run this ONCE per session before the first dagger/task command.
#
# This is deliberately NOT scripts/setup_dagger_remote.sh: that one is for CI,
# decrypts secrets.enc.yaml with SOPS and speaks GitHub-Actions (::add-mask::,
# $GITHUB_ENV). The worker must never hold SOPS_AGE_KEY, and gets the two creds
# it needs straight from the Secret above.
set -euo pipefail

PORT=8080

# Already up? A stale forward-to-nowhere keeps the local port LISTENing after
# the far end dies (laptop suspend / network change), so a plain /dev/tcp probe
# reports a dead tunnel as healthy (issue #694). Probe the engine itself: if it
# answers, we are done; if the port is up but the engine does not, tear the
# stale tunnel down so the fresh one below can bind the port.
if (exec 3<>"/dev/tcp/localhost/${PORT}") 2>/dev/null; then
    exec 3>&- 3<&-
    if timeout 15 dagger core --help >/dev/null 2>&1; then
        echo "dagger tunnel already up and engine reachable on localhost:${PORT}"
        exit 0
    fi
    echo "localhost:${PORT} is listening but the engine did not answer — tearing down the stale tunnel." >&2
    pkill -f "ssh.*-L ${PORT}:/run/dagger/engine.sock" 2>/dev/null || true
    sleep 1
fi

: "${DAGGER_ENGINE_HOST:?not set — expected from the agentloop-repo-sharedinbox-secrets Secret}"
: "${DAGGER_SSH_KEY:?not set — expected from the agentloop-repo-sharedinbox-secrets Secret}"

mkdir -p ~/.ssh
chmod 700 ~/.ssh
umask 077
printf '%s\n' "$DAGGER_SSH_KEY" > ~/.ssh/dagger_key
chmod 600 ~/.ssh/dagger_key

echo "Opening SSH tunnel to dagger@${DAGGER_ENGINE_HOST} (localhost:${PORT} -> /run/dagger/engine.sock)…"
# StrictHostKeyChecking=no is acceptable: the engine host is only reachable over
# the private WireGuard net. -f -N detaches a persistent forward-only tunnel.
ssh -i ~/.ssh/dagger_key \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -f -N -L "${PORT}:/run/dagger/engine.sock" "dagger@${DAGGER_ENGINE_HOST}"

# Verify the CLI can actually reach the engine over the tunnel (also catches a
# CLI/engine version mismatch, which looks like an unreachable engine).
if dagger core --help >/dev/null 2>&1; then
    echo "dagger engine reachable via tunnel (CLI $(dagger version 2>/dev/null | grep -oE 'v[0-9.]+' | head -1))."
else
    echo "WARNING: tunnel is up but 'dagger core' failed — likely a CLI/engine version mismatch (both must be the same, see DAGGER.md)." >&2
    exit 1
fi
