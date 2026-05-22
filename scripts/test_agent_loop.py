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


class TestKillAgent(unittest.TestCase):
    def test_kill_sends_sigkill(self):
        with patch("agent_loop.os.kill") as mock_kill:
            agent_loop._kill_agent({"pid": 1234})
            mock_kill.assert_called_once_with(1234, 9)

    def test_kill_ignores_missing_process(self):
        with patch("agent_loop.os.kill", side_effect=ProcessLookupError):
            agent_loop._kill_agent({"pid": 1234})  # Should not raise.

    def test_kill_noop_when_no_pid(self):
        with patch("agent_loop.os.kill") as mock_kill:
            agent_loop._kill_agent({})
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
             patch("agent_loop._latest_ci_run", return_value=None), \
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
             patch("agent_loop._latest_ci_run", return_value=None), \
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
             patch("agent_loop._latest_ci_run", return_value=None), \
             patch("agent_loop._ready_issues", return_value=[]), \
             patch("agent_loop._set_labels") as mock_labels, \
             patch("agent_loop._start_agent") as mock_start:
            result = agent_loop._run_loop()

        self.assertEqual(result, 0)
        mock_labels.assert_not_called()
        mock_start.assert_not_called()


class TestOutputFormat(unittest.TestCase):
    """Verify output format: no [agent_loop] prefix, URLs in output."""

    def test_output_starts_with_header(self):
        buf = io.StringIO()
        with patch("agent_loop._read_state", return_value=None), \
             patch("agent_loop._latest_ci_run", return_value=None), \
             patch("agent_loop._ready_issues", return_value=[]), \
             contextlib.redirect_stdout(buf):
            agent_loop._run_loop()
        first_line = buf.getvalue().splitlines()[0]
        self.assertTrue(first_line.startswith("---------------------- Starting "),
                        f"Unexpected first line: {first_line!r}")

    def test_no_agent_loop_prefix_in_output(self):
        buf = io.StringIO()
        with patch("agent_loop._read_state", return_value=None), \
             patch("agent_loop._latest_ci_run", return_value=None), \
             patch("agent_loop._ready_issues", return_value=[]), \
             contextlib.redirect_stdout(buf):
            agent_loop._run_loop()
        self.assertNotIn("[agent_loop]", buf.getvalue())

    def test_ci_run_output_contains_url(self):
        run = {"id": 4145144, "status": "running"}
        buf = io.StringIO()
        with patch("agent_loop._read_state", return_value=None), \
             patch("agent_loop._latest_ci_run", return_value=run), \
             contextlib.redirect_stdout(buf):
            agent_loop._run_loop()
        self.assertIn("https://codeberg.org/guettli/sharedinbox/actions/runs/4145144",
                      buf.getvalue())

    def test_issue_output_contains_url_and_title(self):
        issue = {"number": 128, "title": "Fix something", "body": "", "labels": []}
        buf = io.StringIO()
        with patch("agent_loop._read_state", return_value=None), \
             patch("agent_loop._latest_ci_run", return_value=None), \
             patch("agent_loop._ready_issues", return_value=[issue]), \
             patch("agent_loop._set_labels"), \
             patch("agent_loop._start_agent", return_value=99), \
             patch("agent_loop._write_state"), \
             contextlib.redirect_stdout(buf):
            agent_loop._run_loop()
        output = buf.getvalue()
        self.assertIn("https://codeberg.org/guettli/sharedinbox/issues/128", output)
        self.assertIn("Fix something", output)


if __name__ == "__main__":
    unittest.main()
