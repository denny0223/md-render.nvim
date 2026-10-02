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
local stored, deleted = {}, {}
vim.api.nvim_ui_send = function(bytes)
  for sequence in bytes:gmatch "\27_G(.-)\27\\" do
    local id = tonumber(sequence:match ",i=(%d+)")
    if sequence:match "^a=t," then stored[id] = true end
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
    if text and text[1][1]:find("failed", 1, true) then return true end
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
