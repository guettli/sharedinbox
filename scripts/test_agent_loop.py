#!/usr/bin/env python3
"""Tests for scripts/agent_loop.py."""
import json
import unittest
from pathlib import Path
from unittest.mock import MagicMock, call, patch


class TestStartAgent(unittest.TestCase):
    """Verify that _start_agent builds the correct tmux / claude command."""

    def _run(self, prompt: str, session_name: str):
        """Call _start_agent with all subprocess.run calls mocked out."""
        calls: list = []

        def fake_run(cmd, **kwargs):
            calls.append(cmd)
            return MagicMock(returncode=0)

        with (
            patch("scripts.agent_loop.subprocess.run", side_effect=fake_run),
            patch("scripts.agent_loop.Path.mkdir"),
        ):
            import scripts.agent_loop as al
            al._start_agent(prompt, session_name)

        return calls

    def _get_shell_cmd(self, calls: list) -> str:
        """Extract the shell command string from tmux new-session call."""
        for cmd in calls:
            if "new-session" in cmd:
                # last element is the shell_cmd passed to bash -c
                return cmd[-1]
        self.fail("tmux new-session call not found")

    def test_no_print_flag(self):
        calls = self._run("Do something", "issue-1")
        shell_cmd = self._get_shell_cmd(calls)
        self.assertNotIn(" -p ", shell_cmd)
        self.assertNotIn("--print", shell_cmd)

    def test_prompt_included_in_cmd(self):
        calls = self._run("Fix the bug", "issue-42")
        shell_cmd = self._get_shell_cmd(calls)
        self.assertIn("Fix the bug", shell_cmd)

    def test_session_name_in_cmd(self):
        calls = self._run("task prompt", "issue-99")
        shell_cmd = self._get_shell_cmd(calls)
        self.assertIn("issue-99", shell_cmd)

    def test_dangerously_skip_permissions_present(self):
        calls = self._run("prompt", "ci-fix")
        shell_cmd = self._get_shell_cmd(calls)
        self.assertIn("--dangerously-skip-permissions", shell_cmd)

    def test_prompt_with_special_chars_is_quoted(self):
        prompt = "Fix issue #42; rm -rf /"
        calls = self._run(prompt, "issue-42")
        shell_cmd = self._get_shell_cmd(calls)
        # The dangerous part should be inside quotes, not interpreted by shell
        self.assertNotIn("; rm -rf /", shell_cmd.split("'")[-1])

    def test_tmux_new_session_is_detached(self):
        calls = self._run("prompt", "issue-1")
        new_session_call = next(c for c in calls if "new-session" in c)
        self.assertIn("-d", new_session_call)

    def test_tmux_new_session_uses_correct_name(self):
        calls = self._run("prompt", "issue-7")
        new_session_call = next(c for c in calls if "new-session" in c)
        self.assertIn("issue-7", new_session_call)

    def test_pipe_pane_called_for_logging(self):
        calls = self._run("prompt", "issue-1")
        pipe_pane_calls = [c for c in calls if "pipe-pane" in c]
        self.assertEqual(len(pipe_pane_calls), 1)

    def test_returns_session_name(self):
        with (
            patch("scripts.agent_loop.subprocess.run", return_value=MagicMock(returncode=0)),
            patch("scripts.agent_loop.Path.mkdir"),
        ):
            import scripts.agent_loop as al
            result = al._start_agent("prompt", "issue-55")
        self.assertEqual(result, "issue-55")


class TestWriteAndReadState(unittest.TestCase):
    def test_roundtrip(self):
        import tempfile
        import scripts.agent_loop as al
        with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as f:
            tmp = Path(f.name)
        original = al.STATE_FILE
        try:
            al.STATE_FILE = tmp
            al._write_state("issue-10", 10, "issue")
            state = al._read_state()
            self.assertEqual(state["tmux_session"], "issue-10")
            self.assertEqual(state["issue"], 10)
            self.assertEqual(state["type"], "issue")
        finally:
            al.STATE_FILE = original
            tmp.unlink(missing_ok=True)

    def test_read_missing_returns_none(self):
        import scripts.agent_loop as al
        original = al.STATE_FILE
        try:
            al.STATE_FILE = Path("/nonexistent/state.json")
            self.assertIsNone(al._read_state())
        finally:
            al.STATE_FILE = original


if __name__ == "__main__":
    unittest.main()
