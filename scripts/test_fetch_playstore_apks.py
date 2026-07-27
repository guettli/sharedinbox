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
        freshly uploaded AAB. The helper signals this with ``None`` so
        :func:`_poll_generated_apks` can retry until Play catches up."""
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


class TestPollGeneratedApks(unittest.TestCase):
    """Polling replaces the old ``.skip`` fallback: we wait inside the run
    instead of deferring to the next hourly cron, and fail loudly when Play
    never catches up so a stuck deploy surfaces as a red build."""

    def test_returns_first_non_none_listing(self):
        session = MagicMock()
        listing = {"generatedApks": [{"key": "v"}]}
        with patch(
            "fetch_playstore_apks._list_generated_apks",
            side_effect=[None, None, listing],
        ):
            with patch("fetch_playstore_apks.time.sleep"):
                result = fetch_playstore_apks._poll_generated_apks(
                    session, "pkg", 42
                )
        self.assertIs(result, listing)

    def test_raises_timeout_after_deadline(self):
        session = MagicMock()
        with patch(
            "fetch_playstore_apks._list_generated_apks", return_value=None
        ):
            # time.monotonic advances past the deadline on the second call so
            # the loop exits on the very next iteration.
            with patch(
                "fetch_playstore_apks.time.monotonic",
                side_effect=[0.0, 10_000_000.0, 10_000_001.0],
            ):
                with patch("fetch_playstore_apks.time.sleep"):
                    with self.assertRaises(TimeoutError) as ctx:
                        fetch_playstore_apks._poll_generated_apks(
                            session, "pkg", 42
                        )
        self.assertIn("42", str(ctx.exception))


def _patches(dest_dir, *, version_code, list_apks, env=None):
    """Common patch stack used by the main() tests.

    Stubs out the network-y bits (auth, session) so the test exercises only
    the policy in ``main()``.

    ``list_apks`` may be either a listing (returned by ``_poll_generated_apks``)
    or an exception instance to raise from the poller — the latter drives
    the "Play never generated APKs" failure path.
    """
    env_vars = {"PLAY_STORE_CONFIG_JSON": '{"type":"service_account"}'}
    if env:
        env_vars.update(env)
    if isinstance(list_apks, BaseException):
        poll_kwargs = {"side_effect": list_apks}
    else:
        poll_kwargs = {"return_value": list_apks}
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
            "fetch_playstore_apks._poll_generated_apks",
            **poll_kwargs,
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


class TestMainWritesPendingMarkerWhenPlayNotReady(unittest.TestCase):
    """When Play has not finished generating split APKs within the poll
    window, the script writes a ``PENDING`` marker (and a ``versionCode``)
    and exits 0 so the wrapper can skip the Firebase Test Lab attempt
    without filing a failure issue (see #414). The next scheduled run
    retries. Any other error still propagates."""

    def test_writes_pending_marker_on_poll_timeout(self):
        with tempfile.TemporaryDirectory() as dest_dir:
            _with_patches(
                _patches(
                    dest_dir,
                    version_code=200,
                    list_apks=TimeoutError(
                        "Play has not generated split APKs for versionCode "
                        "200 within 3600s"
                    ),
                ),
                fetch_playstore_apks.main,
            )

            pending_path = Path(dest_dir) / "PENDING"
            self.assertTrue(
                pending_path.is_file(),
                "PENDING marker must be written when Play is still generating",
            )
            self.assertEqual(pending_path.read_text().strip(), "200")

            vc_path = Path(dest_dir) / "versionCode"
            self.assertTrue(
                vc_path.is_file(),
                "versionCode must also be written so the wrapper can log it",
            )
            self.assertEqual(vc_path.read_text().strip(), "200")

    def test_other_errors_still_propagate(self):
        """A generic error (auth, Play API 5xx, …) must NOT be swallowed —
        the PENDING skip is narrow to the Play-still-generating case."""
        with tempfile.TemporaryDirectory() as dest_dir:
            with self.assertRaises(RuntimeError):
                _with_patches(
                    _patches(
                        dest_dir,
                        version_code=200,
                        list_apks=RuntimeError("Play API 500"),
                    ),
                    fetch_playstore_apks.main,
                )

            self.assertFalse(
                (Path(dest_dir) / "PENDING").is_file(),
                "PENDING marker must not be written for non-timeout errors",
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
            _with_patches(
                _patches(dest_dir, version_code=42, list_apks={}),
                fetch_playstore_apks.main,
            )

            vc_path = Path(dest_dir) / "versionCode"
            self.assertTrue(vc_path.is_file(), f"{vc_path} not created")
            self.assertEqual(vc_path.read_text().strip(), "42")


if __name__ == "__main__":
    unittest.main()
