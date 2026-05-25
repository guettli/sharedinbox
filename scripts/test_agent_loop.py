#!/usr/bin/env python3
"""Tests for agent_loop.py."""
import contextlib
import io
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

import sys
sys.path.insert(0, str(Path(__file__).parent))

import agent_loop


class TestUrlHelpers(unittest.TestCase):
    def test_issue_url(self):
        url = agent_loop._issue_url(128)
        self.assertEqual(url, "https://codeberg.org/guettli/sharedinbox/issues/128")

    def test_ci_run_url(self):
        url = agent_loop._ci_run_url(4145144)
        self.assertEqual(url, "https://codeberg.org/guettli/sharedinbox/actions/runs/4145144")


class TestStateFile(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".json")
        self._tmp.close()
        self._orig = agent_loop.STATE_FILE
        agent_loop.STATE_FILE = Path(self._tmp.name)
        Path(self._tmp.name).unlink()  # Start with no state file.

    def tearDown(self):
        agent_loop.STATE_FILE = self._orig
        Path(self._tmp.name).unlink(missing_ok=True)

    def test_write_state_stores_pid(self):
        agent_loop._write_state(12345, 91, "issue")
        data = json.loads(Path(self._tmp.name).read_text())
        self.assertEqual(data["pid"], 12345)
        self.assertNotIn("tmux_session", data)

    def test_write_state_stores_issue_and_kind(self):
        agent_loop._write_state(99, 7, "ci-fix")
        data = json.loads(Path(self._tmp.name).read_text())
        self.assertEqual(data["issue"], 7)
        self.assertEqual(data["type"], "ci-fix")
        self.assertIn("started_at", data)

    def test_read_state_returns_none_when_missing(self):
        self.assertIsNone(agent_loop._read_state())

    def test_read_and_write_roundtrip(self):
        agent_loop._write_state(42, 10, "issue")
        state = agent_loop._read_state()
        self.assertIsNotNone(state)
        self.assertEqual(state["pid"], 42)
        self.assertEqual(state["issue"], 10)

    def test_clear_state_removes_file(self):
        agent_loop._write_state(1, None, "ci-fix")
        agent_loop._clear_state()
        self.assertIsNone(agent_loop._read_state())

    def test_write_state_stores_issue_title(self):
        agent_loop._write_state(42, 10, "issue", "My Test Issue")
        data = json.loads(Path(self._tmp.name).read_text())
        self.assertEqual(data["issue_title"], "My Test Issue")

    def test_write_state_omits_issue_title_when_none(self):
        agent_loop._write_state(42, None, "ci-fix")
        data = json.loads(Path(self._tmp.name).read_text())
        self.assertNotIn("issue_title", data)


class TestAgentAlive(unittest.TestCase):
    def test_own_pid_is_alive(self):
        self.assertTrue(agent_loop._agent_alive({"pid": os.getpid()}))

    def test_nonexistent_pid_is_dead(self):
        self.assertFalse(agent_loop._agent_alive({"pid": 999999999}))

    def test_missing_pid_returns_false(self):
        self.assertFalse(agent_loop._agent_alive({}))
        self.assertFalse(agent_loop._agent_alive({"pid": None}))


class TestIsClaudeProcess(unittest.TestCase):
    def test_returns_true_for_claude_comm(self):
        with patch.object(agent_loop.Path, "read_text", return_value="claude\n"):
            self.assertTrue(agent_loop._is_claude_process(1234))

    def test_returns_true_for_node_comm(self):
        with patch.object(agent_loop.Path, "read_text", return_value="node\n"):
            self.assertTrue(agent_loop._is_claude_process(1234))

    def test_returns_false_for_other_process(self):
        with patch.object(agent_loop.Path, "read_text", return_value="bash\n"):
            self.assertFalse(agent_loop._is_claude_process(1234))

    def test_returns_false_when_proc_missing(self):
        with patch.object(agent_loop.Path, "read_text", side_effect=OSError):
            self.assertFalse(agent_loop._is_claude_process(1234))


