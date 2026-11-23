-- Drive a real native pager and image tab, controlling only the Kitty frame uploads.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd "runtime plugin/md-render.lua"
local image = require "md-render.image"
local preview = require "md-render.preview"
local native = require "md-render.native_image_view"
vim.env.TMUX, vim.env.SSH_TTY, vim.env.SSH_CONNECTION = nil, nil, nil
image._test_cell_size = { cell_w = 10, cell_h = 20 }
local probes = 0
require("md-render.tty").kitty_version = function()
  probes = probes + 1
  return { 0, 48 }
end

local missing = vim.fn.tempname()
local decoded = { frame_w = 160, frame_h = 120, frame_ids = { 10, 11 }, frame_files = { "a.png", "b.png" } }
assert(
  not native.path({ ready_images = { [missing] = { animation = decoded } } }, { path = missing }),
  "a removed source cannot be reopened"
)
assert(vim.fn.writefile({ "fixture" }, missing) == 0)
vim.env.SSH_TTY = "/dev/pts/1"
assert(
  not native.path({ ready_images = { [missing] = { animation = decoded } } }, { path = missing }),
  "remote files are not local to Kitty"
)
vim.env.SSH_TTY = nil
decoded.frame_ids = { 10 }
assert(
  not native.path({ ready_images = { [missing] = { animation = decoded } } }, { path = missing }),
  "a single frame offers no playback"
)
vim.fn.delete(missing)
assert(probes == 0, "unavailable media triggered a terminal probe")

local uploads, frames, painted, next_id = {}, {}, {}, 0
local uploaded_sources = {}
image.transmit_animated_async = function(source, callback, owner, on_response)
  uploaded_sources[owner] = source
  assert(owner)
  table.insert(uploads, function(failure)
    if failure == "decode" then return callback(nil) end
    local ids = {}
    for i = 1, 3 do
      next_id = next_id + 1
      frames[next_id] = owner
      ids[i] = next_id
    end
    local files = type(source) == "table" and source or { "a.png", "b.png", "c.png" }
    callback(ids, nil, 160, 120, files)
    vim.schedule(function()
      on_response(ids[1], failure)
    end)
    return ids
  end)
end
image.put_image = function(id, win)
  assert(frames[id], "a retired frame was painted")
  painted[win] = id
  return true
end
image.clear_placements = function() end
image.delete_images = function(ids)
  for _, id in ipairs(ids) do
    assert(frames[id], "frame released twice")
    frames[id] = nil
  end
end
local function press(key)
  vim.api.nvim_feedkeys(vim.keycode(key), "x", false)
end
local function wait_for(predicate, message)
  assert(vim.wait(2000, predicate, 5), message)
end
local function finish_upload()
  wait_for(function()
    return #uploads > 0
  end, "no frame upload")
  return table.remove(uploads, 1)()
