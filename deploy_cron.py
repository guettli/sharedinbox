#!/usr/bin/env python3
"""
Cron deploy script for sharedinbox website.
Runs every 15 minutes; skips if origin/main has not changed since last successful deploy.
If last deploy failed and main still hasn't changed, creates a Codeberg issue.
"""
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO_DIR = Path(__file__).parent.resolve()
SHA_FILE        = REPO_DIR / '.last_deployed_sha'
FAILED_SHA_FILE = REPO_DIR / '.last_failed_sha'
ERROR_FILE      = REPO_DIR / '.last_deploy_error'
ISSUE_SHA_FILE  = REPO_DIR / '.last_issue_sha'

REPO = 'guettli/sharedinbox'
CODEBERG = 'https://codeberg.org'


def git(*args):
    return subprocess.run(
        ['git', *args], cwd=REPO_DIR, check=True,
        capture_output=True, text=True,
    ).stdout.strip()


def read(path: Path) -> str:
    return path.read_text().strip() if path.exists() else ''


def create_issue(failed_sha: str) -> None:
    error_output = read(ERROR_FILE)
    tail = '\n'.join(error_output.splitlines()[-40:]) if error_output else '(no output captured)'
    commit_url = f'{CODEBERG}/{REPO}/commit/{failed_sha}'
    script_url = f'{CODEBERG}/{REPO}/src/branch/main/deploy_cron.py'
    timestamp = datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')

    title = f'Deploy failed on {failed_sha[:8]} — main needs a fix'
    body = f"""\
## Deploy failure — action needed

The automated deploy cron has been failing on commit \
[{failed_sha[:8]}]({commit_url}) and `main` has not advanced since the failure.

| | |
|---|---|
| **Detected** | {timestamp} |
| **Failing commit** | [{failed_sha}]({commit_url}) |
| **Deploy script** | [deploy_cron.py]({script_url}) |
| **Log file** | `~/si-deploy-cron/deploy.log` |

### Last deploy output

```
{tail}
```

### Next steps

Push a fix to `main` — the cron runs every 15 min and will retry automatically.
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
    git('fetch', 'origin', 'main')
    remote_sha = git('rev-parse', 'origin/main')

    last_sha    = read(SHA_FILE)
    last_failed = read(FAILED_SHA_FILE)
    last_issue  = read(ISSUE_SHA_FILE)

    if remote_sha == last_sha:
        print(f'No changes since {remote_sha[:8]}, skipping.')
        return

    if remote_sha == last_failed:
        if remote_sha != last_issue:
            print(f'{remote_sha[:8]} failed before and main has not changed — creating issue.')
            create_issue(remote_sha)
            ISSUE_SHA_FILE.write_text(remote_sha + '\n')
        else:
            print(f'{remote_sha[:8]} still failing, issue already open, skipping.')
        return

    print(f'Deploying {remote_sha[:8]} (was {last_sha[:8] or "none"})...')
    git('pull', '--ff-only', 'origin', 'main')

    result = subprocess.run(
        ['task', 'publish-website'],
        cwd=REPO_DIR,
        capture_output=True, text=True,
    )
    combined = result.stdout + result.stderr
    print(combined, end='')

    if result.returncode != 0:
        print(f'Deploy failed (exit {result.returncode})', file=sys.stderr)
        FAILED_SHA_FILE.write_text(remote_sha + '\n')
        ERROR_FILE.write_text(combined)
        ISSUE_SHA_FILE.unlink(missing_ok=True)
        sys.exit(1)

    SHA_FILE.write_text(remote_sha + '\n')
    FAILED_SHA_FILE.unlink(missing_ok=True)
    ERROR_FILE.unlink(missing_ok=True)
    ISSUE_SHA_FILE.unlink(missing_ok=True)
    print('Deploy complete.')


if __name__ == '__main__':
    main()
