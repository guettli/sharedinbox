# Dockerfile for a Codeberg Runner with Nix and a non-root worker
FROM gitea/act_runner:latest-ubuntu

# Install Nix requirements and basic tools
RUN apt-get update && apt-get install -y curl xz-utils sudo && rm -rf /var/lib/apt/lists/*

# Install Nix in single-user mode
RUN curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install linux \
    --init none \
    --no-confirm

ENV PATH="/nix/var/nix/profiles/default/bin:${PATH}"
RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf

# Create a restricted 'worker' user for running the actual CI jobs
RUN useradd -m -s /bin/bash worker && \
    mkdir -p /home/worker && \
    chown -R worker:worker /home/worker

# Allow the worker user to use Nix
RUN chown -R worker:worker /nix/var/nix/profiles/per-user/worker || true && \
    chmod -R 777 /nix/store /nix/var/nix/db

# We still start as root so the act_runner entrypoint can initialize,
# but the 'act_runner' is configured to run jobs as a specific user if requested.
# However, by default, act_runner executes inside this container.
