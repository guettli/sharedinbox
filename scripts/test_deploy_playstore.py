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


if __name__ == "__main__":
    unittest.main()
