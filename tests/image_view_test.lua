package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local geometry = require("md-render.image_view").geometry
local cell = { cell_w = 13, cell_h = 30 }
for _, size in ipairs { { 1502, 3420 }, { 1568, 1658 }, { 9000, 800 } } do
  for _, cols in ipairs { 118, 219 } do
    local iw, ih = unpack(size)
    local fit = geometry(iw, ih, cols, 40, cell, 1, 0.5, 0.5)
    assert(fit.x == 0 and fit.y == 0 and fit.w == iw and fit.h == ih)
    for _, zoom in ipairs { 2, 8, 16 } do
      for _, center in ipairs { -10, 0, 0.5, 1, 10 } do
        local g = geometry(iw, ih, cols, 40, cell, zoom, center, center)
        assert(g.x >= 0 and g.y >= 0 and g.x + g.w <= iw and g.y + g.h <= ih)
        assert(g.cols <= cols and g.rows <= 40 and g.w > 0 and g.h > 0)
      end
    end
  end
end
print "Image overview, zoom and pan boundaries OK"

-- Exercise the real tab/window lifecycle without invoking image converters.
require("md-render.async").run = function() end
local executable = vim.fn.executable
vim.fn.executable = function(name)
  return name == "magick" and 1 or executable(name)
end
vim.o.lines, vim.o.columns, vim.o.showtabline = 40, 120, 1
local origin = vim.api.nvim_get_current_win()
local origin_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.tbl_map(tostring, vim.fn.range(1, 100)))

-- Exercise real mappings and crop geometry without starting image processes.
do
  local image = require "md-render.image"
  local system, cell_size = vim.system, image._test_cell_size
  vim.system = function()
    return { kill = function() end }
  end
  image._test_cell_size = cell
  local navigation_keys = { "zH", "zL", "<C-d>", "<C-u>", "<C-f>", "<C-b>", "gg", "G", "0", "^", "$", "f" }
  local original_maps = {}
  for _, key in ipairs(navigation_keys) do
    original_maps[key] = vim.fn.maparg(key, "n", false, true)
  end
  local view = require("md-render.image_view").open "unused.png"
  vim.cmd "belowright new"
  local extra_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(view.win)
  local function press(key)
    vim.cmd("normal " .. vim.api.nvim_replace_termcodes(key, true, false, true))
  end
  for _, key in ipairs(navigation_keys) do
    assert(vim.fn.maparg(key, "n", false, true).buffer == 1, key .. " must be buffer-local")
    press(key) -- Loading has not produced a crop yet.
  end
  assert(not view.crop, "navigation before loading must be harmless")
  view.path, view.iw, view.ih = "unused.png", 6400, 3200
  local function center()
    view.x, view.y = 0.5, 0.5
    vim.api.nvim_exec_autocmds("WinResized", {})
  end
  for _, size in ipairs { { 20, 4 }, { 20, 8 }, { 12, 8 } } do
    vim.api.nvim_win_set_height(view.win, size[1])
    assert(vim.api.nvim_win_get_height(view.win) == size[1], "test must resize the viewport")
    view.zoom = size[2]
    center()
    local page = (view.crop.rows - 2) / view.crop.rows
    for _, move in ipairs {
      { "h", -1 / 8, 0 },
      { "l", 1 / 8, 0 },
      { "k", 0, -1 / 8 },
      { "j", 0, 1 / 8 },
      { "zH", -1 / 2, 0 },
      { "zL", 1 / 2, 0 },
      { "<C-d>", 0, 1 / 2 },
      { "<C-u>", 0, -1 / 2 },
      { "<C-f>", 0, page },
      { "<C-b>", 0, -page },
    } do
      center()
      local before = view.crop
      press(move[1])
      assert(math.abs(view.crop.x - before.x - move[2] * before.w) <= 1, move[1] .. " horizontal distance")
      assert(math.abs(view.crop.y - before.y - move[3] * before.h) <= 1, move[1] .. " vertical distance")
    end
    for _, jump in ipairs {
      { "0", "x", 0, "y" },
      { "^", "x", 0, "y" },
      { "$", "x", 1, "y" },
      { "gg", "y", 0, "x" },
      { "G", "y", 1, "x" },
    } do
      center()
      press "l"
      press "j"
      local before, zoom = view.crop, view.zoom
      press(jump[1])
      local limit = jump[2] == "x" and view.iw - view.crop.w or view.ih - view.crop.h
      assert(view.crop[jump[2]] == jump[3] * limit, jump[1] .. " must reach the image edge")
      assert(view.crop[jump[4]] == before[jump[4]], jump[1] .. " must preserve the other axis")
      assert(view.zoom == zoom, jump[1] .. " must preserve zoom")
      local at_edge = view.crop
      press(jump[1])
      assert(vim.deep_equal(at_edge, view.crop), jump[1] .. " must stay at the edge on repeat")
    end
  end
  for _, edge in ipairs { { "zH", "x", 0 }, { "zL", "x", 1 }, { "<C-b>", "y", 0 }, { "<C-f>", "y", 1 } } do
    center()
    for _ = 1, 20 do
      press(edge[1])
    end
    local limit = edge[2] == "x" and view.iw - view.crop.w or view.ih - view.crop.h
    assert(view.crop[edge[2]] == edge[3] * limit, edge[1] .. " must stop at the image edge")
  end
  vim.api.nvim_win_set_height(view.win, 4)
  center()
  assert(view.crop.rows == 2, "test must exercise a tiny viewport")
  local before = view.crop
  press "<C-f>"
  assert(math.abs(view.crop.y - before.y - before.h / before.rows) <= 1, "tiny viewport must advance one row")
  press "<C-b>"
  assert(math.abs(view.crop.y - before.y) <= 1, "tiny viewport must page back")
  press "f"
  assert(view.zoom == 1 and view.x == 0.5 and view.y == 0.5, "fit must restore the complete centered image")
  for _, key in ipairs(navigation_keys) do
    press(key)
    assert(view.crop.x == 0 and view.crop.y == 0, key .. " must preserve the overview")
    assert(view.crop.w == view.iw and view.crop.h == view.ih)
  end
  vim.api.nvim_win_close(extra_win, true)
  press "q"
  assert(vim.wait(1000, function()
    return view.closed and vim.api.nvim_get_current_win() == origin
  end, 10))
  for _, key in ipairs(navigation_keys) do
    assert(vim.deep_equal(original_maps[key], vim.fn.maparg(key, "n", false, true)), key .. " leaked into the document")
  end
  vim.system, image._test_cell_size = system, cell_size
