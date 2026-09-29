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
local image = require "md-render.image"
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
  local count = #output
  assert(image.png_status().supported == false and #output == count, "unsupported connections send no query")
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
output = {}
local probe = image.png_status()
assert(not probe.supported and #output == 0, "public image support waits for the placeholder renderer")
require("md-render.tty").kitty_version = function()
  error "tmux uploads must not send identity queries"
end
image.supports_kitty = function()
  error "tmux headings must not depend on the ordinary image backend"
end

local ready = false
local first_upload = assert(image.transmit_png(string.rep("YWJj", 1500), function()
  ready = true
end, 10, 2))
assert(not ready, "quiet completion is deferred until after queuing the upload")
assert(
  output[1]:find("a=T", 1, true) and output[1]:find("U=1,p=1,c=10,r=2", 1, true),
  "upload and retain the correctly sized PNG as one atomic Kitty operation"
)
settle()
assert(ready)
for _, message in ipairs(output) do
  assert(not message:find("d=A", 1, true), "headings must never delete another pane's images")
  assert(not message:find("a=q", 1, true) and not message:find("q=0", 1, true), "never request terminal replies")
  assert(message:sub(1, 7) == "\27Ptmux;", "wrap graphics commands in tmux passthrough")
  assert(message:find("q=2", 1, true), "every chunk stays quiet even if the first chunk is dropped")
end
assert(#output == 1 and output[1]:find("q=2,m=0", 1, true), "all PNG chunks travel in a single tmux DCS")
local placements = 0
for _, message in ipairs(output) do
  if message:find("U=1", 1, true) then placements = placements + 1 end
end
assert(placements == 1)
blocked(7, "1", "copy mode")
image.delete_image(first_upload)
local old_id = first_upload
local count = #output
assert(not output[#output]:find("d=I", 1, true), "copy-mode snapshots keep their uploaded PNG until return")
inspect(client)
assert(#output > count and output[#output]:find("d=I,i=" .. old_id, 1, true))

local called = false
local schedule, queued = vim.schedule, nil
vim.schedule = function(callback)
  queued = callback
end
local upload = image.transmit_png("YWJj", function()
  called = true
end)
vim.schedule = schedule
local new_client = vim.deepcopy(client)
new_client[1] = "456"
inspect(new_client)
queued()
assert(not called, "a queued callback from a retired connection cannot complete new work")
image.delete_image(upload)
assert(tmux.status().key, "replacement client has its own transport capability")

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
table.remove(jobs, 1) { code = 0, stdout = table.concat(new_client, "\t") }
settle()
vim.wait(300, function()
  return false
end)
assert(#jobs == 0, "closing the preview stops connection polling")

local retired = assert(image.transmit_png "YWJj")
blocked(7, "1", "copy mode")
image.delete_image(retired)
assert(
  vim.wait(600, function()
    return #jobs > 0
  end),
  "pending cleanup keeps observing after the last preview closes"
)
table.remove(jobs, 1) { code = 0, stdout = table.concat(new_client, "\t") }
settle()
assert(output[#output]:find("d=I,i=" .. retired, 1, true), "returning to the owning client flushes retired PNGs")
vim.wait(300, function()
  return false
end)
assert(#jobs == 0, "flushing cleanup releases its observer")

retired = assert(image.transmit_png "YWJj")
blocked(7, "1", "copy mode")
image.delete_image(retired)
count = #output
inspect(client)
assert(#output == count, "a new client must not receive deletions owned by a different connection")

retired = assert(image.transmit_png "YWJj")
local resized = vim.deepcopy(client)
resized[9] = "14"
local old_connection = tmux.status()
local resized_connection = inspect(resized)
assert(resized_connection.key ~= old_connection.key and resized_connection.owner == old_connection.owner)
image.delete_image(retired)
assert(
  output[#output]:find("d=I,i=" .. retired, 1, true),
  "font resizing invalidates the layout without orphaning PNGs"
)
inspect(client)
upload = image.transmit_png("YWJj", function()
  error "deleted quiet upload completed"
end)
image.delete_image(upload)
settle()
local send = vim.api.nvim_ui_send
vim.api.nvim_ui_send = function()
  error "EIO: simulated terminal output failure"
end
local failed, failure = image.transmit_png "YWJj"
assert(not failed and failure:find("EIO", 1, true), "local output errors reach the caller")
vim.api.nvim_ui_send = send

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
local before_large = #output
local large_id, large_error = image.transmit_png(string.rep("YWJj", 2500))
assert(
  not large_id and large_error:find("input-buffer-size", 1, true) and #output == before_large,
  "oversized DCS never masks text or reaches the terminal"
)
vim.env.TMUX, vim.env.TERM_PROGRAM = nil, "tmux"
local output_count = #output
assert(
  not image.png_status().supported and #output == output_count,
  "missing tmux connection data must not trigger a direct probe"
)
print "Tmux PNG transport: quiet atomic uploads, owner-scoped retirement and local failures OK"
