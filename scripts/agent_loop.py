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
  { "tmux_session": "issue-91", "issue": 91,
    "started_at": "2026-05-15T12:00:00+00:00", "type": "issue" }

The agent runs inside a detached tmux session so you can watch it live or
resume the Claude conversation afterward:

  tmux attach -t issue-91          # watch while running
  claude --resume issue-91         # continue the conversation later
"""

import json
import os
import shlex
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

# Cron runs with a minimal PATH; ensure Nix profile binaries (tea, claude) are found.
os.environ["PATH"] = f"/home/si/.nix-profile/bin:{os.environ.get('PATH', '/usr/bin:/bin')}"

# ── configuration ─────────────────────────────────────────────────────────────

REPO = "guettli/sharedinbox"
STATE_FILE = Path.home() / ".sharedinbox-agent-state.json"
MAX_AGENT_AGE_SECONDS = 3600  # 1 hour

# Labels used by the workflow.
LABEL_READY = "State/Ready"
LABEL_IN_PROGRESS = "State/InProgress"
LABEL_QUESTION = "State/Question"

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
    """Return open issues with State/Ready, oldest first."""
    data = _tea(f"repos/{REPO}/issues?state=open&type=issues&limit=50") or []
    ready = [
        i for i in data
        if any(lbl["name"] == LABEL_READY for lbl in i.get("labels", []))
    ]
    ready.sort(key=lambda i: i["number"])
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


def _write_state(tmux_session: str, issue: int | None, kind: str) -> None:
    STATE_FILE.write_text(
        json.dumps(
            {
                "tmux_session": tmux_session,
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


def _start_agent(prompt: str, session_name: str) -> str:
    """
    Start Claude Code inside a detached tmux session and return the session name.

    The session inherits the tmux server's environment (including ANTHROPIC_API_KEY
    and any keychain access), which is more reliable than cron's minimal env.
    Output is written to both the tmux scrollback buffer and a log file via tee.
    """
    log_dir = Path.home() / ".sharedinbox-agent-logs"
    log_dir.mkdir(exist_ok=True)
    ts = datetime.now().strftime("%Y%m%dT%H%M%S")
    log_file = log_dir / f"{session_name}-{ts}.log"

    # Kill any stale session with this name before creating a new one.
    subprocess.run(["tmux", "kill-session", "-t", session_name], capture_output=True)

    # printf '\n' answers the workspace-trust dialog (press Enter to confirm the
    # default "Yes, I trust this folder") when claude shows it despite -p mode.
    # After that newline, stdin hits EOF, which -p mode ignores.
    shell_cmd = (
        f"printf '\\n' | claude --dangerously-skip-permissions"
        f" --name {shlex.quote(session_name)}"
        f" -p {shlex.quote(prompt)}"
        f" 2>&1 | tee {shlex.quote(str(log_file))}"
    )
    subprocess.run(
        ["tmux", "new-session", "-d", "-s", session_name, "bash", "-c", shell_cmd],
        check=True,
    )
    print(f"[agent_loop] Started tmux session={session_name!r}, log={log_file}")
    print(f"[agent_loop]   Watch:  tmux attach -t {shlex.quote(session_name)}")
    print(f"[agent_loop]   Resume: claude --resume {shlex.quote(session_name)}")
    return session_name


def _agent_alive(state: dict) -> bool:
    """Return True if the agent's tmux session is still running."""
    session = state.get("tmux_session")
    if session:
        r = subprocess.run(
            ["tmux", "has-session", "-t", session], capture_output=True
        )
        return r.returncode == 0
    # Backward compat: old state files stored a pid instead of a tmux session.
    pid = state.get("pid")
    if pid is not None:
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
    return False


def _agent_age_seconds(state: dict) -> float:
    """Seconds elapsed since the agent was launched, from the state file timestamp."""
    try:
        started_at = datetime.fromisoformat(state["started_at"])
        return (datetime.now(timezone.utc) - started_at).total_seconds()
    except Exception:
        return 0.0


def _kill_agent(state: dict) -> None:
    """Forcefully stop the running agent."""
    session = state.get("tmux_session")
    if session:
        subprocess.run(["tmux", "kill-session", "-t", session], capture_output=True)
        return
    pid = state.get("pid")
    if pid:
        try:
            os.kill(pid, 9)
        except ProcessLookupError:
            pass


# ── main flow ─────────────────────────────────────────────────────────────────


def main() -> int:
    state = _read_state()

    # ── 1. Agent already running? ─────────────────────────────────────────────
    if state and _agent_alive(state):
        age = _agent_age_seconds(state)
        issue = state.get("issue")
        kind = state.get("type", "issue")
        session = state.get("tmux_session", state.get("pid", "?"))

        if age > MAX_AGENT_AGE_SECONDS:
            print(
                f"[agent_loop] Agent session={session!r} (issue #{issue}) "
                f"has been running for {age/60:.0f} min — aborting."
            )
            _kill_agent(state)
            _clear_state()
            if issue:
                _set_labels(issue, add=[LABEL_QUESTION], remove=[LABEL_IN_PROGRESS])
                print(f"[agent_loop] Set issue #{issue} to State/Question.")
            return 1

        print(
            f"[agent_loop] Agent session={session!r} ({kind}, issue #{issue}) "
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
        session_name = _start_agent(prompt, "ci-fix")
        _write_state(session_name, None, "ci-fix")
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

    session_name = _start_agent(prompt, f"issue-{issue_number}")
    _write_state(session_name, issue_number, "issue")
    return 0


if __name__ == "__main__":
    sys.exit(main())
