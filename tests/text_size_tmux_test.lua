-- Run: nvim --headless -u NONE --noplugin -l tests/text_size_tmux_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. package.path
local tmux = require "md-render.text_size_tmux"
local pane = { "%3", "$1", "@2", "51", "18", "50", "20", "0", "on", "0", "1", "101", "38", "1", "3.7c" }
local client = { "/dev/pts/1", "$1", "@2", "kitty(0.48.2)", "101", "40", "2", "top", "100", "200", "0", "attached" }
local function snapshot(p, c, extra)
  return table.concat(p or pane, "\t") .. "\n" .. table.concat(c or client, "\t") .. (extra or "") .. "\n"
end
local function change(values, index, value)
  local copy = vim.deepcopy(values)
  copy[index] = value
  return copy
end
local ctx = tmux.parse(snapshot(), "%3")
assert(ctx.supported and ctx.drawable and ctx.left == 51 and ctx.top == 20)
for _, version in ipairs { "3.6", "3.6a", "3.7c", "4.0" } do
  assert(tmux.parse(snapshot(change(pane, 15, version)), "%3").supported, version)
end
for _, version in ipairs { "2.9", "3.4", "3.5a", "", "unknown" } do
  local unsupported = tmux.parse(snapshot(change(pane, 15, version)), "%3")
  assert(not unsupported.supported and unsupported.reason:find("tmux >= 3.6", 1, true), version)
end
assert(tmux.parse(snapshot(nil, change(client, 8, "bottom")), "%3").top == 18)
assert(tmux.parse(snapshot(nil, change(client, 7, "off")), "%3").top == 18)
assert(tmux.parse(snapshot(nil, change(client, 4, "kitty(0.40.0)")), "%3").supported)
for _, version in ipairs { "kitty(0.39.9)", "tmux 3.7c", "WezTerm 20260101", "", "xterm-kitty" } do
  assert(not tmux.parse(snapshot(nil, change(client, 4, version)), "%3").supported, version)
end
assert(tmux.parse(snapshot(change(pane, 9, "all")), "%3").supported)
for _, option in ipairs { "off", "" } do
  assert(not tmux.parse(snapshot(change(pane, 9, option)), "%3").supported)
end
assert(not tmux.parse(snapshot(change(pane, 14, "0")), "%3").supported)
assert(not tmux.parse(snapshot(change(pane, 10, "1")), "%3").supported, "grouped sessions also link windows")
assert(not tmux.parse(snapshot(nil, nil, "\n" .. table.concat(client, "\t")), "%3").supported)
assert(tmux.parse(snapshot(nil, nil, "\n" .. table.concat(change(client, 2, "$9"), "\t")), "%3").supported)
assert(tmux.parse(snapshot(nil, nil, "\n" .. table.concat(change(client, 11, "1"), "\t")), "%3").supported)
for _, case in ipairs {
  { change(pane, 8, "1"), client }, -- copy mode
  { change(pane, 11, "0"), client }, -- inactive pane, whether visible or hidden by zoom
  { pane, change(client, 3, "@9") }, -- another window
  { pane, change(client, 12, "attached,suspended") },
} do
  local hidden = tmux.parse(snapshot(case[1], case[2]), "%3")
  assert(hidden.supported and not hidden.drawable, "visibility must not discard confirmed capability")
end
for _, case in ipairs {
  { change(pane, 4, "-1"), client },
  { change(pane, 5, ""), client },
  { pane, change(client, 5, "80") },
  { pane, change(client, 6, "30") },
} do
  assert(not tmux.parse(snapshot(case[1], case[2]), "%3").supported, "do not guess cropped geometry")
end
assert(not tmux.parse("", "%3").supported)
assert(not tmux.parse(snapshot(), "%9").supported)
local bytes = "\27[4;5H\27]66;s=2;共同文字\27\\"
assert(tmux.wrap(bytes) == "\27Ptmux;" .. bytes:gsub("\27", "\27\27") .. "\27\\")

