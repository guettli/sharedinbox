#!/usr/bin/env python3
"""Download the Play Store split APKs of the most recent alpha-track release.

Used by Firebase Test Lab CI so we test the exact binary users install from
Play, not a debug build assembled from source. Auth comes from the same
``PLAY_STORE_CONFIG_JSON`` service-account secret already used by
``scripts/deploy_playstore.py``.

The resolved ``versionCode`` is printed to **stdout** (status messages go to
stderr) so callers can capture it via ``$(…)``.

Usage::

    PLAY_STORE_CONFIG_JSON=<sa-json> python3 scripts/fetch_playstore_apks.py <dest-dir>
"""

import json
import os
import sys

from google.auth.transport.requests import AuthorizedSession
from google.oauth2 import service_account

PACKAGE_NAME = "de.sharedinbox.mua"
TRACK = "alpha"
_BASE = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"


def _resolve_version_code(session, package, track):
    """Return the highest versionCode currently published on ``track``.

    Track state is only exposed through the edits API; the non-edit
    ``applications/{package}/tracks/{track}`` URL returns 404 even when the
    track has a live release (see ``verify_playstore_deploy.py`` for the same
    pattern).
    """
    edit_resp = session.post(f"{_BASE}/{package}/edits", json={}, timeout=30)
    edit_resp.raise_for_status()
    edit_id = edit_resp.json()["id"]
    try:
        resp = session.get(
            f"{_BASE}/{package}/edits/{edit_id}/tracks/{track}", timeout=30
        )
        resp.raise_for_status()
        releases = resp.json().get("releases") or []
    finally:
        try:
            session.delete(f"{_BASE}/{package}/edits/{edit_id}", timeout=30)
        except Exception:
            pass
    best = None
    for release in releases:
        for code in release.get("versionCodes") or []:
            n = int(code)
            if best is None or n > best:
                best = n
    if best is None:
        raise RuntimeError(f"No releases found on track '{track}'")
    return best


def _list_generated_apks(session, package, version_code):
    """Return the generatedApks listing for ``version_code``, or ``None`` on 404.

    Play returns 404 until it has finished generating the downloadable split
    APKs for an uploaded AAB. Generation can take an hour or more after the
    AAB upload completes (occasionally much longer), so callers must be
    prepared to fall back to an older bundle whose APKs are already ready.
    """
    url = f"{_BASE}/{package}/generatedApks/{version_code}/downloads"
    resp = session.get(url, timeout=60)
    if resp.status_code == 404:
        return None
    resp.raise_for_status()
    return resp.json()


def _list_bundles(session, package):
    """Return all uploaded bundle versionCodes, newest first.

    Bundles can only be enumerated through the edits API; there is no
    top-level ``applications/{package}/bundles`` resource. Used to fall
    back to an older bundle when ``generatedApks`` 404s for the most
    recent release.
    """
    edit_resp = session.post(f"{_BASE}/{package}/edits", json={}, timeout=30)
    edit_resp.raise_for_status()
    edit_id = edit_resp.json()["id"]
    try:
        resp = session.get(
            f"{_BASE}/{package}/edits/{edit_id}/bundles", timeout=30
        )
        resp.raise_for_status()
        bundles = resp.json().get("bundles") or []
    finally:
        try:
            session.delete(f"{_BASE}/{package}/edits/{edit_id}", timeout=30)
        except Exception:
            pass
    return sorted(
        (int(b["versionCode"]) for b in bundles if "versionCode" in b),
        reverse=True,
    )


def _download(session, package, version_code, download_id, dest):
    url = (
        f"{_BASE}/{package}/generatedApks/{version_code}"
        f"/downloads/{download_id}:download"
    )
    with session.get(url, stream=True, timeout=600) as resp:
        resp.raise_for_status()
        with open(dest, "wb") as out:
            for chunk in resp.iter_content(chunk_size=1 << 20):
                if chunk:
                    out.write(chunk)


