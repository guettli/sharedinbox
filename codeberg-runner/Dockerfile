# Dockerfile for a Codeberg Runner with Nix installed
FROM gitea/act_runner:latest

# Install Nix requirements and basic tools
RUN apt-get update && apt-get install -y curl xz-utils sudo && rm -rf /var/lib/apt/lists/*

# Install Nix in single-user mode (suitable for container)
# We use the Determinate Systems installer for reliability
RUN curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install linux \
    --init none \
    --no-confirm

# Add Nix to PATH
ENV PATH="/nix/var/nix/profiles/default/bin:${PATH}"
ENV NIX_PATH="nixpkgs=channel:nixos-unstable"

# Ensure the runner user can use Nix
RUN echo "experimental-features = nix-command flakes" >> /etc/nix/nix.conf
