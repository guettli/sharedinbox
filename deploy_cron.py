#!/usr/bin/env python3
"""
Cron deploy script for sharedinbox website.
Runs every 5 minutes; skips if origin/main has not changed since last successful deploy.
Gives up and creates a Codeberg issue after 5 consecutive failures on the same commit.
"""
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_DIR = Path(__file__).parent.resolve()
SHA_FILE        = REPO_DIR / '.last_deployed_sha'
FAILED_SHA_FILE = REPO_DIR / '.last_failed_sha'
FAIL_COUNT_FILE = REPO_DIR / '.fail_count'
ERROR_FILE      = REPO_DIR / '.last_deploy_error'
ISSUE_SHA_FILE  = REPO_DIR / '.last_issue_sha'

MAX_FAILURES = 5
REPO = 'guettli/sharedinbox'
CODEBERG = 'https://codeberg.org'


def git(*args):
    return subprocess.run(
        ['git', *args], cwd=REPO_DIR, check=True,
        capture_output=True, text=True,
    ).stdout.strip()


def read(path: Path) -> str:
    return path.read_text().strip() if path.exists() else ''


def read_int(path: Path) -> int:
    try:
        return int(read(path))
    except ValueError:
        return 0


def issue_exists_for(sha: str) -> bool:
    """Check Codeberg for an open issue referencing this commit SHA."""
    result = subprocess.run(
        ['tea', 'issue', 'list', '--repo', REPO, '--state', 'open',
         '--limit', '50', '--output', 'simple'],
        capture_output=True, text=True,
    )
    return sha[:8] in result.stdout


def create_issue(failed_sha: str, fail_count: int) -> None:
    error_output = read(ERROR_FILE)
    tail = '\n'.join(error_output.splitlines()[-40:]) if error_output else '(no output captured)'
    commit_url = f'{CODEBERG}/{REPO}/commit/{failed_sha}'
    script_url = f'{CODEBERG}/{REPO}/src/branch/main/deploy_cron.py'
    timestamp = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')

    title = f'Deploy failed {fail_count}x on {failed_sha[:8]} — needs fix'
    body = f"""\
## Deploy failure — action needed

The automated deploy cron failed **{fail_count} times** on commit \
[{failed_sha[:8]}]({commit_url}) and has stopped retrying.

| | |
|---|---|
| **Detected** | {timestamp} |
| **Failing commit** | [{failed_sha}]({commit_url}) |
| **Failures** | {fail_count} / {MAX_FAILURES} |
| **Deploy script** | [deploy_cron.py]({script_url}) |
| **Log file** | `~/si-deploy-cron/deploy.log` |

### Last deploy output

```
{tail}
```

### Next steps

Push a fix to `main` — the cron (every 5 min) will retry automatically on the next commit.
"""

    result = subprocess.run(
        ['tea', 'issue', 'create',
         '--repo', REPO,
         '--title', title,
         '--description', body,
         '--labels', 'State/Ready,Prio/High'],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f'Failed to create issue: {result.stderr}', file=sys.stderr)
    else:
        print(f'Issue created: {result.stdout.strip()}')


def main():
    try:
        git('fetch', 'origin', 'main')
    except subprocess.CalledProcessError as exc:
        print(f'git fetch failed (transient?): {exc} — skipping this run.', file=sys.stderr)
        return
    remote_sha = git('rev-parse', 'origin/main')

    last_sha    = read(SHA_FILE)
    last_failed = read(FAILED_SHA_FILE)
    fail_count  = read_int(FAIL_COUNT_FILE) if remote_sha == last_failed else 0
    last_issue  = read(ISSUE_SHA_FILE)

    if remote_sha == last_sha:
        print(f'No changes since {remote_sha[:8]}, skipping.')
        return

    if fail_count >= MAX_FAILURES:
        if remote_sha != last_issue and not issue_exists_for(remote_sha):
            print(f'{remote_sha[:8]} failed {fail_count}x — creating issue.')
            create_issue(remote_sha, fail_count)
            ISSUE_SHA_FILE.write_text(remote_sha + '\n')
        else:
            print(f'{remote_sha[:8]} failed {fail_count}x, issue already exists, skipping.')
        return

    attempt = fail_count + 1
    print(f'Deploying {remote_sha[:8]} (attempt {attempt}/{MAX_FAILURES}, was {last_sha[:8] or "none"})...')
    git('pull', '--ff-only', 'origin', 'main')

    result = subprocess.run(
        ['task', 'publish-website'],
        cwd=REPO_DIR,
        capture_output=True, text=True,
    )
    combined = result.stdout + result.stderr
    print(combined, end='')

    if result.returncode != 0:
        print(f'Deploy failed (exit {result.returncode}), attempt {attempt}/{MAX_FAILURES}', file=sys.stderr)
        FAILED_SHA_FILE.write_text(remote_sha + '\n')
        FAIL_COUNT_FILE.write_text(str(attempt) + '\n')
        ERROR_FILE.write_text(combined)
        sys.exit(1)

    SHA_FILE.write_text(remote_sha + '\n')
    for f in (FAILED_SHA_FILE, FAIL_COUNT_FILE, ERROR_FILE, ISSUE_SHA_FILE):
        f.unlink(missing_ok=True)
    print('Deploy complete.')


if __name__ == '__main__':
    main()