class TestKillAgent(unittest.TestCase):
    def test_kill_sends_sigkill(self):
        with patch("agent_loop._is_claude_process", return_value=True):
            with patch("agent_loop.os.kill") as mock_kill:
                agent_loop._kill_agent({"pid": 1234})
                mock_kill.assert_called_once_with(1234, 9)

    def test_kill_ignores_missing_process(self):
        with patch("agent_loop._is_claude_process", return_value=True):
            with patch("agent_loop.os.kill", side_effect=ProcessLookupError):
                agent_loop._kill_agent({"pid": 1234})  # Should not raise.

    def test_kill_noop_when_no_pid(self):
        with patch("agent_loop.os.kill") as mock_kill:
            agent_loop._kill_agent({})
            mock_kill.assert_not_called()

    def test_kill_skips_recycled_pid(self):
        with patch("agent_loop._is_claude_process", return_value=False):
            with patch("agent_loop.os.kill") as mock_kill:
                agent_loop._kill_agent({"pid": 1234})
                mock_kill.assert_not_called()


class TestStartAgent(unittest.TestCase):
    def _make_mock_proc(self, pid=42):
        proc = MagicMock()
        proc.pid = pid
        proc.stdin = io.BytesIO()
        return proc

    def test_start_agent_returns_pid(self):
        mock_proc = self._make_mock_proc(pid=42)
        with tempfile.TemporaryDirectory() as tmpdir:
            with patch("agent_loop.subprocess.Popen", return_value=mock_proc):
                with patch.object(agent_loop.Path, "home", return_value=Path(tmpdir)):
                    result = agent_loop._start_agent("do something", "issue-99")
        self.assertEqual(result, 42)

    def test_start_agent_uses_popen_not_tmux(self):
        mock_proc = self._make_mock_proc(pid=7)
        with tempfile.TemporaryDirectory() as tmpdir:
            with patch("agent_loop.subprocess.Popen", return_value=mock_proc) as mock_popen:
                with patch("agent_loop.subprocess.run") as mock_run:
                    with patch.object(agent_loop.Path, "home", return_value=Path(tmpdir)):
                        agent_loop._start_agent("prompt", "ci-fix")
            mock_popen.assert_called_once()
            mock_run.assert_not_called()

    def test_start_agent_passes_session_name_to_claude(self):
        mock_proc = self._make_mock_proc(pid=7)
        with tempfile.TemporaryDirectory() as tmpdir:
            with patch("agent_loop.subprocess.Popen", return_value=mock_proc) as mock_popen:
                with patch.object(agent_loop.Path, "home", return_value=Path(tmpdir)):
                    agent_loop._start_agent("prompt", "issue-55")
            cmd = mock_popen.call_args[0][0]
            self.assertIn("issue-55", cmd)
            self.assertIn("claude", cmd[0])

    def test_start_agent_uses_start_new_session(self):
        mock_proc = self._make_mock_proc(pid=7)
        with tempfile.TemporaryDirectory() as tmpdir:
            with patch("agent_loop.subprocess.Popen", return_value=mock_proc) as mock_popen:
                with patch.object(agent_loop.Path, "home", return_value=Path(tmpdir)):
                    agent_loop._start_agent("prompt", "issue-55")
            kwargs = mock_popen.call_args[1]
            self.assertTrue(kwargs.get("start_new_session"))


