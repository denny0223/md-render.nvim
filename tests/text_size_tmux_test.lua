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
vim.system, vim.api.nvim_list_uis, vim.uv.hrtime = system, uis, hrtime
vim.env.TMUX, vim.env.TMUX_PANE, vim.env.TERM_PROGRAM = unpack(env)
print "tmux: capability, geometry, visibility, transport and reconnection checks passed"
