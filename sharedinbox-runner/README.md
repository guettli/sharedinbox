# SharedInbox CI Runner

This directory contains the configuration for a self-hosted Codeberg (Forgejo) Actions runner. 

## Strategy: "Thin CI, Heavy Taskfile"
We use a self-hosted runner to bypass the resource limits of hosted CI. The CI workflow is a thin wrapper that invokes `nix develop --command task check`. This ensures that CI environments are identical to local development environments.

## Prerequisites
- Docker and Docker Compose installed.
- Systemd (for persistence).
- A registration token from Codeberg (Settings > Actions > Runners).
- A `.env` file in the project root containing `CODEBERG_CI_RUNNER_TOKEN`.

## Installation & Setup

Run these commands as a user with `sudo` to install the runner on your laptop or VPS:

```bash
# 1. Create the system directory
sudo mkdir -p /opt/sharedinbox-runner

# 2. Copy the runner configuration and your .env file
# (Run this from the root of your local sharedinbox3 project)
sudo cp -r sharedinbox-runner /opt/sharedinbox-runner/
sudo cp .env /opt/sharedinbox-runner/

# 3. Install the systemd service
sudo cp /opt/sharedinbox-runner/sharedinbox-runner/sharedinbox-runner.service /etc/systemd/system/

# 4. Reload systemd and start the service
sudo systemctl daemon-reload
sudo systemctl enable --now sharedinbox-runner.service
```

## Management
- **Check status:** `systemctl status sharedinbox-runner.service`
- **View logs:** `journalctl -u sharedinbox-runner.service -f`
- **Restart:** `sudo systemctl restart sharedinbox-runner.service`
- **Stop:** `sudo systemctl stop sharedinbox-runner.service`
