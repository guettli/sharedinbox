#!/usr/bin/env python3
"""Upload an Android App Bundle to the Google Play Store closed-testing (alpha) track."""

import json
import os
import sys
import time

from google.auth.transport.requests import AuthorizedSession
from google.oauth2 import service_account

PACKAGE_NAME = "de.sharedinbox.mua"
AAB_PATH = "build/app/outputs/bundle/release/app-release.aab"
TRACKS = ("alpha",)
_BASE = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
_UPLOAD_BASE = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
_MAX_UPLOAD_ATTEMPTS = 3
# How many times to start over with a FRESH edit after Play threw ours away.
# The Play Developer API allows exactly one live edit per application and
# `edits.insert` silently DELETES the existing one -- so any other process that
# opens an edit while we are busy kills ours, and we only find out when the next
# request into it is rejected (see #907). The AAB PUT alone takes ~2m20s, and
# the Firebase Tests workflow opens an edit every 60s while it waits for Play to
# generate split APKs, so the collision is routine rather than exotic. Nothing
# is wrong with the bundle when it happens: the whole edit simply has to be
# redone from a new one.
_MAX_EDIT_ATTEMPTS = 3
# Play's wording for exactly that, answered as 400 FAILED_PRECONDITION.
_EDIT_DELETED_MESSAGE = "this edit has been deleted"
# Env var pointing at the R8 mapping file (build/app/outputs/mapping/release/mapping.txt).
# CI (ci/main.go UploadToPlayStore) sets this. Mandatory: uploading a release
# without a matching mapping file breaks Play Console's stack-trace
# deobfuscation, so the script refuses to deploy when it is missing.
_MAPPING_PATH_ENV = "MAPPING_TXT_PATH"


def _raise_for_status(resp, what):
    """`requests`' own raise_for_status() reports the status line and nothing
    else, so a Play API rejection arrives as a bare "400 Client Error: Bad
    Request for url: ..." -- while the actual reason, which Google DOES send as
    a JSON body, is discarded.

    That is the difference between a one-line diagnosis and guesswork: a failed
    deploy on 2026-09-26 produced three identical 400s with no stated cause, and
    the only way to learn why was to change this file. Include the body.
    """
    try:
        resp.raise_for_status()
    except Exception as exc:
        body = (resp.text or "").strip()
        if len(body) > 2000:
            body = body[:2000] + "… (truncated)"
        raise RuntimeError(
            f"{what} failed: {exc}\nPlay API response body: {body or '(empty)'}"
        ) from exc


def _play_response(exc):
    """The Play API response behind ``exc``, however deeply the retry wrappers
    have nested it with ``raise ... from``.

    Returns ``None`` when the failure never got as far as a response -- a
    connection reset, a timeout, a DNS error.
    """
    seen = set()
    while exc is not None and id(exc) not in seen:
        seen.add(id(exc))
        resp = getattr(exc, "response", None)
        if resp is not None:
            return resp
        exc = getattr(exc, "__cause__", None)
    return None


def _is_retryable(exc):
    """Whether re-uploading the same bytes could plausibly succeed.

    A 4xx is the server saying the REQUEST is wrong -- a bad bundle, a reused
    version code, a revoked credential. Re-sending it unchanged cannot fix that,
    and retrying only buries the real error under two more copies of itself and
    30s of sleeps, which is exactly how the 2026-09-26 failure came to look like
    a flake. Retry transport faults and 5xx; also 408/429, which are explicit
    "try again" signals.

    A deleted edit is a 4xx too, and re-sending into it is just as futile --
    but the deploy as a whole is still retryable from a fresh edit, which
    :func:`main` does around this loop.
    """
    resp = _play_response(exc)
    if resp is None:
        return True  # connection reset, timeout, DNS -- worth another go
    return resp.status_code >= 500 or resp.status_code in (408, 429)