class TestMain(unittest.TestCase):
    """Tests for the main() flow."""

    def _make_mock_proc(self, pid=42):
        proc = MagicMock()
        proc.pid = pid
        proc.stdin = io.BytesIO()
        return proc

    def _make_issue(self, number=10, title="Do something"):
        return {"number": number, "title": title, "body": "", "labels": []}

    def test_sets_in_progress_before_starting_agent(self):
        """_set_labels(InProgress) must be called before _start_agent."""
        call_order = []
        mock_proc = self._make_mock_proc(pid=55)

        def fake_set_labels(issue, add, remove):
            call_order.append(("set_labels", add, remove))

        def fake_start_agent(prompt, session_name):
            call_order.append(("start_agent", session_name))
            return 55

        with patch("agent_loop._read_state", return_value=None), \
             patch("agent_loop._open_issue_prs", return_value=[]), \
             patch("agent_loop._latest_main_ci_run", return_value=None), \
             patch("agent_loop._ready_issues", return_value=[self._make_issue(10)]), \
             patch("agent_loop._set_labels", side_effect=fake_set_labels), \
             patch("agent_loop._start_agent", side_effect=fake_start_agent), \
             patch("agent_loop._write_state"):
            result = agent_loop._run_loop()

        self.assertEqual(result, 0)
        labels_idx = next(
            i for i, c in enumerate(call_order) if c[0] == "set_labels"
        )
        agent_idx = next(
            i for i, c in enumerate(call_order) if c[0] == "start_agent"
        )
        self.assertLess(labels_idx, agent_idx,
                        "_set_labels must be called before _start_agent")

    def test_sets_in_progress_label_and_removes_ready(self):
        """The InProgress label is added and the Ready label is removed."""
        captured = {}

        def fake_set_labels(issue, add, remove):
            captured["add"] = add
            captured["remove"] = remove

        with patch("agent_loop._read_state", return_value=None), \
             patch("agent_loop._open_issue_prs", return_value=[]), \
             patch("agent_loop._latest_main_ci_run", return_value=None), \
             patch("agent_loop._ready_issues", return_value=[self._make_issue(7)]), \
             patch("agent_loop._set_labels", side_effect=fake_set_labels), \
             patch("agent_loop._start_agent", return_value=99), \
             patch("agent_loop._write_state"):
            agent_loop._run_loop()

        self.assertIn(agent_loop.LABEL_IN_PROGRESS, captured.get("add", []))
        self.assertIn(agent_loop.LABEL_READY, captured.get("remove", []))

    def test_no_ready_issues_does_nothing(self):
        """main() exits cleanly with 0 when there are no ready issues."""
        with patch("agent_loop._read_state", return_value=None), \
             patch("agent_loop._open_issue_prs", return_value=[]), \
             patch("agent_loop._latest_main_ci_run", return_value=None), \
             patch("agent_loop._ready_issues", return_value=[]), \
             patch("agent_loop._set_labels") as mock_labels, \
             patch("agent_loop._start_agent") as mock_start:
            result = agent_loop._run_loop()

        self.assertEqual(result, 0)
        mock_labels.assert_not_called()
        mock_start.assert_not_called()

    def test_prompt_does_not_tell_agent_to_close_issue(self):
        """Agents must not close issues; the loop handles closing after CI passes."""
        captured_prompt = {}

        def fake_start_agent(prompt, session_name):
            captured_prompt["prompt"] = prompt
            return 77

        with patch("agent_loop._read_state", return_value=None), \
             patch("agent_loop._open_issue_prs", return_value=[]), \
             patch("agent_loop._latest_main_ci_run", return_value=None), \
             patch("agent_loop._ready_issues", return_value=[self._make_issue(42)]), \
             patch("agent_loop._set_labels"), \
             patch("agent_loop._start_agent", side_effect=fake_start_agent), \
             patch("agent_loop._write_state"):
            agent_loop._run_loop()

        prompt = captured_prompt.get("prompt", "")
        # "do NOT close the issue" (blocker instruction) is fine; what must be
        # absent is any affirmative instruction to close on completion.
        self.assertNotIn("close the issue and stop", prompt.lower())


