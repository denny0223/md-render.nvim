#!/usr/bin/env python3
"""Kitty installation must verify the executable before publishing its path."""

import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[1] / ".github/ci/install-terminal.sh"


class KittyInstallerTest(unittest.TestCase):
    def test_output_requires_matching_executable_version(self):
        for actual_version in ("0.49.2", "0.40.0", "0.49.20"):
            with self.subTest(actual_version=actual_version), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                stubs = root / "stubs"
                stubs.mkdir()
                # Version checks use a local archive fixture, not a release download.
                for name, body in {
                    "sha256sum": "cat >/dev/null\n",
                    "curl": "exit 1\n",
                    "gh": "exit 1\n",
                }.items():
                    tool = stubs / name
                    tool.write_text("#!/bin/sh\n" + body)
                    tool.chmod(0o755)
                archives = root / "archives"
                archives.mkdir()
                checked = root / "version-checked"
                executable = (
                    f'#!/bin/sh\ntest "$1" = --version || exit 1\n'
                    f'touch "{checked}"\nprintf "kitty {actual_version} created by Kovid Goyal\\n"\n'
                ).encode()
                with tarfile.open(archives / "kitty-0.49.2-x86_64.txz", "w:xz") as archive:
                    entry = tarfile.TarInfo("bin/kitty")
                    entry.mode = 0o755
                    entry.size = len(executable)
                    archive.addfile(entry, io.BytesIO(executable))
                output = root / "output"
                result = subprocess.run(
                    ["/bin/bash", str(INSTALLER), "kitty", "0.49.2"],
                    env=os.environ | {
                        "PATH": str(stubs) + os.pathsep + os.environ["PATH"],
                        "RUNNER_TEMP": str(root),
                        "MD_RENDER_TERMINAL_ARCHIVES": str(archives),
                        "GITHUB_OUTPUT": str(output),
                    },
                    capture_output=True, text=True, timeout=10,
                )
                self.assertTrue(checked.exists(), result.stdout + result.stderr)
                if actual_version == "0.49.2":
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(output.read_text(),
                                     f"bin={root}/md-terminal/kitty-0.49.2/bin\nversion=0.49.2\n")
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
