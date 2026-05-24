#!/usr/bin/env python3
"""Tests for deploy_playstore.py."""
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, call, patch

sys.path.insert(0, str(Path(__file__).parent))

import deploy_playstore


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
    def _run_main(self, fake_config):
        mock_service = MagicMock()
        mock_edits = mock_service.edits.return_value
        mock_edits.insert.return_value.execute.return_value = {"id": "edit-42"}
        mock_edits.bundles.return_value.upload.return_value.execute.return_value = {
            "versionCode": 7
        }
        mock_edits.tracks.return_value.update.return_value.execute.return_value = {}
        mock_edits.commit.return_value.execute.return_value = {}

        with patch.dict(os.environ, {"PLAY_STORE_CONFIG_JSON": fake_config}):
            with patch("deploy_playstore.os.path.exists", return_value=True):
                with patch("deploy_playstore.service_account.Credentials.from_service_account_info"):
                    with patch("deploy_playstore.google_auth_httplib2.AuthorizedHttp"):
                        with patch("deploy_playstore.build", return_value=mock_service):
                            with patch("deploy_playstore.MediaFileUpload"):
                                deploy_playstore.main()

        return mock_edits

    def test_insert_called_with_num_retries(self):
        edits = self._run_main('{"type":"service_account"}')
        edits.insert.return_value.execute.assert_called_once_with(num_retries=3)

    def test_bundle_upload_called_with_num_retries(self):
        edits = self._run_main('{"type":"service_account"}')
        edits.bundles.return_value.upload.return_value.execute.assert_called_once_with(num_retries=3)

    def test_tracks_update_called_with_num_retries(self):
        edits = self._run_main('{"type":"service_account"}')
        edits.tracks.return_value.update.return_value.execute.assert_called_once_with(num_retries=3)

    def test_commit_called_with_num_retries(self):
        edits = self._run_main('{"type":"service_account"}')
        edits.commit.return_value.execute.assert_called_once_with(num_retries=3)

    def test_authorized_http_uses_timeout(self):
        fake_config = '{"type":"service_account"}'
        with patch.dict(os.environ, {"PLAY_STORE_CONFIG_JSON": fake_config}):
            with patch("deploy_playstore.os.path.exists", return_value=True):
                with patch("deploy_playstore.service_account.Credentials.from_service_account_info"):
                    with patch("deploy_playstore.httplib2.Http") as mock_http_cls:
                        with patch("deploy_playstore.google_auth_httplib2.AuthorizedHttp") as mock_auth:
                            mock_service = MagicMock()
                            mock_edits = mock_service.edits.return_value
                            mock_edits.insert.return_value.execute.return_value = {"id": "e1"}
                            mock_edits.bundles.return_value.upload.return_value.execute.return_value = {
                                "versionCode": 1
                            }
                            mock_edits.tracks.return_value.update.return_value.execute.return_value = {}
                            mock_edits.commit.return_value.execute.return_value = {}
                            with patch("deploy_playstore.build", return_value=mock_service):
                                with patch("deploy_playstore.MediaFileUpload"):
                                    deploy_playstore.main()

        mock_http_cls.assert_called_once_with(timeout=deploy_playstore._TIMEOUT)


def _redirect_error():
    import httplib2
    return httplib2.error.RedirectMissingLocation("redirect missing", {}, b"")


