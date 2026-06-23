#!/usr/bin/env python3
"""Generate Hugo markdown pages listing builds fetched from the server.

Reads build artifacts under public_html/builds/ on the deployment server via SSH,
parses the git hash from each filename, fetches the commit title from the
GitHub API, then writes Hugo content pages to website/content/builds/.

Covers two platforms:
  - Linux:   sharedinbox-linux-amd64-<hash>.tar.gz
  - Android: sharedinbox-mua-<hash>.apk

At most MAX_BUILDS_PER_PLATFORM of the most-recent builds are shown per platform.

These generated pages are not tracked in git (see .gitignore).
"""
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

GITHUB_REPO = "guettli/sharedinbox"
REMOTE_BUILDS_DIR = "public_html/builds"
CONTENT_DIR = Path("website/content/builds")
BASE_URL = "https://sharedinbox.de"
GITHUB_BASE = "https://github.com"
MAX_BUILDS_PER_PLATFORM = 30


def list_remote_files(ssh_user: str, ssh_host: str, pattern: str) -> list[str]:
    result = subprocess.run(
        [
            "ssh",
            f"{ssh_user}@{ssh_host}",
            f"find {REMOTE_BUILDS_DIR} -name '{pattern}' -type f | sort",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(
            f"WARNING: ssh exit {result.returncode} listing {pattern} on {ssh_user}@{ssh_host}"
            " — build history will be empty for this pattern",
            file=sys.stderr,
        )
        print(result.stderr, file=sys.stderr)
        return []
    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def get_commit_info(hash_val: str) -> tuple[str, str]:
    """Return (title, datetime_iso) for the given commit hash."""
    url = f"https://api.github.com/repos/{GITHUB_REPO}/commits/{hash_val}"
    try:
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "sharedinbox-ci",
                "Accept": "application/vnd.github+json",
            },
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
        title = data.get("commit", {}).get("message", "").split("\n")[0]
        dt = data.get("commit", {}).get("author", {}).get("date", "")
        return title, dt
    except Exception as exc:
        print(f"  warning: could not fetch commit info for {hash_val}: {exc}", file=sys.stderr)
        return hash_val, ""


def parse_builds(
    paths: list[str],
    path_re: re.Pattern,  # type: ignore[type-arg]
) -> dict[str, list[tuple[str, str, str, str]]]:
    """Parse build file paths into {date_key: [(hash, url, title, dt), ...]}."""
    limited = paths[-MAX_BUILDS_PER_PLATFORM:] if len(paths) > MAX_BUILDS_PER_PLATFORM else paths
    days: dict[str, list[tuple[str, str, str, str]]] = {}
    for path in limited:
        m = path_re.match(path)
        if not m:
            print(f"  skipping unexpected path: {path}", file=sys.stderr)
            continue
        year, month, day, filename, hash_val = m.groups()
        date_key = f"{year}/{month}/{day}"
        download_url = f"{BASE_URL}/builds/{year}/{month}/{day}/{filename}"
        commit_title, commit_dt = get_commit_info(hash_val)
        days.setdefault(date_key, []).append((hash_val, download_url, commit_title, commit_dt))
    return days


def render_entries(
    entries: list[tuple[str, str, str, str]],
    link_label: str,
) -> str:
    lines = []
    for hash_val, download_url, commit_title, commit_dt in entries:
        commit_url = f"{GITHUB_BASE}/{GITHUB_REPO}/commit/{hash_val}"
        dt_str = f" · {commit_dt}" if commit_dt else ""
        lines.append(
            f"- [{commit_title}]({commit_url}){dt_str}  \n"
            f"  [{link_label}]({download_url}) (`{hash_val}`)\n"
        )
    return "".join(lines)


def main() -> None:
    ssh_user = os.environ.get("SSH_USER", "")
    ssh_host = os.environ.get("SSH_HOST", "")
    if not ssh_user or not ssh_host:
        print("SSH_USER and SSH_HOST must be set", file=sys.stderr)
        sys.exit(1)

    print(f"Listing Linux builds on {ssh_host}…")
    linux_paths = list_remote_files(ssh_user, ssh_host, "sharedinbox-linux-amd64-*.tar.gz")
    print(f"Found {len(linux_paths)} Linux build(s)")
    linux_re = re.compile(
        r"public_html/builds/(\d{4})/(\d{2})/(\d{2})/(sharedinbox-linux-amd64-(.+)\.tar\.gz)$"
    )
    linux_days = parse_builds(linux_paths, linux_re)

    print(f"Listing Android APKs on {ssh_host}…")
    apk_paths = list_remote_files(ssh_user, ssh_host, "*.apk")
    print(f"Found {len(apk_paths)} APK(s)")
    apk_re = re.compile(
        r"public_html/builds/(\d{4})/(\d{2})/(\d{2})/(sharedinbox-mua-(.+)\.apk)$"
    )
    android_days = parse_builds(apk_paths, apk_re)

    CONTENT_DIR.mkdir(parents=True, exist_ok=True)

    # _index.md: platform sections, newest-first within each
    index_lines = ["---\ntitle: Builds\n---\n\n"]

    index_lines.append(f"## Linux (last {MAX_BUILDS_PER_PLATFORM})\n\n")
    if linux_days:
        for date_key in sorted(linux_days, reverse=True):
            year, month, day = date_key.split("/")
            index_lines.append(f"### {year}-{month}-{day}\n\n")
            index_lines.append(render_entries(linux_days[date_key], "Download"))
            index_lines.append("\n")
    else:
        index_lines.append("_No Linux builds yet._\n\n")

    index_lines.append(f"## Android (last {MAX_BUILDS_PER_PLATFORM})\n\n")
    if android_days:
        for date_key in sorted(android_days, reverse=True):
            year, month, day = date_key.split("/")
            index_lines.append(f"### {year}-{month}-{day}\n\n")
            index_lines.append(render_entries(android_days[date_key], "Download APK"))
            index_lines.append("\n")
    else:
        index_lines.append("_No Android builds yet._\n\n")

    (CONTENT_DIR / "_index.md").write_text("".join(index_lines), encoding="utf-8")

    # Per-day pages (combined)
    all_days = set(linux_days) | set(android_days)
    for date_key in sorted(all_days):
        year, month, day = date_key.split("/")
        date_iso = f"{year}-{month}-{day}"
        day_dir = CONTENT_DIR / year / month
        day_dir.mkdir(parents=True, exist_ok=True)

        lines = [f"---\ntitle: 'Builds for {date_iso}'\ndate: {date_iso}T00:00:00Z\n---\n\n"]
        if date_key in linux_days:
            lines.append("## Linux\n\n")
            lines.append(render_entries(linux_days[date_key], "Download"))
            lines.append("\n")
        if date_key in android_days:
            lines.append("## Android\n\n")
            lines.append(render_entries(android_days[date_key], "Download APK"))
            lines.append("\n")
        (day_dir / f"{day}.md").write_text("".join(lines), encoding="utf-8")

    total_linux = sum(len(v) for v in linux_days.values())
    total_android = sum(len(v) for v in android_days.values())
    print(
        f"Generated pages: {total_linux} Linux build(s), {total_android} Android build(s) "
        f"across {len(all_days)} day(s)"
    )


if __name__ == "__main__":
    main()
