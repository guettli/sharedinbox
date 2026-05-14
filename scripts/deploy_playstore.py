#!/usr/bin/env python3
"""Upload an Android App Bundle to the Google Play Store internal track."""

import json
import os
import sys
import time

import google_auth_httplib2
import httplib2
from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload

PACKAGE_NAME = "de.sharedinbox.mua"
AAB_PATH = "build/app/outputs/bundle/release/app-release.aab"
TRACK = "internal"
_TIMEOUT = 300  # seconds — AAB uploads can be large
_MAX_UPLOAD_ATTEMPTS = 3


def _make_service(creds):
    authorized_http = google_auth_httplib2.AuthorizedHttp(
        creds, http=httplib2.Http(timeout=_TIMEOUT)
    )
    return build("androidpublisher", "v3", http=authorized_http)


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

    service = _make_service(creds)

    edit = service.edits().insert(body={}, packageName=PACKAGE_NAME).execute(num_retries=3)
    edit_id = edit["id"]

    # The resumable upload can fail with RedirectMissingLocation on transient
    # network hiccups. Retry the upload (with a fresh MediaFileUpload each
    # time) using exponential backoff before giving up.
    version_code = None
    last_exc = None
    for attempt in range(_MAX_UPLOAD_ATTEMPTS):
        try:
            media = MediaFileUpload(
                AAB_PATH, mimetype="application/octet-stream", resumable=True
            )
            bundle = (
                service.edits()
                .bundles()
                .upload(packageName=PACKAGE_NAME, editId=edit_id, media_body=media)
                .execute(num_retries=3)
            )
            version_code = bundle["versionCode"]
            break
        except httplib2.error.RedirectMissingLocation as exc:
            last_exc = exc
            if attempt < _MAX_UPLOAD_ATTEMPTS - 1:
                delay = 10 * (2 ** attempt)
                print(
                    f"Upload attempt {attempt + 1} failed (redirect error), "
                    f"retrying in {delay}s…"
                )
                time.sleep(delay)
    else:
        raise RuntimeError(
            f"AAB upload failed after {_MAX_UPLOAD_ATTEMPTS} attempts"
        ) from last_exc

    print(f"Uploaded AAB, version code: {version_code}")

    service.edits().tracks().update(
        packageName=PACKAGE_NAME,
        editId=edit_id,
        track=TRACK,
        body={"releases": [{"versionCodes": [version_code], "status": "completed"}]},
    ).execute(num_retries=3)

    service.edits().commit(packageName=PACKAGE_NAME, editId=edit_id).execute(num_retries=3)
    print(f"Deployed version {version_code} to {TRACK} track")


if __name__ == "__main__":
    main()
