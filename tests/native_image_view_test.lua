-- Exercise the actual preview mappings and native window ownership, with a recording terminal.
local root = vim.fn.getcwd()
vim.opt.rtp:prepend(root)
vim.cmd "runtime plugin/md-render.lua"
local image = require "md-render.image"
local native = require "md-render.native_image_view"
local preview = require "md-render.preview"
vim.env.TMUX = nil
vim.env.PATH = "/nonexistent"
image._set_kitty_supported(true)
image._test_cell_size = { cell_w = 10, cell_h = 20 }
require("md-render.tty").kitty_version = function()
  return { 0, 48 }
end
local transmit_file = image.transmit_image_async
local next_id, live, painted = 0, {}, {}
image.transmit_image_async = function(path, callback, confirmed)
  next_id = next_id + 1
  live[next_id] = path
  local id = next_id
  local revision = image.file_revision(path)
  callback(id)
  vim.schedule(function()
    confirmed(id, nil, revision)
  end)
end
image.put_image = function(id, win, row, col, cols, rows)
  assert(live[id], "painted freed image")
  painted[win] = { id = id, row = row, col = col, cols = cols, rows = rows }
  return true
end
image.clear_placements = function(id)
  for win, placement in pairs(painted) do
    if placement.id == id then painted[win] = nil end
  end
end
image.delete_images = function(ids)
  for _, id in ipairs(ids) do
    assert(live[id], "freed image twice")
    live[id] = nil
  end
end
local function press(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
end
local function wait_for(check, message)
  assert(vim.wait(2000, check, 10), message)
end

local png = root .. "/assets/demo/test.png"
local gif = root .. "/assets/demo/test_animated.gif"
assert(not native.path({ image_ids = {} }, { path = png }), "pending PNG must stay in the document")
assert(not native.path({ image_ids = { [gif] = 1 } }, { path = gif }), "GIF must retain inline controls")
local removed = vim.fn.tempname() .. ".png"
live[1] = removed
assert(
  not native.path({ ready_images = { [removed] = { png_revision = "removed" } } }, { path = removed }),
  "removed PNG must not advertise Enter"
)
live[1] = nil
vim.env.TMUX = "test"
assert(not native.path({ ready_images = { [png] = { png_revision = image.file_revision(png) } } }, { path = png }))
vim.env.TMUX = nil
local cols, rows = image.calc_display_size(160, 120, 100, 30)
assert(cols == 16 and rows == 6, "ordinary previews retain the natural size")
cols, rows = image.calc_display_size(160, 120, 100, 30, true)
assert(cols == 80 and rows == 30, "focused view fits the available height")
cols, rows = image.calc_display_size(2000, 100, 100, 30, true)
assert(cols == 100 and rows >= 2 and rows <= 3, "wide images fit the available width")

-- The initial Kitty identity query can service a pending UIEnter heading rebuild
-- before the first visible PNG has finished uploading.
do
  vim.cmd.tabnew()
  vim.bo.filetype = "markdown"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "![First](" .. png .. ")" })
  vim.bo.modified = false
  local refreshed
  local transmit, delete = image.transmit_image_async, image.delete_image
  image.delete_image = function(id)
    live[id] = nil
  end
  image.transmit_image_async = function(path, callback, confirmed)
    image.transmit_image_async = transmit
    vim.schedule(function()
      preview.rebuild_visible()
      refreshed = true
    end)
    wait_for(function()
      return refreshed
    end, "first upload did not receive its pending UI refresh")
    transmit(path, callback, confirmed)
  end
  vim.cmd "MdRender pager"
  local session = assert(preview._sessions[vim.api.nvim_get_current_buf()])
  wait_for(function()
    return refreshed and session.image_state and session.image_state.image_ids[png]
  end, "first visible PNG did not load after the refresh")
  assert(vim.tbl_count(live) == 1, "startup refresh leaked a second image owner")
  vim.cmd.tabclose()
  assert(not next(live), "closing the startup pager left its image behind")
  image.delete_image = delete
end

local source = vim.api.nvim_get_current_buf()
vim.bo[source].filetype = "markdown"
local document = {}
for i = 1, 30 do
  vim.list_extend(document, { "Before image " .. i, "" })
end
vim.list_extend(
  document,
  { "![Demo](" .. png .. ")", "", "> [!NOTE]- Details", "> Fold body", "", "[Link](https://example.org)" }
)
vim.api.nvim_buf_set_lines(source, 0, -1, false, document)
vim.bo[source].modified = false
vim.cmd "MdRender pager"
local session = assert(preview._sessions[vim.api.nvim_get_current_buf()])
local p = assert(session.content.image_placements[1])
vim.api.nvim_win_set_cursor(session.win, { p.line, 0 })
vim.cmd "normal! zz"
vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(session.win) })
wait_for(function()
  return native.path(session.image_state, p)
end, "source image not ready")
local hint_ns = vim.api.nvim_create_namespace "md_render_image_hint"
require("md-render.image_hint").refresh()
local mark = assert(vim.api.nvim_buf_get_extmarks(session.buf, hint_ns, 0, -1, { details = true })[1])
assert(mark[2] == p.line - 1 and mark[4].virt_text[1][1]:find("Enter: open image", 1, true))
local function pager_layout()
  return { vim.o.laststatus, vim.o.cmdheight, vim.o.showtabline, vim.o.ruler, vim.o.showcmd, vim.fn.winheight(0) }
