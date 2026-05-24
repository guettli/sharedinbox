#!/usr/bin/env python3
"""
agent_loop.py — called from cron every 10 minutes.

Flow
----
1. Agent already running?
   a. Age > 1 h  → kill it, set its issue to State/Question, exit 1
   b. Age ≤ 1 h  → print status, exit 0  (let it keep working)
2. No agent running → extract pending_issue from state (if any), then check CI
   a. CI is running         → save pending-ci state, exit 0
   b. Latest CI failed      → start fix-CI agent (preserving pending_issue), exit 0
   c. CI ok + pending_issue → close the issue (CI passed), exit 0
   d. CI ok (or no run yet) → find oldest Ready issue, start issue agent,
                              save state, exit 0
   e. No Ready issues       → print "nothing to do", exit 0

Issue agents must NOT close the issue themselves; the loop closes it after CI passes.

State file: ~/.sharedinbox-agent-state.json
  { "pid": 12345, "issue": 91,
    "started_at": "2026-05-15T12:00:00+00:00", "type": "issue" }

Output is written to ~/.sharedinbox-agent-logs/<session>-<timestamp>.log.
To resume the Claude conversation, look up the session UUID first:

  scripts/agent_loop.py list          # shows NAME and UUID columns
  claude --resume <uuid>              # use the UUID, NOT the session name
"""

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Cron runs with a minimal PATH; ensure Nix profile binaries (tea, claude) and ~/go/bin (fgj) are found.
os.environ["PATH"] = (
    f"{Path.home()}/.nix-profile/bin"
    f":{Path.home()}/go/bin"
    f":{os.environ.get('PATH', '/usr/bin:/bin')}"
)

# ── configuration ─────────────────────────────────────────────────────────────

REPO = "guettli/sharedinbox"
REPO_URL = f"https://codeberg.org/{REPO}"
STATE_FILE = Path.home() / ".sharedinbox-agent-state.json"
MAX_AGENT_AGE_SECONDS = 3600  # 1 hour
CLAUDE_PROJECTS_DIR = Path.home() / ".claude" / "projects" / (
    "-" + str(Path.home())[1:].replace("/", "-")
)

# Labels used by the workflow.
LABEL_READY = "State/Ready"
LABEL_IN_PROGRESS = "State/InProgress"
LABEL_QUESTION = "State/Question"
LABEL_PRIO_HIGH = "Prio/High"

# Only pick up issues filed by these accounts.
ALLOWED_ISSUE_AUTHORS = {"guettli", "guettlibot", "guettlibot2"}

# ── helpers ───────────────────────────────────────────────────────────────────


def _issue_url(number: int) -> str:
    return f"{REPO_URL}/issues/{number}"


def _ci_run_url(run_id: int) -> str:
    return f"{REPO_URL}/actions/runs/{run_id}"


def _fgj(*args: str) -> None:
    """Run a fgj command, raising on failure."""
    cmd = ["fgj", "--hostname", "codeberg.org", *args]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"fgj {' '.join(args)} failed:\n{result.stderr or result.stdout}"
        )


def _tea_get(path: str) -> dict | list | None:
    """Run a tea api GET and return parsed JSON. Only use for reads — tea PATCH/PUT
    silently fails (exits 0) when unauthenticated, so writes must go via fgj."""
    cmd = ["tea", "api", path]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"tea api {path} failed:\n{result.stderr or result.stdout}"
        )
    out = result.stdout.strip()
    if not out:
        return None
    data = json.loads(out)
    if isinstance(data, dict) and "message" in data and "url" in data:
        raise RuntimeError(f"tea api {path} returned error: {data['message']}")
    return data


def _set_labels(issue: int, add: list[str], remove: list[str]) -> None:
    """Add/remove labels on an issue via fgj."""
    cmd = ["issue", "edit", str(issue), "--repo", REPO]
    for label in add:
        cmd += ["--add-label", label]
    for label in remove:
        cmd += ["--remove-label", label]
    _fgj(*cmd)


def _close_issue(issue: int) -> None:
    _fgj("issue", "close", str(issue), "--repo", REPO)
    _set_labels(issue, add=[], remove=[LABEL_IN_PROGRESS])


def _comment_issue(issue: int, body: str) -> None:
    _fgj("issue", "comment", str(issue), "--repo", REPO, "--body", body)


