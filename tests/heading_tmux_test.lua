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
    cmd[1] == "tmux"
      and cmd[2] == "-S"
      and cmd[3] == "/private/test"
      and cmd[4] == "display-message"
      and cmd[5] == "-p"
      and cmd[6] == "-t"
      and cmd[7] == "%2"
      and cmd[8] == "#{pane_id}\t#{pane_in_mode}\t#{allow-passthrough}\t#{window_width}\t#{window_height}" .. "\t#{input-buffer-size}\t#{window_id}"
      and cmd[9] == ";"
      and cmd[10] == "list-clients"
      and cmd[11] == "-F"
      and cmd[12] == "#{client_pid}\t#{client_created}\t#{client_termtype}\t#{client_flags}\t#{client_cell_width}" .. "\t#{client_cell_height}\t#{client_termfeatures}\t#{client_width}\t#{client_height}\t#{status}" .. "\t#{W:#{window_id}:}"
      and #cmd == 12,
    "inspect the owning pane independently of keyboard focus"
  )
  jobs[#jobs + 1] = callback
  return { kill = function() end }
end
local tmux = require "md-render.heading_tmux"
local image = require "md-render.image"
local size = require "md-render.text_size"
local native_supported, native_checks = false, 0
size.supports = function()
  native_checks = native_checks + 1
  return native_supported
end
assert(size.resolve_backend() == "plain" and #output == 0 and #jobs == 1, "auto waits for connection inspection")
native_supported = true
assert(size.resolve_backend() == "plain" and native_checks == 0, "pending inspection must not activate native")
local client = {
  "%2",
  "0",
  "all",
  "120",
  "53",
  "1048576",
  "@2",
  "123",
  "1000",
  "kitty(0.48.2)",
  "attached,focused,UTF-8",
  "13",
  "30",
  "RGB,clipboard,hyperlinks",
  "120",
  "55",
  "2",
  "@2:",
}
local function snapshot(values)
  return table.concat(values, "\t", 1, 7) .. "\n" .. table.concat(values, "\t", 8) .. "\n"
end
local function settle()
  vim.wait(20, function()
    return false
  end)
end
local function inspect(values, extra)
  vim.api.nvim_exec_autocmds("FocusGained", {})
  local callback = assert(table.remove(jobs, 1))
  callback { code = 0, stdout = snapshot(values) .. (extra or "") }
  settle()
  return tmux.status()
end
assert(not tmux.status().key and #jobs == 1)
tmux.status()
assert(#jobs == 1, "coalesce connection checks")
assert(inspect(client).key)
assert(size.resolve_backend() == "image" and native_checks == 0, "auto selects a verified quiet connection")
assert(vim.deep_equal(image.get_cell_size(true), { cell_w = 13, cell_h = 30 }))
local function blocked(index, value, reason)
  local values = vim.deepcopy(client)
  values[index] = value
  local status = inspect(values)
  assert(not status.key and status.reason:find(reason, 1, true), vim.inspect(status))
  local count = #output
  assert(image.png_status().supported == false and #output == count, "unsupported connections send no query")
  native_supported = true
  assert(size.resolve_backend() == "native", "auto falls back through independent native support")
  native_supported = false
  assert(size.resolve_backend() == "plain", "auto keeps ordinary text when neither backend is supported")
end
blocked(1, "%1", "pane information")
blocked(2, "1", "copy mode")
blocked(3, "off", "passthrough")
blocked(3, "on", "passthrough")
blocked(10, "tmux 3.7c", "Kitty")
blocked(10, "kitty(0.27.0)", "Kitty")
blocked(11, "attached,active-pane", "topology")
blocked(12, "0", "dimensions")
blocked(14, "256", "RGB")
blocked(14, "RGB", "hyperlinks")
blocked(4, "180", "viewport")
blocked(5, "54", "viewport")
blocked(6, "", "buffer limit")
blocked(18, "@20:", "no attached")
assert(not inspect(client, table.concat(client, "\t", 8) .. "\n").key, "multiple clients retain ordinary text")
local linked = vim.deepcopy(client)
linked[18] = "@20:@2:@3:"
assert(inspect(linked).key, "a linked window is valid in the attached client's session")
inspect(client)
output = {}
local probe = image.png_status()
assert(probe.supported and #output == 0, "capability inspection never sends a terminal probe")
assert(size.status():find("not acknowledged", 1, true))
require("md-render.tty").kitty_version = function()
  error "tmux uploads must not send identity queries"
end
image.supports_kitty = function()
  error "tmux headings must not depend on the ordinary image backend"
end

local content = {
  lines = { "Body", "共同研究", "" },
  text_placements = {
    {
      line = 1,
      col = 0,
      text = "共同研究",
      scale = 2,
      raster = { data = string.rep("YWJj", 1500), cols = 10, width = 130, height = 60 },
    },
  },
}
vim.api.nvim_buf_set_lines(0, 0, -1, false, content.lines)
vim.fn.screenpos = function(_, row, col)
  return { row = row, col = col }
end
local headings = require "md-render.heading_image"
local state = assert(headings.attach(0, content))
assert(state.drawn == 0 and not state.masked, "queue the upload before displaying placeholders")
assert(
  output[1]:find("a=T", 1, true) and output[1]:find("U=1,p=1,c=10,r=2", 1, true),
  "upload and retain the correctly sized PNG as one atomic Kitty operation"
)
settle()
local entry = state.entries[1]
for _, message in ipairs(output) do
  assert(not message:find("d=A", 1, true), "headings must never delete another pane's images")
  assert(not message:find("a=q", 1, true) and not message:find("q=0", 1, true), "never request terminal replies")
  assert(message:sub(1, 7) == "\27Ptmux;", "wrap graphics commands in tmux passthrough")
  assert(message:find("q=2", 1, true), "every chunk stays quiet even if the first chunk is dropped")
end
assert(state.drawn == 1 and state.masked)
local connection, before_focus = tmux.status().key, #output
vim.api.nvim_exec_autocmds("FocusLost", {})
assert(inspect(client).key == connection and #output == before_focus, "focus changes preserve the connection")
assert(state.drawn == 1 and state.masked, "focus changes preserve image masks")
assert(#output == 1 and output[1]:find("q=2,m=0", 1, true), "all PNG chunks travel in a single tmux DCS")
local marks = vim.api.nvim_buf_get_extmarks(0, state.mask_ns, 0, -1, { details = true })
assert(#marks == 2 and marks[1][4].virt_text[1][1]:find(vim.fn.nr2char(0x10EEEE), 1, true))
assert(vim.api.nvim_get_hl(0, { name = entry.hl }).fg == entry.id)
assert(
  vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), content.lines),
  "placeholders never enter searchable or yankable text"
)
local placements = 0
for _, message in ipairs(output) do
  if message:find("U=1", 1, true) then placements = placements + 1 end
end
assert(placements == 1)
local count = #output
vim.api.nvim_exec_autocmds("User", { pattern = require("md-render.display_utils").REPAINT_EVENT })
settle()
assert(#output == count, "tmux redraw reuses the virtual placement")

blocked(2, "1", "copy mode")
assert(state.drawn == 0 and not state.masked, "connection changes immediately remove masks")
headings.detach(state)
local old_id = entry.id
count = #output
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
new_client[8] = "456"
inspect(new_client)
queued()
assert(not called, "a queued callback from a retired connection cannot complete new work")
image.delete_image(upload)
assert(image.png_status().supported, "the new supported client also uses inspection without ACKs")

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
table.remove(jobs, 1) { code = 0, stdout = snapshot(new_client) }
settle()
vim.wait(300, function()
  return false
end)
assert(#jobs == 0, "closing the preview stops connection polling")

-- Idle polling checks can expire the cache; answer the connection mock before
-- starting the next upload rather than relying on the runner's elapsed time.
assert(inspect(new_client).key, "complete the owning-client inspection after the polling idle period")
local retired = assert(image.transmit_png "YWJj")
blocked(2, "1", "copy mode")
image.delete_image(retired)
assert(
  vim.wait(600, function()
    return #jobs > 0
  end),
  "pending cleanup keeps observing after the last preview closes"
)
table.remove(jobs, 1) { code = 0, stdout = snapshot(new_client) }
settle()
assert(output[#output]:find("d=I,i=" .. retired, 1, true), "returning to the owning client flushes retired PNGs")
vim.wait(300, function()
  return false
end)
assert(#jobs == 0, "flushing cleanup releases its observer")

assert(inspect(new_client).key, "complete the owning-client inspection after the cleanup idle period")
retired = assert(image.transmit_png "YWJj")
blocked(2, "1", "copy mode")
image.delete_image(retired)
count = #output
inspect(client)
assert(#output == count, "a new client must not receive deletions owned by a different connection")

retired = assert(image.transmit_png "YWJj")
local resized = vim.deepcopy(client)
resized[12] = "14"
local old_connection = tmux.status()
local resized_connection = inspect(resized)
assert(resized_connection.key ~= old_connection.key and resized_connection.owner == old_connection.owner)
image.delete_image(retired)
assert(
  output[#output]:find("d=I,i=" .. retired, 1, true),
  "font resizing invalidates the layout without orphaning PNGs"
)
-- The three smaller heading levels occupy one row; do not mask following text.
inspect(client)
content.link_metadata = { { line = 1, col_start = 0, col_end = 6, url = "https://example.invalid/first" } }
content.text_placements[1].raster.columns = { 0, 0, 0, 3, false, 6, 6, 9, 9, false }
state = assert(headings.attach(0, content))
settle()
entry = state.entries[1]
assert(entry.links[1]:find(vim.fn.nr2char(0x0305) .. vim.fn.nr2char(0x0305), 1, true))
assert(
  entry.links[2]:find(vim.fn.nr2char(0x030D) .. vim.fn.nr2char(0x0305), 1, true),
  "linked rows encode distinct image origins"
)
assert(output[#output]:sub(1, 8) == "\27[?2026h", "link cells redraw in a pane-local synchronized batch")
headings.detach(state)

content.text_placements[1].scale = 1
content.text_placements[1].raster.height = 30
state = assert(headings.attach(0, content))
settle()
marks = vim.api.nvim_buf_get_extmarks(0, state.mask_ns, 0, -1, {})
assert(#marks == 1 and marks[1][2] == 1, "one-row headings leave the following row intact")
headings.detach(state)

upload = image.transmit_png("YWJj", function()
  error "deleted quiet upload completed"
end)
image.delete_image(upload)
settle()
local send = vim.api.nvim_ui_send
for _, command in ipairs { "a=T", "]8" } do
  vim.api.nvim_ui_send = function(data)
    if data:find(command, 1, true) then error "EIO: simulated terminal output failure" end
    send(data)
  end
  state = assert(headings.attach(0, content))
  settle()
  assert(state.failed and not state.masked and state.drawn == 0, "failed output must not hide text")
  assert(size.resolve_backend() == "plain" and size.status():find("EIO", 1, true))
  headings.detach(state)
  size.retry_image()
end
vim.api.nvim_ui_send = send
assert(size.resolve_backend() == "image", "explicit retry recovers without probes")

local system = vim.system
vim.system = function()
  error "EAGAIN: simulated tmux spawn failure"
end
vim.api.nvim_exec_autocmds("FocusGained", {})
assert(not tmux.status().key and tmux.status().reason:find("EAGAIN", 1, true))
assert(size.resolve_backend() == "plain", "process failures keep text without wedging inspection")
vim.system = system
assert(inspect(client).key, "inspection can recover from a local spawn failure")
size.retry_image()
assert(size.resolve_backend() == "image", "explicit retry recovers without probes")
local small_buffer = vim.deepcopy(client)
small_buffer[6] = "10000"
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
print "Tmux headings: auto selection, quiet transport, connection gates, placeholder ownership and retirement OK"