class TestPendingCi(unittest.TestCase):
    """Tests for the pending-CI state: issue closed only after CI passes."""

    def _dead_state(self, issue: int, kind: str = "issue") -> dict:
        return {
            "pid": 999999999,  # non-existent PID
            "issue": issue,
            "started_at": "2026-01-01T00:00:00+00:00",
            "type": kind,
        }

    def _open_pr(self, branch: str = "issue-10-fix") -> dict:
        return {"number": 5, "head": {"ref": branch}, "created_at": "2026-01-01T00:00:00+00:00"}

    def _find_pr_open(self, branch, state="open"):
        if state == "open":
            return self._open_pr(branch)
        return None

    def test_closes_issue_when_ci_passes_after_agent_finishes(self):
        """After issue agent finishes, loop merges the PR and closes the issue once CI is green."""
        # First call: PR found open. Second call (post-merge verification): PR closed.
        with patch("agent_loop._read_state", return_value=self._dead_state(10)), \
             patch("agent_loop._find_pr_for_branch", side_effect=[self._open_pr(), None]), \
             patch("agent_loop._latest_ci_run_for_branch", return_value={"id": 1, "status": "success"}), \
             patch("agent_loop._merge_pr") as mock_merge, \
             patch("agent_loop._close_issue") as mock_close, \
             patch("agent_loop._clear_state"):
            result = agent_loop._run_loop()

        self.assertEqual(result, 0)
        mock_merge.assert_called_once_with(5)
        mock_close.assert_called_once_with(10)

    def test_ci_passed_output_includes_ci_run_url(self):
        """'CI passed' line includes the CI run URL when a run is available."""
        buf = io.StringIO()
        with patch("agent_loop._read_state", return_value=self._dead_state(10)), \
             patch("agent_loop._find_pr_for_branch", side_effect=[self._open_pr(), None]), \
             patch("agent_loop._latest_ci_run_for_branch", return_value={"id": 4145144, "status": "success"}), \
             patch("agent_loop._merge_pr"), \
             patch("agent_loop._close_issue"), \
             patch("agent_loop._clear_state"), \
             contextlib.redirect_stdout(buf):
            agent_loop._run_loop()
        output = buf.getvalue()
        self.assertIn("https://codeberg.org/guettli/sharedinbox/actions/runs/4145144", output)
        self.assertIn("https://codeberg.org/guettli/sharedinbox/issues/10", output)

    def test_already_merged_pr_closes_issue_without_ci_url(self):
        """When the PR was already merged, the issue is closed and no CI run URL appears."""
        def find_pr(branch, state="open"):
            if state == "closed":
                return {"number": 5, "merged": True}
            return None

        buf = io.StringIO()
        with patch("agent_loop._read_state", return_value=self._dead_state(10)), \
             patch("agent_loop._find_pr_for_branch", side_effect=find_pr), \
             patch("agent_loop._close_issue") as mock_close, \
             patch("agent_loop._clear_state"), \
             contextlib.redirect_stdout(buf):
            result = agent_loop._run_loop()
        output = buf.getvalue()
        self.assertEqual(result, 0)
        mock_close.assert_called_once_with(10)
        self.assertIn("already merged", output)
        self.assertNotIn("/actions/runs/", output)

    def test_no_pr_found_sets_question_label(self):
        """When no open or merged PR exists for the pending branch, set State/Question."""
        with patch("agent_loop._read_state", return_value=self._dead_state(10)), \
             patch("agent_loop._find_pr_for_branch", return_value=None), \
             patch("agent_loop._set_labels") as mock_labels, \
             patch("agent_loop._comment_issue") as mock_comment, \
             patch("agent_loop._close_issue") as mock_close, \
             patch("agent_loop._clear_state"):
            result = agent_loop._run_loop()

        self.assertEqual(result, 0)
        mock_close.assert_not_called()
        mock_labels.assert_called_once_with(
            10,
            add=[agent_loop.LABEL_QUESTION],
            remove=[agent_loop.LABEL_IN_PROGRESS],
        )
        mock_comment.assert_called_once()
        self.assertIn("issue-10-fix", mock_comment.call_args[0][1])

    def test_does_not_close_issue_when_ci_fails(self):
        """After issue agent finishes, loop must NOT close the issue if CI failed on PR branch."""
        with patch("agent_loop._read_state", return_value=self._dead_state(10)), \
             patch("agent_loop._find_pr_for_branch", side_effect=self._find_pr_open), \
             patch("agent_loop._latest_ci_run_for_branch", return_value={"id": 1, "status": "failure"}), \
             patch("agent_loop._close_issue") as mock_close, \
             patch("agent_loop._start_agent", return_value=55), \
             patch("agent_loop._write_state"), \
             patch("agent_loop._clear_state"):
            result = agent_loop._run_loop()

        self.assertEqual(result, 0)
        mock_close.assert_not_called()

    def test_saves_pending_ci_state_while_ci_running(self):
        """When CI is still running on PR branch after agent finishes, pending issue is preserved."""
        written = {}

        def fake_write_state(pid, issue, kind, issue_title=None, session_name=None, ci_run_id=None):
            written["pid"] = pid
            written["issue"] = issue
            written["kind"] = kind

        with patch("agent_loop._read_state", return_value=self._dead_state(10)), \
             patch("agent_loop._find_pr_for_branch", side_effect=self._find_pr_open), \
             patch("agent_loop._latest_ci_run_for_branch", return_value={"id": 1, "status": "running"}), \
             patch("agent_loop._write_state", side_effect=fake_write_state), \
             patch("agent_loop._clear_state"):
            result = agent_loop._run_loop()

        self.assertEqual(result, 0)
        self.assertEqual(written.get("issue"), 10)
        self.assertEqual(written.get("kind"), "pending-ci")
        self.assertIsNone(written.get("pid"))

    def test_ci_fix_preserves_pending_issue_in_state(self):
        """When CI fails on PR branch after agent finishes, ci-fix state includes the pending issue."""
        written = {}

        def fake_write_state(pid, issue, kind, issue_title=None, session_name=None, ci_run_id=None):
            written["pid"] = pid
            written["issue"] = issue
            written["kind"] = kind

        with patch("agent_loop._read_state", return_value=self._dead_state(10)), \
             patch("agent_loop._find_pr_for_branch", side_effect=self._find_pr_open), \
             patch("agent_loop._latest_ci_run_for_branch", return_value={"id": 1, "status": "failure"}), \
             patch("agent_loop._start_agent", return_value=55), \
             patch("agent_loop._write_state", side_effect=fake_write_state), \
             patch("agent_loop._clear_state"):
            result = agent_loop._run_loop()

        self.assertEqual(result, 0)
        self.assertEqual(written.get("issue"), 10)
        self.assertEqual(written.get("kind"), "ci-fix")

    def test_closes_issue_after_ci_fix_and_ci_passes(self):
        """After ci-fix agent finishes and CI passes on PR branch, the pending issue is closed."""
        with patch("agent_loop._read_state", return_value=self._dead_state(10, "ci-fix")), \
             patch("agent_loop._find_pr_for_branch", side_effect=[self._open_pr(), None]), \
             patch("agent_loop._latest_ci_run_for_branch", return_value={"id": 1, "status": "success"}), \
             patch("agent_loop._merge_pr") as mock_merge, \
             patch("agent_loop._close_issue") as mock_close, \
             patch("agent_loop._clear_state"):
            result = agent_loop._run_loop()

        self.assertEqual(result, 0)
        mock_merge.assert_called_once_with(5)
        mock_close.assert_called_once_with(10)

    def test_no_pending_issue_ci_fix_without_issue(self):
        """ci-fix for a manual push (no pending issue) does not try to close anything."""
        with patch("agent_loop._read_state", return_value={
            "pid": 999999999, "issue": None, "started_at": "2026-01-01T00:00:00+00:00",
            "type": "ci-fix",
        }), \
             patch("agent_loop._open_issue_prs", return_value=[]), \
             patch("agent_loop._latest_main_ci_run", return_value={"id": 1, "status": "success"}), \
             patch("agent_loop._close_issue") as mock_close, \
             patch("agent_loop._ready_issues", return_value=[]), \
             patch("agent_loop._clear_state"):
            result = agent_loop._run_loop()

        self.assertEqual(result, 0)
        mock_close.assert_not_called()


