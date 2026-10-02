"""Stdlib checks for test/maintenance scripts, with no real terminal or network."""
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

REPO = Path(__file__).resolve().parents[1]


def png(color):
    def chunk(kind, data):
        return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack("!2I5B", 8, 8, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\0" + bytes(color) * 8) * 8)) + chunk(b"IEND", b""))


class ToolingTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="md-render-tooling-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=str(self.bin), TOOL_TEST_ROOT=str(self.root))
        self.env.pop("MD_RENDER_VISUAL_MAX_RMSE", None)
        self.env["NVIM_LOG_FILE"] = str(self.root / "nvim.log")
        for kind in ("CONFIG", "DATA", "STATE", "CACHE"):
            self.env[f"XDG_{kind}_HOME"] = str(self.root / kind.lower())
        for name in ("dirname", "mkdir", "mktemp", "rm", "cp", "sed", "grep", "perl", "cat"):
            (self.bin / name).symlink_to(shutil.which(name))
        (self.bin / "python3").symlink_to(sys.executable)
        self.script = self.root / "tests/run_visual_test.sh"
        self.script.parent.mkdir()
        shutil.copyfile(REPO / "tests/run_visual_test.sh", self.script)
        self.actual = self.root / "tests/screenshots/wezterm.png"
        self.reference = self.root / "tests/screenshots/reference/wezterm.png"
        self.reference.parent.mkdir(parents=True)
        self.actual.write_bytes(png((0, 0, 0)))
        self.reference.write_bytes(self.actual.read_bytes())
        self.executable("sleep", "import time\ntime.sleep(0.05)\n")
        self.executable("magick", """import os, sys
if os.environ.get('TOOL_MAGICK_FAIL'):
    sys.exit('error 99: deliberately broken ImageMagick')
if sys.argv[1] != 'identify':
    print(os.environ.get('TOOL_METRIC', '0'))
""")

    def executable(self, name, source):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n" + source)
        path.chmod(0o755)
        return path

    def run_visual(self, mode="--compare", **env):
        return subprocess.run(["/bin/bash", str(self.script), mode], env=self.env | env,
                              capture_output=True, text=True, timeout=15)

    def run_lua(self, test):
        return subprocess.run([shutil.which("nvim"), "--headless", "-u", "NONE", "--noplugin", "-l", test],
                              cwd=REPO, env=self.env, capture_output=True, text=True, timeout=10)

    def capture_stubs(self):
        self.executable("wezterm", """import os, signal, time
from pathlib import Path
root = Path(os.environ['TOOL_TEST_ROOT'])
def stop(*_):
    (root / 'owned-stopped').write_text('terminated')
    raise SystemExit(0)
signal.signal(signal.SIGTERM, stop)
(root / 'title').write_text(os.environ['VISUAL_TEST_TITLE'])
if not os.environ.get('TOOL_NO_READY'):
    Path(os.environ['VISUAL_TEST_SIGNAL']).write_text('ready')
time.sleep(60)
""")
        self.executable("pgrep", """import os
from pathlib import Path
Path(os.environ['TOOL_TEST_ROOT'], 'searched-processes').touch()
print(os.environ['TOOL_FOREIGN_PID'])
""")
        (self.root / "tests/capture_window.py").write_text("""import os, sys
from pathlib import Path
if os.environ.get('TOOL_CAPTURE_FAIL'):
    sys.exit('deliberate capture failure')
if not os.environ.get('TOOL_CAPTURE_EMPTY'):
    Path(sys.argv[-1]).write_bytes(b'fresh capture')
""")

    def test_compare_status_and_bad_metrics(self):
        self.assertEqual(self.run_visual().returncode, 0)
        for value in ("0.5", "nan", "inf", "-1", "error 0.01", ""):
            with self.subTest(value=value):
                self.assertNotEqual(self.run_visual(TOOL_METRIC=value).returncode, 0)
        self.assertNotEqual(self.run_visual(TOOL_MAGICK_FAIL="1").returncode, 0)
        (self.bin / "magick").unlink()
        self.assertNotEqual(self.run_visual().returncode, 0)

    def test_missing_reference_and_empty_run_fail(self):
        self.reference.unlink()
        self.assertNotEqual(self.run_visual().returncode, 0)
        self.actual.unlink()
        self.assertNotEqual(self.run_visual().returncode, 0)

    def test_failed_capture_never_updates_old_baseline(self):
        self.capture_stubs()
        before = self.reference.read_bytes()
        for fault in ("TOOL_CAPTURE_FAIL", "TOOL_CAPTURE_EMPTY", "TOOL_NO_READY"):
            with self.subTest(fault=fault):
                result = self.run_visual("--update", **{fault: "1"})
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(self.reference.read_bytes(), before)
                self.assertEqual(self.actual.read_bytes(), before)
        self.assertTrue((self.root / "owned-stopped").exists(), "failure must clean up its own terminal")

    def test_update_owns_only_its_launch_and_uses_fresh_capture(self):
        self.capture_stubs()
        foreign = subprocess.Popen([shutil.which("sleep"), "60"], start_new_session=True)
        try:
            result = self.run_visual("--update", TOOL_FOREIGN_PID=str(foreign.pid))
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(self.reference.read_bytes(), b"fresh capture")
            self.assertTrue((self.root / "owned-stopped").exists())
            self.assertIsNone(foreign.poll(), "an unrelated terminal must survive")
            self.assertFalse((self.root / "searched-processes").exists())
            self.assertNotEqual((self.root / "title").read_text(), "md-render-visual-test")
        finally:
            foreign.terminate()
            foreign.wait(timeout=5)

    @unittest.skipUnless(shutil.which("magick"), "real ImageMagick 7 is optional locally")
    def test_real_normalized_rmse(self):
        (self.bin / "magick").unlink()
        (self.bin / "magick").symlink_to(shutil.which("magick"))
        result = self.run_visual()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.reference.write_bytes(png((255, 255, 255)))
        self.assertNotEqual(self.run_visual().returncode, 0)
        self.reference.write_bytes(b"not a PNG 0")
        self.assertNotEqual(self.run_visual().returncode, 0)


    def test_installed_broken_plantuml_fails_instead_of_skipping(self):
        for source, error in (("raise SystemExit(7)\n", "renderer failed"),
                              (f"import sys\nsys.stdout.buffer.write({png((0, 0, 0))!r})\nsys.exit(7)\n", "renderer failed"),
                              ("import sys\nsys.stdout.buffer.write(b'\\x89PNG')\n", "not a readable PNG")):
            with self.subTest(error=error):
                self.executable("plantuml", source)
                result = self.run_lua("tests/plantuml_kitty_test.lua")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(error, result.stdout + result.stderr)
                self.assertNotIn("SKIP", result.stdout + result.stderr)

    def test_plantuml_without_decoder_reports_unverified_output(self):
        (self.bin / "magick").unlink()
        for status in (0, 7):
            self.executable("plantuml", f"import sys\nsys.stdout.buffer.write({png((0, 0, 0))!r})\nsys.exit({status})\n")
            result = self.run_lua("tests/plantuml_kitty_test.lua")
            if status == 0:
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("SKIP PlantUML PNG validation", result.stdout + result.stderr)
                self.assertNotIn("passed", result.stdout + result.stderr)
            else:
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("SKIP", result.stdout + result.stderr)

    @unittest.skipUnless(any(shutil.which(name) for name in ("magick", "convert", "sips")),
                         "real PNG decoding needs ImageMagick or sips")
    def test_real_renderer_output_decoding(self):
        (self.bin / "magick").unlink()
        decoder = next(name for name in ("magick", "convert", "sips") if shutil.which(name))
        (self.bin / decoder).symlink_to(shutil.which(decoder))
        for renderer, test in (("plantuml", "tests/plantuml_kitty_test.lua"), ("mmdc", "tests/mermaid_integration.lua")):
            for content, status in ((png((0, 0, 0)), 0), (png((0, 0, 0))[:24], 0), (png((0, 0, 0)), 7)):
                with self.subTest(renderer=renderer, size=len(content), status=status):
                    write = ("sys.stdout.buffer.write(content)" if renderer == "plantuml" else
                             'Path(sys.argv[sys.argv.index("-o") + 1]).write_bytes(content)')
                    self.executable(renderer, f"import sys\nfrom pathlib import Path\ncontent={content!r}\n{write}\nsys.exit({status})\n")
                    result = self.run_lua(test)
                    if status == 0 and len(content) > 24:
                        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    else:
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertNotIn("SKIP", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
