# SharedInbox CI Runner

Installed like explained here:

https://forgejo.org/docs/next/admin/actions/installation/binary/

## Connecting to Dagger (via stunnel)

Dagger is running on the host machine and exported via stunnel on port 8774. The runner connects to it using a local stunnel client.

The following TLS secrets must be configured as environment variables in Codeberg:
- `DAGGER_CLIENT_CERT`: Content of `client.crt`
- `DAGGER_CLIENT_KEY`: Content of `client.key`
- `DAGGER_CA_CERT`: Content of `ca.crt`

### Setup Script

This snippet can be used in a CI job to establish the connection:

```bash
# Write TLS files from environment variables
mkdir -p /etc/dagger/tls
echo "$DAGGER_CLIENT_CERT" > /etc/dagger/tls/client.crt
echo "$DAGGER_CLIENT_KEY" > /etc/dagger/tls/client.key
echo "$DAGGER_CA_CERT" > /etc/dagger/tls/ca.crt

# Create stunnel configuration
cat > /tmp/dagger-client.conf << EOF
foreground = yes
pid =

[dagger]
client  = yes
accept  = 127.0.0.1:1774
connect = <server-ip>:8774
cert    = /etc/dagger/tls/client.crt
key     = /etc/dagger/tls/client.key
CAfile  = /etc/dagger/tls/ca.crt
verify  = 2
EOF

# Start stunnel in the background
stunnel /tmp/dagger-client.conf &

# Configure Dagger to use the tunnel
export _EXPERIMENTAL_DAGGER_RUNNER_HOST=tcp://127.0.0.1:1774
dagger version
```

Note: Replace `<server-ip>` with the actual IP address of the machine running Dagger.
