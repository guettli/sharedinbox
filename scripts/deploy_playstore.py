#!/usr/bin/env python3
"""Upload an Android App Bundle to the Google Play Store internal track."""

import json
import os
import sys
import time

import requests
from google.auth.transport.requests import AuthorizedSession
from google.oauth2 import service_account

PACKAGE_NAME = "de.sharedinbox.mua"
AAB_PATH = "build/app/outputs/bundle/release/app-release.aab"
TRACK = "internal"
_TIMEOUT = 300  # seconds — AAB uploads can be large
_MAX_UPLOAD_ATTEMPTS = 3
_BASE = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
_UPLOAD_BASE = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"


def _make_session(config_json: str) -> AuthorizedSession:
    creds = service_account.Credentials.from_service_account_info(
        json.loads(config_json),
        scopes=["https://www.googleapis.com/auth/androidpublisher"],
    )
    return AuthorizedSession(creds)


def _upload_aab(session: AuthorizedSession, edit_id: str) -> int:
    """Resumable upload of the AAB. Returns the version code."""
    file_size = os.path.getsize(AAB_PATH)

    with open(AAB_PATH, "rb") as f:
        data = f.read()

    last_exc = None
    for attempt in range(_MAX_UPLOAD_ATTEMPTS):
        # Each attempt needs a fresh resumable upload URL — the previous URL expires on failure.
        init_resp = session.post(
            f"{_UPLOAD_BASE}/{PACKAGE_NAME}/edits/{edit_id}/bundles",
            params={"uploadType": "resumable"},
            headers={
                "X-Upload-Content-Type": "application/octet-stream",
                "X-Upload-Content-Length": str(file_size),
            },
            json={},
            timeout=30,
        )
        init_resp.raise_for_status()
        upload_url = init_resp.headers["Location"]

        try:
            upload_resp = session.put(
                upload_url,
                data=data,
                headers={
                    "Content-Type": "application/octet-stream",
                    "Content-Length": str(file_size),
                },
                timeout=_TIMEOUT,
            )
            upload_resp.raise_for_status()
            return upload_resp.json()["versionCode"]
        except requests.RequestException as exc:
            last_exc = exc
            if attempt < _MAX_UPLOAD_ATTEMPTS - 1:
                delay = 10 * (2 ** attempt)
                print(f"Upload attempt {attempt + 1} failed ({exc}), retrying in {delay}s…")
                time.sleep(delay)

    raise RuntimeError(
        f"AAB upload failed after {_MAX_UPLOAD_ATTEMPTS} attempts"
    ) from last_exc


def main():
    config_json = os.environ.get("PLAY_STORE_CONFIG_JSON")
    if not config_json:
        print("Error: PLAY_STORE_CONFIG_JSON environment variable not set", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(AAB_PATH):
        print(f"Error: AAB not found at {AAB_PATH}", file=sys.stderr)
        sys.exit(1)

    session = _make_session(config_json)

    edit_resp = session.post(
        f"{_BASE}/{PACKAGE_NAME}/edits",
        json={},
        timeout=30,
    )
    edit_resp.raise_for_status()
    edit_id = edit_resp.json()["id"]

    version_code = _upload_aab(session, edit_id)
    print(f"Uploaded AAB, version code: {version_code}")

    tracks_resp = session.put(
        f"{_BASE}/{PACKAGE_NAME}/edits/{edit_id}/tracks/{TRACK}",
        json={"releases": [{"versionCodes": [version_code], "status": "completed"}]},
        timeout=30,
    )
    tracks_resp.raise_for_status()

    commit_resp = session.post(
        f"{_BASE}/{PACKAGE_NAME}/edits/{edit_id}:commit",
        timeout=30,
    )
    commit_resp.raise_for_status()
    print(f"Deployed version {version_code} to {TRACK} track")


if __name__ == "__main__":
    main()