def _ready_issues() -> list[dict]:
    """Return open issues with State/Ready, Prio/High first, then oldest."""
    result = subprocess.run(
        ["fgj", "--hostname", "codeberg.org", "issue", "list",
         "--repo", REPO, "--state", "open", "--json"],
        capture_output=True, text=True, check=True,
    )
    data = json.loads(result.stdout) if result.stdout.strip() else []
    ready = [
        i for i in data
        if any(lbl["name"] == LABEL_READY for lbl in i.get("labels", []))
        and i.get("user", {}).get("login", "") in ALLOWED_ISSUE_AUTHORS
    ]
    ready.sort(key=lambda i: (
        0 if any(lbl["name"] == LABEL_PRIO_HIGH for lbl in i.get("labels", [])) else 1,
        i["number"],
    ))
    return ready


def _latest_ci_run() -> dict | None:
    data = _tea_get(f"repos/{REPO}/actions/runs?limit=1")
    runs = (data or {}).get("workflow_runs", [])
    return runs[0] if runs else None


def _latest_ci_run_for_branch(branch: str) -> dict | None:
    """Return the latest CI run for a specific branch, or None.

    Forgejo's workflow_runs API has no top-level head_branch field.
    For push events the branch is in ``prettyref``; for pull_request
    events it lives inside ``event_payload["pull_request"]["head"]["ref"]``.
    """
    data = _tea_get(f"repos/{REPO}/actions/runs?limit=20")
    runs = (data or {}).get("workflow_runs", [])
    for run in runs:
        if run.get("event") == "pull_request":
            try:
                payload = json.loads(run.get("event_payload", "{}"))
                if payload.get("pull_request", {}).get("head", {}).get("ref") == branch:
                    return run
            except (json.JSONDecodeError, AttributeError):
                pass
        else:
            if run.get("prettyref") == branch:
                return run
    return None


