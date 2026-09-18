-- Exercise window-driven layout without a terminal image backend or converter.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local preview = require "md-render.preview"
local image = require "md-render.image"
local display = require "md-render.display_utils"

assert(image.config().backend == "kitty", "native Kitty must remain the default backend")
image.supports_kitty = function()
  return true
end
image._test_cell_size = { cell_w = 10, cell_h = 20 }
-- Keep real content building and resize autocmds; skip only image transport.
display.setup_images = function() end
vim.o.columns, vim.o.lines = 160, 70
local path = vim.fn.tempname() .. ".svg"
vim.fn.writefile({ [[<svg width="2400" height="2400"></svg>]] }, path)

local function open(backend, opts)
  image.setup { backend = backend }
  local source = vim.api.nvim_create_buf(false, true)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "![Square](" .. path .. ")" })
  local win = vim.api.nvim_open_win(source, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 120,
    height = 50,
    style = "minimal",
  })
  preview.toggle(opts)
  return preview._toggle_sessions[source], win
end

local function check(session, cols, rows)
  local p = session.content.image_placements[1]
  assert(p and p.cols == cols and p.rows == rows, vim.inspect { expected = { cols, rows }, placement = p })
end

local function resize(session, win, width, height)
  local before = session.content
  vim.api.nvim_win_set_config(win, { width = width, height = height })
  -- Headless runs do not deliver the UI's resize event automatically.
  vim.api.nvim_exec_autocmds("WinResized", { pattern = tostring(win), modeline = false })
  assert(
    vim.wait(1000, function()
      return session.content ~= before
    end),
    "resizing should rebuild the preview"
  )
end

local function close(session, win)
  preview.toggle()
  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(session.source_bufnr, { force = true })
end

local session, win = open "kitty"
assert(session.opts.max_width == 80, "native automatic text width remains capped at 80")
check(session, 50, 25)
resize(session, win, 40, 20)
assert(session.opts.max_width == 40, "native preview still adapts to a narrow window")
check(session, 38, 19) -- Native retains its 25-row limit, rather than window height minus six.
close(session, win)

session, win = open "snacks"
assert(session.opts.max_width == 120, "Snacks uses the available window width")
check(session, 88, 44)
resize(session, win, 60, 50)
check(session, 58, 29)
resize(session, win, 60, 20)
check(session, 28, 14)
close(session, win)

session, win = open("snacks", { max_width = 100 })
assert(session.opts.max_width == 100, "explicit text width is preserved")
check(session, 88, 44)
resize(session, win, 60, 20)
assert(session.opts.max_width == 100, "resizing does not override explicit text width")
check(session, 28, 14) -- Height must still respond when max_width was explicit.
close(session, win)

vim.fn.delete(path)
print "Preview layout: native caps, Snacks width/height resize, and explicit width OK"
