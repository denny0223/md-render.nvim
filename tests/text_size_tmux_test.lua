-- Run: nvim --headless -u NONE --noplugin -l tests/text_size_tmux_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. package.path
local tmux = require "md-render.text_size_tmux"
local pane = { "%3", "$1", "@2", "51", "18", "50", "20", "0", "on", "0", "1", "101", "38", "1" }
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
size.setup { enabled = true, backend = "native" }
local builder = require("md-render.content_builder").ContentBuilder.new()
builder:render_document({ "Body.", "", "## Heading" }, { max_width = 60, indent = "" })
local content = builder:result()
local buf, win = vim.api.nvim_create_buf(false, true), vim.api.nvim_get_current_win()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
vim.api.nvim_win_set_buf(win, buf)
vim.cmd "redraw"
local state = size.attach(win, content)
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
size.detach(state)
tmux.get, tmux.redraw, vim.api.nvim_ui_send = get, redraw, send
vim.system, vim.api.nvim_list_uis, vim.uv.hrtime = system, uis, hrtime
vim.env.TMUX, vim.env.TMUX_PANE, vim.env.TERM_PROGRAM = unpack(env)
print "tmux: capability, geometry, visibility, transport, reconnection and policy checks passed"
