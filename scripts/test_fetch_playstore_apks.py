#!/usr/bin/env python3
"""Tests for fetch_playstore_apks.py."""
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

sys.path.insert(0, str(Path(__file__).parent))

import fetch_playstore_apks


class TestResolveVersionCode(unittest.TestCase):
    def _session_with_releases(self, releases):
        session = MagicMock()
        edit_resp = MagicMock()
        edit_resp.json.return_value = {"id": "edit-1"}
        session.post.return_value = edit_resp
        track_resp = MagicMock()
        track_resp.json.return_value = {"releases": releases}
        session.get.return_value = track_resp
        return session

    def test_returns_highest_version_code_across_releases(self):
        session = self._session_with_releases(
            [
                {"versionCodes": ["100", "120"]},
                {"versionCodes": ["110"]},
            ]
        )
        self.assertEqual(
            fetch_playstore_apks._resolve_version_code(session, "pkg", "alpha"),
            120,
        )

    def test_raises_when_no_releases(self):
        session = self._session_with_releases([])
        with self.assertRaises(RuntimeError):
            fetch_playstore_apks._resolve_version_code(session, "pkg", "alpha")

    def test_reads_track_via_edit_and_discards_edit(self):
        """Regression for #666: the non-edit track URL returns 404, so we must
        open an edit, read the track within it, and discard the edit."""
        session = self._session_with_releases([{"versionCodes": ["42"]}])
        fetch_playstore_apks._resolve_version_code(session, "pkg", "alpha")
        post_url = session.post.call_args[0][0]
        get_url = session.get.call_args[0][0]
        delete_url = session.delete.call_args[0][0]
        self.assertTrue(post_url.endswith("/applications/pkg/edits"))
        self.assertIn("/edits/edit-1/tracks/alpha", get_url)
        self.assertTrue(delete_url.endswith("/edits/edit-1"))


class TestEnumerateDownloads(unittest.TestCase):
    def test_master_split_named_base_master(self):
        listing = {
            "generatedApks": [
                {
                    "generatedSplitApks": [
                        {"downloadId": "d-master", "splitId": "", "moduleName": "base"},
                    ],
                }
            ]
        }
        downloads = fetch_playstore_apks._enumerate_downloads(listing)
        self.assertIn(("d-master", "base-master.apk"), downloads)

    def test_raises_when_empty(self):
        with self.assertRaises(RuntimeError):
            fetch_playstore_apks._enumerate_downloads({"generatedApks": []})


class TestMainWritesVersionCodeFile(unittest.TestCase):
    """Regression: the runner has no way to capture stdout when callers invoke
    the script via ``dagger call --progress=plain ... -o <dir>``. The script must also persist
    the resolved versionCode to ``<dest_dir>/versionCode`` so those callers
    can recover it."""

    def test_writes_versioncode_file(self):
        with tempfile.TemporaryDirectory() as dest_dir:
            session = MagicMock()

            with patch.dict(
                os.environ, {"PLAY_STORE_CONFIG_JSON": '{"type":"service_account"}'}
            ), patch.object(sys, "argv", ["fetch_playstore_apks.py", dest_dir]), patch(
                "fetch_playstore_apks.service_account.Credentials.from_service_account_info"
            ), patch(
                "fetch_playstore_apks.AuthorizedSession", return_value=session
            ), patch(
                "fetch_playstore_apks._resolve_version_code", return_value=42
            ), patch(
                "fetch_playstore_apks._list_generated_apks", return_value={}
            ), patch(
                "fetch_playstore_apks._enumerate_downloads",
                return_value=[("dl-1", "base-master.apk")],
            ), patch(
                "fetch_playstore_apks._download"
            ):
                fetch_playstore_apks.main()

            vc_path = Path(dest_dir) / "versionCode"
            self.assertTrue(vc_path.is_file(), f"{vc_path} not created")
            self.assertEqual(vc_path.read_text().strip(), "42")


if __name__ == "__main__":
    unittest.main()
