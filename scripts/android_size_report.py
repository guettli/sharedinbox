#!/usr/bin/env python3
"""Report the Android app size from a built App Bundle (.aab), and optionally
append one row to a tab-separated size-history file.

Why this exists: the Play Store download size looked like it jumped with no
obvious cause and we had no record of what it used to be (issue: Android size
history). This tool turns every published AAB into a durable, diffable row so
the *next* size change points at its own cause instead of needing archaeology.

Two sizes are recorded, because they are different numbers and both matter:

  * download (`--download-bytes`) — the real Play-delivered size, the figure the
    Play listing shows a user. It can't be derived from the AAB zip alone; it
    comes from `bundletool get-size` (the Dagger `AndroidDownloadSizeCsv`
    function), passed in here. "unknown" when that step was unavailable.

  * install-arm64 — the uncompressed bytes an arm64-v8a device receives: the
    base module's manifest + dex + arm64 libs + assets + res, read straight from
    the AAB zip. An on-device *install-size proxy*: it trends with the download
    number but reads larger — Play serves these compressed and drops unused
    densities/languages. Other ABIs are excluded (an AAB ships only the device's
    ABI), and so is BUNDLE-METADATA/ (the debugSymbolLevel=FULL native symbols
    Play strips before download — counting them would be the classic red
    herring).

  * a per-component breakdown — libapp.so (Dart code, AOT), libflutter.so
    (engine), other native (SQLCipher/OpenSSL, BoringSSL, …), dex, assets, res —
    so a jump names its own cause.

  * aab-file and debug-symbols — reported separately so the inflated .aab upload
    size is never mistaken for either delivered figure.

Version/commit facts (git hash, versionName, versionCode, Flutter) are passed in
rather than parsed from the binary manifest proto, which keeps this robust.
"""

from __future__ import annotations

import argparse
import os
import sys
import zipfile
from datetime import datetime, timezone

ARCH = "arm64-v8a"

# Tab-separated columns, in order. Bytes are exact (diffable); the *_mb columns
# are the at-a-glance headlines. append_row() migrates an older file to this set
# by column *name*, so columns may be reordered/added without breaking history.
COLUMNS = [
    "date_utc",
    "git_hash",
    "version_name",
    "version_code",
    "flutter",
    "download_mb",          # the number Play shows the user (from bundletool)
    "download_bytes",
    "install_mb",           # uncompressed on-device install proxy (from the AAB)
    "install_arm64_bytes",
    "libapp_bytes",
    "libflutter_bytes",
    "native_other_bytes",
    "dex_bytes",
    "assets_bytes",
    "res_bytes",
    "aab_file_bytes",
    "debug_symbols_bytes",
]


def _is_debug_symbols(name: str) -> bool:
    return name.startswith("BUNDLE-METADATA/") and "debugsymbol" in name.lower()


def measure(aab_path: str) -> dict[str, int]:
    """Return a dict of byte sizes computed from the AAB zip entries."""
    sizes = {
        "install_arm64_bytes": 0,
        "libapp_bytes": 0,
        "libflutter_bytes": 0,
        "native_other_bytes": 0,
        "dex_bytes": 0,
        "assets_bytes": 0,
        "res_bytes": 0,
        "debug_symbols_bytes": 0,
    }
    lib_prefix = f"base/lib/{ARCH}/"
    with zipfile.ZipFile(aab_path) as z:
        for info in z.infolist():
            name = info.filename
            n = info.file_size  # uncompressed — what lands on the device
            if _is_debug_symbols(name):
                sizes["debug_symbols_bytes"] += n
                continue
            if not name.startswith("base/"):
                # other feature modules (none today) — ignore for the arm64 base figure
                continue
            # Only the device's own ABI is delivered; skip the other ABIs.
            if name.startswith("base/lib/") and not name.startswith(lib_prefix):
                continue

            # Everything left is part of what an arm64 device receives.
            sizes["install_arm64_bytes"] += n

            if name.startswith(lib_prefix):
                base = os.path.basename(name)
                if base == "libapp.so":
                    sizes["libapp_bytes"] += n
                elif base == "libflutter.so":
                    sizes["libflutter_bytes"] += n
                else:
                    sizes["native_other_bytes"] += n
            elif name.startswith("base/dex/"):
                sizes["dex_bytes"] += n
            elif name.startswith("base/assets/"):
                sizes["assets_bytes"] += n
            elif name.startswith("base/res/") or name == "base/resources.pb":
                sizes["res_bytes"] += n
    return sizes


def _mb_str(byte_str: str) -> str:
    """'12345678' -> '11.8'; 'unknown'/'' -> 'unknown'."""
    try:
        return f"{int(byte_str) / 1_048_576:.1f}"
    except (TypeError, ValueError):
        return "unknown"


