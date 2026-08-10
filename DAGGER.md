# Dagger CI/CD Setup

This project has migrated from Taskfile-based CI to **Dagger**. This document
explains where the Dagger engine lives, how CI reaches it, and where secrets
come from.

## Architecture

CI and local development share a single **remote Dagger engine** running on a
dedicated host. Sharing one engine (and its cache) across jobs is what makes
builds fast; nothing runs a throwaway engine per job.

- **Engine:** a system-wide `dagger-engine` systemd unit reading its config
  from `/etc/dagger/engine.json`. It is **not** managed from this repo — the
  unit, its config, and the pinned engine version are provisioned by Ansible in
  the gitops repo (`ansible/p16.yml`). Treat that playbook as the source of
  truth; do not duplicate its content here.
- **Access:** clients reach the engine over an SSH tunnel to its Unix socket
  (`/run/dagger/engine.sock`) and point Dagger at it via
  `_EXPERIMENTAL_DAGGER_RUNNER_HOST`. See
  [`scripts/setup_dagger_remote.sh`](scripts/setup_dagger_remote.sh).

### Version pinning

The engine version is kept in lockstep with the two Dagger CLIs that talk to it
(the `sharedinbox-arc` runner image and the local dev container). The engine
runs `github:dagger/nix/v0.21.7#dagger` (pinned in `ansible/p16.yml`); the CLIs
are pinned in `arc-runner-image/Dockerfile` and `Dockerfile.dev`.
`scripts/check_dagger_versions.sh` enforces that all three agree — the CLI and
engine must be the exact same version, there is no fallback when they differ
(the tunnel authenticates but the protocol handshake fails). Bumping the engine
means bumping `ansible/p16.yml` in gitops and restarting `dagger-engine`.

The check has two modes:

| Mode | Who runs it | What it compares |
|---|---|---|
| *(no args)* | pre-commit, `task check-dagger-versions` | the in-repo pins against each other |
| `--engine` | CI, right after `setup_dagger_remote.sh` | the in-repo pins against the **running engine**, queried with `echo '{version}' \| dagger query` |

Static mode compares files to other files, so all pins can agree and CI can
still fail — the version that decides lives on the engine host, in another repo.
`--engine` closes that gap and refuses to run without a reachable engine rather
than quietly falling back to the weaker check.

The check runs **outside** the Dagger pipeline on purpose: a version mismatch is
what stops the pipeline from loading, so a check inside it can never report the
problem it exists to catch.

**`ci/dagger.json` is different from the three pins above.** Its `engineVersion`
is a compatibility *floor*, not a pin — Dagger rejects a module only when
`engineVersion` is **newer** than the running engine. It is therefore
deliberately excluded from Renovate (see `renovate.json`): raising it buys
nothing and can only break CI, which is what happened in #445. Raise it by hand
when the module genuinely needs a newer engine, after the engine has moved.

## CI path

Every workflow pins `runs-on: sharedinbox-arc`. Each job's first Dagger step is
[`scripts/setup_dagger_remote.sh`](scripts/setup_dagger_remote.sh), which opens
the SSH tunnel to the remote engine and exports
`_EXPERIMENTAL_DAGGER_RUNNER_HOST=tcp://localhost:8080` for the steps that
follow (see `.github/workflows/ci.yml`).

```
sharedinbox-arc runner → scripts/setup_dagger_remote.sh → remote dagger-engine
```

**A local engine inside the runner is not supported.** The runner executes in a
dind wedge where a co-located engine wedges too, which is the whole reason the
remote setup exists. The script fails loudly rather than falling back to a local
engine: if it ever runs somewhere without a route to the engine host, the tunnel
must error out instead of silently degrading.

## Local development

Local development uses the same remote engine, not a local one. With
`SOPS_AGE_KEY` set, running
[`scripts/setup_dagger_remote.sh`](scripts/setup_dagger_remote.sh) establishes
the SSH tunnel and exports `_EXPERIMENTAL_DAGGER_RUNNER_HOST` exactly as CI does.

