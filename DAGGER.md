# Dagger CI/CD Setup

This project has migrated from Taskfile-based CI to **Dagger**. This document explains the infrastructure setup for the shared Dagger Server.

## Architecture

We use a **Shared Dagger Server** approach for both local development and CI. This allows multiple users to share a single Dagger Engine and its cache, significantly speeding up builds.

- **Container Engine:** Rootless Podman (managed by the `dagger-svc` user).
- **Orchestration:** System-wide `systemd` service.
- **Access:** Users connect via TCP (localhost) or Unix Socket.

## Server Setup (Admin)

### 1. Dedicated Service User
A dedicated user `dagger-svc` owns the Dagger Engine and its cache.

```bash
sudo useradd -m -s /bin/bash dagger-svc
sudo loginctl enable-linger dagger-svc
```

**Why Lingering?**
Lingering is required for rootless users to maintain a persistent background session. It ensures that `/run/user/<UID>` and the user-level Dagger/Podman namespaces are initialized at boot and remain active even when the user is not logged in.

### 2. Systemd Service
The engine is managed by a system-wide systemd service located at `/etc/systemd/system/dagger-engine.service`.

```ini
[Unit]
Description=Dagger Engine (Shared Server)
After=network.target

[Service]
Type=simple
User=dagger-svc
Group=dagger-svc
WorkingDirectory=/home/dagger-svc
# Replace 1003 with the actual UID of dagger-svc
Environment=DOCKER_HOST=unix:///run/user/1003/podman/podman.sock
Environment=XDG_RUNTIME_DIR=/run/user/1003
ExecStart=/usr/bin/nix run github:dagger/nix/v0.11.4#dagger -- engine --addr tcp://0.0.0.0:8080
Restart=always

[Install]
WantedBy=multi-user.target
```

## Client Configuration

To connect to the shared engine, users should set the `_DAGGER_RUNNER_HOST` environment variable.

### Local Development (.env)
The project uses a `.env` file to manage the connection string. Ensure your `.env` contains:

```bash
_DAGGER_RUNNER_HOST=tcp://127.0.0.1:8080
```

### Usage
Once the environment is set up, you can run the Dagger pipeline. For non-interactive environments (CI, LLMs), use `--progress=plain` for readable logs:

```bash
nix develop --command dagger call --progress=plain -q -m ci --source=. check
```

## CI Integration (Codeberg/Forgejo)

The CI workflow in `.forgejo/workflows/ci.yml` is configured to use the Dagger module located in the `ci/` directory.

- **Check Suite:** Runs analysis and tests in parallel.
- **Builds:** Produces Linux and Android artifacts.
- **Caching:** When using the shared engine, CI runners benefit from the persistent cache on the host.
