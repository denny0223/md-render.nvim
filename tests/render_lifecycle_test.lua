-- Exercise real async ownership while controlling conversion completion and terminal output.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local image = require "md-render.image"
local display = require "md-render.display_utils"
local png = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"
local gif = vim.fn.getcwd() .. "/assets/demo/test_animated.gif"
vim.env.TMUX, vim.env.TMUX_PANE, vim.env.TERM_PROGRAM = nil, nil, "kitty"
vim.o.showtabline = 0
image.setup { backend = "kitty", autoplay = true }
image._set_kitty_supported(true)
image._test_cell_size = { cell_w = 8, cell_h = 16 }
local stored, deleted, visible, present = {}, {}, {}, {}
local confirmed_uploads = {}
local wakes = 0
vim.api.nvim_ui_send = function(bytes)
  if bytes == "\0" then wakes = wakes + 1 end
  for sequence in bytes:gmatch "\27_G(.-)\27\\" do
    local id = tonumber(sequence:match ",i=(%d+)")
    if sequence:match "^a=t," then
      stored[id] = true
      confirmed_uploads[id] = sequence:find(",q=0;", 1, true) ~= nil
    end
    if sequence:match "^a=p," and not sequence:find(",U=1", 1, true) then visible[id] = (visible[id] or 0) + 1 end
    if sequence:match "^a=p," and sequence:find(",p=2,q=0", 1, true) then present[id] = (present[id] or 0) + 1 end
    if sequence:match "^a=d,d=[iI]," then visible[id] = nil end
    if sequence:match "^a=d,d=I," then
      stored[id], deleted[id] = nil, true
    end
  end
end
local ns = vim.api.nvim_create_namespace "render_lifecycle_test"
local function wait_for(done, message)
  assert(vim.wait(2000, done, 5), message)
end
local function content(path, line)
  return { image_placements = { { path = path, line = line or 0, col = 0, cols = 5, rows = 1 } } }
end
local function placeholder(buf, line)
  vim.api.nvim_buf_set_lines(buf, line, line + 1, false, { "Loading NEW" })
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns, line, 0, { end_col = 11, hl_group = "MdRenderImagePlaceholder" })
  vim.bo[buf].modified = false
end
local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn["repeat"]({ "" }, 450))

for _, animated in ipairs { false, true } do
  local method = animated and "extract_frames_async" or "ensure_png_async"
  local original, pending = image[method], {}
  image[method] = function(_, callback)
    pending[#pending + 1] = callback
  end
  local path = animated and gif or png
  local state = display.setup_images(win, content(path), ns)
  wait_for(function()
    return #pending == 1
  end, "old conversion did not start")
  -- The same GIF in a new revision must not share old terminal IDs.
  placeholder(buf, 0)
  display.update_images(state, win, content(path, 1), ns)
  wait_for(function()
    return #pending == 2
  end, "new conversion did not start")
  local before = vim.tbl_count(deleted)
  pending[1](animated and { png, png } or png, false)
  wait_for(function()
    return vim.tbl_count(deleted) > before
  end, "obsolete IDs were not released")
  assert(
    next(stored) == nil and next(state.image_ids) == nil and next(state.anims) == nil,
    "old result acquired ownership"
  )
  assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == "Loading NEW", "old completion changed new content")
  assert(not vim.bo[buf].modified, "obsolete completion marked the buffer modified")
  pending[2](animated and { png, png } or png, false)
  wait_for(function()
    return next(stored) ~= nil
  end, "current conversion did not finish")
  assert(vim.tbl_count(stored) == (animated and 2 or 1), "current revision lost its terminal IDs")
  display.cleanup_images(state)
  assert(next(stored) == nil, "cleanup left terminal IDs behind")
  image[method] = original
end

-- Reusing the window for a different buffer also retires conversion output.
local ensure_png, pending = image.ensure_png_async, nil
image.ensure_png_async = function(_, callback)
  pending = callback
end
local state = display.setup_images(win, content(png), ns)
wait_for(function()
  return pending ~= nil
end, "conversion did not start")
local other = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(other, 0, -1, false, { "Other buffer" })
vim.api.nvim_win_set_buf(win, other)
local before = vim.tbl_count(deleted)
pending(png, false)
wait_for(function()
  return vim.tbl_count(deleted) > before
end, "wrong-window result retained an ID")
assert(vim.api.nvim_buf_get_lines(other, 0, -1, false)[1] == "Other buffer", "late result changed another buffer")
display.cleanup_images(state)
vim.api.nvim_win_set_buf(win, buf)
vim.api.nvim_buf_delete(other, { force = true })

-- Rebuilds preserve the initial viewport limit, including not-yet-produced diagrams.
local renders, render = 0, image.render_mermaid_async
image.render_mermaid_async = function()
  renders = renders + 1
end
pending = nil
state = display.setup_images(win, content(png), ns)
wait_for(function()
  return pending ~= nil
end, "visible image did not start")
local distant = {
  image_placements = {
    { path = png, line = 400, col = 0, cols = 5, rows = 1 },
    { mermaid_source = "graph LR\nA-->B", line = 402, col = 0, cols = 5, rows = 1 },
  },
}
display.update_images(state, win, distant, ns)
pending(png, false)
vim.wait(100, function()
  return false
end, 5)
assert(renders == 0 and next(state.image_ids) == nil, "rebuild loaded an offscreen image")
vim.fn.winrestview { topline = 395, lnum = 395 }
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(win), modeline = false })
wait_for(function()
  return renders == 1
end, "scroll did not start the deferred diagram")
display.cleanup_images(state)
image.render_mermaid_async, image.ensure_png_async = render, ensure_png
vim.fn.winrestview { topline = 1, lnum = 1 }

