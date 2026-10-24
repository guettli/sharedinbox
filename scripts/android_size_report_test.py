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


def test_download_column_from_bundletool_and_unknown():
    with tempfile.TemporaryDirectory() as d:
        aab = os.path.join(d, "app.aab")
        _make_aab(aab, {"base/lib/arm64-v8a/libapp.so": 2_097_152})  # 2 MiB
        # with a real download byte count
        r = asr.build_row(aab, git_hash="abc1234", version_name="0.1.1",
                          version_code="1700000000", flutter="3.47.7",
                          download_bytes="15728640", date_utc="2026-10-24 10:00")
        assert r["download_bytes"] == "15728640"
        assert r["download_mb"] == "15.0"
        assert r["install_mb"] == "2.0"
        # with download unavailable
        r2 = asr.build_row(aab, git_hash="abc1234", version_name="0.1.1",
                           version_code="unknown", flutter="3.47.7",
                           download_bytes="unknown", date_utc="2026-10-24 10:00")
        assert r2["download_bytes"] == "unknown"
        assert r2["download_mb"] == "unknown"


def test_append_writes_header_once_and_keeps_column_order():
    with tempfile.TemporaryDirectory() as d:
        aab = os.path.join(d, "app.aab")
        _make_aab(aab, {"base/lib/arm64-v8a/libapp.so": 2_097_152})
        hist = os.path.join(d, "hist.tsv")
        row = asr.build_row(aab, git_hash="abc1234", version_name="0.1.1",
                            version_code="1700000000", flutter="3.47.7",
                            download_bytes="15728640", date_utc="2026-10-24 10:00")
        asr.append_row(hist, row)
        asr.append_row(hist, row)
        lines = open(hist, encoding="utf-8").read().splitlines()
        assert lines[0] == "\t".join(asr.COLUMNS)
        assert len(lines) == 3  # header + two rows
        cols = lines[1].split("\t")
        assert cols[asr.COLUMNS.index("git_hash")] == "abc1234"
        assert cols[asr.COLUMNS.index("download_mb")] == "15.0"
        assert cols[asr.COLUMNS.index("libapp_bytes")] == "2097152"


def test_append_migrates_an_older_schema_by_name():
    """A file written under the pre-download schema must upgrade: old rows kept,
    new columns filled with 'unknown', header rewritten — no data loss."""
    with tempfile.TemporaryDirectory() as d:
        hist = os.path.join(d, "hist.tsv")
        # an older header WITHOUT the download columns, in a different order
        old_cols = [
            "date_utc", "git_hash", "version_name", "version_code", "flutter",
            "install_mb", "install_arm64_bytes", "libapp_bytes", "libflutter_bytes",
            "native_other_bytes", "dex_bytes", "assets_bytes", "res_bytes",
            "aab_file_bytes", "debug_symbols_bytes",
        ]
        old_vals = {
            "date_utc": "2026-10-23 17:03", "git_hash": "8c9baba", "version_name": "0.1.1",
            "version_code": "unknown", "flutter": "3.47.7", "install_mb": "39.7",
            "install_arm64_bytes": "41582422", "libapp_bytes": "13435784",
            "libflutter_bytes": "11747864", "native_other_bytes": "10452664",
            "dex_bytes": "3864220", "assets_bytes": "1072620", "res_bytes": "549723",
            "aab_file_bytes": "171802643", "debug_symbols_bytes": "481399348",
        }
        with open(hist, "w", encoding="utf-8") as f:
            f.write("\t".join(old_cols) + "\n")
            f.write("\t".join(old_vals[c] for c in old_cols) + "\n")

        aab = os.path.join(d, "app.aab")
        _make_aab(aab, {"base/lib/arm64-v8a/libapp.so": 1_048_576})
        new_row = asr.build_row(aab, git_hash="deadbee", version_name="0.1.1",
                                version_code="unknown", flutter="3.47.8",
                                download_bytes="15000000", date_utc="2026-10-24 12:00")
        asr.append_row(hist, new_row)

        lines = open(hist, encoding="utf-8").read().splitlines()
        assert lines[0] == "\t".join(asr.COLUMNS), "header not migrated"
        assert len(lines) == 3, f"expected header + migrated old + new, got {len(lines)}"
        migrated = dict(zip(asr.COLUMNS, lines[1].split("\t")))
        # preserved old data
        assert migrated["git_hash"] == "8c9baba"
        assert migrated["install_arm64_bytes"] == "41582422"
        assert migrated["install_mb"] == "39.7"
        # new columns filled with 'unknown' for the pre-download row
        assert migrated["download_bytes"] == "unknown"
        assert migrated["download_mb"] == "unknown"
        # the appended new row carries the real download
        newest = dict(zip(asr.COLUMNS, lines[2].split("\t")))
        assert newest["git_hash"] == "deadbee"
        assert newest["download_mb"] == "14.3"


def main():
    test_buckets_and_exclusions()
    test_download_column_from_bundletool_and_unknown()
    test_append_writes_header_once_and_keeps_column_order()
    test_append_migrates_an_older_schema_by_name()
    print("all android_size_report tests passed")


if __name__ == "__main__":
    main()
