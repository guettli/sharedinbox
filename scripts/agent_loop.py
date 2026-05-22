#!/usr/bin/env python3
"""
agent_loop.py — called from cron every 10 minutes.

Flow
----
1. Agent already running?
   a. Age > 1 h  → kill it, set its issue to State/Question, exit 1
   b. Age ≤ 1 h  → print status, exit 0  (let it keep working)
2. No agent running → check Codeberg CI
   a. CI is running         → print "CI running, waiting", exit 0
   b. Latest CI failed      → start fix-CI agent, save state, exit 0
   c. CI ok (or no run yet) → find oldest Ready issue, start issue agent,
                              save state, exit 0
   d. No Ready issues       → print "nothing to do", exit 0

State file: ~/.sharedinbox-agent-state.json
  { "pid": 12345, "issue": 91,
    "started_at": "2026-05-15T12:00:00+00:00", "type": "issue" }

Output is written to ~/.sharedinbox-agent-logs/<session>-<timestamp>.log.
Resume the Claude conversation afterward with:

  claude --resume issue-91
"""

import argparse
import json
import os
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Cron runs with a minimal PATH; ensure Nix profile binaries (tea, claude) are found.
os.environ["PATH"] = f"{Path.home()}/.nix-profile/bin:{os.environ.get('PATH', '/usr/bin:/bin')}"

# ── configuration ─────────────────────────────────────────────────────────────

REPO = "guettli/sharedinbox"
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

# ── helpers ───────────────────────────────────────────────────────────────────


def _tea(*args: str) -> dict | list | None:
    """Run a `tea api` command and return parsed JSON, or None on 204."""
    method = "GET"
    path = args[0]
    extra: list[str] = []
    body_str = None

    i = 1
    while i < len(args):
        if args[i] in ("--method", "-X") and i + 1 < len(args):
            method = args[i + 1]
            i += 2
        elif args[i] in ("--data", "-d") and i + 1 < len(args):
            body_str = args[i + 1]
            i += 2
        else:
            extra.append(args[i])
            i += 1

    cmd = ["tea", "api", "--repo", REPO, "-X", method]
    if body_str:
        cmd += ["-d", body_str]
    cmd.append(path)

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(
            f"tea api {path} failed:\n{result.stderr or result.stdout}"
        )
    out = result.stdout.strip()
    if not out:
        return None
    return json.loads(out)


def _set_labels(issue: int, add: list[str], remove: list[str]) -> None:
    """Replace labels on an issue via the tea CLI."""
    current = _tea(f"repos/{REPO}/issues/{issue}/labels") or []
    current_names = {lbl["name"] for lbl in current}
    all_labels = _tea(f"repos/{REPO}/labels") or []
    name_to_id = {lbl["name"]: lbl["id"] for lbl in all_labels}

    desired = (current_names - set(remove)) | set(add)
    ids = [name_to_id[n] for n in desired if n in name_to_id]
    _tea(
        f"repos/{REPO}/issues/{issue}/labels",
        "-X", "PUT",
        "-d", json.dumps({"labels": ids}),
    )


def _close_issue(issue: int) -> None:
    _tea(
        f"repos/{REPO}/issues/{issue}",
        "-X", "PATCH",
        "-d", json.dumps({"state": "closed"}),
    )


def _ready_issues() -> list[dict]:
    """Return open issues with State/Ready, Prio/High first, then oldest."""
    data = _tea(f"repos/{REPO}/issues?state=open&type=issues&limit=50") or []
    ready = [
        i for i in data
        if any(lbl["name"] == LABEL_READY for lbl in i.get("labels", []))
    ]
    ready.sort(key=lambda i: (
        0 if any(lbl["name"] == LABEL_PRIO_HIGH for lbl in i.get("labels", [])) else 1,
        i["number"],
    ))
    return ready


def _latest_ci_run() -> dict | None:
    data = _tea(f"repos/{REPO}/actions/runs?limit=1")
    runs = (data or {}).get("workflow_runs", [])
    return runs[0] if runs else None


# ── state file ────────────────────────────────────────────────────────────────


def _read_state() -> dict | None:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            pass
    return None


def _write_state(pid: int, issue: int | None, kind: str) -> None:
    STATE_FILE.write_text(
        json.dumps(
            {
                "pid": pid,
                "issue": issue,
                "started_at": datetime.now(timezone.utc).isoformat(),
                "type": kind,
            },
            indent=2,
        )
    )


