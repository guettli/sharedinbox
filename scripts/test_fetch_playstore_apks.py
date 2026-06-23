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


class TestListGeneratedApks(unittest.TestCase):
    def test_returns_none_on_404(self):
        """Regression for #668: Play returns 404 until it has finished
        generating split APKs for a freshly uploaded AAB. The helper must
        signal this with ``None`` rather than raising, so callers can fall
        back to an older bundle."""
        session = MagicMock()
        resp = MagicMock(status_code=404)
        session.get.return_value = resp
        self.assertIsNone(
            fetch_playstore_apks._list_generated_apks(session, "pkg", 42)
        )
        resp.raise_for_status.assert_not_called()

    def test_raises_on_other_errors(self):
        from requests.exceptions import HTTPError

        session = MagicMock()
        resp = MagicMock(status_code=500)
        resp.raise_for_status.side_effect = HTTPError("500 Server Error")
        session.get.return_value = resp
        with self.assertRaises(HTTPError):
            fetch_playstore_apks._list_generated_apks(session, "pkg", 42)


class TestListBundles(unittest.TestCase):
    def test_returns_version_codes_descending(self):
        session = MagicMock()
        edit_resp = MagicMock()
        edit_resp.json.return_value = {"id": "edit-1"}
        session.post.return_value = edit_resp
        bundles_resp = MagicMock()
        bundles_resp.json.return_value = {
            "bundles": [
                {"versionCode": 100},
                {"versionCode": 200},
                {"versionCode": 150},
            ]
        }
        session.get.return_value = bundles_resp

        self.assertEqual(
            fetch_playstore_apks._list_bundles(session, "pkg"),
            [200, 150, 100],
        )
        # Must list via an edit and clean it up.
        self.assertIn("/edits/edit-1/bundles", session.get.call_args[0][0])
        session.delete.assert_called_once()


class TestMainFallsBackWhenLatestNotReady(unittest.TestCase):
    """Regression for #668: when Play has not yet generated split APKs for
    the alpha release (the new endpoint 404s), the script must fall back to
    the most recent older bundle whose APKs are available instead of
    aborting the Firebase test."""

    def test_uses_next_older_bundle_when_latest_404s(self):
        with tempfile.TemporaryDirectory() as dest_dir:
            session = MagicMock()
            calls = []

            def list_apks(_session, _package, vc):
                calls.append(vc)
                return None if vc == 200 else {"generatedApks": []}

            with patch.dict(
                os.environ, {"PLAY_STORE_CONFIG_JSON": '{"type":"service_account"}'}
            ), patch.object(sys, "argv", ["fetch_playstore_apks.py", dest_dir]), patch(
                "fetch_playstore_apks.service_account.Credentials.from_service_account_info"
            ), patch(
                "fetch_playstore_apks.AuthorizedSession", return_value=session
            ), patch(
                "fetch_playstore_apks._resolve_version_code", return_value=200
            ), patch(
                "fetch_playstore_apks._list_generated_apks", side_effect=list_apks
            ), patch(
                "fetch_playstore_apks._list_bundles", return_value=[200, 150, 100]
            ), patch(
                "fetch_playstore_apks._enumerate_downloads",
                return_value=[("dl-1", "base-master.apk")],
            ), patch(
                "fetch_playstore_apks._download"
            ):
                fetch_playstore_apks.main()

            self.assertEqual(calls, [200, 150])
            vc_path = Path(dest_dir) / "versionCode"
            self.assertEqual(vc_path.read_text().strip(), "150")

    def test_skips_when_no_bundle_has_generated_apks(self):
        """Regression for #83: when Play has not generated APKs for the latest
        alpha and no older bundle has APKs to fall back to, write a ``.skip``
        sentinel in the dest dir and return cleanly. The daily Firebase CI
        treats ``.skip`` as a transient infrastructure state (Play APK
        generation can take an hour or more after upload) and skips the run
        instead of opening a spurious failure issue."""
        with tempfile.TemporaryDirectory() as dest_dir:
            session = MagicMock()
            with patch.dict(
                os.environ, {"PLAY_STORE_CONFIG_JSON": '{"type":"service_account"}'}
            ), patch.object(sys, "argv", ["fetch_playstore_apks.py", dest_dir]), patch(
                "fetch_playstore_apks.service_account.Credentials.from_service_account_info"
            ), patch(
                "fetch_playstore_apks.AuthorizedSession", return_value=session
            ), patch(
                "fetch_playstore_apks._resolve_version_code", return_value=200
            ), patch(
                "fetch_playstore_apks._list_generated_apks", return_value=None
            ), patch(
                "fetch_playstore_apks._list_bundles", return_value=[200, 150]
            ):
                fetch_playstore_apks.main()

            skip_path = Path(dest_dir) / ".skip"
            vc_path = Path(dest_dir) / "versionCode"
            self.assertTrue(skip_path.is_file(), f"{skip_path} not created")
            self.assertIn("split APKs", skip_path.read_text())
            self.assertFalse(
                vc_path.is_file(),
                "versionCode must not be written when skipping — otherwise the "
                "CI cache would treat the untested versionCode as 'tested'.",
            )

    def test_skip_message_includes_latest_versioncode(self):
        """The skip reason is surfaced as a ``::notice::`` line in the CI log,
        so include the resolved versionCode so the operator sees which build
        Play is still processing."""
        with tempfile.TemporaryDirectory() as dest_dir:
            session = MagicMock()
            with patch.dict(
                os.environ, {"PLAY_STORE_CONFIG_JSON": '{"type":"service_account"}'}
            ), patch.object(sys, "argv", ["fetch_playstore_apks.py", dest_dir]), patch(
                "fetch_playstore_apks.service_account.Credentials.from_service_account_info"
            ), patch(
                "fetch_playstore_apks.AuthorizedSession", return_value=session
            ), patch(
                "fetch_playstore_apks._resolve_version_code", return_value=1782243611
            ), patch(
                "fetch_playstore_apks._list_generated_apks", return_value=None
            ), patch(
                "fetch_playstore_apks._list_bundles", return_value=[1782243611]
            ):
                fetch_playstore_apks.main()

            skip_text = (Path(dest_dir) / ".skip").read_text()
            self.assertIn("1782243611", skip_text)
            self.assertEqual(
                skip_text.count("\n"), 1,
                "skip message must be a single line (plus trailing newline) so "
                "the ::notice:: line stays on one row in the Actions log",
            )


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