def _enumerate_downloads(listing):
    """Return a list of (download_id, filename) pairs from the API payload.

    The base APK is named ``base-master.apk`` so callers can pass it as
    ``--app`` to ``gcloud firebase test android run``. Config splits keep their
    splitId in the filename so duplicate destination paths are impossible.
    """
    generated = listing.get("generatedApks") or []
    if not generated:
        raise RuntimeError("Play API returned no generatedApks group")
    # We sign with a single upload key, so there is only one signing-key group.
    group = generated[0]

    downloads = []
    for split in group.get("generatedSplitApks") or []:
        module = split.get("moduleName") or "base"
        split_id = split.get("splitId")
        # The "master" split has an empty splitId in the API response.
        suffix = split_id if split_id else "master"
        downloads.append((split["downloadId"], f"{module}-{suffix}.apk"))
    for stand in group.get("generatedStandaloneApks") or []:
        variant = stand.get("variantId", "x")
        downloads.append((stand["downloadId"], f"standalone-{variant}.apk"))
    universal = group.get("generatedUniversalApk")
    if universal:
        downloads.append((universal["downloadId"], "universal.apk"))
    if not downloads:
        raise RuntimeError(
            "Play API generatedApks payload contained no downloadable APKs"
        )
    return downloads


def main():
    if len(sys.argv) != 2:
        print("Usage: fetch_playstore_apks.py <dest-dir>", file=sys.stderr)
        sys.exit(2)
    dest_dir = sys.argv[1]
    os.makedirs(dest_dir, exist_ok=True)

    config_json = os.environ.get("PLAY_STORE_CONFIG_JSON")
    if not config_json:
        print(
            "Error: PLAY_STORE_CONFIG_JSON environment variable not set",
            file=sys.stderr,
        )
        sys.exit(1)

    creds = service_account.Credentials.from_service_account_info(
        json.loads(config_json),
        scopes=["https://www.googleapis.com/auth/androidpublisher"],
    )
    session = AuthorizedSession(creds)

    version_code = _resolve_version_code(session, PACKAGE_NAME, TRACK)
    print(f"Resolved {TRACK} versionCode: {version_code}", file=sys.stderr)

    listing = _list_generated_apks(session, PACKAGE_NAME, version_code)
    if listing is None:
        # Play has not yet generated split APKs for the latest release. Fall
        # back to the most recent older bundle whose APKs are available so
        # the Firebase test still has something to crawl.
        print(
            f"Play has not yet generated split APKs for versionCode "
            f"{version_code}; falling back to an older bundle…",
            file=sys.stderr,
        )
        for candidate in _list_bundles(session, PACKAGE_NAME):
            if candidate == version_code:
                continue
            listing = _list_generated_apks(session, PACKAGE_NAME, candidate)
            if listing is not None:
                print(
                    f"Using fallback versionCode {candidate}",
                    file=sys.stderr,
                )
                version_code = candidate
                break
        else:
            # Play retains generatedApks for ~60 days after a bundle's release
            # ends, so when the latest alpha is still processing AND every
            # older bundle has aged past that retention window, no APKs are
            # available anywhere. That is a transient Play state, not a bug
            # in our binary — emit a marker so the shell wrapper can skip
            # the run instead of opening a daily noisy issue.
            marker_msg = (
                "No uploaded bundle has generated APKs available "
                f"(checked versionCode {version_code} plus all older bundles)"
            )
            with open(os.path.join(dest_dir, "no_apks_available"), "w") as f:
                f.write(f"{marker_msg}\n")
            print(marker_msg, file=sys.stderr)
            return
    downloads = _enumerate_downloads(listing)

    for download_id, name in downloads:
        dest = os.path.join(dest_dir, name)
        print(f"Downloading {name}…", file=sys.stderr)
        _download(session, PACKAGE_NAME, version_code, download_id, dest)

    # Also persist the versionCode next to the APKs so callers that cannot
    # capture stdout (e.g. `dagger call --progress=plain ... -o <dir>`) can
    # still recover it.
    with open(os.path.join(dest_dir, "versionCode"), "w") as f:
        f.write(f"{version_code}\n")

    # versionCode on stdout so the caller can do VC=$(fetch_playstore_apks.py …)
    print(version_code)


if __name__ == "__main__":
    main()
