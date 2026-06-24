# Runner image for the GitHub Actions Runner Controller (ARC) scale set
# "sharedinbox-arc" (deployed from gitops: k8s/helm-values/arc-runner-set.yaml).
#
# This image is the SINGLE SOURCE OF TRUTH for the CI toolchain. Workflows that
# run on sharedinbox-arc rely on these baked tools and do NOT reinstall them at
# job time -- if a version here is wrong, CI must fail loudly rather than be
# silently patched. See guettli/otelhouse#33.
#
# Built and pushed automatically by .github/workflows/publish-ci-runner.yml on
# every change to this file. The package is private; arc-runners pulls it via
# the `ghcr-pull` secret (gitops: task k8s-create-arc-secret).
FROM ghcr.io/actions/actions-runner:latest
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      jq python3 openssh-client ca-certificates curl git \
    && rm -rf /var/lib/apt/lists/*
# Keep this in sync with the version CI relies on (no per-job reinstall).
RUN curl -fsSL -o /usr/local/bin/sops https://github.com/getsops/sops/releases/download/v3.13.1/sops-v3.13.1.linux.amd64 \
    && chmod +x /usr/local/bin/sops
# Must match the pinned Dagger engine on p16 (gitops: ansible/p16/systemd/system/dagger-engine.service).
# CLI and engine version must be identical or the engine appears "unreachable" to the runner.
RUN curl -fsSL https://dl.dagger.io/dagger/install.sh | DAGGER_VERSION=0.21.7 BIN_DIR=/usr/local/bin sh
RUN curl -fsSL https://taskfile.dev/install.sh | sh -s -- -b /usr/local/bin v3.48.0
USER runner
