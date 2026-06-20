#!/usr/bin/env python3
"""
Cron deploy script for sharedinbox website.
Runs every 5 minutes; skips if origin/main has not changed since last trigger.
Triggers the 'Deploy Website' Forgejo Actions workflow via fj on each new commit.
Forgejo Actions handles failure reporting.
"""
import subprocess
import sys
from pathlib import Path

REPO_DIR = Path(__file__).parent.resolve()
SHA_FILE = REPO_DIR / '.last_deployed_sha'
REPO = 'guettli/sharedinbox'


def git(*args):
    return subprocess.run(
        ['git', *args], cwd=REPO_DIR, check=True,
        capture_output=True, text=True,
    ).stdout.strip()


def read(path: Path) -> str:
    return path.read_text().strip() if path.exists() else ''


def main():
    try:
        git('fetch', 'origin', 'main')
    except subprocess.CalledProcessError as exc:
        print(f'git fetch failed (transient?): {exc} — skipping this run.', file=sys.stderr)
        return
    remote_sha = git('rev-parse', 'origin/main')
    last_sha = read(SHA_FILE)

    if remote_sha == last_sha:
        print(f'No changes since {remote_sha[:8]}, skipping.')
        return

    print(f'New commit {remote_sha[:8]} (was {last_sha[:8] or "none"}) — triggering workflow...')
    result = subprocess.run(
        ['fj', '-H', 'sialoop.thomas-guettler.de', 'actions', 'dispatch', '-r', REPO, 'website.yml', 'main'],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f'fj workflow run failed: {result.stderr}', file=sys.stderr)
        sys.exit(1)

    SHA_FILE.write_text(remote_sha + '\n')
    print('Workflow triggered.')


if __name__ == '__main__':
    main()
