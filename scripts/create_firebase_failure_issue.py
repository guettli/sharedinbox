#!/usr/bin/env python3
"""Create a GitHub issue describing a Firebase Test Lab failure.

Replaces the inline Python that used to live in firebase-tests.yml's
"Create issue on test failure" step. Reads from the environment:

  GITHUB_TOKEN      — token with repo:issues write
  GITHUB_API_URL    — https://api.github.com (runner-provided)
  GITHUB_REPOSITORY — owner/repo
  RUN_URL           — link to the failing run, included in the body

Skips creation when an open issue with the canonical title already exists,
so hourly runs cannot pile up duplicate failure issues until a fix lands.
"""

import json
import os
import sys
import urllib.request


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

    # The list endpoint returns both issues and PRs — filter PRs.
    existing = [
        i for i in api_get("/issues?state=open&labels=loop/code&per_page=100")
        if i["title"] == title and not i.get("pull_request")
    ]
    if existing:
        print(f"Existing open issue #{existing[0]['number']} — not creating duplicate")
        return 0

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
