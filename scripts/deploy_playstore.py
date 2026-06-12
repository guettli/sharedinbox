#!/usr/bin/env python3
"""Upload an Android App Bundle to the Google Play Store.

The bundle is published to every track in ``TRACKS`` within a single Play edit,
so internal testing and closed testing share the same version code. ``alpha``
is what the Play Console labels "Closed testing"; publishing there removes the
need to manually drag-and-drop the AAB into the closed-testing release form.
"""

import json
import os
import sys
import time

from google.auth.transport.requests import AuthorizedSession
from google.oauth2 import service_account

PACKAGE_NAME = "de.sharedinbox.mua"
AAB_PATH = "build/app/outputs/bundle/release/app-release.aab"
TRACKS = ("internal", "alpha")
_BASE = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
_UPLOAD_BASE = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
_MAX_UPLOAD_ATTEMPTS = 3


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
    init_resp.raise_for_status()
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
    upload_resp.raise_for_status()
    return upload_resp.json()


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
    edit_resp.raise_for_status()
    edit_id = edit_resp.json()["id"]

    last_exc = None
    bundle = None
    for attempt in range(_MAX_UPLOAD_ATTEMPTS):
        try:
            bundle = _upload_aab_resumable(session, PACKAGE_NAME, edit_id, AAB_PATH)
            break
        except Exception as exc:
            last_exc = exc
            if attempt < _MAX_UPLOAD_ATTEMPTS - 1:
                delay = 10 * (2 ** attempt)
                print(
                    f"Upload attempt {attempt + 1} failed ({type(exc).__name__}: {exc}), "
                    f"retrying in {delay}s…"
                )
                time.sleep(delay)
    if bundle is None:
        raise RuntimeError(
            f"AAB upload failed after {_MAX_UPLOAD_ATTEMPTS} attempts"
        ) from last_exc

    version_code = bundle["versionCode"]
    print(f"Uploaded AAB, version code: {version_code}")

    for track in TRACKS:
        track_resp = session.put(
            f"{_BASE}/{PACKAGE_NAME}/edits/{edit_id}/tracks/{track}",
            json={"releases": [{"versionCodes": [version_code], "status": "completed"}]},
            timeout=30,
        )
        try:
            track_resp.raise_for_status()
        except Exception as exc:
            if hasattr(exc, "response") and exc.response is not None:
                print(f"Track response error body: {exc.response.text}", file=sys.stderr)
            raise

    commit_resp = session.post(
        f"{_BASE}/{PACKAGE_NAME}/edits/{edit_id}:commit",
        timeout=30,
    )
    try:
        commit_resp.raise_for_status()
    except Exception as exc:
        if hasattr(exc, "response") and exc.response is not None:
            print(f"Commit response error body: {exc.response.text}", file=sys.stderr)
        raise
    print(f"Deployed version {version_code} to tracks: {', '.join(TRACKS)}")


if __name__ == "__main__":
    main()
