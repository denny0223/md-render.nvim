#!/usr/bin/env python3
"""The final CI gate must preserve failures and incomplete required checks."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

GATE = Path(__file__).resolve().parents[1] / ".github/ci/check-results.py"


class RequiredResultsTest(unittest.TestCase):
    def run_gate(self, steps, required=("install", "test")):
        with tempfile.TemporaryDirectory() as directory:
            summary = Path(directory) / "summary.md"
            result = subprocess.run(
                [sys.executable, str(GATE), *required],
                env=os.environ | {"STEP_RESULTS": json.dumps(steps), "GITHUB_STEP_SUMMARY": str(summary)},
                capture_output=True, text=True, timeout=5,
            )
            return result, summary.read_text() if summary.exists() else ""

    def test_success_ignores_unselected_checks(self):
        result, summary = self.run_gate({
            "install": {"outcome": "success"},
            "test": {"outcome": "success"},
            "optional": {"outcome": "skipped"},
        })
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("| test | success |", summary)
        self.assertNotIn("optional", summary)

    def test_continue_on_error_cannot_hide_failure(self):
        result, summary = self.run_gate({
            "install": {"outcome": "success"},
            "test": {"outcome": "failure", "conclusion": "success"},
        })
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("test", result.stderr)
        self.assertIn("| test | failure |", summary)

    def test_missing_or_incomplete_required_check_fails(self):
        for test in (None, {}, {"outcome": "skipped"}, {"outcome": "cancelled"}, {"outcome": "unknown"}):
            with self.subTest(test=test):
                steps = {"install": {"outcome": "success"}}
                if test is not None:
                    steps["test"] = test
                result, summary = self.run_gate(steps)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("test", result.stderr)
                self.assertIn("| test |", summary)

    def test_empty_plan_cannot_pass(self):
        result, _ = self.run_gate({}, required=())
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
