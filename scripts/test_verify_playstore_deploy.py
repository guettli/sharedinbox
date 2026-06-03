#!/usr/bin/env python3
"""Tests for verify_playstore_deploy.py."""
import os
import sys
import time
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).parent))

import verify_playstore_deploy


def _make_session(version_code, track="internal"):
    """Return a mock AuthorizedSession with the given version code on the track."""
    session = MagicMock()

    edit_resp = MagicMock()
    edit_resp.json.return_value = {"id": "edit-99"}
    session.post.return_value = edit_resp

    track_resp = MagicMock()
    track_resp.json.return_value = {
        "releases": [{"versionCodes": [str(version_code)], "status": "completed"}]
    }
    session.get.return_value = track_resp
    session.delete.return_value = MagicMock()

    return session


class TestMissingEnv(unittest.TestCase):
    def test_missing_env_exits(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(SystemExit) as ctx:
                verify_playstore_deploy.main()
        self.assertEqual(ctx.exception.code, 1)


class TestRecentDeploy(unittest.TestCase):
    def _run(self, version_code):
        session = _make_session(version_code)
        with patch.dict(os.environ, {"PLAY_STORE_CONFIG_JSON": '{"type":"service_account"}'}):
            with patch("verify_playstore_deploy.service_account.Credentials.from_service_account_info"):
                with patch("verify_playstore_deploy.AuthorizedSession", return_value=session):
                    verify_playstore_deploy.main()

    def test_recent_version_code_passes(self):
        # Version code is Unix timestamp — a very recent one should pass.
        recent_vc = int(time.time()) - 60  # 1 minute ago
        self._run(recent_vc)

    def test_old_version_code_fails(self):
        old_vc = int(time.time()) - 7200  # 2 hours ago
        with self.assertRaises(SystemExit) as ctx:
            self._run(old_vc)
        self.assertEqual(ctx.exception.code, 1)


class TestEmptyTrack(unittest.TestCase):
    def _run_empty(self, releases):
        session = MagicMock()
        session.post.return_value = MagicMock(**{"json.return_value": {"id": "edit-1"}})
        session.get.return_value = MagicMock(**{"json.return_value": {"releases": releases}})
        session.delete.return_value = MagicMock()

        with patch.dict(os.environ, {"PLAY_STORE_CONFIG_JSON": '{"type":"service_account"}'}):
            with patch("verify_playstore_deploy.service_account.Credentials.from_service_account_info"):
                with patch("verify_playstore_deploy.AuthorizedSession", return_value=session):
                    verify_playstore_deploy.main()

    def test_no_releases_exits(self):
        with self.assertRaises(SystemExit) as ctx:
            self._run_empty([])
        self.assertEqual(ctx.exception.code, 1)

    def test_release_with_no_version_codes_exits(self):
        with self.assertRaises(SystemExit) as ctx:
            self._run_empty([{"status": "completed", "versionCodes": []}])
        self.assertEqual(ctx.exception.code, 1)


if __name__ == "__main__":
    unittest.main()
