#!/usr/bin/env bash
# Record one Android app-size row for the just-published build.
#
# main is protected (a pull request is required — no direct pushes), so the
# history cannot live on main and be appended by CI. Instead it accumulates on a
# dedicated, unprotected orphan branch, app-size-history, holding a single file:
# android-app-size.tsv. Browse it at:
#   https://github.com/guettli/sharedinbox/blob/app-size-history/android-app-size.tsv
#
# Called by the non-blocking "Record app size" step of deploy.yml after a
# successful + verified Play publish. continue-on-error there means anything
# here is best-effort and must never fail the deploy; we still use `set -e` for
# correctness and let the workflow swallow a non-zero exit.
set -euo pipefail

BRANCH="app-size-history"
HISTORY_FILE="android-app-size.tsv"   # path *within* the app-size-history branch
AAB="build/app/outputs/bundle/release/app-release.aab"
REPO_ROOT="$(pwd)"

# Build (or reuse the cached) AAB so we have the artifact to measure. The publish
# step built this exact bundle on the Dagger engine, so this is a cache hit that
# only exports the file to the runner.
if [ ! -f "$AAB" ]; then
    task build-android-bundle
fi

HASH=$(git rev-parse --short HEAD)
VERSION_NAME=$(python3 -c "import re;m=re.search(r'^version:\s*([^+\s]+)',open('pubspec.yaml').read(),re.M);print(m.group(1) if m else 'unknown')")
FLUTTER=$(python3 -c "import json;print(json.load(open('.fvmrc')).get('flutter','unknown'))")

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Check out the history branch into a throwaway worktree so the deploy's own
# checkout is never disturbed. Reuse the checkout's authenticated `origin`
# remote — the dedicated branch is unprotected, so contents:write can push it.
WT="$(mktemp -d)"
cleanup() { git worktree remove --force "$WT" 2>/dev/null || true; }
trap cleanup EXIT

if git fetch --depth=1 origin "$BRANCH" 2>/dev/null; then
    git worktree add --force -B "$BRANCH" "$WT" FETCH_HEAD
else
    # First ever run: start an orphan branch with no history and nothing but the
    # TSV. (Done in two steps rather than `worktree add --orphan`, whose argument
    # shape differs across git versions.)
    git worktree add --force --detach "$WT" HEAD
    git -C "$WT" checkout --orphan "$BRANCH"
    git -C "$WT" rm -rf --quiet . >/dev/null 2>&1 || true
fi

python3 "$REPO_ROOT/scripts/android_size_report.py" "$REPO_ROOT/$AAB" \
    --git-hash "$HASH" \
    --version-name "$VERSION_NAME" \
    --version-code "${VERSION_CODE:-unknown}" \
    --flutter "$FLUTTER" \
    --append "$WT/$HISTORY_FILE"

cd "$WT"
git add "$HISTORY_FILE"
if git diff --cached --quiet; then
    echo "no size-history change to commit"
    exit 0
fi
git commit -m "Android app size for ${HASH}"

# Push to the dedicated branch (unprotected). Ride out a concurrent writer once;
# a lost race is harmless — the next published build records the size again.
for attempt in 1 2; do
    if git push origin "HEAD:refs/heads/${BRANCH}"; then
        echo "recorded Android size row for ${HASH} on ${BRANCH}"
        exit 0
    fi
    echo "push attempt ${attempt} failed; refreshing ${BRANCH}" >&2
    git fetch --depth=1 origin "$BRANCH" 2>/dev/null || true
    git rebase FETCH_HEAD 2>/dev/null || git rebase --abort 2>/dev/null || true
    sleep 3
done
echo "::warning::could not push the Android size row; it will be recorded on the next build" >&2
exit 0