end
print "Image navigation: page/half-page keys, edge jumps, zoom/resize, overview and buffer scope OK"

local function check_return(close, message)
  vim.api.nvim_win_set_cursor(origin, { 60, 0 })
  vim.cmd "normal! zt"
  local before = vim.fn.winsaveview()
  local view = require("md-render.image_view").open "unused.png"
  close(view)
  assert(
    vim.wait(1000, function()
      return vim.api.nvim_get_current_win() == origin and vim.deep_equal(before, vim.fn.winsaveview())
    end, 10),
    message
  )
  assert(view.closed and not vim.api.nvim_win_is_valid(view.win), "viewer must be cleaned up")
end
for _, key in ipairs { "q", "<Esc>" } do
  check_return(function()
    vim.fn.maparg(key, "n", false, true).callback()
  end, key .. " did not preserve the original viewport")
end
check_return(function()
  vim.cmd "tabclose"
end, "closing the image tab did not preserve the original viewport")

-- Do not restore the old cursor after the reader has navigated elsewhere.
vim.api.nvim_win_set_cursor(origin, { 50, 0 })
vim.cmd "normal! zt"
local view = require("md-render.image_view").open "unused.png"
vim.cmd "tabprevious"
vim.api.nvim_win_set_cursor(origin, { 70, 0 })
vim.cmd "normal! zt"
local latest = vim.api.nvim_win_get_cursor(origin)
vim.api.nvim_win_close(view.win, true)
vim.wait(20, function()
  return false
end)
assert(
  vim.deep_equal(latest, vim.api.nvim_win_get_cursor(origin)),
  "closing a background viewer restored a stale cursor"
)
-- An existing tab must not become the destination when the viewer closes.
vim.cmd "tabnew"
local other = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(origin)
for _, close in ipairs {
  function()
    vim.fn.maparg("q", "n", false, true).callback()
  end,
  function()
    vim.fn.maparg("<Esc>", "n", false, true).callback()
  end,
  function()
    vim.cmd "tabclose"
  end,
} do
  check_return(close, "closing the viewer did not return to its original window")
end

-- Revisit the document and scroll without moving the cursor, then return.
vim.api.nvim_win_set_cursor(origin, { 60, 0 })
vim.cmd "normal! zt"
view = require("md-render.image_view").open "unused.png"
vim.api.nvim_set_current_win(origin)
local cursor = vim.api.nvim_win_get_cursor(origin)
vim.cmd("normal! 8" .. vim.api.nvim_replace_termcodes("<C-y>", true, false, true))
local scrolled = vim.fn.winsaveview()
assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(origin)) and scrolled.topline ~= 60)
vim.api.nvim_set_current_win(view.win)
vim.fn.maparg("q", "n", false, true).callback()
assert(
  vim.wait(1000, function()
    return vim.api.nvim_get_current_win() == origin and vim.deep_equal(scrolled, vim.fn.winsaveview())
  end, 10),
  "returning to the document lost its latest scroll position"
)

-- Closing a background viewer must not switch away from another window.
view = require("md-render.image_view").open "unused.png"
vim.api.nvim_set_current_win(other)
vim.api.nvim_win_close(view.win, true)
vim.wait(20, function()
  return false
end)
assert(vim.api.nvim_get_current_win() == other, "background close stole focus")

-- A replaced or closed origin must leave Neovim's fallback window intact.
vim.api.nvim_set_current_win(origin)
view = require("md-render.image_view").open "unused.png"
vim.api.nvim_win_set_buf(origin, vim.api.nvim_create_buf(false, true))
vim.api.nvim_win_close(view.win, true)
vim.wait(20, function()
  return false
end)
assert(vim.api.nvim_get_current_win() == other, "return activated a different document")
vim.api.nvim_win_set_buf(origin, origin_buf)
vim.api.nvim_set_current_win(origin)
view = require("md-render.image_view").open "unused.png"
vim.api.nvim_win_close(origin, true)
vim.api.nvim_win_close(view.win, true)
vim.wait(20, function()
  return false
end)
assert(vim.api.nvim_get_current_win() == other, "return did not tolerate a closed origin")
print "Image view return: original window, latest scroll, background close and invalid origin OK"