Once connected, run the pipeline. For non-interactive environments (CI, LLMs)
use `--progress=plain` for readable logs:

```bash
nix develop --command dagger call --progress=plain -q -m ci --source=. check
```

## Secrets

CI holds exactly **one** GitHub Actions secret: `SOPS_AGE_KEY`. Everything else
lives SOPS-encrypted in `secrets.enc.yaml` in this repo.
[`scripts/setup_dagger_remote.sh`](scripts/setup_dagger_remote.sh) decrypts that
file with the age key at the start of each job and exports the individual
secrets to `$GITHUB_ENV` (registering each for log redaction) so later steps can
use them without touching the SOPS store directly. The engine's own SSH access
credentials (`DAGGER_SSH_KEY`, `DAGGER_ENGINE_HOST`) are decrypted the same way.

The secrets carried in `secrets.enc.yaml` include the SSH deploy credentials
(`SSH_PRIVATE_KEY`, `SSH_KNOWN_HOSTS`, `SSH_USER`, `SSH_HOST`,
`WEBSITE_SSH_HOST`), the Android signing material
(`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`), the Play Store service
account (`PLAY_STORE_CONFIG_JSON`), the Firebase Test Lab service account
(`FIREBASE_TEST_LAB_SERVICE_ACCOUNT_KEY`), and the tokens used by the pipeline
(`GITHUB_TOKEN`, `AGENTLOOP_OTEL_TOKEN`).

Inside the Dagger module all sensitive credentials are passed as `dagger.Secret`
(never as plain strings), so values never appear in Dagger logs or get cached in
the engine.

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

## CI Integration

All workflow steps in `.github/workflows/*.yml` run through the Dagger
module in `ci/`. Each step is either `scripts/setup_dagger_remote.sh` (the
SOPS-decrypt bootstrap that opens the SSH tunnel to the engine) or a
`dagger call --progress=plain -q -m ci --source=. <function>` invocation.
The only non-Dagger step that survived is `setup_dagger_remote.sh`
itself, because Dagger cannot decrypt the secrets that grant access to
the engine.

- **Check Suite:** Runs analysis and tests in parallel (`check`).
- **Builds:** Produces Linux and Android artifacts (`deploy-linux`,
  `deploy-apk`, `publish-android`).
- **Caching:** All jobs share the persistent cache on the remote engine host.
- **GitHub-API helpers:** `print-runner-wait`, `changed-targets`,
  `update-deploy-health-label`, `create-firebase-failure-issue`,
  `verify-play-store-deploy`, and `website-verify` replace the inline
  Python that used to live in workflow YAML; the deploy-health label
  flip, the firebase failure-issue creator, and the changed-targets
  detector all run inside Dagger so the workflows stay declarative.

### Deploy-health tracker setup

The hourly `Deploy` workflow ends with a `label-deploy-health` job that
flips `CI/Full-Pass` / `CI/Full-Fail` on a long-lived tracker issue. It
fails loudly if any piece of the setup is missing, so a fresh fork or
mirror needs three things wired up once:

1. Two repository labels: `CI/Full-Pass` and `CI/Full-Fail`.
2. A long-lived tracker issue (do not close it — closing it breaks the
   labeler). Give it a descriptive title like "Deploy health tracker".
3. A repository (or organisation) Actions variable
   `DEPLOY_HEALTH_ISSUE` whose value is the tracker issue number.

Verify locally with

```sh
DEPLOY_HEALTH_ISSUE=<n> GITHUB_TOKEN=$(gh auth token) \
  GITHUB_API_URL=https://api.github.com \
  GITHUB_REPOSITORY=<owner>/<repo> ALL_SUCCEEDED=true \
  python3 scripts/update_deploy_health_label.py
```
- **Dev container:** `publish-dev-container` builds `Dockerfile.dev` and
  pushes both `:latest` and `:<short-sha>` to GHCR via `dag.Container().Build().Publish()`,
  replacing the `docker login` / `docker build` / `docker push` steps.
