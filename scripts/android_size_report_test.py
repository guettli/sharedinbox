#!/usr/bin/env python3
"""Standalone tests for android_size_report.py (run: python3 scripts/android_size_report_test.py).

No pytest dependency — plain asserts, exits non-zero on the first failure.
"""

import importlib.util
import os
import tempfile
import zipfile

_spec = importlib.util.spec_from_file_location(
    "asr", os.path.join(os.path.dirname(__file__), "android_size_report.py"))
asr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(asr)


def _make_aab(path, entries):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED) as z:
        for name, size in entries.items():
            z.writestr(name, b"\0" * size)


def test_buckets_and_exclusions():
    with tempfile.TemporaryDirectory() as d:
        aab = os.path.join(d, "app.aab")
        _make_aab(aab, {
            "base/manifest/AndroidManifest.xml": 2_000,
            "base/dex/classes.dex": 5_000_000,
            "base/dex/classes2.dex": 1_000_000,
            "base/lib/arm64-v8a/libapp.so": 12_000_000,
            "base/lib/arm64-v8a/libflutter.so": 9_000_000,
            "base/lib/arm64-v8a/libsqlite3.so": 4_000_000,
            # other ABIs must not count toward the arm64 install figure
            "base/lib/armeabi-v7a/libapp.so": 8_000_000,
            "base/lib/x86_64/libapp.so": 13_000_000,
            "base/assets/flutter_assets/fonts/Icons.otf": 1_600_000,
            "base/res/drawable/ic.png": 200_000,
            "base/resources.pb": 100_000,
            # debug symbols are isolated and excluded from the delivered figure
            "BUNDLE-METADATA/com.android.tools.build.debugsymbols/arm64-v8a/x.sym": 40_000_000,
        })
        s = asr.measure(aab)
        assert s["libapp_bytes"] == 12_000_000
        assert s["libflutter_bytes"] == 9_000_000
        assert s["native_other_bytes"] == 4_000_000
        assert s["dex_bytes"] == 6_000_000
        assert s["assets_bytes"] == 1_600_000
        assert s["res_bytes"] == 300_000
        assert s["debug_symbols_bytes"] == 40_000_000
        expected_install = (2_000 + 6_000_000 + 12_000_000 + 9_000_000 + 4_000_000
                            + 1_600_000 + 200_000 + 100_000)
        assert s["install_arm64_bytes"] == expected_install, s["install_arm64_bytes"]


def test_append_writes_header_once_and_keeps_column_order():
    with tempfile.TemporaryDirectory() as d:
        aab = os.path.join(d, "app.aab")
        _make_aab(aab, {"base/lib/arm64-v8a/libapp.so": 2_097_152})  # 2 MiB
        hist = os.path.join(d, "hist.tsv")
        row = asr.build_row(aab, git_hash="abc1234", version_name="0.1.1",
                            version_code="1700000000", flutter="3.47.7",
                            date_utc="2026-10-23 16:00")
        asr.append_row(hist, row)
        asr.append_row(hist, row)
        lines = open(hist, encoding="utf-8").read().splitlines()
        assert lines[0] == "\t".join(asr.COLUMNS)
        assert len(lines) == 3  # header + two rows
        cols = lines[1].split("\t")
        assert cols[asr.COLUMNS.index("git_hash")] == "abc1234"
        assert cols[asr.COLUMNS.index("install_mb")] == "2.0"
        assert cols[asr.COLUMNS.index("libapp_bytes")] == "2097152"


def main():
    test_buckets_and_exclusions()
    test_append_writes_header_once_and_keeps_column_order()
    print("all android_size_report tests passed")


if __name__ == "__main__":
    main()
