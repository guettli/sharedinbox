#!/usr/bin/env bash
# Fail if any `dagger call` invocation omits --progress=plain, so CI logs stay
# greppable instead of full of the interactive TUI's escape codes.
#
# Checks real invocations only. The previous inline hook grepped the whole
# worktree and failed on any *mention* of "dagger call" — a sentence in
# AGENTS.md and two comment lines — so a clean `main` could not be committed
# without --no-verify (issue #684). This skips this repo's docs (*.md) and
# comment lines, which describe `dagger call` rather than run it.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# git grep -n emits "path:lineno:content". Exclude the hook config and markdown,
# then drop lines that already pass and lines that are comments (first
# non-space char is '#').
offenders=$(
  git --no-pager grep -n 'dagger call' -- ':!.pre-commit-config.yaml' ':!*.md' \
    | grep -v -- '--progress=plain' \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    || true
)

if [ -n "$offenders" ]; then
  echo "ERROR: these 'dagger call' invocations must include --progress=plain:" >&2
  echo "$offenders" >&2
  exit 1
fi
