#!/usr/bin/env python3
"""Tests for deploy_playstore.py."""
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import MagicMock, call, patch

sys.path.insert(0, str(Path(__file__).parent))

import deploy_playstore


def _make_session(
    edit_id="edit-42",
    version_code=7,
    upload_side_effects=None,
):
    """Return a mock AuthorizedSession with sensible defaults."""
    session = MagicMock()

    # POST /edits → create edit
    edit_resp = MagicMock()
    edit_resp.json.return_value = {"id": edit_id}
    session.post.return_value = edit_resp

    # POST resumable-init → Location header
    init_resp = MagicMock()
    init_resp.headers = {"Location": "https://upload.example.com/session"}

    # PUT upload → bundle JSON
    upload_resp = MagicMock()
    upload_resp.json.return_value = {"versionCode": version_code}

    if upload_side_effects is not None:
        # Use side_effect list: first call is edit create, rest are upload inits
        # We override the PUT side effects via _upload_aab_resumable mock instead
        pass

    return session, init_resp, upload_resp


class TestMainEnvChecks(unittest.TestCase):
    def test_missing_env_exits(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(SystemExit) as ctx:
                deploy_playstore.main()
        self.assertEqual(ctx.exception.code, 1)

    def test_missing_aab_exits(self):
        fake_config = '{"type": "service_account"}'
        with patch.dict(os.environ, {"PLAY_STORE_CONFIG_JSON": fake_config}):
            with patch("deploy_playstore.os.path.exists", return_value=False):
                with self.assertRaises(SystemExit) as ctx:
                    deploy_playstore.main()
        self.assertEqual(ctx.exception.code, 1)


class TestMainHappyPath(unittest.TestCase):
    def _run_main(self, fake_config='{"type":"service_account"}'):
        mock_session = MagicMock()
        # POST for edit create and commit
        post_responses = [
            MagicMock(**{"json.return_value": {"id": "edit-42"}}),  # create edit
            MagicMock(),  # commit
        ]
        mock_session.post.side_effect = post_responses
        # PUT for track update
        mock_session.put.return_value = MagicMock()

        with patch.dict(os.environ, {"PLAY_STORE_CONFIG_JSON": fake_config}):
            with patch("deploy_playstore.os.path.exists", return_value=True):
                with patch("deploy_playstore.service_account.Credentials.from_service_account_info"):
                    with patch("deploy_playstore.AuthorizedSession", return_value=mock_session):
                        with patch(
                            "deploy_playstore._upload_aab_resumable",
                            return_value={"versionCode": 7},
                        ):
                            deploy_playstore.main()

        return mock_session

    def test_creates_edit(self):
        session = self._run_main()
        create_call = session.post.call_args_list[0]
        self.assertIn("/edits", create_call[0][0])

    def test_commits_edit(self):
        session = self._run_main()
        commit_call = session.post.call_args_list[1]
        self.assertIn(":commit", commit_call[0][0])

    def test_updates_track(self):
        session = self._run_main()
        track_call = session.put.call_args_list[0]
        self.assertIn("/tracks/", track_call[0][0])

    def test_updates_all_configured_tracks(self):
        session = self._run_main()
        track_urls = [c[0][0] for c in session.put.call_args_list]
        self.assertEqual(len(track_urls), len(deploy_playstore.TRACKS))
        for track in deploy_playstore.TRACKS:
            self.assertTrue(
                any(url.endswith(f"/tracks/{track}") for url in track_urls),
                f"no PUT to /tracks/{track} (saw {track_urls})",
            )

    def test_commits_after_all_track_updates(self):
        session = self._run_main()
        # All PUTs are track updates; commit is the second POST after the
        # initial edit-create. Verify PUTs precede the commit by checking
        # mock_calls order across both methods.
        method_order = [c[0] for c in session.method_calls]
        commit_idx = next(
            i for i, m in enumerate(method_order)
            if m == "post" and ":commit" in session.method_calls[i][1][0]
        )
        put_indices = [i for i, m in enumerate(method_order) if m == "put"]
        self.assertEqual(len(put_indices), len(deploy_playstore.TRACKS))
        self.assertTrue(all(i < commit_idx for i in put_indices))


class TestUploadRetry(unittest.TestCase):
    def _run_main(self, upload_side_effects, sleep_mock=None):
        mock_session = MagicMock()
        post_responses = [
            MagicMock(**{"json.return_value": {"id": "edit-1"}}),
            MagicMock(),
        ]
        mock_session.post.side_effect = post_responses
        mock_session.put.return_value = MagicMock()

        patches = [
            patch.dict(os.environ, {"PLAY_STORE_CONFIG_JSON": '{"type":"service_account"}'}),
            patch("deploy_playstore.os.path.exists", return_value=True),
            patch("deploy_playstore.service_account.Credentials.from_service_account_info"),
            patch("deploy_playstore.AuthorizedSession", return_value=mock_session),
            patch("deploy_playstore._upload_aab_resumable", side_effect=upload_side_effects),
            patch("deploy_playstore.time.sleep"),
        ]
        for p in patches:
            p.start()
        try:
            deploy_playstore.main()
        finally:
            for p in patches:
                p.stop()

    def test_succeeds_on_first_attempt(self):
        with patch("deploy_playstore._upload_aab_resumable", return_value={"versionCode": 5}) as mock_upload:
            with patch.dict(os.environ, {"PLAY_STORE_CONFIG_JSON": '{"type":"service_account"}'}):
                with patch("deploy_playstore.os.path.exists", return_value=True):
                    with patch("deploy_playstore.service_account.Credentials.from_service_account_info"):
                        mock_session = MagicMock()
                        mock_session.post.side_effect = [
                            MagicMock(**{"json.return_value": {"id": "e1"}}),
                            MagicMock(),
                        ]
                        mock_session.put.return_value = MagicMock()
                        with patch("deploy_playstore.AuthorizedSession", return_value=mock_session):
                            deploy_playstore.main()
            mock_upload.assert_called_once()

    def test_retries_once_on_error_then_succeeds(self):
        self._run_main([ValueError("transient"), {"versionCode": 9}])

    def test_raises_after_all_attempts_exhausted(self):
        with self.assertRaises(RuntimeError) as ctx:
            self._run_main([ValueError("err"), ValueError("err"), ValueError("err")])
        self.assertIn(str(deploy_playstore._MAX_UPLOAD_ATTEMPTS), str(ctx.exception))

    def test_backoff_delays_are_10s_then_20s(self):
        mock_session = MagicMock()
        mock_session.post.side_effect = [
            MagicMock(**{"json.return_value": {"id": "e1"}}),
            MagicMock(),
        ]
        mock_session.put.return_value = MagicMock()

        with patch.dict(os.environ, {"PLAY_STORE_CONFIG_JSON": '{"type":"service_account"}'}):
            with patch("deploy_playstore.os.path.exists", return_value=True):
                with patch("deploy_playstore.service_account.Credentials.from_service_account_info"):
                    with patch("deploy_playstore.AuthorizedSession", return_value=mock_session):
                        with patch(
                            "deploy_playstore._upload_aab_resumable",
                            side_effect=[ValueError("e"), ValueError("e"), {"versionCode": 3}],
                        ):
                            with patch("deploy_playstore.time.sleep") as mock_sleep:
                                deploy_playstore.main()

        mock_sleep.assert_has_calls([call(10), call(20)])


class TestUploadAabResumable(unittest.TestCase):
    def test_initiates_and_uploads(self):
        mock_session = MagicMock()
        init_resp = MagicMock()
        init_resp.headers = {"Location": "https://upload.example.com/sess"}
        upload_resp = MagicMock()
        upload_resp.json.return_value = {"versionCode": 42}
        mock_session.post.return_value = init_resp
        mock_session.put.return_value = upload_resp

        import tempfile
        with tempfile.NamedTemporaryFile(delete=False) as f:
            f.write(b"fake-aab-content")
            aab_path = f.name

        try:
            result = deploy_playstore._upload_aab_resumable(
                mock_session, "com.example.app", "edit-1", aab_path
            )
        finally:
            os.unlink(aab_path)

        self.assertEqual(result["versionCode"], 42)
        mock_session.post.assert_called_once()
        mock_session.put.assert_called_once()
        put_call = mock_session.put.call_args
        self.assertEqual(put_call[0][0], "https://upload.example.com/sess")


if __name__ == "__main__":
    unittest.main()
