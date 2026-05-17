#!/usr/bin/env bash
# Establishes a secure tunnel to a remote Dagger Engine via stunnel.
# Probes ports 8774 and 8775 to find the active server.
set -euo pipefail

SERVER_IP="${DAGGER_SERVER_IP:-${SSH_HOST:-}}"
if [ -z "$SERVER_IP" ]; then
    echo "Error: DAGGER_SERVER_IP or SSH_HOST must be set."
    exit 1
fi

# 1. Probe for active port
REMOTE_PORT=""
for port in 8774 8775; do
    echo "Probing $SERVER_IP:$port..."
    if nc -zw 3 "$SERVER_IP" "$port" 2>/dev/null; then
        echo "Found active Dagger server on $SERVER_IP:$port"
        REMOTE_PORT="$port"
        break
    fi
done

if [ -z "$REMOTE_PORT" ]; then
    echo "Error: No Dagger server responded on $SERVER_IP:8774 or 8775"
    # Fallback: If no remote server is found, we could just let Dagger start a local engine,
    # but the user specifically wants the shared server. For now, we fail to be explicit.
    exit 1
fi

# 2. Setup TLS credentials (passed as env vars from secrets)
mkdir -p /tmp/dagger-tls
echo "$DAGGER_CA_CERT" > /tmp/dagger-tls/ca.crt
echo "$DAGGER_CLIENT_CERT" > /tmp/dagger-tls/client.crt
echo "$DAGGER_CLIENT_KEY" > /tmp/dagger-tls/client.key
chmod 600 /tmp/dagger-tls/client.key

# 3. Configure and start stunnel
# We use a temp config file
STUNNEL_CONF="/tmp/stunnel-dagger.conf"
cat << EOF > "$STUNNEL_CONF"
client = yes
foreground = yes
pid = /tmp/stunnel.pid

[dagger]
accept = 127.0.0.1:1774
connect = $SERVER_IP:$REMOTE_PORT
CAfile = /tmp/dagger-tls/ca.crt
cert = /tmp/dagger-tls/client.crt
key = /tmp/dagger-tls/client.key
verifyChain = yes
EOF

# Start stunnel in the background
# We assume 'stunnel' is in the PATH (provided by Nix)
stunnel "$STUNNEL_CONF" &
TUNNEL_PID=$!

# Give it a moment to establish
sleep 2

if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo "Error: stunnel failed to start"
    exit 1
fi

# 4. Export environment for subsequent CI steps
if [ -n "${GITHUB_ENV:-}" ]; then
    echo "_EXPERIMENTAL_DAGGER_RUNNER_HOST=tcp://127.0.0.1:1774" >> "$GITHUB_ENV"
    echo "_DAGGER_RUNNER_HOST=tcp://127.0.0.1:1774" >> "$GITHUB_ENV"
    echo "Tunnel established. Dagger is configured to use the remote engine."
else
    export _EXPERIMENTAL_DAGGER_RUNNER_HOST=tcp://127.0.0.1:1774
    export _DAGGER_RUNNER_HOST=tcp://127.0.0.1:1774
    echo "Tunnel established. Run: export _DAGGER_RUNNER_HOST=tcp://127.0.0.1:1774"
fi
