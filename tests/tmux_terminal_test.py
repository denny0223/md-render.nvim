#!/usr/bin/env python3
"""Native heading acceptance in an isolated real Kitty/tmux session.

Run under X11 or xvfb-run. Requires Kitty >= 0.40, tmux and Neovim >= 0.12.
Optional --output DIR retains terminal snapshots and screenshots (ImageMagick).
"""
import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import re
import shlex
import signal
import socket as network
import subprocess
import tempfile
import time
import unicodedata

from terminal_test import level_of, parse_meta

REPO = Path(__file__).resolve().parent.parent
OSC66 = re.compile(r"\x1b\]66;([^;]*);(.*?)(?:\x1b\\|\x07)", re.S)
SGR = re.compile(r"\x1b\[[0-9;:]*m")
OSC8 = re.compile(r"\x1b\]8;.*?(?:\x1b\\|\x07)")


def cell_width(text):
    return sum(0 if unicodedata.combining(ch) else 2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in text)


def scaled_positions(screen):
    """Read actual Kitty cell positions, including each multicell run's width."""
    for row, line in enumerate(screen.splitlines()):
        column = end = 0
        for match in OSC66.finditer(line):
            column += cell_width(SGR.sub("", OSC8.sub("", line[end:match.start()])))
            meta = parse_meta(match[1])
            height = meta.get("s", 1)
            width = height * (meta.get("w") or cell_width(match[2]))
            yield row, column, height, width
            column += width
            end = match.end()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--checkout", type=Path, default=REPO, help="plugin checkout to test")
    parser.add_argument("--ssh", action="store_true", help="attach through an isolated loopback OpenSSH server")
    parser.add_argument("--passthrough", choices=("on", "all"), default="on")
    parser.add_argument("--snacks", type=Path, help="installed Snacks checkout for image coexistence checks")
    options = parser.parse_args()
    output = options.output
    if output:
        output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    for key in ("TMUX", "TMUX_PANE", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"):
        env.pop(key, None)

    def run(args):
        return subprocess.check_output(args, env=env, text=True, timeout=10)

    def wait_for(check, label):
        deadline = time.monotonic() + 10
        while not check():
            assert time.monotonic() < deadline, label
            time.sleep(.1)
        print("PASS " + label, flush=True)
        checks.append(label)

    checks = []
    with tempfile.TemporaryDirectory(prefix="md-native-tmux-") as td, ExitStack() as cleanups:
        root = Path(td)
        env["NVIM_LOG_FILE"] = str(root / "nvim.log")
        server = str(root / "nvim.sock")
        socket = str(root / "tmux.sock")
        terminal = "unix:" + str(root / "kitty.sock")

        def stop(child):
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=5)

        def launch(args, logfile):
            child = subprocess.Popen(args, env=env, stdout=logfile, stderr=logfile, start_new_session=True)
            cleanups.callback(stop, child)
            return child

        cleanups.callback(subprocess.run, ["tmux", "-S", socket, "kill-server"], env=env, capture_output=True)
        fixture = root / "headings.md"
        fixture.write_text("Body.\n\n" + "\n\n".join("#" * level + f" 共同 H{level}" for level in range(1, 7)) + "\n\n" + "Body after headings.\n\n" * 60)
        config = root / "tmux.conf"
        config.write_text(f'set -g default-terminal tmux-256color\nset -g allow-passthrough {options.passthrough}\nset -g focus-events on\nset -g status 2\nset -g status-position top\nset -g status-interval 0\nset -g status-format[0] "Native headings | #{{window_name}}"\nset -g status-format[1] "pane #{{pane_index}}"\n')
        init = root / "init.lua"
        snacks_setup = ""
        if options.snacks:
            assert (options.snacks / "lua/snacks/init.lua").is_file(), "invalid Snacks checkout"
            snacks_setup = '''
vim.opt.runtimepath:prepend(%s)
require("snacks").setup { image = { enabled = true, cache = %s, doc = {enabled = false}, math = {enabled = false} } }
require("md-render.image").setup { backend = "snacks" }
''' % (json.dumps(str(options.snacks.resolve())), json.dumps(str(root / "snacks-cache")))
        init.write_text('''
vim.opt.runtimepath:prepend(%s)
%s
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.termguicolors = true
vim.opt.mouse = "a"
vim.opt.cursorline = true
vim.opt.laststatus = 0
_G.focus_events = {}
vim.api.nvim_create_autocmd({"FocusLost", "FocusGained"}, {callback=function(ev)
  table.insert(_G.focus_events, {event=ev.event, time=vim.uv.hrtime()/1e9})
end})
vim.api.nvim_create_autocmd("TextYankPost", {callback=function() vim.hl.on_yank({timeout=500}) end})
vim.api.nvim_create_autocmd("VimEnter", {once=true, callback=function()
  vim.schedule(function()
    vim.cmd "MdRender textsize native"
    vim.cmd "MdRender toggle"
    vim.cmd "normal! gg0"
  end)
end})
''' % (json.dumps(str(options.checkout.resolve())), snacks_setup))

        def tmux(*args):
            return run(["tmux", "-S", socket, *args])

        def kitty(*args):
            return run(["kitty", "@", "--to", terminal, *args])

        def lua(code):
            return run(["nvim", "--server", server, "--remote-expr", "luaeval('" + code.replace("'", "''") + "')"])

        def state():
            return json.loads(lua('''(function()
              local s = require('md-render.preview')._sessions[vim.api.nvim_get_current_buf()]
              local mux = package.loaded['md-render.text_size_tmux']
              return vim.json.encode({ status=require('md-render.text_size').status(),
                context=mux and mux.get() or {},
                backend=s and s.content.heading_backend,
                placements=s and #s.content.text_placements,
                drawn=s and s.text_size_state and s.text_size_state.last_drawn,
                focus_events=_G.focus_events, eventignore=vim.o.eventignore, termsync=vim.o.termsync,
                columns=vim.o.columns, rows=vim.o.lines, topline=vim.fn.line('w0'),
                messages=vim.fn.execute('messages') })
            end)()'''))

        def scaled():
            return OSC66.findall(kitty("get-text", "--ansi", "--add-wrap-markers"))

        def six_levels():
            runs = scaled()
            return all("".join(text for meta, text in runs if level_of(meta) == level) == f"共同 H{level}"
                       for level in range(1, 7))

        def stays_plain(label):
            wait_for(lambda: not scaled(), label)
            deadline = time.monotonic() + 1.1
            while time.monotonic() < deadline:
                assert not scaled(), label + ": delayed output escaped"
                time.sleep(.1)

        def inside_pane():
            fields = tmux("display-message", "-p", "-t", pane,
                          "#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{status}|#{status-position}").strip().split("|")
            left, top, pane_width, pane_height = map(int, fields[:4])
            status_rows = 1 if fields[4] == "on" else 0 if fields[4] == "off" else int(fields[4])
            if fields[5] == "top":
                top += status_rows
            positions = list(scaled_positions(kitty("get-text", "--ansi", "--add-wrap-markers")))
            return bool(positions) and all(
                top <= row and row + height <= top + pane_height
                and left <= column and column + width <= left + pane_width
                for row, column, height, width in positions
            )

        def capture(name):
            if not output:
                return
            (output / (name + ".ansi")).write_text(kitty("get-text", "--ansi", "--add-wrap-markers"))
            (output / (name + ".json")).write_text(json.dumps(state(), ensure_ascii=False, indent=2) + "\n")
            window = str(json.loads(kitty("ls"))[0]["platform_window_id"])
            run(["magick", "import", "-window", window, str(output / (name + ".png"))])

        run(["tmux", "-S", socket, "-f", str(config), "new-session", "-d", "-s", "headings", "-x", "110", "-y", "56", "sleep 3600"])
        attach = ["tmux", "-S", socket, "attach-session", "-t", "headings"]
        sshd = None
        if options.ssh:
            for name in ("host", "identity"):
                run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / name)])
            with network.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                port = listener.getsockname()[1]
            ssh_config = root / "sshd.conf"
            ssh_config.write_text(f"Port {port}\nListenAddress 127.0.0.1\nHostKey {root / 'host'}\nPidFile {root / 'sshd.pid'}\nAuthorizedKeysFile {root / 'identity.pub'}\nStrictModes no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nAllowUsers {run(['id', '-un']).strip()}\n")
            ssh_log = cleanups.enter_context((output / "sshd.log" if output else root / "sshd.log").open("w"))
            sshd = launch(["/usr/sbin/sshd", "-D", "-e", "-f", str(ssh_config)], ssh_log)
            known_hosts = root / "known_hosts"
            known_hosts.write_text(f"[127.0.0.1]:{port} " + (root / "host.pub").read_text())
            attach = ["ssh", "-F", "/dev/null", "-tt", "-p", str(port), "-i", str(root / "identity"),
                      "-o", "IdentitiesOnly=yes", "-o", "StrictHostKeyChecking=yes",
                      "-o", f"UserKnownHostsFile={known_hosts}", "127.0.0.1", shlex.join(attach)]
            time.sleep(.2)
            assert sshd.poll() is None, "isolated sshd failed to start"

        command = ["kitty", "--config", "NONE", "--title", "md-render native tmux acceptance",
                   "-o", "allow_remote_control=yes", "-o", "confirm_os_window_close=0",
                   "-o", "remember_window_size=no", "-o", "initial_window_width=110c",
                   "-o", "initial_window_height=56c", "-o", "font_size=9",
                   "-o", "linux_display_server=x11", "--listen-on", terminal, *attach]
        log = cleanups.enter_context((output / "kitty.log" if output else root / "kitty.log").open("w"))
        process = launch(command, log)
        try:
            wait_for(lambda: (root / "kitty.sock").exists(), "Kitty started")
            tmux("split-window", "-h", "-t", "headings:0.0", "sleep 3600")
            nvim = shlex.join(["nvim", "-u", str(init), "-i", "NONE", "--listen", server, str(fixture)])
            pane = tmux("split-window", "-v", "-t", "headings:0.1", "-P", "-F", "#{pane_id}", nvim).strip()
            wait_for(lambda: Path(server).exists(), "Neovim started")
            try:
                wait_for(lambda: state().get("drawn") == 6 and six_levels() and inside_pane(), "six distinct scales within bottom-right pane")
            except AssertionError:
                print(json.dumps(state(), ensure_ascii=False, indent=2), flush=True)
                raise
            assert not state()["termsync"], "native headings disable pane-wide synchronized redraws"
            capture("01-split")
            wait_for(six_levels, "startup redraw restores six complete headings")
            tmux("select-pane", "-t", "headings:0.0")
            stays_plain("inactive pane pauses scaling")
            assert state().get("backend") == "native", "focus must not change the backend"
            tmux("select-pane", "-t", pane)
            tmux("refresh-client")
            wait_for(lambda: six_levels(), "headings return after tmux redraw")
            tmux("copy-mode", "-t", pane)
            stays_plain("copy mode exposes ordinary text")
            capture("02-copy-mode")
            tmux("send-keys", "-t", pane, "-X", "cancel")
            wait_for(lambda: six_levels(), "headings return after copy mode")
            tmux("new-window", "-n", "other", "sleep 3600")
            stays_plain("no headings in unrelated window")
            capture("03-other-window")
            tmux("select-window", "-t", "headings:0")
            wait_for(lambda: six_levels(), "headings return after window switch")
            tmux("resize-pane", "-Z", "-t", pane)
            wait_for(lambda: six_levels() and inside_pane(), "zoom preserves six levels within pane bounds")
            capture("04-zoom")
            tmux("resize-pane", "-Z", "-t", pane)
            wait_for(lambda: six_levels() and inside_pane(), "unzoom restores pane placement")
            tmux("set-option", "-w", "-t", pane, "pane-border-status", "top")
            wait_for(lambda: six_levels() and inside_pane(), "pane border titles preserve heading coordinates")
            tmux("set-option", "-w", "-t", pane, "pane-border-status", "off")
            tmux("set-option", "-g", "status-position", "bottom")
            wait_for(lambda: state()["context"]["top"] == int(tmux("display-message", "-p", "-t", pane, "#{pane_top}").strip()) and six_levels() and inside_pane(), "bottom status rows do not shift pane coordinates")
            capture("04-bottom-status")
            tmux("set-option", "-g", "status", "off")
            wait_for(lambda: six_levels() and inside_pane(), "status off preserves placement after resize")
            tmux("resize-pane", "-t", pane, "-y", "28")
            wait_for(lambda: state()["rows"] == 28 and six_levels() and inside_pane(), "pane resize keeps headings inside its bounds")
            lua("vim.cmd('normal! G')")
            wait_for(lambda: not scaled(), "scrolling away clears offscreen headings")
            lua("vim.cmd('normal! gg0')")
            wait_for(six_levels, "scrolling back restores six levels")
            lua("(function() vim.fn.setreg('/', '共同'); vim.o.hlsearch=true; vim.v.hlsearch=1; vim.cmd('redraw!') end)()")
            wait_for(lambda: not scaled(), "search exposes every matching heading")
            capture("05-search")
            lua("vim.cmd('nohlsearch')")
            wait_for(lambda: six_levels(), "nohlsearch restores scaling")
            lua("(function() local s=require('md-render.preview')._sessions[vim.api.nvim_get_current_buf()]; local p=s.content.text_placements[1]; vim.api.nvim_win_set_cursor(0,{p.line+1,p.col}); vim.api.nvim_input('v1l') end)()")
            wait_for(lambda: not any("H1" in text for _, text in scaled()) and any("H2" in text for _, text in scaled()), "Visual selection reveals only its heading")
            capture("05-visual")
            lua("vim.api.nvim_input('y')")
            wait_for(lambda: lua("vim.fn.getreg('0')") == "共同", "Visual yank copies the real CJK text")
            lua("vim.cmd('normal! gg0')")
            wait_for(six_levels, "scaling returns after yank feedback and leaving the cursor line")
            tmux("set-option", "-p", "-t", pane, "allow-passthrough", "off")
            wait_for(lambda: state().get("backend") == "plain" and not scaled(), "passthrough off restores plain headings")
            assert state()["termsync"], "plain fallback restores synchronized updates"
            capture("06-disabled-passthrough")
            tmux("set-option", "-p", "-t", pane, "allow-passthrough", options.passthrough)
            wait_for(lambda: state().get("backend") == "native" and six_levels(), "enabling passthrough recovers without reopening")
            assert not state()["termsync"], "native recovery suspends synchronized updates again"
            lua("vim.cmd('MdRender textsize auto')")
            wait_for(lambda: state()["status"].startswith("auto -> native") and six_levels(), "auto selects verified native fallback")
            lua("vim.cmd('MdRender textsize off')")
            wait_for(lambda: not scaled(), "off clears all enlarged text")
            assert state()["termsync"], "textsize off restores synchronized updates"
            lua("vim.cmd('MdRender textsize on')")
            wait_for(lambda: six_levels(), "on restores selected policy")
            capture("07-restored")
            tmux("detach-client", "-s", "headings")
            wait_for(lambda: state().get("backend") == "plain", "detaching invalidates the old client capability")
            process.wait(timeout=10)
            process = launch(command, log)
            wait_for(lambda: (root / "kitty.sock").exists(), "replacement Kitty started")
            wait_for(lambda: state().get("backend") == "native" and six_levels(), "reattachment rechecks capability and restores headings")
            capture("08-reattached")

            # A second real client is sufficient to require safe plain output;
            # absolute coordinates cannot be broadcast to independent grids.
            extra_command = command.copy()
            extra_command[extra_command.index(terminal)] = "unix:" + str(root / "second.sock")
            extra = launch(extra_command, log)
            try:
                wait_for(lambda: state().get("backend") == "plain" and not scaled(), "multiple attached clients use ordinary text")
                capture("09-multiple-clients")
            finally:
                stop(extra)
            # A bare Xvfb server has no window manager to return desktop focus
            # after the second window closes. Focus the remaining test window.
            kitty("focus-window", "--match", "all")
            wait_for(lambda: state().get("backend") == "native" and six_levels(), "single-client recovery after another client leaves")
            tmux("new-session", "-d", "-t", "headings", "-s", "grouped")
            assert tmux("display-message", "-p", "-t", pane, "#{window_linked_sessions}").strip() == "1"
            wait_for(lambda: state().get("backend") == "plain" and not scaled(), "grouped sessions cannot bypass the linked-window guard")
            capture("10-grouped-sessions")
            tmux("kill-session", "-t", "grouped")
            wait_for(six_levels, "removing grouped session restores native headings")
            lua("vim.cmd('MdRender toggle')")
            wait_for(lambda: not scaled(), "preview teardown clears enlarged text")
            assert state()["termsync"], "closing the preview restores synchronized updates"
            time.sleep(.7)
            assert not scaled(), "a queued paint revived detached headings"
            lua("vim.cmd('MdRender toggle')")
            wait_for(six_levels, "preview reopening restores six complete headings")

            popup = launch(["tmux", "-S", socket, "display-popup", "-E", "-w", "100%", "-h", "100%",
                            shlex.join(["sh", "-c", 'printf "POPUP ACCEPTANCE\\n"; read answer; printf "POPUP INPUT: %s\\n" "$answer"; sleep 30'])], log)
            wait_for(lambda: "POPUP ACCEPTANCE" in kitty("get-text"), "fullscreen popup opened")
            kitty("send-text", "--", "popup-input\r")
            wait_for(lambda: "POPUP INPUT: popup-input" in kitty("get-text"), "keyboard input reaches the popup")
            lua("vim.cmd('redraw!')")
            time.sleep(1.3)  # Cross two keepalive ticks; an initial clear alone is not enough.
            capture("11-popup")
            assert not scaled(), "native keepalive painted headings over the tmux popup"
            wait_for(lambda: not scaled(), "popup stays clear across redraw and keepalive")
            tmux("display-popup", "-C")
            popup.wait(timeout=10)
            wait_for(six_levels, "closing popup restores native headings")

            # Reuse the existing terminal transport with a wrapped CJK heading.
            # An optional real Snacks image shares the same visible document.
            tmux("resize-pane", "-Z", "-t", pane)
            long_text = "共同文字自然排列閱讀測試" * 6
            extra = ""
            if options.snacks:
                picture = root / "coexist.png"
                run(["magick", "-size", "96x32", "xc:#e43b44", str(picture)])
                extra = f"\n\n![Snacks coexistence]({picture})"
            long_fixture = root / "long-heading.md"
            long_fixture.write_text("Body.\n\n## " + long_text + extra + "\n")
            lua("vim.cmd('MdRender toggle')")
            lua("vim.cmd.edit(" + json.dumps(str(long_fixture)) + ")")
            lua("vim.cmd('MdRender toggle')")
            wait_for(lambda: "".join(text for meta, text in scaled() if level_of(meta) == 2) == long_text and inside_pane(),
                     "wrapped CJK heading preserves all text within pane bounds")
            if options.snacks:
                wait_for(lambda: "\U0010eeee" in kitty("get-text"), "real Snacks image placeholders coexist with native headings")
                assert tmux("show-options", "-p", "-t", pane, "-v", "allow-passthrough").strip() == "all"
            capture("12-long-heading")
            # Exercise a partial overlay while normal plugin refreshes temporarily
            # suppress autocmds. No event-loop wait occurs inside eventignore=all.
            lua('''(function()
              local buf=vim.api.nvim_create_buf(false,true)
              _G.refresh_timer = vim.uv.new_timer()
              _G.refresh_timer:start(0, 50, vim.schedule_wrap(function()
                local ei=vim.o.eventignore
                vim.o.eventignore='all'
                local w=vim.api.nvim_open_win(buf,false,
                  {relative='editor',row=2,col=2,width=8,height=1,style='minimal'})
                vim.api.nvim_win_close(w,true)
                vim.o.eventignore=ei
              end))
            end)()''')
            for _ in range(3):
                popup = launch(["tmux", "-S", socket, "display-popup", "-E", "-x", "0", "-y", "0", "-w", "60%", "-h", "50%",
                                "printf 'PARTIAL POPUP'; sleep 30"], log)
                wait_for(lambda: "PARTIAL POPUP" in kitty("get-text"), "partial popup opens during plugin redraws")
                stays_plain("partial popup suppresses all native heading output")
                capture("13-partial-popup")
                tmux("display-popup", "-C")
                popup.wait(timeout=10)
                wait_for(lambda: "".join(text for meta, text in scaled() if level_of(meta) == 2) == long_text,
                         "heading recovers after popup during plugin redraws")
            lua("(function() _G.refresh_timer:stop(); _G.refresh_timer:close() end)()")
            capture("14-recovered")
            # Rich headings use the same native transport and preserve their
            # styles, destinations, and measured wrapping through pane changes.
            rich = root / "rich.md"
            rich.write_text("Body.\n\n" + "\n\n".join([
                "# **共同文字** Heading", "## [FIRST](#first) [SECOND](#second)",
                "### `:Telescope md_render` 擴充功能", "#### *文字 italic* and **bold**",
                "##### ~~移除文字~~ and [外部連結](https://example.com)",
                "###### `共同`**文字***測試*[連結](#first) ordinary text",
                "## First", "## Second"]) + "\n")

            def open_preview(path):
                lua("vim.cmd('MdRender toggle')")
                lua("vim.cmd.edit(" + json.dumps(str(path)) + ")")
                lua("vim.cmd('MdRender toggle')")
                lua("vim.cmd('normal! gg0')")

            open_preview(rich)
            def rich_visible():
                runs = scaled()
                return (state().get("backend") == "native" and inside_pane()
                        and all(any(level_of(meta) == level for meta, _ in runs) for level in range(1, 7)))
            wait_for(rich_visible, "rich Markdown preserves six native levels through tmux")
            screen = kitty("get-text", "--ansi", "--add-wrap-markers")
            assert ":Telescope" in "".join(text for _, text in scaled())
            assert "https://example.com" in screen and "#first" in screen and "#second" in screen
            capture("15-rich-headings")
            tmux("resize-pane", "-Z", "-t", pane)
            wait_for(lambda: state().get("backend") == "native" and inside_pane(), "styled headings wrap within the smaller pane")
            capture("16-rich-wrapped")
            tmux("resize-pane", "-Z", "-t", pane)
            wait_for(rich_visible, "rich heading scales recover after zoom")

            # Match a target using Kitty's painted cells, independently of the
            # renderer's hit map. Exercise both rows via real Neovim input.
            for row_offset in (0, 1):
                screen = kitty("get-text", "--ansi", "--add-wrap-markers")
                matches = list(OSC66.finditer(screen))
                positions = list(scaled_positions(screen))
                index = next(i for i, match in enumerate(matches) if match[2] == "SECOND")
                row, col, _, _ = positions[index]
                ctx = state()["context"]
                y, x = row - ctx["top"] + row_offset, col - ctx["left"] + 2
                lua(f"vim.api.nvim_input_mouse('left','press','',0,{y},{x})")
                lua(f"vim.api.nvim_input_mouse('left','release','',0,{y},{x})")
                wait_for(lambda: lua("(function() local s=require('md-render.preview')._sessions[vim.api.nvim_get_current_buf()]; return vim.json.encode(vim.api.nvim_win_get_cursor(0)[1] == s.content.heading_anchors.second+1) end)()") == "true",
                         f"visible SECOND link activates its own anchor on row {row_offset + 1}")
                lua("vim.cmd('normal! gg0')")
                wait_for(rich_visible, "rich headings return after link activation")

            open_preview(options.checkout / "README.zh-TW.md")
            wait_for(lambda: state()["status"].startswith("auto -> native") and bool(scaled()),
                     "the complete README stays native under auto")
            capture("17-readme")
            lua("(function() local s=require('md-render.preview')._sessions[vim.api.nvim_get_current_buf()]; for _,p in ipairs(s.content.text_placements) do if p.text:find(':Telescope',1,true) then vim.api.nvim_win_set_cursor(0,{p.line,0}); vim.cmd('normal! zt'); break end end end)()")
            wait_for(lambda: ":Telescope" in "".join(text for _,text in scaled()),
                     "README inline-code heading is visibly scaled")
            capture("18-readme-telescope")
            controls = root / "controls.md"
            controls.write_text("Body.\n\n### `a\tb` X\n\n### [a&#9;b](#destination)\n\n## Destination\n")
            open_preview(controls)
            wait_for(lambda: state()["status"].startswith("auto -> plain: native heading text contains control characters")
                     and not scaled(), "control-character headings retain ordinary text")
            assert re.search(r"a[ \t]+b", kitty("get-text")), "heading tab spacing was lost"
            capture("19-control-fallback")

            urls = root / "url-controls.md"
            urls.write_text("Body.\n\n## [TAB](https://example.invalid/a&#9;b) [DEL](https://example.invalid/a&#x7F;b)\n")
            open_preview(urls)
            wait_for(lambda: state().get("backend") == "native" and bool(scaled()),
                     "URL controls do not disable native heading text")
            screen = kitty("get-text", "--ansi", "--add-wrap-markers")
            assert "https://example.invalid/a%09b" in screen and "https://example.invalid/a%7Fb" in screen
            capture("20-encoded-links")

            assert "Pending mode" not in Path(log.name).read_text(), "synchronized output bypassed tmux's frame state"
            print(f"tmux terminal: {len(checks)} checks passed", flush=True)
        except Exception:
            if Path(server).exists() and output:
                capture("failure")
            raise
        finally:
            if output:
                (output / "checks.json").write_text(json.dumps(checks, indent=2) + "\n")


if __name__ == "__main__":
    main()
