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
