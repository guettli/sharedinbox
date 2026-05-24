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

MAX_PROBE_ATTEMPTS=5
PROBE_DELAY=30
for attempt in $(seq 1 $MAX_PROBE_ATTEMPTS); do
    echo "Probing $host:$port (attempt $attempt/$MAX_PROBE_ATTEMPTS)..."
    if nc -zw 5 "$host" "$port" 2>/dev/null; then
        echo "Found active server on $host:$port"
        break
    fi
    if [ "$attempt" -eq "$MAX_PROBE_ATTEMPTS" ]; then
        echo "Warning: No Dagger server responded on $host:$port after $MAX_PROBE_ATTEMPTS attempts"
        echo "Remote engine unavailable — CI will use the local Dagger engine."
        exit 0
    fi
    echo "Dagger server not responding, waiting ${PROBE_DELAY}s before retry..."
    sleep $PROBE_DELAY
done

# 2a. Try plain TCP connection first (works when server is a plain TCP proxy, no TLS)
echo "Trying plain TCP Dagger connection at tcp://$host:$port..."
if _DAGGER_RUNNER_HOST="tcp://$host:$port" \
   _EXPERIMENTAL_DAGGER_RUNNER_HOST="tcp://$host:$port" \
   timeout 8 dagger version >/dev/null 2>&1; then
    echo "Plain TCP Dagger connection succeeded — no TLS stunnel needed."
    if [ -n "${GITHUB_ENV:-}" ]; then
        echo "_EXPERIMENTAL_DAGGER_RUNNER_HOST=tcp://$host:$port" >> "$GITHUB_ENV"
        echo "_DAGGER_RUNNER_HOST=tcp://$host:$port" >> "$GITHUB_ENV"
    else
        export _EXPERIMENTAL_DAGGER_RUNNER_HOST="tcp://$host:$port"
        export _DAGGER_RUNNER_HOST="tcp://$host:$port"
        echo "Dagger configured at tcp://$host:$port (plain TCP)"
    fi
    exit 0
fi
echo "Plain TCP connection not available; trying TLS stunnel..."

# 2b. Setup TLS credentials (passed as env vars from secrets)
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
debug = warning
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