end
local original_layout = pager_layout()
local origin = vim.fn.winsaveview()
local source_id = session.image_state.image_ids[png]
for _, key in ipairs { "<CR>", "q", "<Esc>", "noautocmd close" } do
  press "<CR>"
  local win = vim.api.nvim_get_current_win()
  assert(win ~= session.win and vim.b.md_render_image_view, "Enter did not open native image tab")
  wait_for(function()
    return painted[win] and live[painted[win].id]
  end, "focused image not painted")
  local initial = painted[win]
  assert(initial.id ~= source_id and initial.rows > p.rows, "viewer must own an enlarged placement")
  assert(vim.tbl_count(live) == 2)
  if key ~= "noautocmd close" then vim.cmd.vsplit() end
  if key == "<CR>" then
    vim.api.nvim_win_set_width(win, 24)
    vim.api.nvim_exec_autocmds("WinResized", {})
    wait_for(function()
      return painted[win].cols <= 24
    end, "fitted view did not resize")
    assert(painted[win].id == initial.id, "resize retransmitted the PNG")
  end
  if key ~= "noautocmd close" then
    local duplicate = vim.api.nvim_get_current_win()
    press(key)
    assert(not vim.api.nvim_win_is_valid(duplicate) and vim.api.nvim_get_current_win() == win)
    assert(live[initial.id], "closing a copy released the image owner's upload")
  end
  if key == "noautocmd close" then
    vim.cmd "noautocmd close"
    vim.cmd.redraw()
  else
    press(key)
  end
  wait_for(function()
    return vim.api.nvim_get_current_win() == session.win and not live[initial.id]
  end, "viewer did not release its image and return to the pager")
  assert(live[source_id] == png and vim.tbl_count(live) == 1)
  wait_for(function()
    return painted[session.win] and painted[session.win].id == source_id
  end, "the original PNG was not repainted after " .. key)
  assert(vim.deep_equal(pager_layout(), original_layout), "pager lost screen rows after " .. key)
  local restored = vim.fn.winsaveview()
  assert(restored.lnum == origin.lnum and restored.col == origin.col and restored.topline == origin.topline)
end
-- Even after its owner closes in the background, a copy can still return.
press "<CR>"
local owner = vim.api.nvim_get_current_win()
vim.cmd.vsplit()
local duplicate = vim.api.nvim_get_current_win()
vim.api.nvim_win_close(owner, true)
assert(vim.api.nvim_get_current_win() == duplicate)
press "q"
assert(vim.api.nvim_get_current_win() == session.win and not vim.api.nvim_win_is_valid(duplicate))

local fold = assert(session.content.callout_folds[1])
local collapsed = fold.collapsed
vim.api.nvim_win_set_cursor(session.win, { fold.header_line + 1, 0 })
press "za"
assert(session.content.callout_folds[1].collapsed ~= collapsed)
press "<CR>"
assert(session.content.callout_folds[1].collapsed == collapsed)
assert(vim.fn.maparg("q", "n", false, true).buffer == 1)
-- Exercise real upload requests and their replies across a change of file version.
image.transmit_image_async = transmit_file
image.delete_images = function() end
image.put_image = function(id, win)
  painted[win] = { id = id }
  return true
end
local function viewer_status()
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })) do
    for _, chunk in ipairs(mark[4].virt_text or {}) do
      if chunk[1]:find("Could not load image", 1, true) then return "failed" end
    end
  end
end
for _, change in ipairs { "before Enter", "before upload", "before reply", "refused", "timeout", "unchanged" } do
  local path = vim.fn.tempname() .. ".png"
  assert(vim.uv.fs_copyfile(png, path))
  local function replace()
    local new_file = path .. ".replacement"
    assert(vim.uv.fs_copyfile(root .. "/assets/screenshot-rendering.png", new_file))
    assert(vim.uv.fs_rename(new_file, path))
  end
  local uploads = 0
  vim.api.nvim_ui_send = function(data)
    local id = data:match "\27_Ga=t,f=100,t=f,i=(%d+),q=0;"
    if not id then return end
    uploads = uploads + 1
    if uploads == 2 and change == "before reply" then replace() end
    if uploads == 2 and change == "timeout" then return end
    local reply = uploads == 2 and change == "refused" and "ENOENT" or "OK"
    vim.schedule(function()
      vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27_Gi=" .. id .. ";" .. reply } })
    end)
  end
  vim.cmd.tabnew()
  vim.bo.filetype = "markdown"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "![changing file](" .. path .. ")" })
  vim.bo.modified = false
  vim.cmd "MdRender pager"
  local doc = assert(preview._sessions[vim.api.nvim_get_current_buf()])
  local selected = doc.content.image_placements[1]
  vim.api.nvim_win_set_cursor(doc.win, { selected.line, 0 })
  wait_for(function()
    return doc:image_view_hint(selected, 1)
  end, "source upload not accepted")
  if change == "before Enter" then
    replace()
    assert(not doc:image_view_hint(selected, 1))
    press "<CR>"
    assert(vim.api.nvim_get_current_win() == doc.win and uploads == 1, "stale document opened new pixels")
  else
    if change == "before upload" then
      vim.api.nvim_create_autocmd("FileType", { pattern = "md-render-image", once = true, callback = replace })
    end
    press "<CR>"
    local viewer = vim.api.nvim_get_current_win()
    assert(viewer ~= doc.win)
    if change == "unchanged" then
      wait_for(function()
        return painted[viewer]
      end, "unchanged PNG never appeared")
    else
      wait_for(function()
        return viewer_status() == "failed"
      end, "failure was not reported")
      assert(not painted[viewer], "painted an unconfirmed PNG version")
    end
    assert(uploads == (change == "before upload" and 1 or 2), "unexpected upload count")
    press "q"
    assert(vim.api.nvim_get_current_win() == doc.win)
  end
  vim.cmd.tabclose()
  vim.fn.delete(path)
end
print "Native PNG viewer: direct ready PNG, fit/resize, scoped IDs and pager roundtrip OK"
