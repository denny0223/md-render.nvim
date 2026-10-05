"""Failure retention checks without a real terminal or external tools."""
from contextlib import redirect_stderr, redirect_stdout
import io
import itertools
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from terminal_test import LEVEL_SCALE
import tmux_terminal_test as driver


class TmuxDiagnosticsTest(unittest.TestCase):
    def run_driver(self, output=None, *, plain=False, fault=None, strict=False):
        calls, state_reads = [], 0
        original = RuntimeError("deliberate tmux startup failure")
        ordinary = "\n".join(f"共同 H{level}" for level in range(1, 7))
        enlarged = "\n".join(
            "\x1b]66;s=2" + (f":n={n}:d={d}" if n else "") + f";共同 H{level}\x1b\\"
            for level, (_, n, d) in LEVEL_SCALE.items()
        )
        state = {"backend": "plain" if plain else "native", "drawn": 6,
                 "status": "native -> plain: tmux >= 3.6" if plain else "native -> native",
                 "termsync": True, "context": {"top": 0, "left": 0}}
        if fault == "timeout":
            state["backend"] = "native"

        def check_output(args, **kwargs):
            nonlocal state_reads
            root = str(Path(kwargs["env"]["NVIM_LOG_FILE"]).parent)
            calls.append(tuple(str(value).replace(root, "<root>") for value in args))
            command = Path(args[0]).name
            if command == "tmux":
                if "new-session" in args and fault == "startup":
                    raise original
                if "-V" in args:
                    return "tmux 3.6\n"
                if fault == "startup":
                    raise subprocess.CalledProcessError(1, args, stderr="no tmux server")
                if "split-window" in args and "-P" in args:
                    invocation = shlex.split(args[-1])
                    Path(invocation[invocation.index("--listen") + 1]).touch()
                    Path(kwargs["env"]["NVIM_LOG_FILE"]).write_text("private Neovim log\n")
                    return "%2\n"
                if "capture-pane" in args:
                    return "retained ordinary pane text\n"
                if "display-message" in args:
                    return "0|0|110|56|off|bottom\n"
                return ""
            if command == "kitty":
                if "--version" in args:
                    return "kitty 0.40.0\n"
                socket = args[args.index("--to") + 1].removeprefix("unix:")
                if not Path(socket).exists():
                    raise subprocess.CalledProcessError(1, args, stderr="no Kitty socket")
                if "get-text" in args:
                    if fault == "capture" and state_reads >= 2 and "--ansi" in args:
                        raise subprocess.CalledProcessError(17, args, stderr="deliberate ANSI failure")
                    return enlarged if "--ansi" in args and not plain else ordinary
                if "ls" in args:
                    return '[{"platform_window_id": 123}]'
                return ""
            if command == "nvim":
                if "--version" in args:
                    return "NVIM v0.12.0\n"
                if not Path(args[args.index("--server") + 1]).exists():
                    raise subprocess.CalledProcessError(1, args, stderr="no Neovim socket")
                state_reads += 1
                return json.dumps(state)
            if command in ("magick", "import"):
                if fault == "missing_capture":
                    raise FileNotFoundError("capture tool unavailable")
                if fault == "capture":
                    raise subprocess.CalledProcessError(18, args, stderr="deliberate PNG failure")
                Path(args[-1]).write_bytes(b"stub PNG")
                return ""
            if command == "git":
                return "a2ab4377eba46c5d2f3b95d35d30a643560a61fe\n"
            raise AssertionError(f"unexpected external command: {args}")

        def popen(args, **kwargs):
            Path(args[args.index("--listen-on") + 1].removeprefix("unix:")).touch()
            kwargs["stdout"].write("private Kitty log\n")
            kwargs["stdout"].flush()
            return SimpleNamespace(pid=987654, args=args, returncode=0,
                                   poll=lambda: 0, wait=lambda **_: 0)

        def cleanup(args, **kwargs):
            root = str(Path(kwargs["env"]["NVIM_LOG_FILE"]).parent)
            calls.append(tuple(str(value).replace(root, "<root>") for value in args))
            return SimpleNamespace(returncode=0)

        argv = ["tmux_terminal_test.py"]
        if plain:
            argv.append("--expect-plain")
        if output:
            argv += ["--output" if strict else "--output-on-failure", str(output)]
        clock = itertools.count(0, 11)
        with patch.object(sys, "argv", argv), redirect_stdout(io.StringIO()), \
                patch.object(driver.shutil, "which", lambda name:
                             None if fault == "missing_capture" and name in ("magick", "import") else f"/stub/{name}"), \
                patch.object(driver.subprocess, "check_output", check_output), \
                patch.object(driver.subprocess, "Popen", popen), \
                patch.object(driver.subprocess, "run", cleanup), \
                patch.object(driver.time, "monotonic", side_effect=lambda: next(clock)), \
                patch.object(driver.time, "sleep", side_effect=AssertionError("unexpected test wait")):
            try:
                driver.main()
            except Exception as error:
                return error, calls, original
        return None, calls, original

    def test_tmux_startup_failure_keeps_original_error_and_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "startup"
            error, _, original = self.run_driver(output, fault="startup")
            self.assertIs(error, original)
            self.assertIn(str(original), (output / "failure.json").read_text())
            for name in ("kitty", "tmux", "nvim", "revision"):
                self.assertTrue((output / f"{name}-version.txt").exists())
            self.assertTrue((output / "diagnostics.json").exists())

    def test_failed_capture_keeps_assertion_and_other_sources(self):
        for fault, strict in (("capture", False), ("missing_capture", False), ("capture", True)):
            with self.subTest(fault=fault, strict=strict), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / "partial"
                if strict:
                    output.mkdir()
                    for name in ("failure.png", "failure.ansi", "failure.cells.json"):
                        (output / name).write_text("stale previous capture")
                error, _, _ = self.run_driver(output, fault=fault, strict=strict)
                self.assertIsInstance(error, AssertionError)
                self.assertEqual(str(error), "native headings disable pane-wide synchronized redraws")
                self.assertIn(str(error), (output / "failure.json").read_text())
                self.assertEqual((output / "failure.pane.txt").read_text(), "retained ordinary pane text\n")
                self.assertTrue((output / "failure.state.json").exists())
                self.assertFalse((output / "failure.png").exists())
                if fault == "capture":
                    self.assertIn("deliberate ANSI failure", (output / "diagnostics.json").read_text())
                    self.assertIn("deliberate PNG failure", (output / "diagnostics.json").read_text())
                    self.assertFalse((output / "failure.ansi").exists())
                    self.assertFalse((output / "failure.cells.json").exists())
                else:
                    self.assertIn("capture tool unavailable", (output / "diagnostics.json").read_text())
                    self.assertNotEqual((output / "failure.ansi").read_text(), "stale previous capture")
                self.assertEqual((output / "nvim.log").read_text(), "private Neovim log\n")

    def test_timeout_captures_once_before_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "timeout"
            error, calls, _ = self.run_driver(output, plain=True, fault="timeout")
            self.assertEqual(str(error), "native explains unsupported popup focus events")
            failure = json.loads((output / "failure.json").read_text())
            self.assertEqual(failure["current_wait"], str(error))
            cleanup = next(index for index, args in enumerate(calls) if "kill-server" in args)
            self.assertLess(max(index for index, args in enumerate(calls) if "--server" in args), cleanup)
            self.assertLess(next(index for index, args in enumerate(calls) if "-window" in args), cleanup)
            self.assertEqual(sum("--version" in args and args[0] == "kitty" for args in calls), 1)

    def test_invalid_output_options_fail_before_external_queries(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            previous = output / "failure.png"
            previous.write_bytes(b"preserved previous capture")
            for args in (["--output-on-failure", str(output)],
                         ["--output-on-failure", str(previous)],
                         ["--output-on-failure", str(output), "--output", str(output)]):
                with self.subTest(args=args), patch.object(sys, "argv", ["tmux_terminal_test.py", *args]), \
                        redirect_stderr(io.StringIO()), \
                        patch.object(driver.subprocess, "check_output") as query, \
                        patch.object(driver.subprocess, "Popen") as launch:
                    with self.assertRaises(SystemExit) as caught:
                        driver.main()
                    self.assertEqual(caught.exception.code, 2)
                    query.assert_not_called()
                    launch.assert_not_called()
                    self.assertEqual(previous.read_bytes(), b"preserved previous capture")

    def test_success_has_identical_external_queries_with_failure_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "success"
            baseline_error, baseline, _ = self.run_driver(plain=True)
            error, calls, _ = self.run_driver(output, plain=True)
            self.assertIsNone(baseline_error)
            self.assertIsNone(error)
            self.assertEqual(calls, baseline)
            self.assertFalse((output / "failure.json").exists())


if __name__ == "__main__":
    unittest.main()
