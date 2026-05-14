#!/usr/bin/env python3
"""Generate Hugo markdown pages listing Android builds fetched from the server.

Reads APK files under public_html/builds/ on the deployment server via SSH,
parses the git hash from each filename, fetches the commit title from the
Codeberg API, then writes Hugo content pages to website/content/builds/.

These generated pages are not tracked in git (see .gitignore).
"""
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

CODEBERG_REPO = "guettli/sharedinbox"
REMOTE_BUILDS_DIR = "public_html/builds"
CONTENT_DIR = Path("website/content/builds")
BASE_URL = "https://sharedinbox.de"
CODEBERG_BASE = "https://codeberg.org"


def list_apks(ssh_user: str, ssh_host: str) -> list[str]:
    result = subprocess.run(
        [
            "ssh",
            "-o",
            "StrictHostKeyChecking=no",
            f"{ssh_user}@{ssh_host}",
            f"find {REMOTE_BUILDS_DIR} -name '*.apk' -type f | sort",
        ],
        capture_output=True,
        text=True,
        check=True,
    )
    return [l.strip() for l in result.stdout.splitlines() if l.strip()]


def get_commit_title(hash_val: str) -> str:
    url = f"https://codeberg.org/api/v1/repos/{CODEBERG_REPO}/git/commits/{hash_val}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "sharedinbox-ci"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        return data.get("commit", {}).get("message", "").split("\n")[0]
    except Exception as exc:
        print(f"  warning: could not fetch commit title for {hash_val}: {exc}", file=sys.stderr)
        return hash_val


def main() -> None:
    ssh_user = os.environ.get("SSH_USER", "")
    ssh_host = os.environ.get("SSH_HOST", "")
    if not ssh_user or not ssh_host:
        print("SSH_USER and SSH_HOST must be set", file=sys.stderr)
        sys.exit(1)

    print(f"Listing APKs on {ssh_host}…")
    apk_paths = list_apks(ssh_user, ssh_host)
    print(f"Found {len(apk_paths)} APK(s)")

    # Group by YYYY/MM/DD
    days: dict[str, list[tuple[str, str, str]]] = {}
    for apk_path in apk_paths:
        m = re.match(
            r"public_html/builds/(\d{4})/(\d{2})/(\d{2})/(sharedinbox-mua-(.+)\.apk)$",
            apk_path,
        )
        if not m:
            print(f"  skipping unexpected path: {apk_path}", file=sys.stderr)
            continue
        year, month, day, filename, hash_val = m.groups()
        date_key = f"{year}/{month}/{day}"
        download_url = f"{BASE_URL}/builds/{year}/{month}/{day}/{filename}"
        commit_title = get_commit_title(hash_val)
        days.setdefault(date_key, []).append((hash_val, download_url, commit_title))

    CONTENT_DIR.mkdir(parents=True, exist_ok=True)
    (CONTENT_DIR / "_index.md").write_text(
        "---\ntitle: Builds\n---\nDaily Android builds of SharedInbox.\n",
        encoding="utf-8",
    )

    for date_key in sorted(days):
        year, month, day = date_key.split("/")
        date_iso = f"{year}-{month}-{day}"
        day_dir = CONTENT_DIR / year / month
        day_dir.mkdir(parents=True, exist_ok=True)

        lines = [f"---\ntitle: 'Builds for {date_iso}'\ndate: {date_iso}T00:00:00Z\n---\n\n"]
        for hash_val, download_url, commit_title in days[date_key]:
            commit_url = f"{CODEBERG_BASE}/{CODEBERG_REPO}/commit/{hash_val}"
            lines.append(
                f"- [`{hash_val}`]({download_url}) — {commit_title}  \n"
                f"  [View commit]({commit_url})\n"
            )
        (day_dir / f"{day}.md").write_text("".join(lines), encoding="utf-8")

    total_builds = sum(len(v) for v in days.values())
    print(f"Generated {len(days)} day page(s) covering {total_builds} build(s)")


if __name__ == "__main__":
    main()
