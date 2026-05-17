#!/usr/bin/env python3
"""Tests for agent_loop.py."""
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


if __name__ == "__main__":
    unittest.main()