def _find_pr_for_branch(branch: str, state: str = "open") -> dict | None:
    """Return the first PR in the given state whose head branch matches, or None."""
    result = subprocess.run(
        ["fgj", "--hostname", "codeberg.org", "pr", "list",
         "--repo", REPO, "--state", state, "--json"],
        capture_output=True, text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return None
    prs = json.loads(result.stdout)
    for pr in prs:
        head = pr.get("head", {})
        ref = head.get("ref") or head.get("label", "").split(":")[-1]
        if ref == branch:
            return pr
    return None


def _open_issue_prs() -> list[dict]:
    """Return all open PRs with issue-{N}-fix branches, oldest-first."""
    result = subprocess.run(
        ["fgj", "--hostname", "codeberg.org", "pr", "list",
         "--repo", REPO, "--state", "open", "--json"],
        capture_output=True, text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        return []
    prs = json.loads(result.stdout)
    issue_prs = []
    for pr in prs:
        head = pr.get("head", {})
        ref = head.get("ref") or head.get("label", "").split(":")[-1]
        if re.match(r"^issue-\d+-fix$", ref or ""):
            issue_prs.append(pr)
    issue_prs.sort(key=lambda p: p["number"])
    return issue_prs


def _latest_ci_run_for_pr(pr_number: int) -> dict | None:
    """Return the latest CI run triggered by a pull_request event for the given PR number."""
    data = _tea_get(f"repos/{REPO}/actions/runs?event=pull_request&limit=50")
    runs = (data or {}).get("workflow_runs", [])
    for run in runs:
        try:
            payload = json.loads(run.get("event_payload", "{}"))
            if payload.get("pull_request", {}).get("number") == pr_number:
                return run
        except (json.JSONDecodeError, AttributeError):
            pass
    return None


def _merge_pr(pr_number: int) -> None:
    """Squash-merge a PR via fgj."""
    _fgj("pr", "merge", str(pr_number), "--repo", REPO, "--merge-method", "squash")


# ── state file ────────────────────────────────────────────────────────────────


def _read_state() -> dict | None:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            pass
    return None


def _write_state(pid: int | None, issue: int | None, kind: str, issue_title: str | None = None, session_name: str | None = None, ci_run_id: int | None = None) -> None:
    data: dict = {
        "pid": pid,
        "issue": issue,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "type": kind,
    }
    if issue_title is not None:
        data["issue_title"] = issue_title
    if session_name is not None:
        data["session_name"] = session_name
    if ci_run_id is not None:
        data["ci_run_id_at_start"] = ci_run_id
    STATE_FILE.write_text(json.dumps(data, indent=2))
    STATE_FILE.chmod(0o600)


def _clear_state() -> None:
    STATE_FILE.unlink(missing_ok=True)


def _find_session_uuid(session_name: str) -> str | None:
    """Return the Claude session UUID for *session_name*, or None if not found.

    Claude stores session metadata in JSONL files; the first entry with
    type=="agent-name" contains both the human-readable name and the UUID
    needed for ``claude --resume <uuid>``.
    """
    if not CLAUDE_PROJECTS_DIR.exists():
        return None
    for jsonl in CLAUDE_PROJECTS_DIR.glob("*.jsonl"):
        try:
            with jsonl.open() as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    d = json.loads(line)
                    if d.get("type") == "agent-name" and d.get("agentName") == session_name:
                        return d.get("sessionId")
        except Exception:
            continue
    return None


# ── agent launcher ────────────────────────────────────────────────────────────


def _start_agent(prompt: str, session_name: str) -> int:
    """Start Claude Code as a detached background process and return its PID."""
    log_dir = Path.home() / ".sharedinbox-agent-logs"
    log_dir.mkdir(mode=0o700, exist_ok=True)
    log_dir.chmod(0o700)  # fix permissions if dir already existed with wrong mode
    ts = datetime.now().strftime("%Y%m%dT%H%M%S")
    log_file = log_dir / f"{session_name}-{ts}.log"

    log_fh = open(log_file, "w", opener=lambda p, f: os.open(p, f, 0o600))
    proc = subprocess.Popen(
        [
            "claude",
            "--dangerously-skip-permissions",
            "--name", session_name,
            "-p", prompt,
        ],
        stdin=subprocess.PIPE,
        stdout=log_fh,
        stderr=log_fh,
        start_new_session=True,
    )
    log_fh.close()  # Parent closes its copy; the child retains the fd.
    # Answer the workspace-trust dialog; after this the pipe hits EOF.
    proc.stdin.write(b"\n")
    proc.stdin.close()

    print(f"Started agent pid={proc.pid}, log={log_file}")
    print(f"  Resume: run 'scripts/agent_loop.py list' to get the UUID-based resume command")
    return proc.pid


def _agent_alive(state: dict) -> bool:
    """Return True if the agent process is still running."""
    pid = state.get("pid")
    if pid is None:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _is_claude_process(pid: int) -> bool:
    """Return True if pid's comm name indicates it is a claude/node process."""
    try:
        comm = Path(f"/proc/{pid}/comm").read_text().strip()
        return comm in ("claude", "node")
    except OSError:
        return False


def _agent_age_seconds(state: dict) -> float:
    """Seconds elapsed since the agent was launched, from the state file timestamp."""
    try:
        started_at = datetime.fromisoformat(state["started_at"])
        return (datetime.now(timezone.utc) - started_at).total_seconds()
    except Exception:
        return 0.0


def _git_summary() -> str:
    """Return a one-line summary of the latest commit and whether it's been pushed."""
    try:
        commit = subprocess.run(
            ["git", "log", "--oneline", "-1"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        ahead = subprocess.run(
            ["git", "rev-list", "--count", "HEAD@{u}..HEAD"],
            capture_output=True, text=True,
        )
        if ahead.returncode == 0 and ahead.stdout.strip() != "0":
            push_status = f"not pushed ({ahead.stdout.strip()} ahead)"
        elif ahead.returncode == 0:
            push_status = "pushed"
        else:
            push_status = "no upstream"
        return f"{commit} [{push_status}]"
    except Exception:
        return ""


def _kill_agent(state: dict) -> None:
    """Forcefully stop the running agent."""
    pid = state.get("pid")
    if pid and _is_claude_process(pid):
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass
    elif pid:
        print(f"WARNING: pid {pid} is not a claude process — skipping kill to avoid hitting recycled PID")


# ── subcommands ───────────────────────────────────────────────────────────────


def cmd_list() -> int:
    """List recent agent-loop sessions, newest first."""
    if not CLAUDE_PROJECTS_DIR.exists():
        print(f"No sessions found (directory missing: {CLAUDE_PROJECTS_DIR})")
        return 0

    sessions = []
    for jsonl in CLAUDE_PROJECTS_DIR.glob("*.jsonl"):
        agent_name = None
        session_id = None
        try:
            with jsonl.open() as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    d = json.loads(line)
                    if d.get("type") == "agent-name":
                        agent_name = d.get("agentName")
                        session_id = d.get("sessionId")
                        break
        except Exception:
            continue
        if agent_name:
            sessions.append((jsonl.stat().st_mtime, agent_name, session_id))

    if not sessions:
        print("No agent sessions found.")
        return 0

    sessions.sort(reverse=True)
    total = len(sessions)
    print(f"  {'DATE':<16}  {'NAME':<20}  UUID  (use with: claude --resume <uuid>)")
    print(f"  {'-'*16}  {'-'*20}  {'-'*36}")
    for mtime, name, sid in sessions[:20]:
        ts = datetime.fromtimestamp(mtime).strftime("%Y-%m-%d %H:%M")
        print(f"  {ts:<16}  {name:<20}  {sid}")
    if total > 20:
        print(f"  ... ({total - 20} more)")
    return 0


# ── main flow ─────────────────────────────────────────────────────────────────


def _run_loop() -> int:
    now = datetime.now(timezone.utc)
    print(f"---------------------- Starting {now.strftime('%Y-%m-%d %H:%MZ')}")

    state = _read_state()

    # ── 1. Agent already running? ─────────────────────────────────────────────
    if state and _agent_alive(state):
        age = _agent_age_seconds(state)
        issue = state.get("issue")
        kind = state.get("type", "issue")
        pid = state.get("pid", "?")

        issue_title = state.get("issue_title", "")
        issue_ref = (
            f"{_issue_url(issue)} {issue_title}".strip() if issue else str(issue)
        )

        if age > MAX_AGENT_AGE_SECONDS:
            print(
                f"Agent pid={pid!r} ({issue_ref}) "
                f"has been running for {age/60:.0f} min — aborting."
            )
            _kill_agent(state)
            _clear_state()
            if issue:
                _set_labels(issue, add=[LABEL_QUESTION], remove=[LABEL_IN_PROGRESS])
                _comment_issue(
                    issue,
                    f"Agent (pid {pid}) was killed after running for {age/60:.0f} min "
                    f"(limit: {MAX_AGENT_AGE_SECONDS//60} min). "
                    "Please investigate and resume manually.",
                )
                print(f"Set {_issue_url(issue)} to State/Question.")
            return 1

        session_name = state.get("session_name")
        uuid = _find_session_uuid(session_name) if session_name else None
        if uuid:
            resume_cmd = f"claude --resume {shlex.quote(uuid)}"
        elif session_name:
            resume_cmd = f"claude --resume <uuid>  # run: scripts/agent_loop.py list"
        else:
            resume_cmd = ""
        git_info = _git_summary()
        parts = [
            f"Agent pid={pid!r} ({kind}, {issue_ref}) still running ({age/60:.0f} min). Waiting.",
        ]
        if resume_cmd:
            parts.append(f"  Resume: {resume_cmd}")
        if git_info:
            parts.append(f"  Commit: {git_info}")
        print("\n".join(parts))
        return 0

    # Agent not running (or no state) — extract any pending issue, then clean up.
    pending_issue: int | None = None
    ci_run_id_at_start: int | None = None
    if state:
        pending_issue = state.get("issue")
        ci_run_id_at_start = state.get("ci_run_id_at_start")
        _clear_state()

    # ── 2. Check for a PR opened by the agent ────────────────────────────────
    if pending_issue:
        branch = f"issue-{pending_issue}-fix"
        pr = _find_pr_for_branch(branch)
        if pr:
            pr_number = pr["number"]
            pr_url = f"{REPO_URL}/pulls/{pr_number}"
            print(f"Found PR #{pr_number} ({pr_url}) for issue #{pending_issue}.")
            pr_run = _latest_ci_run_for_branch(branch)

            if pr_run and pr_run.get("status") == "running":
                print(f"CI run {_ci_run_url(pr_run['id'])} on branch {branch!r} is running. Waiting.")
                _write_state(None, pending_issue, "pending-ci")
                return 0

            if pr_run and pr_run.get("status") in ("failure", "error"):
                print(f"CI run {_ci_run_url(pr_run['id'])} on branch {branch!r} failed — starting fix agent.")
                prompt = (
                    f"The Codeberg CI for guettli/sharedinbox just failed on branch {branch!r} "
                    f"(PR #{pr_number}). "
                    f"CI run: {_ci_run_url(pr_run['id'])}. "
                    "Fetch the CI logs using the task ci-logs command or the Codeberg API. "
                    "Identify the failure, fix it, commit, and push to the same branch. "
                    "Do NOT push to main, do NOT close the issue, do NOT merge the PR. "
                    "Verify locally with 'task check' before pushing. "
                    "When done, stop."
                )
                session_name = f"ci-fix-pr-{pr_number}"
                pid = _start_agent(prompt, session_name)
                _write_state(pid, pending_issue, "ci-fix", session_name=session_name)
                return 0

            if not pr_run:
                # No CI run yet — might be that CI hasn't triggered yet.
                # Wait up to 15 min before giving up.
                pr_created_at = pr.get("created_at", "")
                try:
                    created = datetime.fromisoformat(pr_created_at.replace("Z", "+00:00"))
                    age_s = (datetime.now(timezone.utc) - created).total_seconds()
                except Exception:
                    age_s = 999999
                if age_s < 900:
                    print(
                        f"PR #{pr_number} has no CI run yet (created {age_s/60:.0f} min ago). Waiting."
                    )
                    _write_state(None, pending_issue, "pending-ci")
                    return 0
                print(
                    f"No CI run for branch {branch!r} after {age_s/60:.0f} min — "
                    "agent may not have pushed. Setting to State/Question."
                )
                _set_labels(pending_issue, add=[LABEL_QUESTION], remove=[LABEL_IN_PROGRESS])
                _comment_issue(
                    pending_issue,
                    f"Agent opened PR #{pr_number} but no CI run appeared on branch `{branch}` "
                    f"after {age_s/60:.0f} min. The agent may not have pushed any commits. "
                    "Please investigate and resume manually.",
                )
                return 0

            # CI passed on the PR branch — squash-merge and close.
            print(f"CI passed {_ci_run_url(pr_run['id'])} on branch {branch!r} — merging PR #{pr_number}.")
            _merge_pr(pr_number)
            _close_issue(pending_issue)
            print(f"Merged PR #{pr_number} and closed {_issue_url(pending_issue)}.")
            return 0

        # No open PR — check if it was already merged.
        merged_pr = _find_pr_for_branch(branch, state="closed")
        if merged_pr and merged_pr.get("merged"):
            print(f"PR for branch {branch!r} was already merged — closing issue #{pending_issue}.")
            _close_issue(pending_issue)
            return 0

        # No open or merged PR — the agent may not have created one, or it was
        # closed without merging (the bug this block was added to catch).
        print(
            f"No open or merged PR found for branch {branch!r} "
            f"(issue #{pending_issue}) — setting to State/Question."
        )
        _set_labels(pending_issue, add=[LABEL_QUESTION], remove=[LABEL_IN_PROGRESS])
        _comment_issue(
            pending_issue,
            f"Agent finished but no open or merged PR was found for branch `{branch}`. "
            "Please investigate and resume manually.",
        )
        return 0

    # ── 2b. Catch-up: scan open issue-N-fix PRs orphaned by a cleared state ─────
    # This handles PRs whose CI has passed but were never merged because the
    # state file was cleared (loop restart, killed agent, manual intervention).
    open_prs = _open_issue_prs()
    for pr in open_prs:
        pr_number = pr["number"]
        pr_url = f"{REPO_URL}/pulls/{pr_number}"
        head = pr.get("head", {})
        branch = head.get("ref") or head.get("label", "").split(":")[-1]
        m = re.match(r"^issue-(\d+)-fix$", branch or "")
        issue_num = int(m.group(1)) if m else None
        pr_run = _latest_ci_run_for_pr(pr_number)

        if pr_run and pr_run.get("status") == "running":
            print(f"Catch-up: CI {_ci_run_url(pr_run['id'])} on PR #{pr_number} still running. Waiting.")
            _write_state(None, issue_num, "pending-ci")
            return 0

        if pr_run and pr_run.get("status") in ("failure", "error"):
            print(f"Catch-up: CI {_ci_run_url(pr_run['id'])} on PR #{pr_number} failed — skipping.")
            continue

        if pr_run and pr_run.get("status") == "success":
            print(f"Catch-up: CI passed on PR #{pr_number} ({pr_url}) — merging.")
            _merge_pr(pr_number)
            if issue_num:
                _close_issue(issue_num)
                print(f"Merged PR #{pr_number} and closed issue #{issue_num}.")
            else:
                print(f"Merged PR #{pr_number}.")
            return 0

    # ── 3. Global CI check (agent pushed to main, or no pending issue) ────────
    run = _latest_ci_run()

    if run and run.get("status") == "running":
        print(f"CI run {_ci_run_url(run['id'])} is still running. Waiting.")
        if pending_issue:
            _write_state(None, pending_issue, "pending-ci")
        return 0

    if run and run.get("status") in ("failure", "error"):
        print(f"CI run {_ci_run_url(run['id'])} failed — starting fix agent.")
        prompt = (
            "The Codeberg CI for guettli/sharedinbox just failed. "
            f"The CI run ID is {run['id']}. "
            "Fetch the CI logs using the task ci-logs command or the Codeberg API. "
            "Identify the failure, fix it, commit, and push. "
            "Verify locally with 'task check' before pushing. "
            "When done, stop."
        )
        pid = _start_agent(prompt, "ci-fix")
        _write_state(pid, pending_issue, "ci-fix", session_name="ci-fix")
        return 0

    # CI is ok (or no run).
    if pending_issue:
        latest_run_id = run["id"] if run else None
        if ci_run_id_at_start is not None and latest_run_id == ci_run_id_at_start:
            # CI run hasn't changed since the agent was launched → agent pushed nothing
            # (likely crashed or hit a rate limit).
            print(
                f"No new CI run since agent started for {_issue_url(pending_issue)} "
                f"(run id {latest_run_id}) — agent did nothing. Setting to State/Question."
            )
            _set_labels(pending_issue, add=[LABEL_QUESTION], remove=[LABEL_IN_PROGRESS])
            _comment_issue(
                pending_issue,
                "The agent exited without pushing any changes (no new CI run was triggered). "
                "This usually means the agent hit a rate limit or crashed at startup. "
                "The issue has been set to State/Question — please review the agent log and retry.",
            )
            return 0
        _close_issue(pending_issue)
        ci_run_part = f" {_ci_run_url(run['id'])}" if run else ""
        print(f"CI passed{ci_run_part} — closed {_issue_url(pending_issue)}.")
        return 0

    # Find a Ready issue.
    issues = _ready_issues()
    if not issues:
        print("No issues with State/Ready. Nothing to do.")
        return 0

    issue = issues[0]
    issue_number = issue["number"]
    issue_title = issue["title"]
    issue_body = issue.get("body", "")

    print(f"Starting agent for {_issue_url(issue_number)} {issue_title}")

    # Mark InProgress before starting so the next cron tick sees it even if
    # the agent hasn't had time to do so yet.
    _set_labels(
        issue_number,
        add=[LABEL_IN_PROGRESS],
        remove=[LABEL_READY],
    )

    prompt = f"""Work on Codeberg issue #{issue_number} in the guettli/sharedinbox repository.

Issue title: {issue_title}

Issue body:
{issue_body}

Instructions:
- Understand the issue thoroughly before writing any code.
- Implement the required change, following the existing code style.
- Write or update tests as appropriate.
- Run 'task check' locally and fix any failures before committing.
- Commit with a descriptive message referencing the issue number (e.g. "feat: ... (#{issue_number})").
- Create a branch named `issue-{issue_number}-fix`, push your changes there, and open a PR against main:
      git checkout -b issue-{issue_number}-fix
      git push -u origin issue-{issue_number}-fix
      fgj pr create --title "fix: <short description> (#{issue_number})" \\
        --head issue-{issue_number}-fix --base main --repo {REPO}
- Do NOT push to main, do NOT close the issue, and do NOT merge the PR — the loop handles that after CI passes.
- If you hit a blocker you cannot resolve, set the issue label to State/Question
  and stop (do NOT close the issue).
- When the work is pushed and the PR is opened, stop. The loop will merge the PR and close the issue after CI passes.
"""

    session_name = f"issue-{issue_number}"
    pid = _start_agent(prompt, session_name)
    current_run_id = run["id"] if run else None
    _write_state(pid, issue_number, "issue", issue_title, session_name=session_name, ci_run_id=current_run_id)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(prog="agent_loop")
    sub = parser.add_subparsers(dest="cmd")
    sub.add_parser("list", help="List recent agent sessions")
    args = parser.parse_args()

    if args.cmd == "list":
        return cmd_list()
    return _run_loop()


if __name__ == "__main__":
    sys.exit(main())