def build_row(aab_path: str, *, git_hash: str, version_name: str,
              version_code: str, flutter: str, download_bytes: str = "unknown",
              date_utc: str | None = None) -> dict[str, str]:
    sizes = measure(aab_path)
    install = sizes["install_arm64_bytes"]
    row = {
        "date_utc": date_utc or datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M"),
        "git_hash": git_hash,
        "version_name": version_name,
        "version_code": version_code,
        "flutter": flutter,
        "download_mb": _mb_str(download_bytes),
        "download_bytes": download_bytes if download_bytes else "unknown",
        "install_mb": f"{install / 1_048_576:.1f}",
        "install_arm64_bytes": str(install),
        "libapp_bytes": str(sizes["libapp_bytes"]),
        "libflutter_bytes": str(sizes["libflutter_bytes"]),
        "native_other_bytes": str(sizes["native_other_bytes"]),
        "dex_bytes": str(sizes["dex_bytes"]),
        "assets_bytes": str(sizes["assets_bytes"]),
        "res_bytes": str(sizes["res_bytes"]),
        "aab_file_bytes": str(os.path.getsize(aab_path)),
        "debug_symbols_bytes": str(sizes["debug_symbols_bytes"]),
    }
    return row


def append_row(history_path: str, row: dict[str, str]) -> None:
    """Append one row. Writes the header if the file is new/empty, and migrates
    an older file whose header differs from COLUMNS (by column *name*, so rows
    written under an earlier schema are preserved and padded with 'unknown')."""
    if (not os.path.exists(history_path)) or os.path.getsize(history_path) == 0:
        with open(history_path, "w", encoding="utf-8") as f:
            f.write("\t".join(COLUMNS) + "\n")
            f.write("\t".join(row[c] for c in COLUMNS) + "\n")
        return

    with open(history_path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    header = lines[0].split("\t") if lines else []

    if header == COLUMNS:
        with open(history_path, "a", encoding="utf-8") as f:
            f.write("\t".join(row[c] for c in COLUMNS) + "\n")
        return

    # Schema changed: rewrite with the new header, remapping old rows by name.
    old_rows = [dict(zip(header, ln.split("\t"))) for ln in lines[1:] if ln.strip()]
    with open(history_path, "w", encoding="utf-8") as f:
        f.write("\t".join(COLUMNS) + "\n")
        for r in old_rows:
            f.write("\t".join(r.get(c, "unknown") for c in COLUMNS) + "\n")
        f.write("\t".join(row[c] for c in COLUMNS) + "\n")


def _mb(n: int) -> str:
    return f"{n / 1_048_576:.1f} MB"


def print_breakdown(row: dict[str, str]) -> None:
    g = lambda k: int(row[k])
    dl = row["download_mb"]
    print(f"Android app size  —  {row['git_hash']}  v{row['version_name']} "
          f"(versionCode {row['version_code']}, Flutter {row['flutter']})")
    print(f"  download size (Play delivered): "
          f"{dl + ' MB' if dl != 'unknown' else 'unknown'}")
    print(f"  install size (arm64-v8a, uncompressed): {_mb(g('install_arm64_bytes'))}")
    print(f"    libapp.so    (Dart code) : {_mb(g('libapp_bytes'))}")
    print(f"    libflutter.so (engine)   : {_mb(g('libflutter_bytes'))}")
    print(f"    other native (SQLCipher…): {_mb(g('native_other_bytes'))}")
    print(f"    dex          (Kotlin/Java): {_mb(g('dex_bytes'))}")
    print(f"    assets                   : {_mb(g('assets_bytes'))}")
    print(f"    res + resources.pb       : {_mb(g('res_bytes'))}")
    print(f"  .aab file (incl. debug symbols): {_mb(g('aab_file_bytes'))} "
          f"(of which native debug symbols, NOT delivered: {_mb(g('debug_symbols_bytes'))})")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("aab", help="path to app-release.aab")
    ap.add_argument("--git-hash", default=os.environ.get("GIT_HASH", "unknown"))
    ap.add_argument("--version-name", default=os.environ.get("VERSION_NAME", "unknown"))
    ap.add_argument("--version-code", default=os.environ.get("VERSION_CODE", "unknown"))
    ap.add_argument("--flutter", default=os.environ.get("FLUTTER_VERSION", "unknown"))
    ap.add_argument("--download-bytes", default=os.environ.get("DOWNLOAD_BYTES", "unknown"),
                    help="real Play download size in bytes (from bundletool); 'unknown' if unavailable")
    ap.add_argument("--date", default=None, help="override date_utc (YYYY-MM-DD HH:MM)")
    ap.add_argument("--append", metavar="TSV",
                    help="append the row to this history file (writes header if new; migrates an older schema)")
    ap.add_argument("--tsv", action="store_true", help="print the raw TSV row instead of the breakdown")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.aab):
        print(f"error: AAB not found: {args.aab}", file=sys.stderr)
        return 2

    row = build_row(args.aab, git_hash=args.git_hash, version_name=args.version_name,
                    version_code=args.version_code, flutter=args.flutter,
                    download_bytes=args.download_bytes, date_utc=args.date)
    if args.append:
        append_row(args.append, row)
        print(f"appended size row to {args.append}", file=sys.stderr)
    if args.tsv:
        print("\t".join(row[c] for c in COLUMNS))
    else:
        print_breakdown(row)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