-- Starting with no images must retain rebuild callbacks and the highlight namespace.
local download, ready = image.download_async, 0
image.download_async = function(_, callback)
  callback(png)
end
state = display.update_images(
  nil,
  win,
  {
    image_placements = {
      { src_url = "https://example.invalid/image.png", line = 0, col = 0, cols = 5, rows = 1 },
    },
  },
  ns,
  {
    buf = buf,
    on_ready = function()
      ready = ready + 1
    end,
  }
)
wait_for(function()
  return ready == 1
end, "nil-state update lost on_ready")
display.cleanup_images(state)
image.download_async = download

-- A failed conversion replaces indefinite Loading feedback and remains unmodified.
image.ensure_png_async = function(_, callback)
  callback(nil)
end
placeholder(buf, 0)
state = display.update_images(nil, win, content(png), ns, { buf = buf })
wait_for(function()
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local text = mark[4].virt_text
    if text and text[1][2] == "ErrorMsg" then return true end
  end
end, "failed conversion left Loading feedback")
assert(not vim.bo[buf].modified, "error feedback marked the buffer modified")
local previous = state.redraw_timer
state.schedule_redraw()
assert(not previous or previous:is_closing(), "replacing redraw timer leaked its handle")
local timer = state.redraw_timer
display.cleanup_images(state)
assert(timer:is_closing(), "cleanup stopped but did not close its timer")
image.ensure_png_async = ensure_png

-- Two occurrences of a PNG disappear together when their tab is hidden.
-- Returning reuses the original upload, even after displaying a different one.
local tty = require "md-render.tty"
local version = tty.kitty_version
tty.kitty_version = function()
  return { 0, 48 }
end
local function placement_reply(id, status)
  vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=" .. id .. ",p=2;" .. status } })
end
local function upload_reply(id, status)
  vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=" .. id .. ";" .. status } })
end
local repeated = content(png)
table.insert(repeated.image_placements, vim.tbl_extend("force", repeated.image_placements[1], { line = 1 }))
-- The offscreen occurrence shares the upload but cannot request a presentation.
table.insert(repeated.image_placements, 1, vim.tbl_extend("force", repeated.image_placements[1], { line = 400 }))
state = display.setup_images(win, repeated, ns)
wait_for(function()
  return state.image_ids[png] and visible[state.image_ids[png]] == 2
end, "both occurrences were not placed")
local source_id = state.image_ids[png]
assert(confirmed_uploads[source_id] and not state.ready_images[png], "allocating a file ID is not acceptance")
upload_reply(source_id, "ENOENT: file is unreadable from Kitty")
upload_reply(source_id, "OK")
assert(present[source_id] == 1 and wakes == 0, "only the first visible occurrence requests a reply")
placement_reply(source_id, "ENOENT")
placement_reply(source_id + 999, "OK")
assert(wakes == 0, "error or unrelated reply woke the terminal")
state.schedule_redraw()
vim.wait(100)
assert(present[source_id] == 1, "ordinary redraw requested another acknowledgement")
vim.cmd "tabnew"
assert(stored[source_id] and not visible[source_id], "hidden tab left placements or discarded its upload")
local other_state = display.setup_images(vim.api.nvim_get_current_win(), content(png), ns)
wait_for(function()
  return other_state.image_ids[png] and visible[other_state.image_ids[png]]
end, "second tab did not paint")
local other_id = other_state.image_ids[png]
-- A stationary mouse can be over the image while a neighboring split has focus.
vim.cmd "vnew"
local hints = require "md-render.image_hint"
local schedule, notified = hints.schedule, false
hints.schedule = function()
  notified = true
end
upload_reply(other_id, "OK")
wait_for(function()
  return other_state.ready_images[png]
end, "accepted PNG did not become actionable")
hints.schedule = schedule
assert(notified, "accepting the PNG did not refresh the inactive window's hover")
vim.cmd.close()
assert(not state.ready_images[png], "late or unrelated reply enabled the rejected file")
assert(source_id ~= other_id and not visible[source_id], "second tab reused the first tab's placement")
vim.cmd "tabprevious"
wait_for(function()
  return visible[source_id] == 2
end, "return did not restore both original placements")
assert(stored[other_id] and not visible[other_id], "return did not hide only the second tab's image")
assert(present[source_id] == 2 and present[other_id] == 1, "each tab entry requests its own acknowledgement")
placement_reply(source_id, "OK")
assert(wakes == 1, "visible placement was accepted without waking the terminal")
display.cleanup_images(other_state)
placement_reply(other_id, "OK")
assert(wakes == 1, "reply for a retired upload woke the terminal")
tty.kitty_version = version
vim.cmd "tabclose 2"
display.cleanup_images(state)

-- Native animation pauses in a hidden tab, resumes on return, and honors autoplay.
local extract = image.extract_frames_async
image.extract_frames_async = function(_, callback)
  callback { png, png }
end
state = display.setup_images(win, content(gif), ns)
wait_for(function()
  return state.anims[gif] and state.anim_timer:is_active()
end, "animation did not start")
vim.cmd "tabnew"
assert(not state.anim_timer:is_active(), "hidden animation timer kept running")
vim.cmd "tabclose"
wait_for(function()
  return state.anim_timer:is_active()
end, "animation did not resume on return")
display.cleanup_images(state)
image.setup { autoplay = false }
state = display.setup_images(win, content(gif), ns)
wait_for(function()
  return state.anims[gif] ~= nil
end, "paused animation did not load its first frame")
assert(state.anims[gif].current == 1 and not state.anim_timer:is_active(), "autoplay=false started animation")
display.cleanup_images(state)
image.extract_frames_async = extract
image.setup { autoplay = true }
print "Render lifecycle: obsolete IDs, window ownership, lazy rebuild, failure, timers, tabs and autoplay OK"
