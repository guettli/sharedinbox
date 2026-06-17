# Source: https://codeberg.org/guettli/sharedinbox/src/branch/main/.forgejo/Dockerfile
# Install at on the act-runner host on: /etc/forgejo/runner/Dockerfile
#
# In systemd service:
#    ExecStartPre=docker build -t forgejo-act-runner:latest /etc/forgejo/runner
#    ExecStart=/usr/local/bin/forgejo-runner daemon --config /etc/forgejo/config.yml

FROM ghcr.io/catthehacker/ubuntu:go-24.04

# Infrastructure tools required by CI workflows
RUN apt-get update && apt-get install -y --no-install-recommends \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Pre-set init.defaultBranch so actions/checkout's initial `git init` does not
# emit the 13-line "Using 'master' as the name for the initial branch" hint
# on every workflow run.
RUN git config --global init.defaultBranch main

# SOPS
RUN curl -fsSL -o /usr/local/bin/sops https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64 \
    && chmod +x /usr/local/bin/sops

# Dagger CLI — pinned to match the engine version on the runner host
RUN curl -fsSL https://dl.dagger.io/dagger/install.sh \
    | DAGGER_VERSION=0.21.6 BIN_DIR=/usr/local/bin sh

# Task runner
RUN curl -fsSL https://taskfile.dev/install.sh \
    | sh -s -- -b /usr/local/bin v3.48.0
