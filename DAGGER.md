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
ExecStart=/usr/bin/nix run github:dagger/nix/v0.20.8#dagger -- engine --addr tcp://0.0.0.0:8080
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

## Secrets

All sensitive credentials are passed as `dagger.Secret` (never as plain strings).
This prevents values from appearing in Dagger logs or being cached in the engine.

| Parameter | Functions |
|---|---|
| `sshKey *dagger.Secret` | `Deployer`, `GenerateBuildHistory`, `BuildWebsite`, `PublishWebsite`, `DeployLinux`, `DeployApk` |
| `keystoreBase64 *dagger.Secret` | `setupKeystore`, `BuildAndroidApk`, `DeployApk`, `SignAndroidBundle`, `PublishAndroid` |
| `keystorePassword *dagger.Secret` | same as above |
| `playStoreConfig *dagger.Secret` | `UploadToPlayStore`, `PublishAndroid` |
| `serviceAccountKey *dagger.Secret` | `TestAndroidFirebase` |

Secrets are injected via `WithMountedSecret` (file-based, e.g. SSH key) or
`WithSecretVariable` (env-var-based, e.g. keystore data, Play Store JSON).

The only credentials not typed as `dagger.Secret` are the test passwords
(`STALWART_PASS_B`, `STALWART_PASS_C`) in `WithStalwart`. These are hardcoded
development values defined in `stalwart-dev/` — not production secrets.

## CI Integration (Codeberg/Forgejo)

The CI workflow in `.forgejo/workflows/ci.yml` is configured to use the Dagger module located in the `ci/` directory.

- **Check Suite:** Runs analysis and tests in parallel.
- **Builds:** Produces Linux and Android artifacts.
- **Caching:** When using the shared engine, CI runners benefit from the persistent cache on the host.

## Credential Security — Keeping Production Secrets Off Codeberg

### Problem

The current setup stores two categories of secrets in Codeberg repository secrets:

1. **Dagger access credentials** — TLS certificates used to connect to the remote Dagger engine via stunnel (`DAGGER_CA_CERT`, `DAGGER_CLIENT_CERT`, `DAGGER_CLIENT_KEY`, `DAGGER_STUNNEL_URL`).
2. **Production secrets** — actual credentials for external services: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `PLAY_STORE_CONFIG_JSON`, `SSH_PRIVATE_KEY`, `FIREBASE_TEST_LAB_SERVICE_ACCOUNT_KEY`.

If Codeberg is compromised, both categories are leaked. The Dagger TLS certificates enable access only to the Dagger engine and have limited blast radius. But the production secrets give direct access to the Play Store, the Android signing key, the deployment server, and Firebase — a much larger blast radius.

**Goal:** Keep only Dagger access credentials in Codeberg. Store all production secrets on the Dagger host machine so they never touch Codeberg.

### Option 1: Runner-level environment variables

Store production secrets as environment variables in the Forgejo runner's systemd service (e.g., via a `EnvironmentFile=` in the service override). The runner injects host env vars into job processes automatically. CI workflows drop the `${{ secrets.XYZ }}` references for production secrets entirely — the variables are already present in the job environment.

**Pro:**
- No new infrastructure required.
- Works with the existing `dagger call --progress=plain --secret env:VAR_NAME` argument style.
- Secrets never enter Codeberg.
- Straightforward to set up on a single self-hosted runner.

**Con:**
- Env vars are visible to every process on the runner host (e.g., via `/proc/<pid>/environ`).
- Rotating a secret requires host access (no API).
- Does not scale cleanly to multiple runners without a shared secrets mechanism.

### Option 2: Secret files on the CI host with restricted permissions

Store production secrets as files owned by the runner user with mode `600` (e.g., `/home/forgejo-runner/secrets/play_store.json`). A small setup script reads the files and either exports them as env vars or passes them directly as file-type arguments to `dagger call --progress=plain`. CI workflows contain no secret references at all.

**Pro:**
- OS-level file permissions limit access to the runner user.
- Natural format for JSON payloads and key files.
- Easy to audit (list files, check mtime).
- No new infrastructure.

**Con:**
- Plaintext files on disk; root or backup access exposes them.
- Workflow must know file paths (either hardcoded or by convention).
- Rotation still requires host filesystem access.

### Option 3: Dagger host as pipeline orchestrator

Instead of the CI runner invoking the Dagger CLI directly, the CI job sends a trigger to the Dagger host over SSH. The Dagger host runs the pipeline locally against its own environment, where secrets live as env vars or files. Codeberg only stores the SSH key to reach the Dagger host — not the production secrets.

```yaml
# CI job only does this:
- name: Trigger pipeline on Dagger host
  run: ssh dagger-host "cd sharedinbox && task publish-android"
  env:
    SSH_PRIVATE_KEY: ${{ secrets.DAGGER_TRIGGER_SSH_KEY }}
```

**Pro:**
- Production secrets never leave the Dagger host.
- Codeberg stores exactly one secret: the trigger SSH key.
- All deployment logic and secrets are fully contained on the host.

**Con:**
- Harder to stream structured CI logs back to Codeberg Actions.
- Dynamic context (commit SHA, PR branch) must be passed explicitly over SSH.
- The trigger SSH key still grants shell access to the host, so its compromise has its own blast radius.
- CI becomes a "fire-and-forget" call, making failure attribution harder.

### Option 4: External secret manager (e.g., HashiCorp Vault)

Run a secret manager co-located with the Dagger host. The CI job authenticates with a short-lived AppRole credential (stored in Codeberg) and retrieves secrets at runtime. Vault can also be configured with IP-allow-lists to further restrict who can authenticate.

**Pro:**
- Full audit trail: every secret read is logged with a timestamp and caller identity.
- Fine-grained access control per secret.
- Built-in versioning and rotation support.
- Industry-standard approach; scales to team or multi-runner setups.

**Con:**
- Significant additional infrastructure to install, configure, and maintain.
- Vault credentials (RoleID + SecretID) still need to be in Codeberg, though with a smaller blast radius than raw secrets.
- Vault itself becomes a security-critical single point of failure.
- Operational overhead likely disproportionate for a small single-developer project.

### Recommendation

**Option 1** (runner-level env vars) or **Option 2** (secret files) are the pragmatic starting point for a single self-hosted runner. They require no new infrastructure and move all production secrets off Codeberg immediately.

**Option 3** (Dagger host as orchestrator) is worth considering once the trigger SSH key replaces all other secrets in Codeberg — it offers the cleanest security boundary at the cost of reduced CI observability.

**Option 4** (Vault) becomes worthwhile if the project grows to multiple runners or team members who each need audited access to deploy credentials.