def _clear_state() -> None:
    STATE_FILE.unlink(missing_ok=True)


# ── agent launcher ────────────────────────────────────────────────────────────


def _start_agent(prompt: str, session_name: str) -> int:
    """Start Claude Code as a detached background process and return its PID."""
    log_dir = Path.home() / ".sharedinbox-agent-logs"
    log_dir.mkdir(exist_ok=True)
    ts = datetime.now().strftime("%Y%m%dT%H%M%S")
    log_file = log_dir / f"{session_name}-{ts}.log"

    log_fh = open(log_file, "w")
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

    print(f"[agent_loop] Started agent pid={proc.pid}, log={log_file}")
    print(f"[agent_loop]   Resume: claude --resume {shlex.quote(session_name)}")
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


def _agent_age_seconds(state: dict) -> float:
    """Seconds elapsed since the agent was launched, from the state file timestamp."""
    try:
        started_at = datetime.fromisoformat(state["started_at"])
        return (datetime.now(timezone.utc) - started_at).total_seconds()
    except Exception:
        return 0.0


def _kill_agent(state: dict) -> None:
    """Forcefully stop the running agent."""
    pid = state.get("pid")
    if pid:
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass


# ── subcommands ───────────────────────────────────────────────────────────────


def cmd_list() -> int:
    """List recent agent-loop sessions, newest first."""
    if not CLAUDE_PROJECTS_DIR.exists():
        print(f"[agent_loop] No sessions found (directory missing: {CLAUDE_PROJECTS_DIR})")
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
        print("[agent_loop] No agent sessions found.")
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
    state = _read_state()

    # ── 1. Agent already running? ─────────────────────────────────────────────
    if state and _agent_alive(state):
        age = _agent_age_seconds(state)
        issue = state.get("issue")
        kind = state.get("type", "issue")
        pid = state.get("pid", "?")

        if age > MAX_AGENT_AGE_SECONDS:
            print(
                f"[agent_loop] Agent pid={pid!r} (issue #{issue}) "
                f"has been running for {age/60:.0f} min — aborting."
            )
            _kill_agent(state)
            _clear_state()
            if issue:
                _set_labels(issue, add=[LABEL_QUESTION], remove=[LABEL_IN_PROGRESS])
                print(f"[agent_loop] Set issue #{issue} to State/Question.")
            return 1

        print(
            f"[agent_loop] Agent pid={pid!r} ({kind}, issue #{issue}) "
            f"still running ({age/60:.0f} min). Waiting."
        )
        return 0

    # Agent not running (or no state) — clean up stale state.
    if state:
        _clear_state()

    # ── 2. Check CI ───────────────────────────────────────────────────────────
    run = _latest_ci_run()

    if run and run.get("status") == "running":
        print(f"[agent_loop] CI run {run['id']} is still running. Waiting.")
        return 0

    if run and run.get("status") in ("failure", "error"):
        print(f"[agent_loop] CI run {run['id']} failed — starting fix agent.")
        prompt = (
            "The Codeberg CI for guettli/sharedinbox just failed. "
            f"The CI run ID is {run['id']}. "
            "Fetch the CI logs using the task ci-logs command or the Codeberg API. "
            "Identify the failure, fix it, commit, and push. "
            "Verify locally with 'task check' before pushing. "
            "When done, stop."
        )
        pid = _start_agent(prompt, "ci-fix")
        _write_state(pid, None, "ci-fix")
        return 0

    # CI is ok (or no run) — find a Ready issue.
    issues = _ready_issues()
    if not issues:
        print("[agent_loop] No issues with State/Ready. Nothing to do.")
        return 0

    issue = issues[0]
    issue_number = issue["number"]
    issue_title = issue["title"]
    issue_body = issue.get("body", "")

    print(f"[agent_loop] Starting agent for issue #{issue_number}: {issue_title}")

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
- Push to origin/main.
- If you hit a blocker you cannot resolve, set the issue label to State/Question
  and stop (do NOT close the issue).
- When the work is done and pushed, close the issue and stop.
"""

    pid = _start_agent(prompt, f"issue-{issue_number}")
    _write_state(pid, issue_number, "issue")
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