class TestOutputFormat(unittest.TestCase):
    """Verify output format: no [agent_loop] prefix, URLs in output."""

    def test_output_starts_with_header(self):
        buf = io.StringIO()
        with patch("agent_loop._read_state", return_value=None), \
             patch("agent_loop._open_issue_prs", return_value=[]), \
             patch("agent_loop._latest_main_ci_run", return_value=None), \
             patch("agent_loop._ready_issues", return_value=[]), \
             contextlib.redirect_stdout(buf):
            agent_loop._run_loop()
        first_line = buf.getvalue().splitlines()[0]
        self.assertTrue(first_line.startswith("---------------------- Starting "),
                        f"Unexpected first line: {first_line!r}")

    def test_no_agent_loop_prefix_in_output(self):
        buf = io.StringIO()
        with patch("agent_loop._read_state", return_value=None), \
             patch("agent_loop._open_issue_prs", return_value=[]), \
             patch("agent_loop._latest_main_ci_run", return_value=None), \
             patch("agent_loop._ready_issues", return_value=[]), \
             contextlib.redirect_stdout(buf):
            agent_loop._run_loop()
        self.assertNotIn("[agent_loop]", buf.getvalue())

    def test_ci_run_output_contains_url(self):
        run = {"id": 4145144, "status": "running"}
        buf = io.StringIO()
        with patch("agent_loop._read_state", return_value=None), \
             patch("agent_loop._open_issue_prs", return_value=[]), \
             patch("agent_loop._latest_main_ci_run", return_value=run), \
             contextlib.redirect_stdout(buf):
            agent_loop._run_loop()
        self.assertIn("https://codeberg.org/guettli/sharedinbox/actions/runs/4145144",
                      buf.getvalue())

    def test_issue_output_contains_url_and_title(self):
        issue = {"number": 128, "title": "Fix something", "body": "", "labels": []}
        buf = io.StringIO()
        with patch("agent_loop._read_state", return_value=None), \
             patch("agent_loop._open_issue_prs", return_value=[]), \
             patch("agent_loop._latest_main_ci_run", return_value=None), \
             patch("agent_loop._ready_issues", return_value=[issue]), \
             patch("agent_loop._set_labels"), \
             patch("agent_loop._start_agent", return_value=99), \
             patch("agent_loop._write_state"), \
             contextlib.redirect_stdout(buf):
            agent_loop._run_loop()
        output = buf.getvalue()
        self.assertIn("https://codeberg.org/guettli/sharedinbox/issues/128", output)
        self.assertIn("Fix something", output)


