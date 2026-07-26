#!/usr/bin/env python3
"""Flip the CI/Full-Pass and CI/Full-Fail labels on the deploy-health
tracking issue.

Replaces the inline Python that used to live in deploy.yml's
``label-deploy-health`` job. Reads from the environment:

  GITHUB_TOKEN            — token with repo:issues write
  GITHUB_API_URL          — GitHub API base URL (required — pin it in the
                            workflow ``env:`` block, e.g. ``$GITHUB_API_URL``
                            on hosted runners)
  GITHUB_REPOSITORY       — owner/repo
  DEPLOY_HEALTH_ISSUE     — issue number, e.g. "42"; required
  ALL_SUCCEEDED           — "true" if every deploy job succeeded or was
                            skipped, otherwise "false"

Missing or empty ``DEPLOY_HEALTH_ISSUE`` is a hard failure: the whole point
of the label is to reflect deploy health, so silently skipping when the var
is unset would make a broken configuration look green.
"""

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


def main():
    issue = os.environ.get("DEPLOY_HEALTH_ISSUE", "").strip()
    if not issue:
        print(
            "ERROR: DEPLOY_HEALTH_ISSUE is not set. Configure the "
            "Actions variable at the repository (or organisation) level.",
            file=sys.stderr,
        )
        return 1

    token = os.environ["GITHUB_TOKEN"]
    api_base = os.environ["GITHUB_API_URL"].rstrip("/")
    repo = os.environ["GITHUB_REPOSITORY"]
    succeeded = os.environ.get("ALL_SUCCEEDED", "false").lower() == "true"
    add_label = "CI/Full-Pass" if succeeded else "CI/Full-Fail"
    remove_label = "CI/Full-Fail" if succeeded else "CI/Full-Pass"

    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "Content-Type": "application/json",
    }
    api = f"{api_base}/repos/{repo}"

    def call(method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            f"{api}{path}", data=data, headers=headers, method=method,
        )
        with urllib.request.urlopen(req) as r:
            return json.loads(r.read() or "null")

    repo_labels = {l["name"] for l in call("GET", "/labels?per_page=100")}
    if add_label not in repo_labels:
        print(f"Label '{add_label}' not found in repo — create it first")
        return 1

    # Drop the stale opposite label (404 if it wasn't set), then add ours.
    try:
        call("DELETE", f"/issues/{issue}/labels/{urllib.parse.quote(remove_label)}")
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
    call("POST", f"/issues/{issue}/labels", {"labels": [add_label]})
    print(f"Set '{add_label}' on issue #{issue}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
