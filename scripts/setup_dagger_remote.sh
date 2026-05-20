#!/usr/bin/env bash
# Establishes a secure tunnel to a remote Dagger Engine via stunnel.
set -euo pipefail

if [ -z "${DAGGER_STUNNEL_URL:-}" ]; then
    echo "Error: DAGGER_STUNNEL_URL must be set."
    exit 1
fi

# Parse host and port (e.g., example.com:8774 or just example.com)
host=$(echo "$DAGGER_STUNNEL_URL" | cut -d: -f1)
port=$(echo "$DAGGER_STUNNEL_URL" | cut -d: -f2)
if [ "$host" == "$port" ]; then
    port="8774"
fi

echo "Probing $host:$port..."
if ! nc -zw 3 "$host" "$port" 2>/dev/null; then
    echo "Error: No Dagger server responded on $host:$port"
    exit 1
fi
echo "Found active Dagger server on $host:$port"

# 2. Setup TLS credentials (passed as env vars from secrets)
mkdir -p /tmp/dagger-tls
echo "$DAGGER_CA_CERT" > /tmp/dagger-tls/ca.crt
echo "$DAGGER_CLIENT_CERT" > /tmp/dagger-tls/client.crt
echo "$DAGGER_CLIENT_KEY" > /tmp/dagger-tls/client.key
chmod 600 /tmp/dagger-tls/client.key

# 3. Configure and start stunnel
STUNNEL_CONF="/tmp/stunnel-dagger.conf"
cat << EOF > "$STUNNEL_CONF"
client = yes
foreground = yes
pid = /tmp/stunnel.pid
; TCP keepalive on the remote side to prevent NAT/firewall from resetting the connection
socket = r:SO_KEEPALIVE=1
socket = r:TCP_KEEPIDLE=10
socket = r:TCP_KEEPINTVL=5
socket = r:TCP_KEEPCNT=3

[dagger]
accept = 127.0.0.1:1774
connect = $host:$port
CAfile = /tmp/dagger-tls/ca.crt
cert = /tmp/dagger-tls/client.crt
key = /tmp/dagger-tls/client.key
verifyChain = yes
EOF

# Start stunnel in the background
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
