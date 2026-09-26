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


def _is_retryable(exc):
    """Whether re-uploading the same bytes could plausibly succeed.

    A 4xx is the server saying the REQUEST is wrong -- a bad bundle, a reused
    version code, a revoked credential. Re-sending it unchanged cannot fix that,
    and retrying only buries the real error under two more copies of itself and
    30s of sleeps, which is exactly how the 2026-09-26 failure came to look like
    a flake. Retry transport faults and 5xx; also 408/429, which are explicit
    "try again" signals.
    """
    resp = getattr(getattr(exc, "__cause__", None), "response", None)
    if resp is None:
        resp = getattr(exc, "response", None)
    if resp is None:
        return True  # connection reset, timeout, DNS -- worth another go
    return resp.status_code >= 500 or resp.status_code in (408, 429)


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


def main():
    config_json = os.environ.get("PLAY_STORE_CONFIG_JSON")
    if not config_json:
        print("Error: PLAY_STORE_CONFIG_JSON environment variable not set", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(AAB_PATH):
        print(f"Error: AAB not found at {AAB_PATH}", file=sys.stderr)
        sys.exit(1)

    creds = service_account.Credentials.from_service_account_info(
        json.loads(config_json),
        scopes=["https://www.googleapis.com/auth/androidpublisher"],
    )
    session = AuthorizedSession(creds)

    edit_resp = session.post(f"{_BASE}/{PACKAGE_NAME}/edits", json={}, timeout=30)
    _raise_for_status(edit_resp, "creating the Play edit")
    edit_id = edit_resp.json()["id"]

    last_exc = None
    bundle = None
    attempts_made = 0
    for attempt in range(_MAX_UPLOAD_ATTEMPTS):
        attempts_made = attempt + 1
        try:
            bundle = _upload_aab_resumable(session, PACKAGE_NAME, edit_id, AAB_PATH)
            break
        except Exception as exc:
            last_exc = exc
            if not _is_retryable(exc):
                print(
                    f"Upload attempt {attempt + 1} failed and is NOT retryable "
                    f"(the request itself was rejected):\n{exc}"
                )
                break
            if attempt < _MAX_UPLOAD_ATTEMPTS - 1:
                delay = 10 * (2 ** attempt)
                print(
                    f"Upload attempt {attempt + 1} failed ({type(exc).__name__}: {exc}), "
                    f"retrying in {delay}s…"
                )
                time.sleep(delay)
    if bundle is None:
        # Keep the attempt count -- it distinguishes "we gave up after
        # _MAX_UPLOAD_ATTEMPTS transient failures" from "we stopped at the first
        # one because the request itself was rejected" -- and carry the cause,
        # which now includes the Play API's own explanation.
        raise RuntimeError(
            f"AAB upload failed after {attempts_made} of "
            f"{_MAX_UPLOAD_ATTEMPTS} attempt(s): {last_exc}"
        ) from last_exc

    version_code = bundle["versionCode"]
    print(f"Uploaded AAB, version code: {version_code}")

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
    mapping_size = os.path.getsize(mapping_path)
    last_exc = None
    uploaded = False
    for attempt in range(_MAX_UPLOAD_ATTEMPTS):
        try:
            _upload_deobfuscation_file(
                session, PACKAGE_NAME, edit_id, version_code, mapping_path
            )
            uploaded = True
            break
        except Exception as exc:
            last_exc = exc
            if attempt < _MAX_UPLOAD_ATTEMPTS - 1:
                delay = 10 * (2 ** attempt)
                print(
                    f"Deobfuscation upload attempt {attempt + 1} failed "
                    f"({type(exc).__name__}: {exc}), retrying in {delay}s…"
                )
                time.sleep(delay)
    if not uploaded:
        raise RuntimeError(
            f"Deobfuscation file upload failed after {_MAX_UPLOAD_ATTEMPTS} attempts"
        ) from last_exc
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


if __name__ == "__main__":
    main()
