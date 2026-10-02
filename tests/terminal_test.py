#!/usr/bin/env python3
"""
Terminal end-to-end test: drive a real Kitty and assert on what it actually holds.

Sits between the unit tests (which check the bytes md-render emits) and the
visual regression tests (which compare pixels). The trick that makes this layer
cheap is that `kitty @ get-text --ansi` round-trips OSC 66 verbatim:

    ESC ] 66 ; s=2 ; Level One Heading ESC \\
    ESC ] 66 ; s=2:n=3:d=4:w=6 ; Level Th ESC \\

So "is this heading drawn at 1.5x" is answerable as an exact string match, with
no screenshot, no SSIM, and none of the font or timing sensitivity that comes
with comparing images.

Usage:
    tests/terminal_test.py                 # auto-detect kitty, use xvfb if present
    tests/terminal_test.py --kitty /path/to/kitty

Exits non-zero on failure.
"""

import argparse
import json
import os
import re
import shutil
import signal as signal_mod
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Old nf-md-format_header_1 .. _6 prefixes must be absent from both layers.
HEADING_ICONS = [chr(cp) for cp in range(0xF026B, 0xF026B + 6)]

# Where a fractionally scaled run sits in its block: 0 top, 1 bottom, 2
# centered. Kitty ignores it when there is no fraction, which is why level 1's
# text run is exempt below.
VERTICAL_ALIGN = 2

OSC66 = re.compile(rb"\x1b\]66;([^;]*);(.*?)(?:\x1b\\|\x07)", re.S)

# Heading level → the scale md-render is supposed to send for it, as
# `(s, n, d)`. Level 1 scales by whole cells and needs no fraction; the rest
# shrink the font inside those cells with `n` / `d`, which means they also have
# to state a per-run width in `w`.
#
# Compared key by key rather than as a string: Kitty stores the metadata as
# parsed values and `get-text` re-emits them in its own order, so what comes
# back for `s=2:n=3:d=4:w=6` is `w=6:s=2:n=3:d=4`.
LEVEL_SCALE = {
    1: (2, None, None),
    2: (2, 7, 8),
    3: (2, 3, 4),
    4: (2, 7, 10),
    5: (2, 5, 8),
    6: (2, 7, 12),
}

# The text each level's heading carries in the fixture. A fractionally scaled
# heading goes out as several runs, so these are matched against the level's
# payloads joined back together rather than against a single run.
LEVEL_TEXT = {
    1: "Level One Heading",
    2: "Level Two Heading",
    3: "Level Three Heading",
    4: "Level Four Heading",
    5: "Level Five Heading",
    6: "Level Six Heading",
}


def parse_meta(meta):
    """`w=6:s=2:n=3:d=4` -> {'w': 6, 's': 2, 'n': 3, 'd': 4}."""
    out = {}
    for pair in meta.split(":"):
        key, _, value = pair.partition("=")
        if value.isdigit():
            out[key] = int(value)
    return out


def level_of(meta):
    """Heading level a run's metadata belongs to, or None if unrecognised."""
    kv = parse_meta(meta)
    got = (kv.get("s"), kv.get("n"), kv.get("d"))
    for level, expected in LEVEL_SCALE.items():
        if got == expected:
            return level
    return None

passed = failed = 0


def ok(msg):
    global passed
    passed += 1
    print(f"  ok   {msg}")


def bad(msg, detail=None):
    global failed
    failed += 1
    print(f"  FAIL {msg}")
    if detail:
        print(f"       {detail}")


