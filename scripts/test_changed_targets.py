#!/usr/bin/env python3
"""Tests for changed_targets.py — the Dagger-wrapped script that decides
which deploy targets need to run since the last successful workflow job."""

import io
import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))

import changed_targets as ct


_TARGETS = json.dumps({
    "android": r"^(android/|lib/|pubspec\.yaml)",
    "linux":   r"^(linux/|lib/|pubspec\.yaml)",
})

_BASE_ENV = {
    "GITHUB_TOKEN": "ghp_x",
    "GITHUB_REPOSITORY": "owner/repo",
    "GITHUB_API_URL": "https://api.github.com",
    "HEAD_SHA": "deadbeef",
    "EVENT_NAME": "schedule",
    "WORKFLOW_FILE": "deploy.yml",
    "JOB_NAME": "Build & Deploy",
    "TARGETS": _TARGETS,
}


def _run(env_override=None, *, gh_get=None):
    """Run changed_targets.main() with the given env and mocked _gh_get,
    returning the parsed final-line JSON output."""
    env = dict(_BASE_ENV)
    if env_override:
        env.update(env_override)
    buf = io.StringIO()
    with patch.dict(os.environ, env, clear=True):
        if gh_get is not None:
            with patch.object(ct, "_gh_get", side_effect=gh_get):
                with patch("sys.stdout", buf):
                    ct.main()
        else:
            with patch("sys.stdout", buf):
                ct.main()
    last = [l for l in buf.getvalue().splitlines() if l.strip()][-1]
    return json.loads(last)


class ChangedTargetsTests(unittest.TestCase):
    def test_workflow_dispatch_is_all_true(self):
        result = _run({"EVENT_NAME": "workflow_dispatch"})
        self.assertEqual(result, {"android": True, "linux": True})

    def test_always_on_non_schedule_push_is_all_true(self):
        result = _run({
            "EVENT_NAME": "push",
            "ALWAYS_ON_NON_SCHEDULE": "true",
        })
        self.assertEqual(result, {"android": True, "linux": True})

    def test_no_last_run_returns_all_true_precaution(self):
        """When no last-successful run is found, deploy as a precaution."""
        def gh_get(url, token):
            if "/workflows/" in url:
                return {"workflow_runs": []}
            return {}
        result = _run(gh_get=gh_get)
        self.assertEqual(result, {"android": True, "linux": True})

    def test_head_equals_last_deployed_returns_all_false(self):
        def gh_get(url, token):
            if "/workflows/" in url:
                return {"workflow_runs": [{"id": 1, "head_sha": "deadbeef"}]}
            if "/runs/1/jobs" in url:
                return {"jobs": [{
                    "name": "Build & Deploy",
                    "conclusion": "success",
                }]}
            return {}
        result = _run(gh_get=gh_get)
        self.assertEqual(result, {"android": False, "linux": False})

    def test_android_only_change(self):
        def gh_get(url, token):
            if "/workflows/" in url:
                return {"workflow_runs": [{"id": 7, "head_sha": "cafebabe"}]}
            if "/runs/7/jobs" in url:
                return {"jobs": [{
                    "name": "Build & Deploy",
                    "conclusion": "success",
                }]}
            if "/compare/" in url:
                return {"files": [{"filename": "android/app/build.gradle"}]}
            return {}
        result = _run(gh_get=gh_get)
        self.assertEqual(result, {"android": True, "linux": False})

    def test_lib_change_triggers_both(self):
        def gh_get(url, token):
            if "/workflows/" in url:
                return {"workflow_runs": [{"id": 9, "head_sha": "feedface"}]}
            if "/runs/9/jobs" in url:
                return {"jobs": [{
                    "name": "Build & Deploy",
                    "conclusion": "success",
                }]}
            if "/compare/" in url:
                return {"files": [{"filename": "lib/foo/bar.dart"}]}
            return {}
        result = _run(gh_get=gh_get)
        self.assertEqual(result, {"android": True, "linux": True})

    def test_unrelated_change_skips_all(self):
        def gh_get(url, token):
            if "/workflows/" in url:
                return {"workflow_runs": [{"id": 9, "head_sha": "feedface"}]}
            if "/runs/9/jobs" in url:
                return {"jobs": [{
                    "name": "Build & Deploy",
                    "conclusion": "success",
                }]}
            if "/compare/" in url:
                return {"files": [{"filename": "docs/readme.md"}]}
            return {}
        result = _run(gh_get=gh_get)
        self.assertEqual(result, {"android": False, "linux": False})

    def test_skipped_job_is_not_a_successful_deploy(self):
        """A run whose target job was skipped must not be treated as the last
        successful deploy — that's the exact bug the inline Python guarded
        against (see deploy.yml history)."""
        def gh_get(url, token):
            if "/workflows/" in url:
                return {"workflow_runs": [
                    {"id": 1, "head_sha": "aaaa"},
                    {"id": 2, "head_sha": "bbbb"},
                ]}
            if "/runs/1/jobs" in url:
                return {"jobs": [{
                    "name": "Build & Deploy",
                    "conclusion": "skipped",
                }]}
            if "/runs/2/jobs" in url:
                return {"jobs": [{
                    "name": "Build & Deploy",
                    "conclusion": "success",
                }]}
            if "/compare/bbbb" in url:
                return {"files": [{"filename": "linux/main.cc"}]}
            return {}
        result = _run(gh_get=gh_get)
        # bbbb was the true last-success, lib unchanged but linux changed
        self.assertEqual(result, {"android": False, "linux": True})


if __name__ == "__main__":
    unittest.main()