class TestLatestMainCiRun(unittest.TestCase):
    """_latest_main_ci_run() must return only ci.yml push-to-main runs."""

    def _ci_run(self, run_id, status="success"):
        return {"event": "push", "prettyref": "main", "workflow_id": "ci.yml",
                "status": status, "id": run_id}

    def _deploy_run(self, run_id, status="success"):
        return {"event": "push", "prettyref": "main", "workflow_id": "deploy.yml",
                "status": status, "id": run_id}

    def test_skips_deploy_run_returns_ci_run(self):
        # Forgejo reports deploy.yml schedule runs as event=push/prettyref=main;
        # must be excluded by workflow_id filter.
        runs = [self._deploy_run(1), self._ci_run(2)]
        with patch("agent_loop._tea_get", return_value={"workflow_runs": runs}):
            result = agent_loop._latest_main_ci_run()
        self.assertIsNotNone(result)
        self.assertEqual(result["id"], 2)

    def test_returns_none_when_only_deploy_runs_exist(self):
        runs = [self._deploy_run(1)]
        with patch("agent_loop._tea_get", return_value={"workflow_runs": runs}):
            result = agent_loop._latest_main_ci_run()
        self.assertIsNone(result)

    def test_returns_none_when_only_schedule_runs_exist(self):
        runs = [{"event": "schedule", "prettyref": "main", "workflow_id": "deploy.yml",
                 "status": "success", "id": 1}]
        with patch("agent_loop._tea_get", return_value={"workflow_runs": runs}):
            result = agent_loop._latest_main_ci_run()
        self.assertIsNone(result)

    def test_returns_ci_push_to_main_run(self):
        runs = [self._ci_run(42, status="running")]
        with patch("agent_loop._tea_get", return_value={"workflow_runs": runs}):
            result = agent_loop._latest_main_ci_run()
        self.assertIsNotNone(result)
        self.assertEqual(result["id"], 42)


class TestLatestCiRunForBranch(unittest.TestCase):
    """Tests for _latest_ci_run_for_branch — Forgejo API field mapping."""

    def _make_pr_run(self, branch: str, status: str = "success") -> dict:
        payload = json.dumps({"pull_request": {"head": {"ref": branch}}})
        return {"event": "pull_request", "event_payload": payload, "status": status, "id": 1}

    def _make_push_run(self, prettyref: str, status: str = "success") -> dict:
        return {"event": "push", "prettyref": prettyref, "status": status, "id": 2}

    def _mock_tea_runs(self, runs):
        with patch("agent_loop._tea_get", return_value={"workflow_runs": runs}) as m:
            yield m

    def test_pr_event_matches_via_event_payload(self):
        run = self._make_pr_run("issue-166-fix")
        with patch("agent_loop._tea_get", return_value={"workflow_runs": [run]}):
            result = agent_loop._latest_ci_run_for_branch("issue-166-fix")
        self.assertIsNotNone(result)
        self.assertEqual(result["id"], 1)

    def test_pr_event_does_not_match_wrong_branch(self):
        run = self._make_pr_run("issue-99-fix")
        with patch("agent_loop._tea_get", return_value={"workflow_runs": [run]}):
            result = agent_loop._latest_ci_run_for_branch("issue-166-fix")
        self.assertIsNone(result)

    def test_push_event_matches_via_prettyref(self):
        run = self._make_push_run("issue-166-fix")
        with patch("agent_loop._tea_get", return_value={"workflow_runs": [run]}):
            result = agent_loop._latest_ci_run_for_branch("issue-166-fix")
        self.assertIsNotNone(result)
        self.assertEqual(result["id"], 2)

    def test_push_event_prettyref_pr_number_does_not_match_branch(self):
        # Forgejo sets prettyref="#169" for PR runs — must not match branch name.
        run = {"event": "push", "prettyref": "#169", "status": "success", "id": 3}
        with patch("agent_loop._tea_get", return_value={"workflow_runs": [run]}):
            result = agent_loop._latest_ci_run_for_branch("issue-166-fix")
        self.assertIsNone(result)

    def test_head_branch_field_absent_still_works(self):
        # Regression: the old code used run.get("head_branch") which is absent in Forgejo.
        run = self._make_pr_run("issue-166-fix")
        self.assertNotIn("head_branch", run)
        with patch("agent_loop._tea_get", return_value={"workflow_runs": [run]}):
            result = agent_loop._latest_ci_run_for_branch("issue-166-fix")
        self.assertIsNotNone(result)

    def test_returns_none_when_no_runs(self):
        with patch("agent_loop._tea_get", return_value={"workflow_runs": []}):
            result = agent_loop._latest_ci_run_for_branch("issue-166-fix")
        self.assertIsNone(result)

    def test_returns_first_matching_run(self):
        runs = [
            self._make_pr_run("issue-166-fix", status="success"),
            self._make_pr_run("issue-166-fix", status="failure"),
        ]
        runs[0]["id"] = 10
        runs[1]["id"] = 11
        with patch("agent_loop._tea_get", return_value={"workflow_runs": runs}):
            result = agent_loop._latest_ci_run_for_branch("issue-166-fix")
        self.assertEqual(result["id"], 10)


