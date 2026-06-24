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
        """Play returns 404 until it has finished generating split APKs for a
        freshly uploaded AAB. The helper signals this with ``None`` so the
        caller can skip the run cleanly — there is no fallback to older
        bundles (we only ever exercise the binary users actually install)."""
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


def _patches(dest_dir, *, version_code, list_apks, env=None):
    """Common patch stack used by the main() tests.

    Stubs out the network-y bits (auth, session) so the test exercises only
    the policy in ``main()`` (skip vs. download)."""
    env_vars = {"PLAY_STORE_CONFIG_JSON": '{"type":"service_account"}'}
    if env:
        env_vars.update(env)
    return [
        patch.dict(os.environ, env_vars, clear=False),
        patch.object(sys, "argv", ["fetch_playstore_apks.py", dest_dir]),
        patch(
            "fetch_playstore_apks.service_account.Credentials.from_service_account_info"
        ),
        patch("fetch_playstore_apks.AuthorizedSession", return_value=MagicMock()),
        patch(
            "fetch_playstore_apks._resolve_version_code", return_value=version_code
        ),
        patch(
            "fetch_playstore_apks._list_generated_apks",
            return_value=list_apks,
        ),
        patch(
            "fetch_playstore_apks._enumerate_downloads",
            return_value=[("dl-1", "base-master.apk")],
        ),
        patch("fetch_playstore_apks._download"),
    ]


def _with_patches(patches, fn):
    if not patches:
        return fn()
    with patches[0]:
        return _with_patches(patches[1:], fn)


class TestMainSkipsWhenPlayNotReady(unittest.TestCase):
    """Regression for #83: when Play has not generated split APKs for the
    latest alpha, write a ``.skip`` sentinel in the dest dir and return
    cleanly. The shell wrapper treats ``.skip`` as a transient state (Play
    APK generation can take an hour or more after upload) and skips the run
    instead of opening a spurious failure issue. No fallback to older
    bundles — the next hourly cron will pick it up."""

    def test_skips_when_latest_has_no_apks(self):
        with tempfile.TemporaryDirectory() as dest_dir:
            _with_patches(
                _patches(dest_dir, version_code=200, list_apks=None),
                fetch_playstore_apks.main,
            )

            skip_path = Path(dest_dir) / ".skip"
            vc_path = Path(dest_dir) / "versionCode"
            self.assertTrue(skip_path.is_file(), f"{skip_path} not created")
            self.assertIn("split APKs", skip_path.read_text())
            self.assertIn("200", skip_path.read_text())
            self.assertFalse(
                vc_path.is_file(),
                "versionCode must not be written when skipping — otherwise the "
                "CI cache would treat the untested versionCode as 'tested'.",
            )

    def test_skip_message_is_single_line(self):
        """The skip reason is surfaced as a ``::notice::`` line in the CI log,
        so it must be a single line so the notice stays on one row."""
        with tempfile.TemporaryDirectory() as dest_dir:
            _with_patches(
                _patches(dest_dir, version_code=1782243611, list_apks=None),
                fetch_playstore_apks.main,
            )

            skip_text = (Path(dest_dir) / ".skip").read_text()
            self.assertIn("1782243611", skip_text)
            self.assertEqual(
                skip_text.count("\n"), 1,
                "skip message must be a single line (plus trailing newline)",
            )


class TestMainSkipsWhenAlreadyTested(unittest.TestCase):
    """Skip Firebase Test Lab when the latest alpha matches the versionCode
    of the last green run — the same binary doesn't need to be exercised
    twice. The shell wrapper passes the cached versionCode via the
    ``ALREADY_TESTED_VERSION_CODE`` env var; the script writes a ``.skip``
    sentinel and downloads nothing."""

    def test_skips_when_latest_matches_already_tested_env(self):
        with tempfile.TemporaryDirectory() as dest_dir:
            _with_patches(
                _patches(
                    dest_dir,
                    version_code=200,
                    list_apks={"generatedApks": []},
                    env={"ALREADY_TESTED_VERSION_CODE": "200"},
                ),
                fetch_playstore_apks.main,
            )

            skip_path = Path(dest_dir) / ".skip"
            vc_path = Path(dest_dir) / "versionCode"
            self.assertTrue(skip_path.is_file(), f"{skip_path} not created")
            self.assertIn("already tested", skip_path.read_text())
            self.assertIn("200", skip_path.read_text())
            self.assertFalse(
                vc_path.is_file(),
                "versionCode is only written when the binary is actually being "
                "exercised — the cache must not move forward on a skip.",
            )

    def test_runs_when_latest_differs_from_already_tested(self):
        with tempfile.TemporaryDirectory() as dest_dir:
            _with_patches(
                _patches(
                    dest_dir,
                    version_code=200,
                    list_apks={"generatedApks": []},
                    env={"ALREADY_TESTED_VERSION_CODE": "150"},
                ),
                fetch_playstore_apks.main,
            )

            skip_path = Path(dest_dir) / ".skip"
            vc_path = Path(dest_dir) / "versionCode"
            self.assertFalse(skip_path.is_file(), "must not skip when versions differ")
            self.assertTrue(vc_path.is_file())
            self.assertEqual(vc_path.read_text().strip(), "200")

    def test_runs_when_already_tested_env_is_empty(self):
        """An empty ``ALREADY_TESTED_VERSION_CODE`` env var means the cache
        is missing (first run, or token couldn't read it). Treat it as
        "nothing tested yet" — exercise the latest alpha."""
        with tempfile.TemporaryDirectory() as dest_dir:
            _with_patches(
                _patches(
                    dest_dir,
                    version_code=200,
                    list_apks={"generatedApks": []},
                    env={"ALREADY_TESTED_VERSION_CODE": ""},
                ),
                fetch_playstore_apks.main,
            )
            self.assertFalse((Path(dest_dir) / ".skip").is_file())
            self.assertTrue((Path(dest_dir) / "versionCode").is_file())


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
            _with_patches(
                _patches(dest_dir, version_code=42, list_apks={}),
                fetch_playstore_apks.main,
            )

            vc_path = Path(dest_dir) / "versionCode"
            self.assertTrue(vc_path.is_file(), f"{vc_path} not created")
            self.assertEqual(vc_path.read_text().strip(), "42")


if __name__ == "__main__":
    unittest.main()
