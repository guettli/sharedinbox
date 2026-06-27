#!/usr/bin/env python3
"""Detect whether files matching a target pattern changed since the last
successful run of a given workflow job.

Replaces the inline Python that used to live in deploy.yml and website.yml.

Reads from the environment:
  GITHUB_TOKEN     — token with read access to the workflow runs
  GITHUB_API_URL   — https://api.github.com (provided by the runner)
  GITHUB_REPOSITORY — owner/repo
  HEAD_SHA         — current commit (typically $GITHUB_SHA)
  EVENT_NAME       — workflow event (push / schedule / workflow_dispatch)
  WORKFLOW_FILE    — workflow file name e.g. "deploy.yml"
  JOB_NAME         — job name to look for a successful conclusion of
                     (the run-level status is misleading because skipped
                     jobs still report a successful run, see deploy.yml
                     and website.yml for the historical context)
  TARGETS          — JSON object mapping target-name to a regex of paths,
                     e.g. ``{"android": "^(android/|integration_test/|...)$"}``
  ALWAYS_ON_NON_SCHEDULE — when set to "true", treat any event other than
                     "schedule" as "deploy everything". Used by website.yml,
                     which redeploys on every push to main.

Output (stdout, JSON):
  ``{"target1": true|false, "target2": true|false, ...}``

Behaviour rules carried over from the previous inline Python:
  - On ``workflow_dispatch`` → all targets true.
  - When ``ALWAYS_ON_NON_SCHEDULE`` is "true", any event other than
    ``schedule`` → all targets true (matches website.yml).
  - If no last-successful run can be found → all targets true (precaution).
  - If HEAD_SHA == last deployed SHA → all targets false.
  - Otherwise the GitHub Compare API gives the changed-file list and each
    target's regex is matched against it.

Notices/warnings that used to go to the workflow log are emitted as
``::notice::``/``::warning::`` lines on stderr so they still surface in the
Actions UI; the JSON result is the last non-empty line on stdout.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

_API_TIMEOUT = 60


def _gh_get(url, token):
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    with urllib.request.urlopen(req, timeout=_API_TIMEOUT) as r:
        return json.loads(r.read())


def _last_deployed_sha(api, repo, workflow_file, job_name, token):
    """Return the head_sha of the most recent run whose target job concluded
    successfully, or "" if none can be identified.
    """
    runs = _gh_get(
        f"{api}/repos/{repo}/actions/workflows/{workflow_file}/runs"
        "?status=success&per_page=50",
        token,
    ).get("workflow_runs", [])
    for run in runs:
        jobs = _gh_get(
            f"{api}/repos/{repo}/actions/runs/{run['id']}/jobs",
            token,
        ).get("jobs", [])
        for job in jobs:
            if (job.get("name") == job_name
                    and job.get("conclusion") == "success"):
                return run.get("head_sha") or ""
    return ""


def _compare_files(api, repo, base, head, token):
    files = []
    page = 1
    while True:
        data = _gh_get(
            f"{api}/repos/{repo}/compare/{base}...{head}?per_page=100&page={page}",
            token,
        )
        page_files = data.get("files", []) or []
        for f in page_files:
            files.append(f.get("filename", ""))
        if len(page_files) < 100:
            break
        page += 1
    return files


def main():
    token = os.environ.get("GITHUB_TOKEN", "")
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    repo = os.environ.get("GITHUB_REPOSITORY", "")
    head_sha = os.environ.get("HEAD_SHA", "")
    event_name = os.environ.get("EVENT_NAME", "")
    workflow_file = os.environ.get("WORKFLOW_FILE", "")
    job_name = os.environ.get("JOB_NAME", "")
    always_on_non_schedule = os.environ.get(
        "ALWAYS_ON_NON_SCHEDULE", "false").lower() == "true"
    targets_raw = os.environ.get("TARGETS", "")

    if not (token and repo and head_sha and workflow_file and job_name and targets_raw):
        print(
            "::error::changed_targets.py: missing one of GITHUB_TOKEN, "
            "GITHUB_REPOSITORY, HEAD_SHA, WORKFLOW_FILE, JOB_NAME, TARGETS",
            file=sys.stderr,
        )
        sys.exit(2)

    targets = json.loads(targets_raw)
    names = list(targets.keys())

    def emit(result):
        print(json.dumps(result))

    if event_name == "workflow_dispatch":
        emit({n: True for n in names})
        return
    if always_on_non_schedule and event_name != "schedule":
        emit({n: True for n in names})
        return

    try:
        base = _last_deployed_sha(api, repo, workflow_file, job_name, token)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
        print(
            f"::error::LAST_DEPLOYED_SHA lookup failed "
            f"({type(e).__name__}: {e})",
            file=sys.stderr,
        )
        emit({n: True for n in names})
        return

    if not base:
        print(
            "::warning::Could not determine last successfully deployed SHA — "
            "deploying as a precaution",
            file=sys.stderr,
        )
        emit({n: True for n in names})
        return

    if base == head_sha:
        print(
            f"::notice::All targets SKIPPED — HEAD {head_sha} was already "
            "successfully deployed",
            file=sys.stderr,
        )
        emit({n: False for n in names})
        return

    try:
        changed = _compare_files(api, repo, base, head_sha, token)
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError) as e:
        print(
            f"::warning::compare API failed ({type(e).__name__}: {e}) — "
            "deploying as a precaution",
            file=sys.stderr,
        )
        emit({n: True for n in names})
        return

    print(f"Changed files (since {base}):", file=sys.stderr)
    for f in changed:
        print(f"  {f}", file=sys.stderr)

    result = {}
    for name, pattern in targets.items():
        rx = re.compile(pattern)
        hit = any(rx.match(f) for f in changed)
        result[name] = hit
        if hit:
            print(
                f"::notice::{name} TRIGGERED — {name}-relevant files changed "
                f"since {base}",
                file=sys.stderr,
            )
        else:
            print(
                f"::notice::{name} SKIPPED — diff {base}..{head_sha} has no "
                f"{name}-relevant changes",
                file=sys.stderr,
            )
    emit(result)


if __name__ == "__main__":
    main()