end
local function header(win)
  win = win or vim.api.nvim_get_current_win()
  vim.cmd.redraw()
  local pos = vim.fn.screenpos(win, 1, 1)
  local chars = {}
  for col = pos.col, pos.col + vim.api.nvim_win_get_width(win) - 1 do
    chars[#chars + 1] = vim.fn.screenstring(pos.row, col)
  end
  return table.concat(chars)
end

local function roundtrip(asset, autoplay)
  image.setup { backend = "kitty", autoplay = autoplay }
  image._set_kitty_supported(true)
  vim.cmd.enew()
  vim.bo.filetype = "markdown"
  local path = vim.fn.getcwd() .. "/assets/demo/" .. asset
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "# Media", "", "![demo](" .. path .. ")" })
  vim.bo.modified = false
  vim.cmd "MdRender tab"
  local session = assert(preview._sessions[vim.api.nvim_get_current_buf()])
  local p = session.content.image_placements[1]
  vim.api.nvim_win_set_cursor(session.win, { p.line, 0 })
  assert(not session:image_view_hint(p, 1))
  local source_frames = finish_upload()
  wait_for(function()
    return session:image_view_hint(p, 1) ~= nil and painted[session.win]
  end, "no hint for decoded source")
  local origin = vim.fn.winsaveview()
  if not autoplay or asset == "test.mp4" then
    press "<CR>"
    wait_for(function()
      return #uploads == 1
    end, "failure case did not upload")
    table.remove(uploads, 1)(asset == "test.mp4" and "ENOENT" or "decode")
    wait_for(function()
      return header():find("Could not load", 1, true)
    end, "late failure was not reported")
    press "<Space>"
    assert(header():find("Could not load", 1, true))
    press "<Esc>"
    wait_for(function()
      return vim.api.nvim_get_current_win() == session.win
    end, "cannot return from failed upload")
  end

  -- Cancel A in its initial upload, then open B from the same occurrence.
  press "<CR>"
  local a = vim.api.nvim_get_current_win()
  wait_for(function()
    return #uploads == 1
  end, "viewer did not request its own frames")
  assert(a ~= session.win and header():find("Loading", 1, true))
  vim.cmd "vsplit"
  vim.api.nvim_win_set_width(a, 24)
  vim.api.nvim_exec_autocmds("WinResized", {})
  vim.cmd.close()
  vim.wait(70)
  assert(#uploads == 1, "resizing while loading retransmitted the animation")
  press "<Space>"
  assert(header():find("Loading", 1, true))
  press "<CR>"
  wait_for(function()
    return vim.api.nvim_get_current_win() == session.win
  end, "Enter did not cancel the waiting viewer")
  local deliver_a = table.remove(uploads, 1)
  press "<CR>"
  local b = vim.api.nvim_get_current_win()
  local late_ids = deliver_a()
  local own = finish_upload()
  for _, id in ipairs(late_ids) do
    assert(not frames[id], "late upload leaked")
  end
  assert(frames[own[1]] ~= frames[source_frames[1]], "viewer borrowed source frame ownership")
  assert(
    uploaded_sources[frames[own[1]]] == session.image_state.anims[path].frame_files,
    "viewer reopened the source path"
  )
  wait_for(function()
    return header():find(autoplay and "Space pause" or "Space play", 1, true) and painted[b]
  end, "no playable media in viewer")
  local hidden_source = session.image_state.anims[path].current
  if not autoplay then
    vim.wait(450)
    assert(painted[b] == own[1], "autoplay=false advanced the first frame")
    press "<Space>"
  end
  wait_for(function()
    return painted[b] ~= own[1]
  end, "could not play")
  press "<Space>"
  local paused = painted[b]
  assert(header():find("Space play", 1, true))
  vim.cmd "vsplit"
  local duplicate = vim.api.nvim_get_current_win()
  assert(header(duplicate):find("back", 1, true) and not header(duplicate):find("Space", 1, true))
  assert(header(b):find("Space play", 1, true), "the owner lost its playback control")
  press "<Space>"
  vim.wait(450)
  assert(painted[b] == paused and not painted[duplicate], "the duplicate changed the owner's playback")
  vim.api.nvim_win_set_width(b, 24)
  vim.api.nvim_exec_autocmds("WinResized", {})
  vim.cmd.close()
  vim.cmd.tabnew()
  vim.wait(450)
  vim.cmd.tabclose()
  vim.wait(450)
  assert(painted[b] == paused and #uploads == 0, "paused resize or tab switch reset the frame")
  assert(session.image_state.anims[path].current == hidden_source, "viewer changed hidden source playback")
  press "<Space>"
  wait_for(function()
    return painted[b] ~= paused
  end, "could not resume")
  if autoplay and asset == "test_animated.gif" then
    vim.cmd "noautocmd close"
    vim.cmd.redraw()
  else
    press "q"
  end
  wait_for(function()
    return vim.api.nvim_get_current_win() == session.win and not frames[own[1]]
  end, "viewer did not release its frames")
  for _, id in ipairs(source_frames) do
    assert(frames[id], "viewer deleted the source frames")
  end
  local returned = vim.fn.winsaveview()
  assert(returned.lnum == origin.lnum and returned.col == origin.col and returned.topline == origin.topline)
  if autoplay then
    wait_for(function()
      return session.image_state.anims[path].current ~= hidden_source
    end, "inline animation did not resume")
  else
    vim.wait(450)
    assert(session.image_state.anims[path].current == 1, "manual playback enabled autoplay in the document")
  end
  if asset == "test.mp4" and not autoplay then
    press "<CR>"
    local view_win = vim.api.nvim_get_current_win()
    local remaining = finish_upload()
    wait_for(function()
      return painted[view_win] == remaining[1]
    end, "new viewer not painted")
    vim.api.nvim_set_current_win(session.win)
    press "<CR>"
    local second = vim.api.nvim_get_current_win()
    local second_frames = finish_upload()
    wait_for(function()
      return painted[second] == second_frames[1]
    end, "second viewer did not start paused")
    press "<Space>"
    wait_for(function()
      return painted[second] ~= second_frames[1]
    end, "second viewer did not play independently")
    vim.cmd.vsplit()
    vim.api.nvim_win_close(second, true)
    press "<Space>"
    assert(not header():find("Space", 1, true) and not frames[second_frames[1]], "closed viewer kept playback")
    vim.cmd.close()
    vim.api.nvim_set_current_win(view_win)
    assert(header():find("Space play", 1, true) and painted[view_win] == remaining[1], "first viewer lost its pause")

    vim.api.nvim_win_close(session.win, true)
    wait_for(function()
      return not frames[source_frames[1]]
    end, "closing the document did not free its own frames")
    press "<Space>"
    wait_for(function()
      return painted[view_win] ~= remaining[1]
    end, "closing the source stopped the viewer")
    press "q"
  else
    vim.cmd.tabclose()
  end
  wait_for(function()
    return vim.tbl_isempty(frames)
  end, "source or viewer close leaked frames")
end

for _, asset in ipairs { "test_animated.gif", "test.mp4" } do
  for _, autoplay in ipairs { false, true } do
    roundtrip(asset, autoplay)
  end
end
print "Native GIF/video viewer: independent playback, late uploads, resize, return and frame ownership passed"