-- Exercise the real command boundary and cache without touching a tmux server.
local system, uis, hrtime = vim.system, vim.api.nvim_list_uis, vim.uv.hrtime
local env = { vim.env.TMUX, vim.env.TMUX_PANE, vim.env.TERM_PROGRAM }
vim.env.TMUX, vim.env.TMUX_PANE, vim.env.TERM_PROGRAM = "/tmp/test.sock,123,0", "%3", "tmux"
local clock, killed, requests = 0, 0, {}
vim.uv.hrtime = function()
  return clock * 1e6
end
vim.system = function(args, opts, callback)
  requests[#requests + 1] = callback
  assert(args[1] == "tmux" and args[2] == "-S" and args[3] == "/tmp/test.sock")
  assert(args[4] == "display-message" and args[7] == "%3" and opts.timeout == 150)
  assert(args[8]:find("#{window_linked}", 1, true), "count grouped sessions individually")
  assert(args[8]:find("#{version}", 1, true), "check the server version, not the client executable")
  return {
    wait = function()
      error "redraw must never wait for tmux"
    end,
    kill = function()
      killed = killed + 1
    end,
  }
end
local function finish(index, code, output)
  requests[index] { code = code, stdout = output }
  local done = false
  vim.schedule(function()
    done = true
  end)
  assert(vim.wait(100, function()
    return done
  end, 1))
end
tmux.reset()
vim.env.TMUX_PANE = ""
assert(not tmux.get().supported and not tmux.get().supported and #requests == 0)
vim.env.TMUX_PANE = "%3"
assert(not tmux.get().supported and not tmux.get().supported and #requests == 1)
finish(1, 0, snapshot())
assert(tmux.get().supported and #requests == 1)
clock = clock + 60
tmux.get()
assert(#requests == 2, "one pending read per UI burst")
tmux.get()
assert(#requests == 2)
finish(2, 0, snapshot(nil, change(client, 4, "WezTerm")))
assert(not tmux.get().supported, "reattachment must not reuse a previous terminal")
vim.api.nvim_list_uis = function()
  return { {} }
end
local size = require "md-render.text_size"
size.setup { backend = "native" }
assert(size.resolve_backend() == "plain" and size.status():find("tmux has not identified", 1, true))
clock = clock + 60
tmux.get()
finish(3, 124, "")
clock = clock + 900
assert(not tmux.get().supported and #requests == 3, "timeouts must back off")
clock = clock + 101
tmux.get()
assert(#requests == 4)
tmux.reset()
assert(killed == 1, "reset cancels the pending read")
tmux.get()
finish(5, 0, snapshot())
finish(4, 0, snapshot(nil, change(client, 4, "WezTerm")))
assert(tmux.get().supported, "a stale completion cannot replace the current connection")
assert(size.resolve_backend() == "native", "native policy uses tmux's positive terminal identification")
size.setup { backend = "auto" }
assert(size.resolve_backend() == "native", "auto may use native while image tmux support remains unavailable")
size.setup { enabled = false }
assert(size.resolve_backend() == "plain")

-- Focus protects every output path, including queued scrolls and keepalive.
vim.o.termguicolors = true
local get, redraw, send = tmux.get, tmux.redraw, vim.api.nvim_ui_send
ctx.width, ctx.height = vim.o.columns, vim.o.lines
tmux.get = function()
  return ctx
end
local writes, redraws = {}, 0
tmux.redraw = function()
  redraws = redraws + 1
end
vim.api.nvim_ui_send = function(bytes)
  writes[#writes + 1] = bytes
end
local set_provider, provider = vim.api.nvim_set_decoration_provider, nil
vim.api.nvim_set_decoration_provider = function(ns, opts)
  if ns == vim.api.nvim_get_namespaces().md_render_text_size_redraw and opts.on_start then provider = opts end
  return set_provider(ns, opts)
end
size.setup { enabled = true, backend = "native" }
local builder = require("md-render.content_builder").ContentBuilder.new()
builder:render_document({ "Body.", "", "## Heading", "", "## Another" }, { max_width = 60, indent = "  " })
local content = builder:result()
local buf, win = vim.api.nvim_create_buf(false, true), vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
vim.api.nvim_win_set_buf(win, buf)
vim.cmd "redraw"
local original_termsync = vim.o.termsync
vim.o.termsync = true
local empty = vim.deepcopy(content)
empty.text_placements = {}
local watcher = size.attach(win, empty)
assert(watcher and vim.o.termsync, "a native watcher without enlarged headings must not change synchronized updates")
size.detach(watcher)
local plain = vim.deepcopy(content)
plain.heading_backend, plain.text_placements = "plain", {}
local state = size.attach(win, plain)
assert(vim.o.termsync, "plain fallback must not change synchronized updates")
state = size.refresh(state, win, content)
assert(not vim.o.termsync, "native capability recovery disables pane-wide synchronized redraws")
assert(
  vim.wait(500, function()
    return #writes > 0
  end, 10),
  "foreground startup must not need an initial FocusGained"
)
vim.api.nvim_exec_autocmds("FocusLost", { modeline = false })
assert(redraws == 1 and state.drawn == nil and state.last_drawn == 0, "tmux owns cleanup on focus loss")
assert(
  size.resolve_backend() == "native" and state.content == content,
  "pausing must not rebuild or change the backend"
)
assert(size.status():find("paused", 1, true))
local before = #writes
vim.api.nvim_exec_autocmds("WinScrolled", { modeline = false })
vim.api.nvim_exec_autocmds("SafeState", { modeline = false })
vim.wait(650, function()
  return #writes > before
end, 10)
assert(
  #writes == before and state.drawn == nil and state.last_drawn == 0,
  "paused output stays suppressed across keepalive"
)
vim.api.nvim_exec_autocmds("FocusGained", { modeline = false })
assert(
  vim.wait(500, function()
    return #writes > before
  end, 10),
  "focus recovery repaints without reopening"
)
local other_win = vim.api.nvim_open_win(buf, false, {
  relative = "editor",
  row = 0,
  col = 0,
  width = 20,
  height = 4,
  style = "minimal",
})
local other = size.attach(other_win, content)
size.detach(state)
assert(not vim.o.termsync, "another native preview still needs passthrough-compatible redraws")
size.detach(other)
assert(vim.o.termsync, "closing the last native preview restores the original setting")

local inferred = vim.deepcopy(content)
inferred.heading_backend = nil
state = size.attach(win, inferred)
assert(not vim.o.termsync, "placements also acquire the setting when backend metadata is omitted")
size.detach(state)

vim.o.termsync = false
state = size.attach(win, content)
size.detach(state)
assert(not vim.o.termsync, "an originally disabled setting remains disabled")

vim.o.termsync = true
state = size.attach(win, content)
state = size.refresh(state, win, plain)
assert(vim.o.termsync, "fallback restores synchronized updates before the watcher detaches")
size.detach(state)

for _, selected in ipairs { true, false } do
  vim.o.termsync = true
  state, other = size.attach(win, content), size.attach(other_win, content)
  vim.o.termsync = selected
  -- OptionSet is not emitted during nvim -l startup; emulate the user's :set.
  vim.api.nvim_exec_autocmds("OptionSet", { pattern = "termsync", modeline = false })
  size.detach(state)
  assert(vim.o.termsync == selected, "closing one preview must respect an explicit option change")
  size.detach(other)
  assert(vim.o.termsync == selected, "closing the last preview must not overwrite the user's new setting")
end
vim.api.nvim_win_close(other_win, true)
vim.wait(10) -- drain notifications from the retired previews
-- Follow the actual redraw ranges, including the empty lower row of a scaled
-- heading. Unrelated updates must not erase it or wait for a movement timer.
local function finish_redraw()
  local schedule, callback = vim.schedule, nil
  vim.schedule = function(fn)
    callback = fn
  end
  provider.on_end()
  vim.schedule = schedule
  assert(callback, "redraw schedules completion after the TUI flush")
  callback()
end
state = size.attach(win, content)
size.paint(state)
writes = {}
provider.on_start()
assert(#writes == 0, "unchanged positions do not erase headings")
provider.on_range(nil, win, buf, 0, 0, 1, 0)
assert(#writes == 0, "body redraw leaves unmoved headings alone")
local p = content.text_placements[1]
provider.on_range(nil, win, buf, p.line + 1, 0, p.line + 2, 0)
assert(#writes > 0 and state.erased[1].p == p, "erase multicells before drawing their lower row")
assert(
  writes[1]:gsub("\27\27", "\27"):find(state.erased[1].sgr, 1, true),
  "erase with the heading background, not terminal-default black"
)
state.owes_invalidate = true
local invalidations = size._stats.invalidations
finish_redraw()
assert(not state.owes_invalidate, "finish the cleanup in the current frame")
assert(size._stats.invalidations == invalidations, "already-erased blocks need no forced repaint")

local redraw_api, redraw_requests = vim.api.nvim__redraw, {}
vim.api.nvim__redraw = function(opts)
  redraw_requests[#redraw_requests + 1] = opts
  return redraw_api(opts)
end
local redraw_flags = vim.o.redrawdebug
vim.wo.cursorline = true
vim.api.nvim_win_set_cursor(win, { p.line + 1, 0 })
size.paint(state)
assert(state.last_drawn == 2, "CursorLine in the margin keeps both headings enlarged")
local feedback_ns = vim.api.nvim_create_namespace "native-yank-feedback"
vim.api.nvim_buf_set_extmark(buf, feedback_ns, p.line, p.col, {
  end_row = p.line + 1,
  end_col = 0,
  hl_group = "IncSearch",
})
provider.on_range(nil, win, buf, p.line, 0, p.line + 1, 0)
finish_redraw()
assert(state.last_drawn == 1, "yank feedback completes without waiting for the debounce")
assert(#redraw_requests == 1 and redraw_requests[1].win == win, "restore text through a window redraw")
assert(vim.deep_equal(redraw_requests[1].range, { p.line, p.line + p.scale }), "repaint only the heading rows")
assert(vim.o.redrawdebug == redraw_flags, "restore the user's redraw flags")
vim.wait(10) -- drain the scoped redraw's own notification
vim.api.nvim_buf_clear_namespace(buf, feedback_ns, 0, -1)
size.paint(state)
assert(state.last_drawn == 2, "scaling returns after feedback without moving the cursor")
assert(#redraw_requests == 1, "adding scaling does not invalidate existing headings")

-- Command-line feedback can retire all headings even when the TUI only
-- redrew one. Include the untouched blocks as well as the erased ones.
local feedback = require "md-render.heading_feedback"
local protected = feedback.protected
feedback.protected = function()
  return true, {}
end
provider.on_range(nil, win, buf, p.line, 0, p.line + 1, 0)
finish_redraw()
local last = content.text_placements[#content.text_placements]
assert(state.last_drawn == 0, "all headings yield to command-line feedback")
assert(redraw_requests[#redraw_requests].range[2] == last.line + last.scale, "restore untouched retired headings too")
feedback.protected = protected
vim.wait(10)
size.paint(state)

vim.api.nvim_buf_set_extmark(buf, feedback_ns, p.line, p.col, {
  end_row = p.line + 1,
  end_col = 0,
  hl_group = "IncSearch",
})
provider.on_range(nil, win, buf, p.line, 0, p.line + 1, 0)
vim.api.nvim__redraw = function()
  error "test redraw failure"
end
local ok, err = pcall(finish_redraw)
assert(not ok and err:find("test redraw failure", 1, true), "report the redraw error")
assert(vim.o.redrawdebug == redraw_flags, "restore redraw flags even after a failure")
vim.api.nvim__redraw = redraw_api
vim.wo.cursorline = false
size.detach(state)
vim.api.nvim_set_decoration_provider = set_provider
vim.o.termsync = original_termsync

tmux.get, tmux.redraw, vim.api.nvim_ui_send = get, redraw, send
vim.system, vim.api.nvim_list_uis, vim.uv.hrtime = system, uis, hrtime
vim.env.TMUX, vim.env.TMUX_PANE, vim.env.TERM_PROGRAM = unpack(env)
print "tmux: capability, geometry, visibility, transport, reconnection and policy checks passed"