def _is_edit_deleted(exc):
    """Whether Play rejected the request because our edit no longer exists.

    This is not a fault of ours: `edits.insert` deletes the app's existing edit,
    so a concurrent Play API client (the Firebase Tests workflow opens an edit
    per poll to read the alpha track) silently invalidates the edit this deploy
    is uploading into, and the rejection arrives on our next request (see #907).
    Matching on Play's message rather than the status alone keeps a genuine
    400 -- a bad bundle, a reused version code -- failing loudly.
    """
    resp = _play_response(exc)
    if resp is None:
        return False
    return _EDIT_DELETED_MESSAGE in (getattr(resp, "text", "") or "").lower()


def _upload_aab_resumable(session, package, edit_id, aab_path):
    """Upload AAB using the Google resumable upload protocol."""
    file_size = os.path.getsize(aab_path)
    init_url = f"{_UPLOAD_BASE}/{package}/edits/{edit_id}/bundles"

    # Step 1: initiate the resumable upload session
    init_resp = session.post(
        init_url,
        params={"uploadType": "resumable"},
        headers={
            "X-Upload-Content-Type": "application/octet-stream",
            "X-Upload-Content-Length": str(file_size),
            "Content-Length": "0",
        },
        timeout=60,
    )
    _raise_for_status(init_resp, "initiating the resumable upload session")
    upload_url = init_resp.headers["Location"]

    # Step 2: upload the file in a single PUT to the session URI
    with open(aab_path, "rb") as f:
        upload_resp = session.put(
            upload_url,
            data=f,
            headers={
                "Content-Type": "application/octet-stream",
                "Content-Length": str(file_size),
            },
            timeout=600,
        )
    _raise_for_status(upload_resp, "uploading the AAB")
    return upload_resp.json()


def _upload_deobfuscation_file(session, package, edit_id, version_code, mapping_path):
    """Upload an R8/proguard mapping file as the proguard deobfuscation file
    for the bundle just uploaded (identified by ``version_code``).

    Uses the simple media upload form documented at
    https://developers.google.com/android-publisher/api-ref/rest/v3/edits.deobfuscationfiles/upload.
    """
    with open(mapping_path, "rb") as f:
        data = f.read()
    # The endpoint path is /apks/{apkVersionCode}/... even when the artifact
    # was an AAB — Google reuses the same resource for bundles, keyed by
    # versionCode. Using /bundles/ here returns 404.
    url = (
        f"{_UPLOAD_BASE}/{package}/edits/{edit_id}/apks/{version_code}"
        "/deobfuscationFiles/proguard"
    )
    resp = session.post(
        url,
        params={"uploadType": "media"},
        data=data,
        headers={
            "Content-Type": "application/octet-stream",
            "Content-Length": str(len(data)),
        },
        timeout=600,
    )
    _raise_for_status(resp, "uploading the deobfuscation mapping")
    return resp.json() if resp.content else {}


def _require_mapping_path():
    """Return the R8 mapping file to upload, or exit 1 explaining why we won't
    publish without it."""
    mapping_path = os.environ.get(_MAPPING_PATH_ENV)
    if not mapping_path:
        print(
            f"ERROR: {_MAPPING_PATH_ENV} is not set. Every release must upload "
            "its R8 mapping file so Play Console can deobfuscate crash traces.",
            file=sys.stderr,
        )
        sys.exit(1)
    if not os.path.exists(mapping_path):
        print(
            f"ERROR: {_MAPPING_PATH_ENV} points to {mapping_path} but the file "
            "does not exist. Rebuild the release AAB to regenerate mapping.txt.",
            file=sys.stderr,
        )
        sys.exit(1)
    return mapping_path


def _with_upload_retries(what, operation):
    """Run ``operation()``, retrying it with a 10s/20s backoff.

    Only failures :func:`_is_retryable` accepts are retried: a rejected request
    stays rejected, and re-sending it buries the real error under copies of
    itself (see #906). A deleted edit is not retried here either -- it is
    recovered from in :func:`main` by starting over on a fresh edit, never by
    re-posting into the corpse.

    The attempt count is kept in the final message because it distinguishes "we
    gave up after _MAX_UPLOAD_ATTEMPTS transient failures" from "we stopped at
    the first one because the request itself was rejected".
    """
    last_exc = None
    attempts_made = 0
    for attempt in range(_MAX_UPLOAD_ATTEMPTS):
        attempts_made = attempt + 1
        try:
            return operation()
        except Exception as exc:
            last_exc = exc
            if not _is_retryable(exc):
                print(
                    f"{what} attempt {attempt + 1} failed and is NOT retryable "
                    f"(the request itself was rejected):\n{exc}"
                )
                break
            if attempt < _MAX_UPLOAD_ATTEMPTS - 1:
                delay = 10 * (2 ** attempt)
                print(
                    f"{what} attempt {attempt + 1} failed "
                    f"({type(exc).__name__}: {exc}), retrying in {delay}s…"
                )
                time.sleep(delay)
    raise RuntimeError(
        f"{what} failed after {attempts_made} of "
        f"{_MAX_UPLOAD_ATTEMPTS} attempt(s): {last_exc}"
    ) from last_exc


