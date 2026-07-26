#!/usr/bin/env python3
"""Create a GitHub issue describing a Firebase Test Lab failure.

Replaces the inline Python that used to live in firebase-tests.yml's
"Create issue on test failure" step. Reads from the environment:

  GITHUB_TOKEN      — token with repo:issues write
  GITHUB_API_URL    — https://api.github.com (runner-provided)
  GITHUB_REPOSITORY — owner/repo
  RUN_URL           — link to the failing run, included in the body

Skips creation when:
  * an open issue with the canonical title already exists, so hourly runs
    cannot pile up duplicates until a fix lands; or
  * a similar-titled issue was closed within the last hour, on the
    assumption that its fix has just landed and this failing run started
    against pre-fix code (see #404 for the exact race).
"""

import json
import os
import sys
import urllib.request
from datetime import datetime, timedelta, timezone

# Window during which a just-closed similar issue suppresses a new one.
# Long enough to cover an in-flight run that started before the fix merged
# (the #404 case: ~20 min gap), short enough that a genuine repeat failure
# on the next scheduled run still surfaces.
_RECENT_CLOSE_WINDOW = timedelta(hours=1)


def _parse_github_ts(s):
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def main():
    token = os.environ["GITHUB_TOKEN"]
    api_base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    repo = os.environ["GITHUB_REPOSITORY"]
    run_url = os.environ["RUN_URL"]

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "Content-Type": "application/json",
    }
    api = f"{api_base}/repos/{repo}"

    def api_get(path):
        req = urllib.request.Request(f"{api}{path}", headers=headers, method="GET")
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())

    def api_post(path, body):
        data = json.dumps(body).encode()
        req = urllib.request.Request(
            f"{api}{path}", data=data, headers=headers, method="POST",
        )
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read())

    title = "Firebase Tests failed — find root cause and fix"

    # Filter by `automerge` rather than `loop/code`: the loop/code label
    # progresses to loop/code-in-process → loop/code-ci-pending → loop/code-done
    # as the agent works, and an exact-match `labels=loop/code` filter would
    # miss any issue past the first stage. `automerge` is set once at creation
    # and never removed, so it is a stable handle across the loop lifecycle.
    # The list endpoint returns both issues and PRs — filter PRs.
    existing = [
        i for i in api_get("/issues?state=open&labels=automerge&per_page=100")
        if i["title"] == title and not i.get("pull_request")
    ]
    if existing:
        print(f"Existing open issue #{existing[0]['number']} — not creating duplicate")
        return 0

    # A similar issue closed very recently means the fix has just landed but
    # this failing run started against pre-fix code and could not benefit
    # from it (see #404). The next scheduled run will confirm whether the
    # fix works — creating a new issue now would just be noise.
    recent_closed = [
        i for i in api_get(
            "/issues?state=closed&labels=automerge&per_page=20"
            "&sort=updated&direction=desc"
        )
        if i["title"] == title and not i.get("pull_request") and i.get("closed_at")
    ]
    now = datetime.now(timezone.utc)
    for issue in recent_closed:
        closed_at = _parse_github_ts(issue["closed_at"])
        if now - closed_at <= _RECENT_CLOSE_WINDOW:
            age_min = int((now - closed_at).total_seconds() / 60)
            print(
                f"Similar issue #{issue['number']} closed {age_min}m ago — "
                f"skipping; fix is presumably in flight"
            )
            return 0
        # Closed list is sorted newest-first; older ones can't be recent.
        break

    body = (
        "Firebase robo crawl of the Play Store **alpha** APK failed in the hourly run.\n\n"
        f"**Failed run:** {run_url}\n\n"
        "## Steps to resolve\n\n"
        "1. **Find the root cause**: Check the test run logs linked above. "
        "The job runs `gcloud firebase test android run --type robo` against "
        "the split APKs downloaded from the alpha track, so a failure means "
        "the production binary either crashed (look for `FATAL EXCEPTION` / "
        "`Process … has died`) or the robo crawl reported "
        "`Failed`/`Inconclusive`.\n"
        "2. **Fix if possible**: If the failure is caused by a code bug, "
        "create a fix. If it is a flaky or infrastructure issue, document "
        "the findings.\n"
        "3. Close this issue once the root cause is resolved and the tests "
        "pass.\n"
    )

    # `automerge` so once the agentloop ships a fix and CI is green on the
    # PR, it lands without a human round-trip.
    issue = api_post("/issues", {
        "title": title,
        "body": body,
        "labels": ["loop/code", "automerge"],
    })
    print(f"Created issue #{issue['number']}: {issue['html_url']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
