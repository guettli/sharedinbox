#!/usr/bin/env python3
"""Download the Play Store split APKs of the most recent alpha-track release.

Used by Firebase Test Lab CI so we test the exact binary users install from
Play, not a debug build assembled from source. Auth comes from the same
``PLAY_STORE_CONFIG_JSON`` service-account secret already used by
``scripts/deploy_playstore.py``.

The resolved ``versionCode`` is printed to **stdout** (status messages go to
stderr) so callers can capture it via ``$(…)``.

When Play has not finished generating split APKs within this attempt's short
poll window, the script writes a ``PENDING`` marker file to ``<dest-dir>``
(alongside a ``versionCode`` file) and exits 0. The wrapper
(``scripts/run_firebase_test.sh``) reads the marker and retries the fetch —
each attempt is a fresh, short-lived process so no single run idles long
enough for the Dagger engine to reclaim its snapshot (see #432). Every other
failure mode still exits non-zero so real problems stay visible.

Usage::

    PLAY_STORE_CONFIG_JSON=<sa-json> python3 scripts/fetch_playstore_apks.py <dest-dir>
"""

import json
import os
import sys
import time

from google.auth.transport.requests import AuthorizedSession
from google.oauth2 import service_account

PACKAGE_NAME = "de.sharedinbox.mua"
TRACK = "alpha"
_BASE = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"

# How long a *single* fetch attempt polls for Play to finish generating split
# APKs before giving up and dropping a PENDING marker. Generation typically
# takes minutes but occasionally an hour or more after an AAB upload (see #402,
# #409). This is kept deliberately SHORT: the fetch runs inside a Dagger exec,
# and an exec that idles for the full generation window is long enough for the
# Dagger/buildkit engine to garbage-collect its snapshot — which made both the
# marker writes (FileNotFoundError) and the final ``Directory.export`` ("commit
# output … snapshot does not exist") fail, turning a benign Play-side delay
# into a red build and a spurious "Firebase Tests failed" issue (see #422, #424,
# #425, #432). The long-horizon waiting now lives in the bash wrapper
# (scripts/run_firebase_test.sh), which retries this short fetch across *fresh*
# execs until Play catches up, so no single exec idles long enough to be
# reclaimed. The wrapper's per-attempt timeout must stay ≥ this + margin — see
# the guard there. Overridable via env vars for testing.
_POLL_TIMEOUT_SECONDS = int(os.environ.get("PLAY_APKS_POLL_TIMEOUT_SECONDS", "300"))
_POLL_INTERVAL_SECONDS = int(os.environ.get("PLAY_APKS_POLL_INTERVAL_SECONDS", "60"))

# Play only generates downloadable split APKs for a release it is actually
# serving. A "draft" release (uploaded but never rolled out) never gets a
# generatedApks listing, so resolving to its versionCode makes every fetch poll
# in vain and the Firebase run skip forever — exactly what kept alpha
# versionCode 1785101151 stuck for days (see #432). We therefore ignore
# definitively non-serving statuses when picking the versionCode. Only these
# two are excluded; any other or absent status is treated as serving so an
# unexpected API value never silently drops a real release.
_NON_SERVING_RELEASE_STATUSES = frozenset({"draft", "statusUnspecified"})


def _serves_apks(release):
    """Whether Play serves downloadable APKs for ``release``.

    Only a definitively non-serving status (``draft``, ``statusUnspecified``)
    is excluded; any other or absent status is treated as serving so an
    unexpected API value never silently drops a real release.
    """
    return release.get("status") not in _NON_SERVING_RELEASE_STATUSES


def _highest_version_code(releases):
    """Return the highest versionCode across ``releases``, or ``None``."""
    best = None
    for release in releases:
        for code in release.get("versionCodes") or []:
            n = int(code)
            if best is None or n > best:
                best = n
    return best


