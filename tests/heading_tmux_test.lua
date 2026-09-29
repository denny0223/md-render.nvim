-- Quiet uploads avoid replies leaking into another pane or popup.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. package.path
vim.env.TMUX, vim.env.TMUX_PANE = "/private/test,1,0", "%2"
vim.o.termguicolors = true
local output, jobs = {}, {}
vim.api.nvim_list_uis = function()
  return { {} }
end
vim.api.nvim_ui_send = function(data)
  output[#output + 1] = data
end
vim.fn.executable = function()
  return 1
end
vim.system = function(cmd, opts, callback)
  assert(
    cmd[1] == "tmux" and cmd[2] == "-S" and cmd[3] == "/private/test" and cmd[4] == "list-clients",
    "inspect the owning server without changing options or focus"
  )
  jobs[#jobs + 1] = callback
  return { kill = function() end }
end
local tmux = require "md-render.heading_tmux"
tmux.status()
local client = {
  "123",
  "1000",
  "xterm-kitty",
  "kitty(0.48.2)",
  "attached,focused,UTF-8",
  "%2",
  "0",
  "all",
  "13",
  "30",
  "RGB,clipboard,hyperlinks",
  "120",
  "53",
  "120",
  "55",
  "2",
  "1048576",
}
local function settle()
  vim.wait(20, function()
    return false
  end)
end
local function inspect(values, extra)
  vim.api.nvim_exec_autocmds("FocusGained", {})
  local callback = assert(table.remove(jobs, 1))
  callback { code = 0, stdout = table.concat(values, "\t") .. "\n" .. (extra or "") }
  settle()
  return tmux.status()
end
assert(not tmux.status().key and #jobs == 1)
tmux.status()
assert(#jobs == 1, "coalesce connection checks")
assert(inspect(client).key)
local function blocked(index, value, reason)
  local values = vim.deepcopy(client)
  values[index] = value
  local status = inspect(values)
  assert(not status.key and status.reason:find(reason, 1, true), vim.inspect(status))
  assert(#output == 0, "connection inspection never sends terminal queries")
end
blocked(6, "%1", "active")
blocked(7, "1", "copy mode")
blocked(8, "off", "passthrough")
blocked(8, "on", "passthrough")
blocked(4, "tmux 3.7c", "Kitty")
blocked(4, "kitty(0.27.0)", "Kitty")
blocked(5, "attached,active-pane", "topology")
blocked(9, "0", "dimensions")
blocked(11, "256", "RGB")
blocked(11, "RGB", "hyperlinks")
blocked(12, "180", "viewport")
blocked(13, "54", "viewport")
blocked(17, "", "buffer limit")
assert(not inspect(client, table.concat(client, "\t")).key, "multiple clients retain ordinary text")
inspect(client)
-- A fresh connection cached before opening a preview still needs observation.
vim.b.md_render = true
tmux.status()
assert(
  vim.wait(600, function()
    return #jobs > 0
  end),
  "opening a preview starts observing a fresh cached connection"
)
vim.b.md_render = nil
table.remove(jobs, 1) { code = 0, stdout = table.concat(client, "\t") }
settle()
vim.wait(300, function()
  return false
end)
assert(#jobs == 0, "closing the preview stops connection polling")

-- Retired resources can request observation after the last preview closes.
tmux.watch_cleanup(true)
assert(
  vim.wait(600, function()
    return #jobs > 0
  end),
  "pending cleanup keeps inspecting the client"
)
tmux.watch_cleanup(false)
table.remove(jobs, 1) { code = 0, stdout = table.concat(client, "\t") }
settle()
vim.wait(300, function()
  return false
end)
assert(#jobs == 0, "completed cleanup stops observation")

local resized = vim.deepcopy(client)
resized[9] = "14"
local old_connection = tmux.status()
local resized_connection = inspect(resized)
assert(resized_connection.key ~= old_connection.key and resized_connection.owner == old_connection.owner)
local system = vim.system
vim.system = function()
  error "EAGAIN: simulated tmux spawn failure"
end
vim.api.nvim_exec_autocmds("FocusGained", {})
assert(not tmux.status().key and tmux.status().reason:find("EAGAIN", 1, true))
vim.system = system
assert(inspect(client).key, "inspection can recover from a local spawn failure")

local small_buffer = vim.deepcopy(client)
small_buffer[17] = "10000"
assert(inspect(small_buffer).limit == 8192, "respect tmux's buffer allocation boundary")
vim.env.TMUX = nil
vim.api.nvim_exec_autocmds("FocusGained", {})
assert(not tmux.status().key and tmux.status().reason:find("pane information", 1, true))
assert(#jobs == 0 and #output == 0, "missing connection information starts no work")
print "Tmux image capabilities: inspection, gates, ownership and bounded observation OK"
