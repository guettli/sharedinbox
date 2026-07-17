#!/usr/bin/env python3
"""Tests for detect_duplication.py — the multi-tool duplicate-code orchestrator.

Covers the parsers (jscpd JSON, pylint R0801, dupl -plumbing) and the
baseline diff, since those are the parts that decide whether CI passes or
fails. The tool wrappers themselves shell out to real binaries and are
covered by the smoke script in tests/scripts/test_detect_duplication.sh.
"""

import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))

import detect_duplication as dd


class ParsePylintTests(unittest.TestCase):
    def test_two_file_finding_yields_two_occurrences(self):
        text = (
            "deploy_cron.py:1:0: R0801: Similar lines in 2 files\n"
            "==deploy_playstore:[94:106]\n"
            "==verify_playstore_deploy:[29:42]\n"
            "    some duplicated line\n"
            "    another duplicated line\n"
            "-----------------------------------\n"
        )
        with patch.object(dd, "_python_module_index", return_value={
            "deploy_playstore": "scripts/deploy_playstore.py",
            "verify_playstore_deploy": "scripts/verify_playstore_deploy.py",
        }), patch.object(dd, "_read_block", return_value=["stub", "block"]):
            clones = dd._parse_pylint(text)
        self.assertEqual(len(clones), 2)
        keys = {c.key for c in clones}
        self.assertEqual(len(keys), 1, "both occurrences share the same clone key")
        paths = sorted(c.file for c in clones)
        self.assertEqual(paths, [
            "scripts/deploy_playstore.py",
            "scripts/verify_playstore_deploy.py",
        ])

    def test_single_file_finding_is_dropped(self):
        # After excluded-path filtering leaves only one occurrence, the pair
        # is meaningless and must not appear in the output.
        text = (
            "generated/foo.py:1:0: R0801: Similar lines in 2 files\n"
            "==generated_module:[10:20]\n"
            "==real_module:[30:40]\n"
            "    line\n"
        )
        with patch.object(dd, "_python_module_index", return_value={
            "generated_module": "web/generated.py",
            "real_module": "scripts/real.py",
        }), patch.object(dd, "_read_block", return_value=["stub"]):
            clones = dd._parse_pylint(text)
        self.assertEqual(clones, [])

    def test_empty_output_yields_no_clones(self):
        self.assertEqual(dd._parse_pylint(""), [])


class ParseDuplTests(unittest.TestCase):
    def test_symmetric_pairs_are_deduplicated(self):
        text = (
            "server/uprelay/main.go:10-20: duplicate of server/uprelay/other.go:30-40\n"
            "server/uprelay/other.go:30-40: duplicate of server/uprelay/main.go:10-20\n"
        )
        clones = dd._parse_dupl(text)
        # Should yield two occurrences (one pair), not four.
        self.assertEqual(len(clones), 2)
        self.assertEqual({c.key for c in clones}, {clones[0].key})

    def test_ignores_excluded_paths(self):
        text = (
            "web/foo.go:10-20: duplicate of server/bar.go:30-40\n"
        )
        self.assertEqual(dd._parse_dupl(text), [])


class HashBlockTests(unittest.TestCase):
    def test_whitespace_only_changes_do_not_alter_key(self):
        a = dd._hash_block(["  x = 1", "  y = 2"])
        b = dd._hash_block(["x = 1", "y = 2"])
        c = dd._hash_block(["x =   1", "y =\t2"])
        self.assertEqual(a, b)
        self.assertEqual(b, c)

    def test_content_changes_alter_key(self):
        a = dd._hash_block(["x = 1"])
        b = dd._hash_block(["x = 2"])
        self.assertNotEqual(a, b)


class BaselineDiffTests(unittest.TestCase):
    def test_against_baseline_passes_when_all_known(self, ):
        baseline = {"abc123", "def456"}
        current = [
            dd.Clone("jscpd", "a.dart", 1, 5, "abc123"),
            dd.Clone("jscpd", "b.dart", 1, 5, "abc123"),
        ]
        new = [c for c in current if c.key not in baseline]
        self.assertEqual(new, [])

    def test_against_baseline_flags_new_clone(self):
        baseline = {"abc123"}
        current = [
            dd.Clone("jscpd", "a.dart", 1, 5, "abc123"),
            dd.Clone("pylint", "x.py", 10, 20, "new-key"),
        ]
        new = [c for c in current if c.key not in baseline]
        self.assertEqual(len(new), 1)
        self.assertEqual(new[0].tool, "pylint")


class ExcludedPathsTests(unittest.TestCase):
    def test_generated_and_platform_paths_are_excluded(self):
        for p in [
            "android/app/src/main/kotlin/foo.dart",
            "ios/Runner/foo.dart",
            "build/output/foo.dart",
            "lib/data/db/database.g.dart".replace("g.dart", "dart"),  # sanity
            ".dart_tool/foo.dart",
        ]:
            with self.subTest(p=p):
                if p.startswith(("android/", "ios/", "build/", ".dart_tool/")):
                    self.assertTrue(dd._excluded(p), f"expected {p} to be excluded")

    def test_source_paths_are_not_excluded(self):
        for p in [
            "lib/core/foo.dart",
            "scripts/detect_duplication.py",
            "server/uprelay/main.go",
            "test/unit/foo_test.dart",
        ]:
            with self.subTest(p=p):
                self.assertFalse(dd._excluded(p), f"expected {p} to be included")


class FormatFindingsTests(unittest.TestCase):
    def test_empty_message_when_no_clones(self):
        self.assertEqual(dd.format_findings([]), "no duplicates\n")

    def test_grouping_by_key(self):
        out = dd.format_findings([
            dd.Clone("jscpd", "a.dart", 1, 5, "k1"),
            dd.Clone("jscpd", "b.dart", 1, 5, "k1"),
            dd.Clone("pylint", "x.py", 1, 5, "k2"),
            dd.Clone("pylint", "y.py", 1, 5, "k2"),
        ])
        # Two clone groups, each printed once with its two occurrences.
        self.assertEqual(out.count("[jscpd]"), 1)
        self.assertEqual(out.count("[pylint]"), 1)
        self.assertIn("a.dart:1-5", out)
        self.assertIn("y.py:1-5", out)


if __name__ == "__main__":
    unittest.main()
