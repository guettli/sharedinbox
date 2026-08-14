#!/usr/bin/env python3
"""Verify android/.../GeneratedPluginRegistrant.java stays in sync with pubspec.lock.

The Android release build (Deploy workflow's smoke-test and server-APK jobs)
runs ``flutter build apk --release --no-pub``. ``--no-pub`` skips ``flutter pub
get``, which is the step that would normally regenerate the registrant, so the
committed GeneratedPluginRegistrant.java is compiled verbatim. If a plugin is
removed from the dependencies but its registration block is left behind, the
release build fails at Java compile time with e.g.::

    GeneratedPluginRegistrant.java:79: error:
    package eu.simonbinder.sqlite3_flutter_libs does not exist

That failure mode is invisible to the fast PR checks (they never build the
release APK) and only surfaces hours later when the scheduled Deploy runs — see
issues #531 and #539. This check closes that gap: it runs on every PR and fails
fast if the committed registrant references a plugin that is no longer in
pubspec.lock.

Each registration block in the generated file names the pub package it belongs
to in its error log line, e.g.::

    Log.e(TAG, "Error registering plugin sqlcipher_flutter_libs, "
             + "eu.simonbinder.sqlite3_flutter_libs.Sqlite3FlutterLibsPlugin", e);

We extract those pub package names and assert every one of them is a package in
pubspec.lock. A missing package means the registration is stale.

Exit status:
  0 — every registered plugin is present in pubspec.lock
  1 — one or more registered plugins are missing (details on stderr)
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REGISTRANT = Path(
    "android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java"
)
PUBSPEC_LOCK = Path("pubspec.lock")

# Matches the pub package name in each block's error log line:
#   Log.e(TAG, "Error registering plugin <name>, <java.class>", e);
_PLUGIN_RE = re.compile(r'Error registering plugin ([A-Za-z0-9_]+),')

# Matches a package entry in pubspec.lock (two-space indented key under
# ``packages:``), e.g. ``  path_provider_android:``.
_LOCK_PACKAGE_RE = re.compile(r'^  ([A-Za-z0-9_]+):$')


def registered_plugins(registrant_text: str) -> list[str]:
    """Return the pub package names registered in the generated registrant."""
    return _PLUGIN_RE.findall(registrant_text)


def locked_packages(lock_text: str) -> set[str]:
    """Return the set of package names resolved in pubspec.lock."""
    return {m.group(1) for m in map(_LOCK_PACKAGE_RE.match, lock_text.splitlines()) if m}


def find_stale(registrant_text: str, lock_text: str) -> list[str]:
    """Return registered plugins that are absent from pubspec.lock."""
    packages = locked_packages(lock_text)
    return [p for p in registered_plugins(registrant_text) if p not in packages]


def main() -> int:
    if not REGISTRANT.exists():
        print(f"ERROR: {REGISTRANT} not found", file=sys.stderr)
        return 1
    if not PUBSPEC_LOCK.exists():
        print(f"ERROR: {PUBSPEC_LOCK} not found", file=sys.stderr)
        return 1

    registrant_text = REGISTRANT.read_text()
    plugins = registered_plugins(registrant_text)
    if not plugins:
        print(f"ERROR: no plugin registrations found in {REGISTRANT}", file=sys.stderr)
        return 1

    stale = find_stale(registrant_text, PUBSPEC_LOCK.read_text())
    if stale:
        print(
            "ERROR: GeneratedPluginRegistrant.java registers plugins that are no "
            "longer in pubspec.lock — the release build (flutter build apk "
            "--no-pub) will fail to compile:",
            file=sys.stderr,
        )
        for p in stale:
            print(f"  - {p}", file=sys.stderr)
        print(
            "Remove the dead registration block(s) from the registrant, or run "
            "`flutter pub get` and commit the regenerated file.",
            file=sys.stderr,
        )
        return 1

    print(f"Android plugin registrant is in sync ({len(plugins)} plugins).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
