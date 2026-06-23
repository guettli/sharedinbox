#!/usr/bin/env python3
"""Tests for pure functions in generate_build_history.py."""
import re
import unittest
from unittest.mock import patch

from generate_build_history import MAX_BUILDS_PER_PLATFORM, parse_builds, render_entries

LINUX_RE = re.compile(
    r"public_html/builds/(\d{4})/(\d{2})/(\d{2})/(sharedinbox-linux-amd64-(.+)\.tar\.gz)$"
)
APK_RE = re.compile(
    r"public_html/builds/(\d{4})/(\d{2})/(\d{2})/(sharedinbox-mua-(.+)\.apk)$"
)


def _fake_commit_info(hash_val: str):
    return (f"feat: {hash_val}", "2025-05-10T12:00:00Z")


class TestParseBuilds(unittest.TestCase):
    def setUp(self):
        patcher = patch("generate_build_history.get_commit_info", side_effect=_fake_commit_info)
        self.mock_commit = patcher.start()
        self.addCleanup(patcher.stop)

    def test_linux_path_parsed(self):
        paths = ["public_html/builds/2025/05/10/sharedinbox-linux-amd64-abc1234.tar.gz"]
        result = parse_builds(paths, LINUX_RE)
        self.assertIn("2025/05/10", result)
        entry = result["2025/05/10"][0]
        self.assertEqual(entry[0], "abc1234")
        self.assertIn("sharedinbox-linux-amd64-abc1234.tar.gz", entry[1])

    def test_apk_path_parsed(self):
        paths = ["public_html/builds/2025/05/11/sharedinbox-mua-def5678.apk"]
        result = parse_builds(paths, APK_RE)
        self.assertIn("2025/05/11", result)
        entry = result["2025/05/11"][0]
        self.assertEqual(entry[0], "def5678")
        self.assertIn("sharedinbox-mua-def5678.apk", entry[1])

    def test_unexpected_path_skipped(self):
        paths = [
            "public_html/builds/2025/05/10/sharedinbox-linux-amd64-abc1234.tar.gz",
            "public_html/builds/bad-path/other.tar.gz",
        ]
        result = parse_builds(paths, LINUX_RE)
        self.assertEqual(len(result), 1)

    def test_multiple_builds_same_day(self):
        paths = [
            "public_html/builds/2025/05/10/sharedinbox-linux-amd64-aaa0001.tar.gz",
            "public_html/builds/2025/05/10/sharedinbox-linux-amd64-bbb0002.tar.gz",
        ]
        result = parse_builds(paths, LINUX_RE)
        self.assertEqual(len(result["2025/05/10"]), 2)

    def test_limited_to_max_builds(self):
        paths = [
            f"public_html/builds/2025/05/{i:02d}/sharedinbox-linux-amd64-hash{i:03d}.tar.gz"
            for i in range(1, MAX_BUILDS_PER_PLATFORM + 5)
        ]
        result = parse_builds(paths, LINUX_RE)
        total = sum(len(v) for v in result.values())
        self.assertEqual(total, MAX_BUILDS_PER_PLATFORM)

    def test_download_url_contains_date_and_filename(self):
        paths = ["public_html/builds/2025/03/15/sharedinbox-linux-amd64-cafebabe.tar.gz"]
        result = parse_builds(paths, LINUX_RE)
        url = result["2025/03/15"][0][1]
        self.assertIn("/2025/03/15/", url)
        self.assertIn("sharedinbox-linux-amd64-cafebabe.tar.gz", url)
        self.assertTrue(url.startswith("https://"))


class TestRenderEntries(unittest.TestCase):
    def _make_entry(self, hash_val="abc1234", url="https://example.com/file.apk",
                    title="feat: something", dt="2025-05-10T12:00:00Z"):
        return (hash_val, url, title, dt)

    def test_output_contains_title_and_link(self):
        entry = self._make_entry()
        out = render_entries([entry], "Download APK")
        self.assertIn("feat: something", out)
        self.assertIn("Download APK", out)
        self.assertIn("abc1234", out)

    def test_commit_url_uses_hash(self):
        entry = self._make_entry(hash_val="deadbeef")
        out = render_entries([entry], "Download")
        self.assertIn("deadbeef", out)
        self.assertIn("github.com/guettli/sharedinbox/commit/", out)

    def test_datetime_shown_when_present(self):
        entry = self._make_entry(dt="2025-05-10T12:00:00Z")
        out = render_entries([entry], "Download")
        self.assertIn("2025-05-10T12:00:00Z", out)

    def test_datetime_omitted_when_empty(self):
        entry = self._make_entry(dt="")
        out = render_entries([entry], "Download")
        self.assertNotIn(" · ", out)

    def test_multiple_entries_all_rendered(self):
        entries = [self._make_entry(hash_val=f"hash{i}", title=f"commit {i}") for i in range(3)]
        out = render_entries(entries, "Download")
        for i in range(3):
            self.assertIn(f"commit {i}", out)


if __name__ == "__main__":
    unittest.main()
