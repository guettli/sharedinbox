#!/usr/bin/env bash
# Record one Android app-size row for the just-published build into
# metrics/android-app-size.tsv and commit it to main.
#
# Called by the "Record app size" step of .github/workflows/deploy.yml, which
# runs only after a successful Play Store publish and is marked
# continue-on-error — so anything here is best-effort and must never be able to
# fail the deploy. We still use `set -e` for correctness and simply let the
# workflow swallow a non-zero exit.
#
# The committed row triggers no further CI: metrics/ is outside the deploy
# change-detection globs, and the commit subject carries [skip ci] so the push
# does not start a Full Project Check run.
set -euo pipefail

HISTORY="metrics/android-app-size.tsv"
AAB="build/app/outputs/bundle/release/app-release.aab"

# Build (or reuse the cached) AAB so we have the artifact to measure. The same
# release bundle the publish step built is served from the Dagger cache, so this
# just exports the file to the runner.
if [ ! -f "$AAB" ]; then
    task build-android-bundle
fi

HASH=$(git rev-parse --short HEAD)
VERSION_NAME=$(python3 -c "import re;m=re.search(r'^version:\s*([^+\s]+)',open('pubspec.yaml').read(),re.M);print(m.group(1) if m else 'unknown')")
FLUTTER=$(python3 -c "import json;print(json.load(open('.fvmrc')).get('flutter','unknown'))")

python3 scripts/android_size_report.py "$AAB" \
    --git-hash "$HASH" \
    --version-name "$VERSION_NAME" \
    --version-code "${VERSION_CODE:-unknown}" \
    --flutter "$FLUTTER" \
    --append "$HISTORY"

if git diff --quiet -- "$HISTORY"; then
    echo "no size-history change to commit"
    exit 0
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add "$HISTORY"
git commit -m "chore(metrics): Android app size for ${HASH} [skip ci]"

# Land it on main, riding out a concurrent merge once. A lost race is harmless:
# the next published build records the current size again.
for attempt in 1 2; do
    if git pull --rebase --quiet origin main && git push origin HEAD:main; then
        echo "recorded Android size row for ${HASH}"
        exit 0
    fi
    echo "push attempt ${attempt} failed; retrying after refresh" >&2
    sleep 3
done
echo "::warning::could not push the Android size row (lost the race); it will be recorded on the next build" >&2
exit 0
