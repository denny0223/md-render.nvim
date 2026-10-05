#!/usr/bin/env python3
"""Heading acceptance in an isolated real Kitty/tmux session.

Run under X11 or xvfb-run. Requires Kitty >= 0.40 and Neovim >= 0.12.
Requires tmux >= 3.6 unless checking older versions with --expect-plain.
Optional --output DIR retains terminal snapshots and screenshots (ImageMagick).
--output-on-failure DIR collects diagnostics only after a failure.
--images additionally requires image-heading Python dependencies, Pillow and ImageMagick.
"""
import argparse
from contextlib import ExitStack
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket as network
import subprocess
import tempfile
import time
import traceback
import unicodedata

from terminal_test import level_of, parse_meta

REPO = Path(__file__).resolve().parent.parent
OSC66 = re.compile(r"\x1b\]66;([^;]*);(.*?)(?:\x1b\\|\x07)", re.S)
SGR = re.compile(r"\x1b\[[0-9;:]*m")
OSC8 = re.compile(r"\x1b\]8;.*?(?:\x1b\\|\x07)")


def cell_width(text):
    return sum(0 if unicodedata.combining(ch) else 2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in text)


def scaled_positions(screen):
    """Estimate Kitty cell positions and widths from serialized OSC66 runs."""
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