def _resolve_version_code(session, package, track):
    """Return the highest *serving* versionCode currently published on ``track``.

    Track state is only exposed through the edits API; the non-edit
    ``applications/{package}/tracks/{track}`` URL returns 404 even when the
    track has a live release (see ``verify_playstore_deploy.py`` for the same
    pattern).

    Releases Play is not serving (drafts) are skipped: Play never generates
    downloadable split APKs for them, so picking one makes the fetch poll
    forever (see #432). If no serving release exists we fall back to the raw
    maximum so a served-but-genuinely-stuck version still surfaces (and skips
    via PENDING) rather than erroring.
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
    best = _highest_version_code(r for r in releases if _serves_apks(r))
    if best is None:
        best = _highest_version_code(releases)
    if best is None:
        raise RuntimeError(f"No releases found on track '{track}'")
    return best


def _list_generated_apks(session, package, version_code):
    """Return the generatedApks listing for ``version_code``, or ``None`` on 404.

    Play returns 404 until it has finished generating the downloadable split
    APKs for an uploaded AAB. Callers poll on ``None`` — the wait is bounded
    by :func:`_poll_generated_apks`.
    """
    url = f"{_BASE}/{package}/generatedApks/{version_code}/downloads"
    resp = session.get(url, timeout=60)
    if resp.status_code == 404:
        return None
    resp.raise_for_status()
    return resp.json()


def _poll_generated_apks(session, package, version_code):
    """Poll :func:`_list_generated_apks` until Play returns a listing.

    Fails loudly with :class:`TimeoutError` once ``_POLL_TIMEOUT_SECONDS``
    has elapsed. The generation delay is deterministic-ish (usually minutes,
    occasionally longer) so waiting inside a single run is cheaper than
    letting the next hourly cron pick it up.
    """
    deadline = time.monotonic() + _POLL_TIMEOUT_SECONDS
    while True:
        listing = _list_generated_apks(session, package, version_code)
        if listing is not None:
            return listing
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(
                f"Play has not generated split APKs for versionCode "
                f"{version_code} within {_POLL_TIMEOUT_SECONDS}s"
            )
        sleep_for = min(_POLL_INTERVAL_SECONDS, max(1, int(remaining)))
        print(
            f"Play has not generated split APKs for versionCode "
            f"{version_code} yet — retrying in {sleep_for}s "
            f"({int(remaining)}s left)",
            file=sys.stderr,
        )
        time.sleep(sleep_for)


def _write_dest_file(dest_dir, name, contents):
    """Write ``contents`` to ``<dest_dir>/<name>``, (re)creating ``dest_dir``.

    The Play-still-generating skip can idle for well over an hour (see #409,
    #411) and the long exec's ephemeral ``/tmp`` gets reclaimed underneath us,
    so ``dest_dir`` may be gone — or vanish *again* between two consecutive
    writes — by the time we drop the marker. Re-creating it immediately before
    each write keeps the skip graceful instead of crashing with
    FileNotFoundError and filing a spurious "Firebase Tests failed" issue
    (see #422, #424).
    """
    os.makedirs(dest_dir, exist_ok=True)
    with open(os.path.join(dest_dir, name), "w") as f:
        f.write(contents)


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

    try:
        listing = _poll_generated_apks(session, PACKAGE_NAME, version_code)
    except TimeoutError as exc:
        # Play-side split APK generation is asynchronous and, in practice, can
        # stall for many hours (see #402, #414). Treat "Play still generating"
        # as a skip rather than a hard failure: emit a PENDING marker so the
        # wrapper (scripts/run_firebase_test.sh) can exit 0 without filing a
        # "Firebase Tests failed" issue, and rely on the next scheduled run
        # to retry. Any other error (auth, network, Play API 5xx) still
        # propagates and fails loudly.
        print(f"[fetch_playstore_apks] {exc}", file=sys.stderr)
        # ``dest_dir`` was created at startup, but the poll above can run for
        # well over an hour (see #409, #411). By the time it gives up the
        # directory may be gone — the long idle exec's ephemeral /tmp gets
        # reclaimed underneath us — so writing the marker crashes with
        # FileNotFoundError. That turns a benign Play-side delay into a red
        # build and a spurious "Firebase Tests failed" issue (see #422, #424).
        # ``_write_dest_file`` re-creates the directory before each write so
        # the skip stays graceful even if /tmp is reclaimed again between them.
        _write_dest_file(dest_dir, "PENDING", f"{version_code}\n")
        _write_dest_file(dest_dir, "versionCode", f"{version_code}\n")
        print(version_code)
        return

    downloads = _enumerate_downloads(listing)

    # The poll above can run for well over an hour (see #409, #411, #422). By
    # the time it returns a listing the directory created at startup may be
    # gone — the long idle exec's ephemeral /tmp gets reclaimed underneath us —
    # so the first _download() (or the versionCode write below) would crash
    # with FileNotFoundError. Unlike the timeout skip that only drops a marker,
    # this path is a hard failure with no PENDING marker, so the crash turns a
    # transient reclaim into a red build and a spurious "Firebase Tests failed"
    # issue (see #425). Re-create the directory so the download stays graceful.
    os.makedirs(dest_dir, exist_ok=True)

    for download_id, name in downloads:
        dest = os.path.join(dest_dir, name)
        print(f"Downloading {name}…", file=sys.stderr)
        _download(session, PACKAGE_NAME, version_code, download_id, dest)

    # Also persist the versionCode next to the APKs so callers that cannot
    # capture stdout (e.g. `dagger call --progress=plain ... -o <dir>`) can
    # still recover it.
    _write_dest_file(dest_dir, "versionCode", f"{version_code}\n")

    # versionCode on stdout so the caller can do VC=$(fetch_playstore_apks.py …)
    print(version_code)


if __name__ == "__main__":
    main()
