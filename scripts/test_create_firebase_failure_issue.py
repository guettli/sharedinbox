#!/usr/bin/env python3
"""Tests for create_firebase_failure_issue.py."""
import json
import os
import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).parent))

import create_firebase_failure_issue as cfi

TITLE = "Firebase Tests failed — find root cause and fix"


def _now_utc_iso(delta=timedelta(0)):
    return (datetime.now(timezone.utc) + delta).strftime("%Y-%m-%dT%H:%M:%SZ")


def _urlopen_responder(routes):
    """Build a fake urllib.request.urlopen that returns JSON payloads by URL.

    ``routes`` maps URL substring → (list of payloads to return in order).
    Each payload becomes the ``.read()`` result of the returned context
    manager.
    """
    remaining = {k: list(v) for k, v in routes.items()}

    def fake_urlopen(req, *args, **kwargs):
        url = req.full_url
        for pattern, payloads in remaining.items():
            if pattern in url and payloads:
                payload = payloads.pop(0)
                cm = MagicMock()
                cm.__enter__ = lambda self, payload=payload: MagicMock(
                    read=MagicMock(return_value=json.dumps(payload).encode())
                )
                cm.__exit__ = lambda self, *a: False
                return cm
        raise AssertionError(f"unexpected request to {url}\nleft={remaining}")

    return fake_urlopen


class _MainTest(unittest.TestCase):
    def setUp(self):
        self.env_patch = patch.dict(
            os.environ,
            {
                "GITHUB_TOKEN": "t",
                "GITHUB_API_URL": "https://api.github.com",
                "GITHUB_REPOSITORY": "o/r",
                "RUN_URL": "https://example/run/1",
            },
            clear=False,
        )
        self.env_patch.start()

    def tearDown(self):
        self.env_patch.stop()


class TestDedupOpenIssue(_MainTest):
    """Regression for #404: the old filter `labels=loop/code` missed issues
    whose label had progressed to loop/code-in-process, loop/code-ci-pending
    or loop/code-done. Filtering by the stable `automerge` label catches all
    lifecycle stages.
    """

    def _run_with_open_issue(self, labels):
        open_payload = [{
            "number": 402,
            "title": TITLE,
            "labels": [{"name": name} for name in labels],
        }]
        routes = {
            "/issues?state=open&labels=automerge": [open_payload],
        }
        with patch("urllib.request.urlopen", side_effect=_urlopen_responder(routes)):
            return cfi.main()

    def test_skips_when_open_issue_has_loop_code(self):
        self.assertEqual(self._run_with_open_issue(["loop/code", "automerge"]), 0)

    def test_skips_when_open_issue_has_loop_code_in_process(self):
        self.assertEqual(
            self._run_with_open_issue(["loop/code-in-process", "automerge"]), 0
        )

    def test_skips_when_open_issue_has_loop_code_ci_pending(self):
        self.assertEqual(
            self._run_with_open_issue(["loop/code-ci-pending", "automerge"]), 0
        )


class TestDedupRecentlyClosed(_MainTest):
    """Regression for #404: when a fix has just landed and the same-titled
    issue was closed, a stale in-flight failing run should not file a new
    issue immediately.
    """

    def _run(self, closed_delta):
        closed_payload = [{
            "number": 402,
            "title": TITLE,
            "closed_at": _now_utc_iso(closed_delta),
        }]
        routes = {
            "/issues?state=open&labels=automerge": [[]],
            "/issues?state=closed&labels=automerge": [closed_payload],
        }
        # api_post must not be called on the skip path — leave it unpatched
        # so any unexpected POST raises loudly.
        with patch("urllib.request.urlopen", side_effect=_urlopen_responder(routes)):
            return cfi.main()

    def test_skips_when_similar_closed_within_window(self):
        # Closed 20 minutes ago (matches the #404 race timing).
        self.assertEqual(self._run(-timedelta(minutes=20)), 0)

    def test_creates_when_similar_closed_outside_window(self):
        # Closed 2 hours ago — long enough that this is a genuine repeat.
        closed_payload = [{
            "number": 402,
            "title": TITLE,
            "closed_at": _now_utc_iso(-timedelta(hours=2)),
        }]
        created_payload = {"number": 405, "html_url": "https://ex/405"}
        routes = {
            "/issues?state=open&labels=automerge": [[]],
            "/issues?state=closed&labels=automerge": [closed_payload],
            "/issues": [created_payload],  # matched last; POST target
        }
        with patch("urllib.request.urlopen", side_effect=_urlopen_responder(routes)):
            self.assertEqual(cfi.main(), 0)


class TestCreatesWhenNoDuplicates(_MainTest):
    def test_creates_new_issue(self):
        created_payload = {"number": 500, "html_url": "https://ex/500"}
        routes = {
            "/issues?state=open&labels=automerge": [[]],
            "/issues?state=closed&labels=automerge": [[]],
            "/issues": [created_payload],
        }
        with patch("urllib.request.urlopen", side_effect=_urlopen_responder(routes)):
            self.assertEqual(cfi.main(), 0)


class TestUnrelatedTitleIgnored(_MainTest):
    """The list endpoint returns all issues carrying the `automerge` label;
    unrelated titles must not trip the dedup.
    """

    def test_unrelated_open_issue_does_not_block(self):
        open_payload = [
            {"number": 999, "title": "Something else", "labels": []},
        ]
        created_payload = {"number": 501, "html_url": "https://ex/501"}
        routes = {
            "/issues?state=open&labels=automerge": [open_payload],
            "/issues?state=closed&labels=automerge": [[]],
            "/issues": [created_payload],
        }
        with patch("urllib.request.urlopen", side_effect=_urlopen_responder(routes)):
            self.assertEqual(cfi.main(), 0)


if __name__ == "__main__":
    unittest.main()
