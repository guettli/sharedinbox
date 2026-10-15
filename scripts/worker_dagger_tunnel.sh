#!/usr/bin/env bash
# Open a background SSH tunnel from this agentloop worker to the remote Dagger
# engine on tc, so `dagger call` (task test-backend / analyze / … and the Gmail
# probe) runs on tc instead of this memory-constrained worker node. Flutter/Dart
# are not installed here — everything Dagger-shaped goes over this tunnel.
#
# Reads DAGGER_ENGINE_HOST + DAGGER_SSH_KEY from the environment, injected by the
# repo-scoped Secret `agentloop-repo-sharedinbox-secrets` (agentloop #1082/#1085).
# `_EXPERIMENTAL_DAGGER_RUNNER_HOST=tcp://127.0.0.1:8080` is baked into the image
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
if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then
    exec 3>&- 3<&-
    if timeout 15 dagger core --help >/dev/null 2>&1; then
        echo "dagger tunnel already up and engine reachable on 127.0.0.1:${PORT}"
        exit 0
    fi
    echo "127.0.0.1:${PORT} is listening but the engine did not answer — rebuilding the tunnel." >&2
fi

# Past the healthy early-exit above: we are going to (re)build the tunnel. Stop
# any prior watchdog FIRST, before the teardown/establish below, so its 10s tick
# cannot re-bind 127.0.0.1:${PORT} underneath us and make the `ssh -f` establish
# fail ExitOnForwardFailure (which, under set -e, would abort this script with a
# spurious error even though the tunnel is actually up). The healthy re-run
# exited 0 above and never reaches here, so a working watchdog is left alone.
# Then clear any existing forward (a stale one, or one the old watchdog spawned)
# so the fresh establish can bind the port.
pkill -f dagger-worker-tunnel-watchdog 2>/dev/null || true
pkill -f "ssh.*-L 127.0.0.1:${PORT}:/run/dagger/engine.sock" 2>/dev/null || true
sleep 1

: "${DAGGER_ENGINE_HOST:?not set — expected from the agentloop-repo-sharedinbox-secrets Secret}"
: "${DAGGER_SSH_KEY:?not set — expected from the agentloop-repo-sharedinbox-secrets Secret}"

mkdir -p ~/.ssh
chmod 700 ~/.ssh
umask 077
printf '%s\n' "$DAGGER_SSH_KEY" > ~/.ssh/dagger_key
chmod 600 ~/.ssh/dagger_key

echo "Opening SSH tunnel to dagger@${DAGGER_ENGINE_HOST} (127.0.0.1:${PORT} -> /run/dagger/engine.sock)…"
# StrictHostKeyChecking=no is acceptable: the engine host is only reachable over
# the private WireGuard net. -f -N detaches a persistent forward-only tunnel.
# ConnectTimeout bounds the TCP/auth handshake. ServerAliveInterval/CountMax only
# govern an *already-established* connection, so without ConnectTimeout an
# unreachable engine host (WireGuard down, host rebooting, node saturated) leaves
# ssh in connect-retry until the kernel gives up — ~2min, i.e. the whole
# agentloop preflight budget, killed with only a bare "timed out" and no cause
# (issue #1002). Bound it so a blip fails fast with a diagnostic instead.
ssh_rc=0
ssh -i ~/.ssh/dagger_key \
    -o ConnectTimeout=15 \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 \
    -o ServerAliveCountMax=3 \
    -f -N -L "127.0.0.1:${PORT}:/run/dagger/engine.sock" "dagger@${DAGGER_ENGINE_HOST}" || ssh_rc=$?
if [ "$ssh_rc" -ne 0 ]; then
    echo "ERROR: could not open the SSH tunnel to dagger@${DAGGER_ENGINE_HOST} within ConnectTimeout (ssh exit ${ssh_rc})." >&2
    echo "       The engine host did not complete the handshake in time. Likely cause:" >&2
    echo "       the WireGuard net is down, the engine host is rebooting, or its node is" >&2
    echo "       saturated — not a problem with this repo. Verify DAGGER_ENGINE_HOST is" >&2
    echo "       reachable and sshd on the engine is up, then re-run this script." >&2
    exit 1
fi

# Verify the CLI can actually reach the engine over the tunnel (also catches a
# CLI/engine version mismatch, which looks like an unreachable engine).
if timeout 15 dagger core --help >/dev/null 2>&1; then
    echo "dagger engine reachable via tunnel (CLI $(dagger version 2>/dev/null | grep -oE 'v[0-9.]+' | head -1))."
else
    echo "WARNING: tunnel is up but 'dagger core' did not answer within 15s — the engine is" >&2
    echo "         not responding, or the CLI and engine versions differ (they must match," >&2
    echo "         see DAGGER.md). Left unbounded this check could itself hang out the" >&2
    echo "         preflight clock (issue #1002)." >&2
    exit 1
fi

# Keep the tunnel alive for the life of the Pod (same fix CI got in
# sharedinbox#1045 / gitops#686). The `ssh -f` above is one-shot: if the engine
# host (tc, oversubscribed -- gitops#690) stalls past ServerAliveInterval ×
# ServerAliveCountMax (~45s), ssh exits, 127.0.0.1:${PORT} disappears, and the
# agent's next dagger/task hangs on a dead socket for dagger's full ~10-min
# connect timeout -- until someone re-runs this script. The watchdog
# re-establishes the forward whenever the port stops listening, so a transient
# stall self-heals and dagger's own retry reconnects.
#
# Exactly one watchdog. A *healthy* re-run of this script exits 0 at the probe
# near the top and never reaches here, leaving the running watchdog untouched.
# Any non-healthy path already killed the prior watchdog before the establish
# above, so none is running now. restartPolicy=Never worker Pods are torn down
# after the session, which reaps this one -- no cross-session leak. The marker
# in the body is what that earlier `pkill -f` matches (it is in the child's
# argv, not this script's, whose argv is just the path).
export PORT DAGGER_ENGINE_HOST
nohup bash -c '
  # dagger-worker-tunnel-watchdog
  while true; do
    sleep 10
    if (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null; then
      exec 3>&- 3<&- 2>/dev/null || true
      continue
    fi
    echo "[dagger-worker-tunnel-watchdog] 127.0.0.1:$PORT not listening, re-establishing tunnel" >&2
    timeout 30 ssh -i ~/.ssh/dagger_key -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o BatchMode=yes \
      -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
      -f -N -L "127.0.0.1:$PORT:/run/dagger/engine.sock" "dagger@$DAGGER_ENGINE_HOST" \
      2>&1 | sed "s/^/[dagger-worker-tunnel-watchdog] /" >&2 || true
  done
' >~/.dagger-worker-tunnel-watchdog.log 2>&1 &
disown
echo "Dagger tunnel watchdog started (pid $!, log ~/.dagger-worker-tunnel-watchdog.log)."
