# Source: https://codeberg.org/guettli/sharedinbox/src/branch/main/.forgejo/Dockerfile
# Install at on the act-runner host on: /etc/forgejo/runner/Dockerfile
#
# In systemd service:
#    ExecStartPre=docker build -t forgejo-act-runner:latest /etc/forgejo/runner
#    ExecStart=/usr/local/bin/forgejo-runner daemon --config /etc/forgejo/config.yml
FROM ghcr.io/catthehacker/ubuntu:go-24.04

# Infrastructure tools required by CI workflows
RUN apt-get update && apt-get install -y --no-install-recommends \
    stunnel4 \
    netcat-openbsd \
    age \
    && rm -rf /var/lib/apt/lists/*

# Dagger CLI — pinned to match the engine version on the runner host
RUN curl -fsSL https://dl.dagger.io/dagger/install.sh \
    | DAGGER_VERSION=0.20.8 BIN_DIR=/usr/local/bin sh

# Task runner
RUN curl -fsSL https://taskfile.dev/install.sh \
    | sh -s -- -b /usr/local/bin v3.48.0
