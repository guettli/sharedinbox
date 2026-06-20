#!/usr/bin/env python3
"""Verify that the Android app was recently published to the Play Store alpha track.

The publish-android pipeline sets versionCode = int(time.Now().Unix()), so a
freshly deployed release always has a version code close to the current Unix
timestamp.  This script queries the alpha (closed-testing) track and fails if
the latest version code is older than _MAX_DEPLOY_AGE_SECONDS, which would
mean the deployment silently did not land.
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
# Allow up to one hour for the build + upload to complete.
_MAX_DEPLOY_AGE_SECONDS = 3600


def main():
    config_json = os.environ.get("PLAY_STORE_CONFIG_JSON")
    if not config_json:
        print("Error: PLAY_STORE_CONFIG_JSON environment variable not set", file=sys.stderr)
        sys.exit(1)

    creds = service_account.Credentials.from_service_account_info(
        json.loads(config_json),
        scopes=["https://www.googleapis.com/auth/androidpublisher"],
    )
    session = AuthorizedSession(creds)

    # Open a read-only edit to query the current track state.
    edit_resp = session.post(f"{_BASE}/{PACKAGE_NAME}/edits", json={}, timeout=30)
    edit_resp.raise_for_status()
    edit_id = edit_resp.json()["id"]

    try:
        track_resp = session.get(
            f"{_BASE}/{PACKAGE_NAME}/edits/{edit_id}/tracks/{TRACK}",
            timeout=30,
        )
        track_resp.raise_for_status()
        track_data = track_resp.json()
    finally:
        # Discard the edit — we made no changes.
        try:
            session.delete(f"{_BASE}/{PACKAGE_NAME}/edits/{edit_id}", timeout=30)
        except Exception:
            pass

    releases = track_data.get("releases", [])
    if not releases:
        print(
            f"ERROR: No releases found on {TRACK} track — deploy may have failed silently",
            file=sys.stderr,
        )
        sys.exit(1)

    all_version_codes = [
        int(vc)
        for release in releases
        for vc in release.get("versionCodes", [])
    ]
    if not all_version_codes:
        print("ERROR: Latest release has no version codes", file=sys.stderr)
        sys.exit(1)

    latest_vc = max(all_version_codes)
    now = int(time.time())
    # versionCode is set to Unix timestamp by PublishAndroid in ci/main.go.
    age_seconds = now - latest_vc

    print(f"Latest version code on {TRACK} track: {latest_vc}")
    print(f"Current time: {now} — version code age: {age_seconds}s")

    if age_seconds > _MAX_DEPLOY_AGE_SECONDS:
        print(
            f"::error::Latest version code {latest_vc} is {age_seconds}s old "
            f"(limit: {_MAX_DEPLOY_AGE_SECONDS}s). The deploy may have failed silently.",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"OK: version {latest_vc} verified on {TRACK} track ({age_seconds}s old)")


if __name__ == "__main__":
    main()
