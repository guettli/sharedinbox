#!/usr/bin/env python3
"""Tests for create_firebase_failure_issue.py."""
import datetime
import io
import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).parent))

import create_firebase_failure_issue as mod

TITLE = "Firebase Tests failed — find root cause and fix"


def _issue(number, *, state, title=TITLE, closed_at=None, is_pr=False):
    payload = {"number": number, "title": title, "state": state}
    if is_pr:
        payload["pull_request"] = {"url": "https://api.github.com/x"}
    if closed_at is not None:
        payload["closed_at"] = closed_at
    return payload


def _run_main(open_issues=None, closed_issues=None, created_issue=None):
    """Invoke ``main()`` with urllib.request.urlopen mocked.

    ``open_issues`` and ``closed_issues`` are returned for the two GET
    calls. ``created_issue`` (if set) is returned for the POST create call.
    Returns a list of (method, url) tuples for the requests made.
    """
    open_issues = open_issues or []
    closed_issues = closed_issues or []
    calls = []

    def fake_urlopen(request):
        calls.append((request.get_method(), request.full_url))
        if request.get_method() == "POST":
            body = created_issue or {"number": 999, "html_url": "https://x/999"}
        elif "state=open" in request.full_url:
            body = open_issues
        elif "state=closed" in request.full_url:
            body = closed_issues
        else:
            raise AssertionError(f"unexpected URL {request.full_url}")
        return _fake_response(body)

    env = {
        "GITHUB_TOKEN": "t",
        "GITHUB_API_URL": "https://api.github.com",
        "GITHUB_REPOSITORY": "owner/repo",
        "RUN_URL": "https://x/run",
    }
    with patch.dict(os.environ, env, clear=True):
        with patch("create_firebase_failure_issue.urllib.request.urlopen", side_effect=fake_urlopen):
            mod.main()
    return calls


def _fake_response(body):
    resp = MagicMock()
    resp.__enter__ = lambda self: self
    resp.__exit__ = lambda *a: False
    resp.read.return_value = json.dumps(body).encode()
    return resp


class TestDedup(unittest.TestCase):
    def test_creates_issue_when_no_matches(self):
        calls = _run_main()
        methods = [m for m, _ in calls]
        self.assertIn("POST", methods)

    def test_skips_when_open_issue_exists(self):
        calls = _run_main(open_issues=[_issue(42, state="open")])
        self.assertNotIn("POST", [m for m, _ in calls])

    def test_ignores_open_prs_with_matching_title(self):
        calls = _run_main(open_issues=[_issue(42, state="open", is_pr=True)])
        # PRs must not count as dedup matches — creation should proceed.
        self.assertIn("POST", [m for m, _ in calls])

    def test_ignores_open_issue_with_different_title(self):
        calls = _run_main(open_issues=[_issue(42, state="open", title="unrelated")])
        self.assertIn("POST", [m for m, _ in calls])

    def test_skips_when_recently_closed_issue_in_window(self):
        # Closed 5 minutes ago — inside the 1 h window.
        recent = (
            datetime.datetime.now(datetime.timezone.utc)
            - datetime.timedelta(minutes=5)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        calls = _run_main(closed_issues=[_issue(42, state="closed", closed_at=recent)])
        self.assertNotIn("POST", [m for m, _ in calls])

    def test_creates_issue_when_closed_issue_outside_window(self):
        # Closed 2 hours ago — GitHub's `since` filter should not return it,
        # and even if it did the closed_at check would exclude it.
        old = (
            datetime.datetime.now(datetime.timezone.utc)
            - datetime.timedelta(hours=2)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        calls = _run_main(closed_issues=[_issue(42, state="closed", closed_at=old)])
        self.assertIn("POST", [m for m, _ in calls])

    def test_ignores_closed_prs_with_matching_title(self):
        recent = (
            datetime.datetime.now(datetime.timezone.utc)
            - datetime.timedelta(minutes=5)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        calls = _run_main(
            closed_issues=[_issue(42, state="closed", closed_at=recent, is_pr=True)]
        )
        self.assertIn("POST", [m for m, _ in calls])

    def test_recent_closed_query_uses_since_parameter(self):
        calls = _run_main()
        closed_gets = [url for m, url in calls if m == "GET" and "state=closed" in url]
        self.assertEqual(len(closed_gets), 1)
        self.assertIn("since=", closed_gets[0])
        self.assertIn("labels=loop/code", closed_gets[0])


if __name__ == "__main__":
    unittest.main()