def _create_edit(session):
    edit_resp = session.post(f"{_BASE}/{PACKAGE_NAME}/edits", json={}, timeout=30)
    _raise_for_status(edit_resp, "creating the Play edit")
    return edit_resp.json()["id"]


def _publish_edit(session, edit_id, mapping_path):
    """Upload the AAB and its mapping into ``edit_id``, assign the tracks and
    commit.

    Every failure propagates; the caller decides whether a fresh edit can help.
    """
    bundle = _with_upload_retries(
        "AAB upload",
        lambda: _upload_aab_resumable(session, PACKAGE_NAME, edit_id, AAB_PATH),
    )
    version_code = bundle["versionCode"]
    print(f"Uploaded AAB, version code: {version_code}")

    mapping_size = os.path.getsize(mapping_path)
    _with_upload_retries(
        "Deobfuscation file upload",
        lambda: _upload_deobfuscation_file(
            session, PACKAGE_NAME, edit_id, version_code, mapping_path
        ),
    )
    print(f"Uploaded deobfuscation file ({mapping_size} bytes)")

    print(f"Assigning AAB to tracks {TRACKS} with status: completed…")
    for track in TRACKS:
        track_resp = session.put(
            f"{_BASE}/{PACKAGE_NAME}/edits/{edit_id}/tracks/{track}",
            json={"releases": [{"versionCodes": [version_code], "status": "completed"}]},
            timeout=30,
        )
        _raise_for_status(track_resp, f"assigning the AAB to track {track}")

    commit_resp = session.post(
        f"{_BASE}/{PACKAGE_NAME}/edits/{edit_id}:commit",
        timeout=30,
    )
    _raise_for_status(commit_resp, "committing the Play edit")
    print(f"Deployed version {version_code} to tracks: {', '.join(TRACKS)}")


def main():
    config_json = os.environ.get("PLAY_STORE_CONFIG_JSON")
    if not config_json:
        print("Error: PLAY_STORE_CONFIG_JSON environment variable not set", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(AAB_PATH):
        print(f"Error: AAB not found at {AAB_PATH}", file=sys.stderr)
        sys.exit(1)

    # Checked before the (minutes-long) upload rather than after it: a missing
    # mapping file blocks the release either way, so find out now.
    mapping_path = _require_mapping_path()

    creds = service_account.Credentials.from_service_account_info(
        json.loads(config_json),
        scopes=["https://www.googleapis.com/auth/androidpublisher"],
    )
    session = AuthorizedSession(creds)

    last_exc = None
    for attempt in range(_MAX_EDIT_ATTEMPTS):
        edit_id = _create_edit(session)
        try:
            _publish_edit(session, edit_id, mapping_path)
            return
        except Exception as exc:
            if not _is_edit_deleted(exc):
                raise
            last_exc = exc
            print(
                f"Play deleted edit {edit_id} out from under us (attempt "
                f"{attempt + 1}/{_MAX_EDIT_ATTEMPTS}): another client opened an "
                "edit for this app, and Play allows only one. The bundle is "
                f"fine — starting over with a fresh edit.\n{exc}"
            )
    raise RuntimeError(
        f"Play deleted our edit on all {_MAX_EDIT_ATTEMPTS} attempts: another "
        f"Play API client kept opening edits for {PACKAGE_NAME} throughout this "
        f"deploy (see #907): {last_exc}"
    ) from last_exc


if __name__ == "__main__":
    main()