def run_kitty(kitty, enabled, workdir, mode="float"):
    """Launch kitty+nvim and return (scaled_runs, diagnostics, screen_text)."""
    # A socket per run. Sharing one path lets a query land on a previous
    # instance that has not finished dying, which reads as "scaled text is
    # still on screen after being disabled".
    sock = workdir / f"sock-{mode}-{int(enabled)}"
    signal = workdir / f"ready-{mode}-{int(enabled)}"
    diag = workdir / f"diag-{mode}-{int(enabled)}"
    server = workdir / f"nvim-{mode}-{int(enabled)}.sock"

    env = dict(
        os.environ,
        MD_RENDER_E2E_ENABLED="1" if enabled else "0",
        MD_RENDER_E2E_MODE="toggle" if mode == "pager" else mode,
        MD_RENDER_E2E_SIGNAL=str(signal),
        MD_RENDER_E2E_DIAG=str(diag),
        # Kitty needs a GL context; CI has no GPU.
        LIBGL_ALWAYS_SOFTWARE="1",
        XDG_CONFIG_HOME=str(workdir / "config"),
        XDG_CACHE_HOME=str(workdir / "cache"),
        XDG_DATA_HOME=str(workdir / "data"),
        XDG_STATE_HOME=str(workdir / "state"),
        NVIM_LOG_FILE=str(workdir / f"nvim-{mode}-{int(enabled)}.log"),
    )
    # This is a direct Kitty test, even when launched from tmux or another
    # terminal. Inherited topology hints would probe the wrong transport.
    for key in list(env):
        if key.startswith(("TMUX", "TERM_PROGRAM", "KITTY_", "WEZTERM_", "GHOSTTY_")) or key in (
            "NVIM", "NVIM_LISTEN_ADDRESS", "NVIM_APPNAME", "VIM", "VIMRUNTIME",
        ):
            env.pop(key)

    cmd = [
        kitty,
        "--config", "NONE",
        "--title", f"md-render terminal test ({mode})",
        "-o", "allow_remote_control=yes",
        # A window narrow enough makes the preview float narrow enough that the
        # minimum-width guard declines to scale anything, which would look like
        # a failure. Ask for room.
        "-o", "font_size=10",
        # And a window *short* enough scrolls the later headings out of the
        # float, which reads the same way: the placements are built and simply
        # never drawn. Kitty opens at 80x24 cells by default no matter how big
        # the display is, which fits four of the fixture's seven headings —
        # `placements=9 drawn=4` in the diagnostics below. Ask for the rows too.
        # `remember_window_size` has to go first: while it is on, which is the
        # default, kitty ignores both of these.
        "-o", "remember_window_size=no",
        "-o", "initial_window_width=120c",
        "-o", "initial_window_height=60c",
        "--listen-on", f"unix:{sock}",
        "--directory", str(REPO),
    ]
    if sys.platform.startswith("linux"):
        # An inherited Wayland session must not bypass xvfb-run's display.
        cmd += ["-o", "linux_display_server=x11"]
    cmd += [
        "nvim", "--clean", "-i", "NONE", "--listen", str(server),
        "-u", str(REPO / "tests/text_size_e2e_init.lua"),
    ]
    if shutil.which("xvfb-run"):
        cmd = ["xvfb-run", "-a", "--server-args=-screen 0 2400x1400x24"] + cmd

    # Keep the terminal's own output: when kitty refuses to start (a missing
    # shared library, no fonts) it says so there, and discarding it turns a
    # one-line diagnosis into a blind hunt.
    termlog = workdir / f"kitty-{mode}-{int(enabled)}.log"
    logf = termlog.open("wb")
    # New session so the whole tree can be signalled: under xvfb-run the
    # process here is the wrapper, and killing it leaves kitty running.
    proc = subprocess.Popen(cmd, stdout=logf, stderr=subprocess.STDOUT, env=env, start_new_session=True)
    try:
        deadline = time.time() + 90
        while time.time() < deadline and not signal.exists():
            if proc.poll() is not None:
                logf.close()
                raise RuntimeError(
                    f"kitty exited early with code {proc.returncode}:\n"
                    + (termlog.read_text(errors="replace").strip() or "(no output)")
                )
            time.sleep(0.5)
        if not signal.exists():
            logf.close()
            raise RuntimeError(
                "timed out waiting for the preview to settle:\n"
                + (termlog.read_text(errors="replace").strip() or "(no output)")
            )

        diagnostics = diag.read_text() if diag.exists() else "(no diagnostics)"
        if signal.read_text().strip() != "ready":
            raise RuntimeError(f"{mode} preview failed:\n{diagnostics}")

        def remote(*args):
            return subprocess.run(
                [kitty, "@", "--to", f"unix:{sock}", *args],
                capture_output=True, check=True, env=env, timeout=10,
            ).stdout

        def screen(ansi=False):
            return remote("get-text", "--extent", "screen", *(["--ansi"] if ansi else []))

        def expr(value):
            result = subprocess.run(
                ["nvim", "--server", str(server), "--remote-expr", f"json_encode({value})"],
                capture_output=True, check=True, env=env, text=True, timeout=10,
            )
            return json.loads(result.stdout)

        def lua(code):
            return expr(f"luaeval({json.dumps(code)})")

        out = screen(ansi=True)
        plain = screen().decode("utf-8", "replace")
        if any(icon in plain for icon in HEADING_ICONS):
            bad(f"{mode}: no level icons remain in terminal text")
        else:
            ok(f"{mode}: no level icons remain in terminal text")
        if mode == "toggle" and enabled:
            def body_rows():
                return [(row, line) for row, line in enumerate(screen().decode().splitlines())
                        if "Body text under" in line or "floating preview is sized" in line]

            def check_heading(level, scaled, context, readable=True):
                payloads = [text.decode() for meta, text in OSC66.findall(screen(ansi=True))
                            if level_of(meta.decode()) == level]
                present = LEVEL_TEXT[level] in "".join(payloads)
                if present == scaled and (scaled or not payloads):
                    ok(f"h{level} {'is scaled' if scaled else 'yields to native feedback'} {context}")
                else:
                    bad(f"h{level} scaling {context}", f"expected scaled={scaled}, payloads={payloads!r}")
                if not scaled and readable:
                    if LEVEL_TEXT[level] in screen().decode():
                        ok(f"h{level} text remains readable {context}")
                    else:
                        bad(f"h{level} text remains readable {context}")

            positions = dict(line.split("=", 1) for line in diagnostics.splitlines() if "=" in line)
            heading_row, heading_col = int(positions["h1_row"]), int(positions["h1_col"])
            body_row, body_col = int(positions["body_row"]), int(positions["body_col"])
            check_heading(1, True, "with the cursor on body text")
            expected = body_rows()
            if len(expected) != 2:
                bad("both body lines are visible before cursor movement", repr(expected))
            else:
                # Margins retain enlargement; entering text reveals precise cursor
                # feedback without moving body rows or other headings.
                for context, row, col, scaled in (
                    ("on heading text", heading_row, heading_col, False),
                    ("on the reserved heading row", heading_row + 1, 1, True),
                    ("back on body text", body_row, body_col, True),
                    ("on the heading's left margin", heading_row, 1, True),
                    ("after returning to body text", body_row, body_col, True),
                ):
                    remote("send-text", "--", f"{row}G{col}|")
                    time.sleep(0.5)
                    cursor = expr("getcurpos()[1:2]")
                    if cursor == [row, col]:
                        ok(f"cursor reached {context}")
                    else:
                        bad(f"cursor reached {context}", repr(cursor))
                    check_heading(1, scaled, context)
                    check_heading(2, True, context)
                    actual = body_rows()
                    if actual == expected:
                        ok(f"body rows survive cursor movement {context}")
                    else:
                        bad(f"body rows survive cursor movement {context}", repr(actual))

                def scaled_rows(level):
                    rows = []
                    for row, line in enumerate(screen(ansi=True).splitlines()):
                        text = "".join(text.decode() for meta, text in OSC66.findall(line)
                                       if level_of(meta.decode()) == level)
                        if text:
                            rows.append((row, text))
                    return rows

                expected_h2 = scaled_rows(2)
                assert any(LEVEL_TEXT[2] in text for _, text in expected_h2), expected_h2

                def check_layout(context):
                    actual = (scaled_rows(2), body_rows())
                    if actual == (expected_h2, expected):
                        ok(f"h2 and body retain their screen rows {context}")
                    else:
                        bad(f"h2 and body retain their screen rows {context}", repr(actual))

                overlay_lines = ["FLOAT OVERLAY FIRST ROW STAYS READABLE",
                                 "FLOAT OVERLAY SECOND ROW STAYS READABLE"]
                overlay = lua("(function() "
                              "local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf(); "
                              "local cursor = vim.api.nvim_win_get_cursor(win); "
                              f"assert(cursor[1] == {body_row} and cursor[2] == {body_col - 1}); "
                              f"local pos = vim.fn.screenpos(win, {heading_row}, {heading_col}); "
                              "assert(pos.row > 0 and pos.col > 0); "
                              "local popup_buf = vim.api.nvim_create_buf(false, true); "
                              "vim.bo[popup_buf].bufhidden = 'wipe'; "
                              "vim.api.nvim_buf_set_lines(popup_buf, 0, -1, false, {"
                              + ",".join(json.dumps(line) for line in overlay_lines) + "}); "
                              "local popup = vim.api.nvim_open_win(popup_buf, false, {relative='editor', "
                              f"row=pos.row-1, col=pos.col-1, width={max(map(len, overlay_lines))}, height=2, "
                              "border='none', style='minimal', focusable=false}); "
                              "assert(vim.api.nvim_get_current_win() == win and vim.api.nvim_get_current_buf() == buf); "
                              "assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(win))); "
                              "return {win=popup, tab=vim.api.nvim_get_current_tabpage()} end)()")
                try:
                    # Cross the 500 ms keepalive twice: an initial Neovim repaint
                    # alone must not hide an overlay that later reassertions damage.
                    for context in ("under a non-focusable float", "after another heading keepalive"):
                        time.sleep(0.6)
                        visible = screen().decode()
                        if all(line in visible for line in overlay_lines):
                            ok(f"the complete float remains readable {context}")
                        else:
                            bad(f"the complete float remains readable {context}", visible)
                        check_heading(1, False, context, readable=False)
                        check_layout(context)
                finally:
                    lua(f"(function() if vim.api.nvim_win_is_valid({overlay['win']}) then "
                        f"vim.api.nvim_win_close({overlay['win']}, true) end; return true end)()")
                time.sleep(0.6)
                check_heading(1, True, "after the covering float closes")
                check_layout("after the covering float closes")

                background = lua("(function() local original = vim.api.nvim_get_current_tabpage(); "
                                 "vim.cmd.tabnew(); local tab = vim.api.nvim_get_current_tabpage(); "
                                 "assert(tab ~= original); vim.bo.buftype = 'nofile'; vim.bo.bufhidden = 'wipe'; "
                                 "vim.api.nvim_buf_set_lines(0, 0, -1, false, {'BACKGROUND TAB STAYS CLEAN'}); "
                                 "return tab end)()")
                try:
                    time.sleep(0.6)
                    visible = screen().decode()
                    if ("BACKGROUND TAB STAYS CLEAN" in visible and not OSC66.findall(screen(ansi=True))
                            and not any(title in visible for title in LEVEL_TEXT.values())):
                        ok("background tab stays free of the old preview's heading paint")
                    else:
                        bad("background tab stays free of the old preview's heading paint", visible)
                finally:
                    lua(f"(function() if vim.api.nvim_tabpage_is_valid({background}) then "
                        f"vim.api.nvim_set_current_tabpage({background}); vim.cmd.tabclose() end; "
                        f"vim.api.nvim_set_current_tabpage({overlay['tab']}); return true end)()")
                time.sleep(0.6)
                check_heading(1, True, "after returning from the background tab")
                check_layout("after returning from the background tab")

        if mode == "pager":
            source = workdir / "pager-source.md"
            target = workdir / "pager-target.md"
            notes = workdir / "pager-notes.txt"
            source.write_text("# Pager origin\n\n" + "\n\n".join(
                f"Origin paragraph {index}." for index in range(1, 71)
            ) + "\n\n[Target document](pager-target.md)\n")
            target.write_text("## Pager target\n\nTarget body.\n\n[Edit notes](pager-notes.txt)\n")
            notes.write_text("EDITOR CONTENT\n")
            lua("(function() "
                "local p = require('md-render.preview'); p.toggle(); "
                f"vim.cmd.edit({json.dumps(str(source))}); "
                "vim.bo.filetype = 'markdown'; vim.o.hidden = true; "
                "vim.o.laststatus = 2; vim.o.showtabline = 2; vim.o.cmdheight = 1; "
                "vim.o.ruler = true; vim.o.showcmd = true; vim.wo.number = true; "
                "vim.wo.statusline = 'PAGER EDITOR STATUS'; vim.wo.winbar = 'PAGER EDITOR BAR'; "
                "p.show_pager(); vim.cmd('normal! G0wzt'); return true end)()")

            def state():
                return lua("(function() "
                           "local s = require('md-render.preview')._sessions[vim.api.nvim_get_current_buf()]; "
                           "return {buf=vim.api.nvim_get_current_buf(),win=vim.api.nvim_get_current_win(), "
                           "pager=not not (s and s.pager),view=vim.fn.winsaveview(), "
                           "ui={vim.o.laststatus,vim.o.showtabline,vim.o.cmdheight,vim.o.ruler,vim.o.showcmd}} "
                           "end)()")

            def send(keys):
                remote("send-text", "--", keys)
                time.sleep(0.5)

            origin = state()
            assert origin["pager"] and origin["ui"] == [0, 0, 0, False, False], origin
            ok("pager hides chrome")
            assert "Target document" in screen().decode(), "pager source link is not visible"
            send("gf")
            destination = state()
            assert destination["pager"] and destination["buf"] != origin["buf"], destination
            assert destination["win"] == origin["win"], destination
            assert "Pager target" in screen().decode(), "local Markdown target is not visible"
            ok("pager gf opens rendered Markdown in the same window")
            send("\x0f")
            returned = state()
            assert returned["buf"] == origin["buf"] and returned["view"] == origin["view"], returned
            ok("pager Ctrl-O restores the reading view")
            send("\x09")
            send("G0wgf")
            editor = state()
            assert not editor["pager"] and editor["win"] == origin["win"], editor
            assert editor["ui"] == [2, 2, 1, True, True], editor
            assert expr("&modifiable && &number && empty(maparg('q', 'n'))"), editor
            visible = screen().decode()
            assert all(text in visible for text in ("EDITOR CONTENT", "PAGER EDITOR STATUS", "PAGER EDITOR BAR")), visible
            assert not OSC66.findall(screen(ansi=True)), "heading paint remains in the editor"
            ok("pager opens an ordinary editor with restored chrome and keys")
            send("iUNSAVED NOTES \x1b")
            send("\x0f")
            returned = state()
            assert returned["pager"] and returned["buf"] == destination["buf"], returned
            assert returned["ui"] == [0, 0, 0, False, False], returned
            assert "Pager target" in screen().decode() and "PAGER EDITOR STATUS" not in screen().decode()
            ok("editor Ctrl-O restores the rendered pager and hides chrome")
            send("q")
            assert proc.poll() is None, "pager q discarded unsaved editor changes"
            refusal = screen().decode()
            assert "No write since last change" in refusal, refusal
            send("\r\x1b")  # The normal unsaved-change error requires dismissing hit-enter.
            assert expr(f"getbufvar({json.dumps(str(notes))}, '&modified')"), "editor changes were discarded"
            blocked = state()
            assert not blocked["pager"] and blocked["ui"] == [2, 2, 1, True, True], blocked
            assert expr("expand('%:p')") == str(notes), "unsaved-change refusal did not reveal the editor"
            ok("pager q refuses to discard unsaved editor changes")
            send(":write\r\x0f")
            assert notes.read_text() == "UNSAVED NOTES EDITOR CONTENT\n", "editor changes were not saved"
            saved_return = state()
            assert saved_return["pager"] and saved_return["buf"] == destination["buf"], saved_return
            ok("saving the revealed editor and Ctrl-O returns to the pager")
            remote("send-text", "--", "q")
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired as error:
                raise AssertionError(f"pager q did not exit:\n{screen().decode()}") from error
            assert proc.returncode == 0, f"pager exit failed: {proc.returncode}"
            ok("pager q exits Neovim after changes are resolved")
    finally:
        if not logf.closed:
            logf.close()
        try:
            os.killpg(os.getpgid(proc.pid), signal_mod.SIGKILL)
        except (ProcessLookupError, PermissionError):
            proc.kill()
        proc.wait(timeout=10)
        # Do not let a slow teardown bleed into the next run.
        for _ in range(20):
            if not sock.exists():
                break
            time.sleep(0.25)

    runs = [(m.decode(), t.decode("utf-8", "replace")) for m, t in OSC66.findall(out)]
    return runs, diagnostics, plain


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kitty", default=shutil.which("kitty"))
    args = ap.parse_args()

    if not args.kitty:
        sys.exit("error: kitty not found; pass --kitty")

    version = subprocess.run([args.kitty, "--version"], capture_output=True, text=True).stdout.strip()
    print(f"terminal_test environment:\n  {version}")
    nvim_version = subprocess.run(["nvim", "--version"], capture_output=True, text=True).stdout.splitlines()[0]
    print(f"  {nvim_version}")
    print(f"  xvfb: {'yes' if shutil.which('xvfb-run') else 'no (running against the real display)'}\n")

    with tempfile.TemporaryDirectory() as td:
        workdir = Path(td)

        print("scaled headings ON:")
        runs, diag, _ = run_kitty(args.kitty, True, workdir)
        print("".join(f"    {line}\n" for line in diag.strip().splitlines()), end="")
        if "backend=native\n" in diag:
            ok("the fixture explicitly uses the native backend")
        else:
            bad("the fixture explicitly uses the native backend", diag)

        if not runs:
            bad("kitty holds at least one scaled run", f"none found; diagnostics above")
        else:
            ok(f"kitty holds {len(runs)} scaled run(s)")

        # Nothing else in the plugin emits OSC 66, so every run has to be one
        # of the six heading levels — and at the exact metadata for that level.
        unknown = sorted({m for m, _ in runs if level_of(m) is None})
        if unknown:
            bad("every scaled run matches a heading level", f"also saw {unknown}")
        else:
            ok("every scaled run matches a heading level")

        # Every level reserves a block `s` rows tall while only level 1 fills
        # it, so anything with a fraction has to say where in that block it
        # sits. Level 1's text run is the exception: with no fraction Kitty
        # ignores `v`, so it is not sent.
        adrift = sorted(
            {m for m, _ in runs if parse_meta(m).get("n") and parse_meta(m).get("v") != VERTICAL_ALIGN}
        )
        if adrift:
            bad(f"every fractional run is aligned v={VERTICAL_ALIGN}", f"saw {adrift}")
        else:
            ok(f"every fractional run is aligned v={VERTICAL_ALIGN}")

        # `w` is capped at 7 by the protocol; past that Kitty is free to
        # truncate or resize the run.
        over = sorted({m for m, _ in runs if not 1 <= parse_meta(m).get("w", 1) <= 7})
        if over:
            bad("every run asks for 1..7 cells", f"saw {over}")
        else:
            ok("every run asks for 1..7 cells")

        # Each level's runs, joined back into the heading they came from.
        joined = {}
        for meta, text in runs:
            level = level_of(meta)
            if level:
                joined[level] = joined.get(level, "") + text

        for level, want in LEVEL_TEXT.items():
            got = joined.get(level, "")
            if want in got:
                ok(f"h{level} is scaled")
            else:
                bad(f"h{level} is scaled", f"level {level} payload: {got!r}")

        # A long CJK heading wraps into several scaled blocks instead of
        # falling back to plain size. Both ends have to survive: a heading that
        # only scaled as far as it happened to fit would keep the first.
        cjk = joined.get(2, "")
        if "あいうえお" in cjk and "まみむめも" in cjk:
            ok("long CJK heading is scaled end to end")
        else:
            bad("long CJK heading is scaled end to end", f"level 2 payload: {cjk!r}")

        print("\nscaled headings OFF:")
        # A float exposes parts of the source behind it, whose original #
        # markers would falsely pass the ordinary-text assertions below.
        runs_off, diag_off, plain_off = run_kitty(args.kitty, False, workdir, "toggle")
        print("".join(f"    {line}\n" for line in diag_off.strip().splitlines()), end="")
        if runs_off:
            bad("nothing is scaled when disabled", f"found {runs_off}")
        else:
            ok("nothing is scaled when disabled")
        plain_rows = plain_off.splitlines()
        for level, title in LEVEL_TEXT.items():
            row = next((row for row, line in enumerate(plain_rows)
                        if re.search(rf"(?<!#){'#' * level} {re.escape(title)}", line)), None)
            if row is not None:
                ok(f"plain h{level} retains its Markdown rank")
            else:
                bad(f"plain h{level} retains its Markdown rank")
            if level <= 2:
                rule = "═" if level == 1 else "─"
                if row is not None and row + 1 < len(plain_rows) and rule in plain_rows[row + 1]:
                    ok(f"plain h{level} is followed by its {'double' if level == 1 else 'single'} rule")
                else:
                    bad(f"plain h{level} is followed by its expected rule")

        print("\ncursor movement in an in-place preview:")
        run_kitty(args.kitty, True, workdir, "toggle")

        print("\npager local-file navigation and editing:")
        run_kitty(args.kitty, True, workdir, "pager")

    print(f"\nterminal_test: {passed} passed, {failed} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