class TestUploadRetry(unittest.TestCase):
    def _make_mock_service(self, upload_side_effects):
        mock_service = MagicMock()
        mock_edits = mock_service.edits.return_value
        mock_edits.insert.return_value.execute.return_value = {"id": "edit-1"}
        mock_edits.bundles.return_value.upload.return_value.execute.side_effect = (
            upload_side_effects
        )
        mock_edits.tracks.return_value.update.return_value.execute.return_value = {}
        mock_edits.commit.return_value.execute.return_value = {}
        return mock_service, mock_edits

    def _run_with_service(self, mock_service):
        fake_config = '{"type":"service_account"}'
        with patch.dict(os.environ, {"PLAY_STORE_CONFIG_JSON": fake_config}):
            with patch("deploy_playstore.os.path.exists", return_value=True):
                with patch("deploy_playstore.service_account.Credentials.from_service_account_info"):
                    with patch("deploy_playstore.google_auth_httplib2.AuthorizedHttp"):
                        with patch("deploy_playstore.build", return_value=mock_service):
                            with patch("deploy_playstore.MediaFileUpload"):
                                with patch("deploy_playstore.time.sleep"):
                                    deploy_playstore.main()

    def test_succeeds_on_first_attempt(self):
        mock_service, mock_edits = self._make_mock_service([{"versionCode": 5}])
        self._run_with_service(mock_service)
        mock_edits.bundles.return_value.upload.return_value.execute.assert_called_once_with(
            num_retries=3
        )

    def test_retries_once_on_redirect_error_then_succeeds(self):
        mock_service, mock_edits = self._make_mock_service(
            [_redirect_error(), {"versionCode": 9}]
        )

        with patch.dict(os.environ, {"PLAY_STORE_CONFIG_JSON": '{"type":"service_account"}'}):
            with patch("deploy_playstore.os.path.exists", return_value=True):
                with patch("deploy_playstore.service_account.Credentials.from_service_account_info"):
                    with patch("deploy_playstore.google_auth_httplib2.AuthorizedHttp"):
                        with patch("deploy_playstore.build", return_value=mock_service):
                            with patch("deploy_playstore.MediaFileUpload") as mock_media_cls:
                                with patch("deploy_playstore.time.sleep") as mock_sleep:
                                    deploy_playstore.main()

        self.assertEqual(
            mock_edits.bundles.return_value.upload.return_value.execute.call_count, 2
        )
        mock_sleep.assert_called_once_with(10)
        self.assertEqual(mock_media_cls.call_count, 2)

    def test_raises_after_all_attempts_exhausted(self):
        mock_service, _ = self._make_mock_service(
            [_redirect_error(), _redirect_error(), _redirect_error()]
        )

        with patch.dict(os.environ, {"PLAY_STORE_CONFIG_JSON": '{"type":"service_account"}'}):
            with patch("deploy_playstore.os.path.exists", return_value=True):
                with patch("deploy_playstore.service_account.Credentials.from_service_account_info"):
                    with patch("deploy_playstore.google_auth_httplib2.AuthorizedHttp"):
                        with patch("deploy_playstore.build", return_value=mock_service):
                            with patch("deploy_playstore.MediaFileUpload"):
                                with patch("deploy_playstore.time.sleep"):
                                    with self.assertRaises(RuntimeError) as ctx:
                                        deploy_playstore.main()

        self.assertIn(
            str(deploy_playstore._MAX_UPLOAD_ATTEMPTS), str(ctx.exception)
        )

    def test_backoff_delays_are_10s_then_20s(self):
        mock_service, _ = self._make_mock_service(
            [_redirect_error(), _redirect_error(), {"versionCode": 3}]
        )

        with patch.dict(os.environ, {"PLAY_STORE_CONFIG_JSON": '{"type":"service_account"}'}):
            with patch("deploy_playstore.os.path.exists", return_value=True):
                with patch("deploy_playstore.service_account.Credentials.from_service_account_info"):
                    with patch("deploy_playstore.google_auth_httplib2.AuthorizedHttp"):
                        with patch("deploy_playstore.build", return_value=mock_service):
                            with patch("deploy_playstore.MediaFileUpload"):
                                with patch("deploy_playstore.time.sleep") as mock_sleep:
                                    deploy_playstore.main()

        mock_sleep.assert_has_calls([call(10), call(20)])

    def test_fresh_media_upload_created_on_each_attempt(self):
        mock_service, _ = self._make_mock_service(
            [_redirect_error(), {"versionCode": 2}]
        )

        with patch.dict(os.environ, {"PLAY_STORE_CONFIG_JSON": '{"type":"service_account"}'}):
            with patch("deploy_playstore.os.path.exists", return_value=True):
                with patch("deploy_playstore.service_account.Credentials.from_service_account_info"):
                    with patch("deploy_playstore.google_auth_httplib2.AuthorizedHttp"):
                        with patch("deploy_playstore.build", return_value=mock_service):
                            with patch("deploy_playstore.MediaFileUpload") as mock_media_cls:
                                with patch("deploy_playstore.time.sleep"):
                                    deploy_playstore.main()

        self.assertEqual(mock_media_cls.call_count, 2)


if __name__ == "__main__":
    unittest.main()
