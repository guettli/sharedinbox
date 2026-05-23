#!/usr/bin/env python3
"""
Cron deploy script for sharedinbox website.
Runs every 15 minutes; skips if origin/main has not changed since last successful deploy.
"""
import subprocess
import sys
from pathlib import Path

REPO_DIR = Path(__file__).parent.resolve()
SHA_FILE = REPO_DIR / '.last_deployed_sha'


def git(*args):
    return subprocess.run(
        ['git', *args], cwd=REPO_DIR, check=True,
        capture_output=True, text=True,
    ).stdout.strip()


def main():
    git('fetch', 'origin', 'main')
    remote_sha = git('rev-parse', 'origin/main')

    last_sha = SHA_FILE.read_text().strip() if SHA_FILE.exists() else ''
    if remote_sha == last_sha:
        print(f'No changes since {remote_sha[:8]}, skipping.')
        return

    print(f'Deploying {remote_sha[:8]} (was {last_sha[:8] or "none"})...')
    git('pull', '--ff-only', 'origin', 'main')

    result = subprocess.run(['task', 'publish-website'], cwd=REPO_DIR)
    if result.returncode != 0:
        print(f'Deploy failed (exit {result.returncode})', file=sys.stderr)
        sys.exit(1)

    SHA_FILE.write_text(remote_sha + '\n')
    print('Deploy complete.')


if __name__ == '__main__':
    main()