def rich_frame(screen, geometry, snapshot):
    """Return a painted target and its origin only after resize has settled."""
    ctx = snapshot.get("context") or {}
    if (snapshot.get("backend") != "native" or not ctx.get("supported") or not ctx.get("drawable")
            or any(ctx.get(key) != geometry[key] for key in ("left", "top", "width", "height"))
            or (snapshot.get("columns"), snapshot.get("rows")) != (geometry["width"], geometry["height"])
            or not ctx.get("key") or snapshot.get("tmux_key") != ctx["key"] + ":true"
            or not snapshot.get("placements") or snapshot.get("drawn") != snapshot["placements"]
            or snapshot.get("last_drawn") != snapshot["placements"]):
        return None
    runs = OSC66.findall(screen)
    positions = list(scaled_positions(screen))
    if (not all(any(level_of(meta) == level for meta, _ in runs) for level in range(1, 7))
            or not all(ctx["top"] <= row and row + height <= ctx["top"] + ctx["height"]
                       and ctx["left"] <= col and col + width <= ctx["left"] + ctx["width"]
                       for row, col, height, width in positions)):
        return None
    for (_, text), position in zip(runs, positions):
        if text == "SECOND" and position[0] - ctx["top"] + 1 == snapshot.get("source_link_row"):
            return position, ctx


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    outputs = parser.add_mutually_exclusive_group()
    outputs.add_argument("--output", type=Path)
    outputs.add_argument("--output-on-failure", type=Path)
    parser.add_argument("--checkout", type=Path, default=REPO, help="plugin checkout to test")
    parser.add_argument("--ssh", action="store_true", help="attach through an isolated loopback OpenSSH server")
    parser.add_argument("--passthrough", choices=("on", "all"), default="on")
    parser.add_argument("--snacks", type=Path, help="installed Snacks checkout for image coexistence checks")
    parser.add_argument("--expect-plain", action="store_true", help="verify fallback for tmux older than 3.6")
    parser.add_argument("--images", action="store_true", help="check image pixels, links and auto fallback; requires --passthrough all")
    options = parser.parse_args()
    if options.output_on_failure and options.output_on_failure.exists() and (
        not options.output_on_failure.is_dir() or any(options.output_on_failure.iterdir())
    ):
        parser.error("--output-on-failure requires a new or empty directory")
    if options.images and (options.passthrough != "all" or options.expect_plain):
        parser.error("--images requires --passthrough all and cannot use --expect-plain")
    capture_command = ["magick", "import"] if shutil.which("magick") else ["import"]
    convert_command = ["magick"] if shutil.which("magick") else ["convert"]
    if options.images or options.output:
        assert shutil.which(capture_command[0]), "ImageMagick window capture is required"
    if options.snacks:
        assert shutil.which(convert_command[0]), "ImageMagick conversion is required"
    output = options.output
    diagnostic_output = options.output_on_failure or output
    if output:
        output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    for key in ("TMUX", "TMUX_PANE", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"):
        env.pop(key, None)

    def run(args):
        return subprocess.check_output(args, env=env, text=True, timeout=10,
                                       **({"stderr": subprocess.PIPE} if captured else {}))

    def wait_for(check, label):
        nonlocal current_wait
        current_wait = label
        deadline = time.monotonic() + 10
        try:
            while True:
                result = check()
                if result:
                    break
                assert time.monotonic() < deadline, label
                time.sleep(.1)
        except Exception as error:
            diagnose(type(error), error, error.__traceback__)
            raise
        print("PASS " + label, flush=True)
        checks.append(label)
        current_wait = None
        return result

    checks = []
    current_wait = last_input = painted_screen = None
    launches = []
    captured = False
    with tempfile.TemporaryDirectory(prefix="md-native-tmux-") as td, ExitStack() as cleanups, ExitStack() as diagnostics:
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
            record = {"args": args, "started_at": time.time()}
            launches.append(record)
            child = subprocess.Popen(args, env=env, stdout=logfile, stderr=logfile, start_new_session=True)
            record["pid"] = child.pid
            cleanups.callback(stop, child)
            return child

        cleanups.callback(subprocess.run, ["tmux", "-S", socket, "kill-server"], env=env, capture_output=True)
        fixture = root / "headings.md"
        fixture.write_text("Body.\n\n" + "\n\n".join("#" * level + f" 共同 H{level}" for level in range(1, 7)) + "\n\n" + "Body after headings.\n\n" * 60)
        if options.images:
            fixture.write_text("Body.\n\n" + "\n\n".join("#" * level + f" 共同 H{level}"
                + (" [REF][doc]" if level == 2 else " <https://a.test/x>" if level == 3 else "")
                for level in range(1, 7)) + "\n\n[doc]: https://example.invalid/reference\n")
        config = root / "tmux.conf"
        config.write_text(f'set -g default-terminal tmux-256color\nset -g allow-passthrough {options.passthrough}\nset -g focus-events on\nset -g status 2\nset -g status-position top\nset -g status-interval 0\nset -g status-format[0] "Native headings | #{{window_name}}"\nset -g status-format[1] "pane #{{pane_index}}"\n')
        with config.open("a") as stream:
            stream.write('set -as terminal-features ",xterm-kitty:RGB:hyperlinks"\n')
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
  local buf=vim.api.nvim_get_current_buf()
  local preview=package.loaded['md-render.preview']
  local s=preview and preview._sessions[buf]
  local ts=s and s.text_size_state
  table.insert(_G.focus_events, {event=ev.event, time=vim.uv.hrtime()/1e9, buf=buf,
    last_drawn=ts and ts.last_drawn, tmux_key=ts and ts.tmux_key,
    owes_invalidate=ts and ts.owes_invalidate})
end})
vim.api.nvim_create_autocmd("TextYankPost", {callback=function() vim.hl.on_yank({timeout=500}) end})
vim.api.nvim_create_autocmd("VimEnter", {once=true, callback=function()
  vim.schedule(function()
    %s
    vim.cmd "MdRender textsize %s"
    vim.cmd "MdRender toggle"
    vim.cmd "normal! gg0"
  end)
end})
''' % (json.dumps(str(options.checkout.resolve())), snacks_setup,
       'vim.api.nvim_set_hl(0,"Normal",{fg=0xd8dee9,bg=0x161c28})' if options.images else "",
       "auto" if options.images else "native"))

        def tmux(*args):
            return run(["tmux", "-S", socket, *args])

        def kitty(*args):
            nonlocal last_input
            if args[0] == "send-text":
                last_input = {"kind": "kitty", "args": args, "time": time.time()}
            return run(["kitty", "@", "--to", terminal, *args])

        def lua(code):
            nonlocal last_input
            if "nvim_input(" in code:
                last_input = {"kind": "nvim", "code": code, "time": time.time()}
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

        def pane_geometry():
            fields = tmux("display-message", "-p", "-t", pane,
                          "#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{status}|#{status-position}").strip().split("|")
            left, top, pane_width, pane_height = map(int, fields[:4])
            status_rows = 1 if fields[4] == "on" else 0 if fields[4] == "off" else int(fields[4])
            if fields[5] == "top":
                top += status_rows
            return {"left": left, "top": top, "width": pane_width, "height": pane_height}

        def inside_pane():
            ctx = pane_geometry()
            positions = list(scaled_positions(kitty("get-text", "--ansi", "--add-wrap-markers")))
            return bool(positions) and all(
                ctx["top"] <= row and row + height <= ctx["top"] + ctx["height"]
                and ctx["left"] <= column and column + width <= ctx["left"] + ctx["width"]
                for row, column, height, width in positions
            )

        def screenshot(path):
            window = str(json.loads(kitty("ls"))[0]["platform_window_id"])
            run([*capture_command, "-window", window, str(path)])

        def capture(name):
            if not output:
                return
            (output / (name + ".ansi")).write_text(kitty("get-text", "--ansi", "--add-wrap-markers"))
            (output / (name + ".json")).write_text(json.dumps(state(), ensure_ascii=False, indent=2) + "\n")
            screenshot(output / (name + ".png"))

        def failure_state():
            # Read the renderer's cached context; status()/mux.get() can start
            # a fresh tmux query and change the state being diagnosed.
            return json.loads(lua('''(function()
              local preview=package.loaded['md-render.preview']
              local text=package.loaded['md-render.text_size']
              local s=preview and preview._sessions[vim.api.nvim_get_current_buf()]
              local ts=s and s.text_size_state
              local windows={}
              for _,win in ipairs(vim.api.nvim_list_wins()) do
                table.insert(windows,{win=win,buf=vim.api.nvim_win_get_buf(win),
                  position=vim.api.nvim_win_get_position(win),config=vim.api.nvim_win_get_config(win),
                  width=vim.api.nvim_win_get_width(win),height=vim.api.nvim_win_get_height(win),
                  cursor=vim.api.nvim_win_get_cursor(win)})
              end
              return vim.json.encode({backend=s and s.content.heading_backend,
                fallback=s and s.content.heading_fallback,context=ts and ts.tmux,tmux_key=ts and ts.tmux_key,
                placements=s and s.content.text_placements,drawn=ts and ts.drawn,erased=ts and ts.erased,
                last_drawn=ts and ts.last_drawn,last_layout=ts and ts.last_layout,
                owes_invalidate=ts and ts.owes_invalidate,closed=ts and ts.closed,
                gesture=ts and ts.gesture,press=ts and ts.press,dragged=ts and ts.dragged,
                stats=text and text._stats,anchors=s and s.content.heading_anchors,
                links=s and s.content.link_metadata,buf=vim.api.nvim_get_current_buf(),
                win=vim.api.nvim_get_current_win(),cursor=vim.api.nvim_win_get_cursor(0),
                view=vim.fn.winsaveview(),mouse=vim.fn.getmousepos(),mode=vim.api.nvim_get_mode(),
                focus_events=_G.focus_events,eventignore=vim.o.eventignore,termsync=vim.o.termsync,
                columns=vim.o.columns,rows=vim.o.lines,windows=windows,messages=vim.fn.execute('messages')})
            end)()'''))

        def diagnose(error_type, error, tb):
            nonlocal captured
            if not diagnostic_output or captured:
                return
            captured = error is not None
            try:
                diagnostic_output.mkdir(parents=True, exist_ok=True)
            except Exception as secondary:
                print(f"Cannot create diagnostic directory: {secondary}", flush=True)
                return
            report = {}

            def keep(name, write):
                entry = report[name] = {"started_at": time.time()}
                try:
                    path = diagnostic_output / name
                    path.unlink(missing_ok=True)
                    write(path)
                except Exception as secondary:
                    entry["error"] = repr(secondary)
                    for key in ("stdout", "stderr"):
                        value = getattr(secondary, key, None)
                        if value is not None:
                            entry[key] = value.decode(errors="replace") if isinstance(value, bytes) else value
                entry["finished_at"] = time.time()

            def write_json(path, value):
                path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")

            if error is not None:
                keep("failure.json", lambda path: write_json(path, {
                    "exception": {"type": error_type.__name__, "message": str(error),
                                  "traceback": "".join(traceback.format_exception(error_type, error, tb))},
                    "current_wait": current_wait, "checks": checks, "last_input": last_input,
                    "launches": launches, "options": {key: str(value) if isinstance(value, Path) else value
                                                       for key, value in vars(options).items()},
                    "github": {key: env.get(key) for key in
                               ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_SHA", "GITHUB_JOB")},
                    "captured_at": time.time(), "atomic": False,
                }))
                # Capture pixels and cells before querying Neovim's event loop.
                keep("failure.png", screenshot)
                keep("failure.ansi", lambda path: path.write_text(kitty("get-text", "--ansi", "--add-wrap-markers")))
                keep("failure.cells.json", lambda path: write_json(path, {
                    "positions": list(scaled_positions((diagnostic_output / "failure.ansi").read_text())),
                    "runs": OSC66.findall((diagnostic_output / "failure.ansi").read_text()),
                }))
                keep("input.ansi", lambda path: path.write_text(painted_screen) if painted_screen is not None else None)
                keep("failure.pane.txt", lambda path: path.write_text(tmux("capture-pane", "-p", "-e", "-t", pane)))
                keep("failure.state.json", lambda path: write_json(path, failure_state()))
                keep("failure.kitty.json", lambda path: path.write_text(kitty("ls")))
                keep("failure.clients.txt", lambda path: path.write_text(tmux("list-clients", "-F",
                    "#{client_tty}|#{session_id}|#{window_id}|#{client_width}|#{client_height}|#{client_cell_width}|#{client_cell_height}|#{client_flags}|#{status}|#{status-position}")))
                keep("failure.panes.txt", lambda path: path.write_text(tmux("list-panes", "-a", "-F",
                    "#{pane_id}|#{window_id}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{pane_active}|#{pane_in_mode}|#{window_width}|#{window_height}|#{allow-passthrough}|#{focus-events}")))
                for name, command in (("kitty", ["kitty", "--version"]), ("tmux", ["tmux", "-V"]),
                                      ("nvim", ["nvim", "--version"]),
                                      ("revision", ["git", "-C", str(options.checkout), "rev-parse", "HEAD"])):
                    keep(f"{name}-version.txt", lambda path, command=command: path.write_text(run(command)))
                for name in ("kitty", "nvim", "sshd"):
                    if name == "sshd" and not options.ssh:
                        continue
                    source = (output or root) / (name + ".log") if name != "nvim" else root / "nvim.log"
                    if source != diagnostic_output / (name + ".log"):
                        keep(name + ".log", lambda path, source=source: shutil.copyfile(source, path))
            keep("checks.json", lambda path: write_json(path, checks))
            keep("diagnostics.json", lambda path: write_json(path, {key: value for key, value in report.items()
                                                                  if key != "diagnostics.json"}))

        diagnostics.push(diagnose)

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
            if options.images:
                import base64
                import io
                from PIL import Image

                def image_state():
                    return json.loads(lua('''(function()
                      local s=require('md-render.preview')._sessions[vim.api.nvim_get_current_buf()]
                      if not s or s.content.heading_backend~='image' then return '{}' end
                      local result={entries={},links=s.content.link_metadata}
                      for _,e in ipairs(s.text_size_state and s.text_size_state.entries or {}) do
                        local p=e.placement
                        local colors={}
                        for _,name in ipairs({p.hl,'Normal','MdRenderLink','Underlined'}) do
                          local fg=vim.api.nvim_get_hl(0,{name=name,link=false}).fg
                          if fg then table.insert(colors,fg) end
                        end
                        table.insert(result.entries,{text=p.text,data=e.data,visible=e.visible,
                          rows=p.scale,line=p.line,byte=p.col,columns=e.columns,colors=colors,
                          screen=vim.fn.screenpos(s.win,p.line+1,p.col+1)})
                      end
                      return vim.json.encode(result)
                    end)()'''))

                def image_frame(name):
                    def six_images():
                        info = image_state()
                        entries = info.get("entries", [])
                        return info if len(entries) == 6 and all(e.get("visible") for e in entries) else None

                    info = wait_for(six_images, name + ": six image placements ready")
                    left, top = map(int, tmux("display-message", "-p", "-t", pane, "#{pane_left} #{pane_top}").split())
                    cols, rows, cell_w, cell_h = map(int, tmux("list-clients", "-F",
                        "#{client_width} #{client_height} #{client_cell_width} #{client_cell_height}").split())
                    masks = []
                    for level, entry in enumerate(info["entries"], 1):
                        assert entry["text"].startswith(f"共同 H{level}"), entry["text"]
                        assert entry["rows"] == (2 if level <= 3 else 1), entry
                        raster = Image.open(io.BytesIO(base64.b64decode(entry["data"]))).convert("RGBA")
                        colors = [tuple((color >> shift) & 255 for shift in (16, 8, 0)) for color in entry["colors"]]
                        mask = [(x, y, raster.getpixel((x, y))[:3]) for y in range(raster.height) for x in range(raster.width)
                            if raster.getpixel((x, y))[3] >= 254 and any(
                                max(abs(a-b) for a, b in zip(raster.getpixel((x, y))[:3], color)) < 12 for color in colors)]
                        assert mask, ("no opaque glyph pixels", entry["text"])
                        masks.append(mask)
                    window = str(json.loads(kitty("ls"))[0]["platform_window_id"])
                    path = (output or root) / (name + ".png")

                    def painted_pixels():
                        run([*capture_command, "-window", window, str(path)])
                        matched = []
                        with Image.open(path).convert("RGB") as screen:
                            # Kitty puts an odd spare pixel on the far edge.
                            pad_x = (screen.width - cols * cell_w) // 2
                            pad_y = (screen.height - rows * cell_h) // 2
                            for entry, mask in zip(info["entries"], masks):
                                x = (entry["screen"]["col"] - 1 + left) * cell_w + pad_x
                                y = (entry["screen"]["row"] - 1 + top + 2) * cell_h + pad_y
                                matched.append(sum(max(abs(a-b) for a, b in zip(screen.getpixel((x+dx, y+dy)), color)) < 12
                                    for dx, dy, color in mask) / len(mask))
                        if output:
                            (output / (name + ".pixels.json")).write_text(json.dumps(matched) + "\n")
                        return all(ratio >= .90 for ratio in matched)

                    wait_for(painted_pixels, name + ": all six PNG glyph masks match actual pixels")

                    def painted_links():
                        text = kitty("get-text", "--ansi")
                        pattern = re.compile(r"\x1b\]8;[^;]*;(.*?)(?:\x1b\\|\x07)|\x1b\[[0-?]*[ -/]*[@-~]")
                        grid, row, url, end = [], [], None, 0
                        for match in list(pattern.finditer(text)) + [None]:
                            for char in text[end:match.start() if match else len(text)]:
                                if char == "\n":
                                    grid.append(row)
                                    row = []
                                elif char != "\r":
                                    row.extend([url] * cell_width(char))
                            if match:
                                if match[1] is not None:
                                    url = match[1] or None
                                end = match.end()
                        grid.append(row)
                        covered = set()
                        for entry in info["entries"]:
                            for col, byte in enumerate(entry["columns"]):
                                expected = None if byte is False else next((link["url"] for link in info["links"]
                                    if link["line"] == entry["line"] and link["col_start"] <= entry["byte"] + byte < link["col_end"]), None)
                                if expected:
                                    covered.add(expected)
                                x = entry["screen"]["col"] - 1 + left + col
                                y = entry["screen"]["row"] - 1 + top + 2
                                for offset in range(entry["rows"]):
                                    if y + offset >= len(grid) or x >= len(grid[y+offset]) or grid[y+offset][x] != expected:
                                        return False
                        return covered == {"https://example.invalid/reference", "https://a.test/x"}

                    wait_for(painted_links, name + ": reference and angle URLs match painted cells on both rows")
                    capture(name)

                image_frame("image-initial")
                assert state()["status"].startswith("auto -> image"), state()
                lua("vim.cmd('MdRender toggle')")
                wait_for(lambda: not state().get("backend") and "\U0010eeee" not in kitty("get-text"),
                         "source toggle removes image placeholders")
                assert json.loads(lua("vim.json.encode(vim.api.nvim_buf_get_lines(0,0,-1,false))")) == fixture.read_text().splitlines()
                lua("vim.cmd('MdRender toggle')")
                image_frame("image-reopened")
                tmux("set-option", "-p", "-t", pane, "allow-passthrough", "on")
                wait_for(lambda: state()["status"].startswith("auto -> native") and bool(scaled())
                         and "\U0010eeee" not in kitty("get-text"), "auto falls back to native when image passthrough is unavailable")
                tmux("set-option", "-p", "-t", pane, "allow-passthrough", "off")
                wait_for(lambda: state()["status"].startswith("auto -> plain") and not scaled()
                         and "\U0010eeee" not in kitty("get-text"), "auto keeps readable text when passthrough is off")
                assert all(f"共同 H{level}" in kitty("get-text") for level in range(1, 7))
                tmux("set-option", "-p", "-t", pane, "allow-passthrough", "all")
                image_frame("image-recovered")
                print(f"tmux image terminal: {len(checks)} checks passed", flush=True)
                return
            if options.expect_plain:
                for policy in ("native", "auto"):
                    if policy == "auto":
                        tmux("set-option", "-p", "-t", pane, "allow-passthrough", "on")
                    lua(f"vim.cmd('MdRender textsize {policy}')")
                    wait_for(lambda: state().get("backend") == "plain" and "tmux >= 3.6" in state()["status"],
                             f"{policy} explains unsupported popup focus events")
                    assert not scaled(), "unsupported tmux must not receive enlarged text"
                    assert all(f"共同 H{level}" in kitty("get-text") for level in range(1, 7))
                    assert state()["termsync"], "plain fallback must retain synchronized updates"
                capture("unsupported-tmux")
                print(f"tmux terminal: {len(checks)} checks passed (plain fallback)", flush=True)
                return
            wait_for(lambda: state().get("drawn") == 6 and six_levels() and inside_pane(), "six distinct scales within bottom-right pane")
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
            # Alternate text and margins so an unchanged, pre-movement frame
            # cannot satisfy the next expectation. Confirm the cursor as well.
            for index, (offset, column, label, enlarged) in enumerate((
                (1, "p.col", "text", False), (1, "0", "margin", True),
                (1, "p.col", "text", False), (2, "0", "lower-row margin", True),
            )):
                target = json.loads(lua("(function() local s=require('md-render.preview')._sessions[vim.api.nvim_get_current_buf()]; local p=s.content.text_placements[1]; local c={p.line+%d,%s}; vim.api.nvim_win_set_cursor(0,c); return vim.json.encode(c) end)()" % (offset, column)))

                def cursor_feedback():
                    cursor = json.loads(lua("vim.json.encode(vim.api.nvim_win_get_cursor(0))"))
                    runs = scaled()
                    return cursor == target and all(
                        "".join(text for meta, text in runs if level_of(meta) == level)
                        == ("" if level == 1 and not enlarged else f"共同 H{level}")
                        for level in range(1, 7)
                    ) and (enlarged or "共同 H1" in kitty("get-text"))

                wait_for(cursor_feedback, f"CursorLine on heading {label} {'preserves scaling' if enlarged else 'reveals precise text'}")
                capture(f"04-cursor-{index}-{label.replace(' ', '-')}")
            lua("vim.cmd('normal! gg0')")
            lua("(function() vim.fn.setreg('/', '共同'); vim.o.hlsearch=true; vim.v.hlsearch=1; vim.cmd('redraw!') end)()")
            wait_for(lambda: not scaled(), "search exposes every matching heading")
            assert all(f"共同 H{level}" in kitty("get-text") for level in range(1, 7)), "search feedback lost heading text"
            capture("05-search")
            kitty("send-text", "--", "/")
            wait_for(lambda: not scaled() and all(f"共同 H{level}" in kitty("get-text") for level in range(1, 7)),
                     "open search command line preserves every ordinary heading")
            kitty("send-text", "--", "\x1b")
            lua("vim.cmd('nohlsearch')")
            wait_for(lambda: six_levels(), "nohlsearch restores scaling")
            lua("(function() local s=require('md-render.preview')._sessions[vim.api.nvim_get_current_buf()]; local p=s.content.text_placements[1]; vim.api.nvim_win_set_cursor(0,{p.line+1,p.col}); vim.api.nvim_input('v1l') end)()")
            wait_for(lambda: not any("H1" in text for _, text in scaled()) and any("H2" in text for _, text in scaled()), "Visual selection reveals only its heading")
            assert "共同 H1" in kitty("get-text"), "Visual feedback lost unselected heading text"
            capture("05-visual")
            lua("vim.api.nvim_input('y')")
            wait_for(lambda: lua("vim.fn.getreg('0')") == "共同", "Visual yank copies the real CJK text")
            assert not any("H1" in text for _, text in scaled()), "keyboard cursor still needs ordinary text after yank"
            lua("vim.cmd('normal! 0')")
            wait_for(six_levels, "leaving the text restores scaling after yank feedback")
            lua("vim.cmd('normal! gg0')")
            tmux("set-option", "-p", "-t", pane, "allow-passthrough", "off")
            wait_for(lambda: state().get("backend") == "plain" and not scaled(), "passthrough off restores plain headings")
            assert state()["termsync"], "plain fallback restores synchronized updates"
            capture("06-disabled-passthrough")
            tmux("set-option", "-p", "-t", pane, "allow-passthrough", options.passthrough)
            wait_for(lambda: state().get("backend") == "native" and six_levels(), "enabling passthrough recovers without reopening")
            assert not state()["termsync"], "native recovery suspends synchronized updates again"
            tmux("set-option", "-p", "-t", pane, "allow-passthrough", "on")
            lua("vim.cmd('MdRender textsize auto')")
            wait_for(lambda: state()["status"].startswith("auto -> native") and six_levels(), "auto selects verified native fallback")
            lua("vim.cmd('MdRender textsize native')")
            tmux("set-option", "-p", "-t", pane, "allow-passthrough", options.passthrough)
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
            assert tmux("display-message", "-p", "-t", pane, "#{session_grouped}").strip() == "1"
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
                run([*convert_command, "-size", "96x32", "xc:#e43b44", str(picture)])
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
                nonlocal painted_screen
                geometry = pane_geometry()
                snapshot = json.loads(lua('''(function()
                  local preview=package.loaded['md-render.preview']
                  local s=preview and preview._sessions[vim.api.nvim_get_current_buf()]
                  local ts=s and s.text_size_state
                  local source_link_row
                  for _,link in ipairs(s and s.content.link_metadata or {}) do
                    if link.url=='#second' then
                      source_link_row=vim.fn.screenpos(s.win,link.line+1,link.col_start+1).row
                      break
                    end
                  end
                  return vim.json.encode({backend=s and s.content.heading_backend,
                    context=ts and ts.tmux,tmux_key=ts and ts.tmux_key,
                    placements=s and #s.content.text_placements,
                    drawn=ts and ts.drawn and #ts.drawn,last_drawn=ts and ts.last_drawn,
                    columns=vim.o.columns,rows=vim.o.lines,source_link_row=source_link_row})
                end)()'''))
                screen = kitty("get-text", "--ansi", "--add-wrap-markers")
                frame = rich_frame(screen, geometry, snapshot)
                if frame:
                    painted_screen = screen
                return frame
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
                position, ctx = wait_for(rich_visible, "SECOND link is painted before clicking")
                row, col, height, width = position
                y, x = row - ctx["top"] + row_offset, col - ctx["left"] + 2
                last_input = {"kind": "mouse", "time": time.time(), "painted": [row, col, height, width],
                              "context": dict(ctx), "pane_row": y, "pane_column": x,
                              "row_offset": row_offset, "phase": "press"}
                lua(f"vim.api.nvim_input_mouse('left','press','',0,{y},{x})")
                last_input["phase"] = "release"
                lua(f"vim.api.nvim_input_mouse('left','release','',0,{y},{x})")
                wait_for(lambda: lua("(function() local s=require('md-render.preview')._sessions[vim.api.nvim_get_current_buf()]; return vim.json.encode(vim.api.nvim_win_get_cursor(0)[1] == s.content.heading_anchors.second+1) end)()") == "true",
                         f"visible SECOND link activates its own anchor on row {row_offset + 1}")
                lua("vim.cmd('normal! gg0')")
                wait_for(rich_visible, "rich headings return after link activation")

            open_preview(options.checkout / "README.zh-TW.md")
            wait_for(lambda: state()["status"].startswith("native -> native") and bool(scaled()),
                     "the complete README stays native under the selected policy")
            capture("17-readme")
            lua("(function() local s=require('md-render.preview')._sessions[vim.api.nvim_get_current_buf()]; for _,p in ipairs(s.content.text_placements) do if p.text:find(':Telescope',1,true) then vim.api.nvim_win_set_cursor(0,{p.line,0}); vim.cmd('normal! zt'); break end end end)()")
            wait_for(lambda: ":Telescope" in "".join(text for _,text in scaled()),
                     "README inline-code heading is visibly scaled")
            capture("18-readme-telescope")
            controls = root / "controls.md"
            controls.write_text("Body.\n\n### `a\tb` X\n\n### [a&#9;b](#destination)\n\n## Destination\n")
            open_preview(controls)
            wait_for(lambda: state()["status"].startswith("native -> plain: native heading text contains control characters")
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
        except Exception as error:
            diagnose(type(error), error, error.__traceback__)
            raise


if __name__ == "__main__":
    main()