class TestFindSessionUuid(unittest.TestCase):
    """Tests for _find_session_uuid()."""

    def _write_jsonl(self, directory: Path, filename: str, entries: list) -> Path:
        path = directory / filename
        with path.open("w") as fh:
            for entry in entries:
                fh.write(json.dumps(entry) + "\n")
        return path

    def test_returns_uuid_for_matching_session_name(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            projects_dir = Path(tmpdir)
            self._write_jsonl(projects_dir, "abc123.jsonl", [
                {"type": "agent-name", "agentName": "issue-91", "sessionId": "uuid-abc-123"},
            ])
            orig = agent_loop.CLAUDE_PROJECTS_DIR
            agent_loop.CLAUDE_PROJECTS_DIR = projects_dir
            try:
                result = agent_loop._find_session_uuid("issue-91")
            finally:
                agent_loop.CLAUDE_PROJECTS_DIR = orig
        self.assertEqual(result, "uuid-abc-123")

    def test_returns_none_when_name_does_not_match(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            projects_dir = Path(tmpdir)
            self._write_jsonl(projects_dir, "abc123.jsonl", [
                {"type": "agent-name", "agentName": "issue-99", "sessionId": "uuid-abc-123"},
            ])
            orig = agent_loop.CLAUDE_PROJECTS_DIR
            agent_loop.CLAUDE_PROJECTS_DIR = projects_dir
            try:
                result = agent_loop._find_session_uuid("issue-91")
            finally:
                agent_loop.CLAUDE_PROJECTS_DIR = orig
        self.assertIsNone(result)

    def test_returns_none_when_directory_missing(self):
        orig = agent_loop.CLAUDE_PROJECTS_DIR
        agent_loop.CLAUDE_PROJECTS_DIR = Path("/nonexistent/path/that/does/not/exist")
        try:
            result = agent_loop._find_session_uuid("issue-91")
        finally:
            agent_loop.CLAUDE_PROJECTS_DIR = orig
        self.assertIsNone(result)

    def test_returns_none_when_no_agent_name_entry(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            projects_dir = Path(tmpdir)
            self._write_jsonl(projects_dir, "abc123.jsonl", [
                {"type": "message", "content": "hello"},
            ])
            orig = agent_loop.CLAUDE_PROJECTS_DIR
            agent_loop.CLAUDE_PROJECTS_DIR = projects_dir
            try:
                result = agent_loop._find_session_uuid("issue-91")
            finally:
                agent_loop.CLAUDE_PROJECTS_DIR = orig
        self.assertIsNone(result)

    def test_scans_multiple_files_to_find_match(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            projects_dir = Path(tmpdir)
            self._write_jsonl(projects_dir, "aaa.jsonl", [
                {"type": "agent-name", "agentName": "issue-10", "sessionId": "uuid-10"},
            ])
            self._write_jsonl(projects_dir, "bbb.jsonl", [
                {"type": "agent-name", "agentName": "issue-91", "sessionId": "uuid-91"},
            ])
            orig = agent_loop.CLAUDE_PROJECTS_DIR
            agent_loop.CLAUDE_PROJECTS_DIR = projects_dir
            try:
                result = agent_loop._find_session_uuid("issue-91")
            finally:
                agent_loop.CLAUDE_PROJECTS_DIR = orig
        self.assertEqual(result, "uuid-91")


class TestRunLoopResumeCommand(unittest.TestCase):
    """Tests that _run_loop() shows a UUID-based resume command when agent is running."""

    def _alive_state(self, session_name="issue-91"):
        return {
            "pid": os.getpid(),  # own PID is always alive
            "issue": 91,
            "started_at": "2026-05-23T12:00:00+00:00",
            "type": "issue",
            "session_name": session_name,
        }

    def test_resume_shows_uuid_when_found(self):
        buf = io.StringIO()
        fake_uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        with patch("agent_loop._read_state", return_value=self._alive_state()), \
             patch("agent_loop._agent_alive", return_value=True), \
             patch("agent_loop._agent_age_seconds", return_value=600), \
             patch("agent_loop._find_session_uuid", return_value=fake_uuid), \
             patch("agent_loop._git_summary", return_value=""), \
             contextlib.redirect_stdout(buf):
            agent_loop._run_loop()
        output = buf.getvalue()
        self.assertIn(f"claude --resume {fake_uuid}", output)

    def test_resume_shows_list_hint_when_uuid_not_found(self):
        buf = io.StringIO()
        with patch("agent_loop._read_state", return_value=self._alive_state()), \
             patch("agent_loop._agent_alive", return_value=True), \
             patch("agent_loop._agent_age_seconds", return_value=600), \
             patch("agent_loop._find_session_uuid", return_value=None), \
             patch("agent_loop._git_summary", return_value=""), \
             contextlib.redirect_stdout(buf):
            agent_loop._run_loop()
        output = buf.getvalue()
        self.assertIn("scripts/agent_loop.py list", output)
        # Must NOT show the session name as a valid resume argument.
        self.assertNotIn("claude --resume issue-91", output)

    def test_resume_not_shown_when_no_session_name(self):
        state = self._alive_state()
        del state["session_name"]
        buf = io.StringIO()
        with patch("agent_loop._read_state", return_value=state), \
             patch("agent_loop._agent_alive", return_value=True), \
             patch("agent_loop._agent_age_seconds", return_value=600), \
             patch("agent_loop._find_session_uuid", return_value=None), \
             patch("agent_loop._git_summary", return_value=""), \
             contextlib.redirect_stdout(buf):
            agent_loop._run_loop()
        output = buf.getvalue()
        self.assertNotIn("Resume:", output)



class TestCatchupSkipsQuestionIssues(unittest.TestCase):
    """Catch-up must not retry merging a PR whose issue is already State/Question."""

    def _make_pr(self, pr_number=50, branch="issue-10-fix"):
        return {"number": pr_number, "head": {"ref": branch}}

    def test_skips_merge_when_issue_has_question_label(self):
        pr = self._make_pr()
        ci_run = {"id": 999, "status": "success"}
        with patch("agent_loop._read_state", return_value=None), \
             patch("agent_loop._open_issue_prs", return_value=[pr]), \
             patch("agent_loop._latest_ci_run_for_pr", return_value=ci_run), \
             patch("agent_loop._get_issue_labels", return_value=[agent_loop.LABEL_QUESTION]), \
             patch("agent_loop._merge_pr") as mock_merge, \
             patch("agent_loop._comment_issue") as mock_comment, \
             patch("agent_loop._set_labels") as mock_labels, \
             patch("agent_loop._latest_main_ci_run", return_value=None), \
             patch("agent_loop._ready_issues", return_value=[]):
            result = agent_loop._run_loop()
        self.assertEqual(result, 0)
        mock_merge.assert_not_called()
        mock_comment.assert_not_called()
        mock_labels.assert_not_called()

    def test_proceeds_with_merge_when_issue_lacks_question_label(self):
        pr = self._make_pr()
        ci_run = {"id": 999, "status": "success"}
        with patch("agent_loop._read_state", return_value=None), \
             patch("agent_loop._open_issue_prs", return_value=[pr]), \
             patch("agent_loop._latest_ci_run_for_pr", return_value=ci_run), \
             patch("agent_loop._get_issue_labels", return_value=[agent_loop.LABEL_IN_PROGRESS]), \
             patch("agent_loop._merge_pr") as mock_merge, \
             patch("agent_loop._find_pr_for_branch", return_value=None), \
             patch("agent_loop._close_issue"):
            result = agent_loop._run_loop()
        self.assertEqual(result, 0)
        mock_merge.assert_called_once_with(50)


if __name__ == "__main__":
    unittest.main()
