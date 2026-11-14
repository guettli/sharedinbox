# Runner image for the GitHub Actions Runner Controller (ARC) scale set
# "sharedinbox-arc" (deployed from gitops: k8s/helm-values/vps/arc-runner-set.yaml).
#
# This image is the SINGLE SOURCE OF TRUTH for the CI toolchain. Workflows that
# run on sharedinbox-arc rely on these baked tools and do NOT reinstall them at
# job time -- if a version here is wrong, CI must fail loudly rather than be
# silently patched. See guettli/otelhouse#33.
#
# Built and pushed automatically by .github/workflows/publish-ci-runner.yml on
# every change to this file, tagged v<YYYY.MM.DD.HHMMSS>. gitops Renovate
# auto-merges that tag into the scale set, so a merge here reaches the runners
# without a hand-made gitops PR.
#
# The base is PINNED, never :latest, so that a new actions/runner release is a
# change to this file: Renovate bumps the tag below (auto-merged as a minor/patch),
# which rebuilds and republishes the image, which gitops Renovate then rolls out.
# This matters: GitHub refuses a runner version 30 days after its successor
# ships, and a refused runner made ARC mark the whole scale set Outdated and
# delete its listener -- sharedinbox CI queued for three days (2026-11-05..08).
# With `FROM ...:latest` the image was rebuilt only when someone edited this
# file, so it aged silently.
FROM ghcr.io/actions/actions-runner:2.338.2
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      jq python3 openssh-client ca-certificates curl git \
      python3-google-auth python3-requests \
    && rm -rf /var/lib/apt/lists/*
# python3-google-auth / python3-requests are baked here (not pip-installed per
# job) for scripts/verify_playstore_deploy.py — see deploy.yml. Add new Python
# deps here too; the runner intentionally ships no pip so deps can't drift.
# Keep this in sync with the version CI relies on (no per-job reinstall).
RUN curl -fsSL -o /usr/local/bin/sops https://github.com/getsops/sops/releases/download/v3.13.1/sops-v3.13.1.linux.amd64 \
    && chmod +x /usr/local/bin/sops
# Must match the pinned Dagger engine on p16 (gitops: ansible/p16/systemd/system/dagger-engine.service).
# CLI and engine version must be identical or the engine appears "unreachable" to the runner.
RUN curl -fsSL https://dl.dagger.io/dagger/install.sh | DAGGER_VERSION=0.21.11 BIN_DIR=/usr/local/bin sh
RUN curl -fsSL https://taskfile.dev/install.sh | sh -s -- -b /usr/local/bin v3.48.0
USER runner
