-- Real Snacks integration; point MD_RENDER_SNACKS_PATH at an installed checkout.
local snacks_path = vim.env.MD_RENDER_SNACKS_PATH
if not snacks_path or snacks_path == "" then
  print "SKIP snacks_image_test: set MD_RENDER_SNACKS_PATH to an installed Snacks checkout"
  return
end
assert(vim.fn.filereadable(snacks_path .. "/lua/snacks/init.lua") == 1, "invalid MD_RENDER_SNACKS_PATH")
if vim.fn.executable "magick" ~= 1 and vim.fn.executable "identify" ~= 1 then
  print "SKIP snacks_image_test: ImageMagick identify is unavailable"
  return
end

local root, cache = vim.fn.getcwd(), vim.fn.tempname()
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(snacks_path)
vim.o.showtabline = 0
require("snacks").setup {
  image = { enabled = true, cache = cache, doc = { enabled = false }, math = { enabled = false } },
}
local terminal = Snacks.image.terminal
terminal._terminal, terminal._env = { terminal = "kitty" }, { supported = true, placeholders = true }
terminal.write = function() end -- Headless test: keep real placements, intercept terminal bytes.
terminal.size = function()
  return { width = 80, height = 24, columns = 80, rows = 24, cell_width = 1, cell_height = 1, scale = 1 }
end
local image = require "md-render.image"
image._set_kitty_supported(false)
image.setup { backend = "snacks" }
assert(image.supports_kitty(), "switching backends must discard native detection results")
assert(image.config().backend == "snacks", "select the optional backend")
local function wait_for(fn, message)
  assert(vim.wait(3000, fn, 5), message)
end
local buf, win, tab = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
local lines = { "        ", "        ", "        " }
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
local function drawn_rows()
  local rows = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, Snacks.image.placement.ns, 0, -1, { details = true })) do
    if mark[4].virt_text then rows[#rows + 1] = mark[2] end
  end
  table.sort(rows)
  return rows
end
local content = {
  image_placements = { { path = root .. "/tests/fixtures/test_4x4.png", line = 0, col = 0, cols = 4, rows = 3 } },
}
local backend = require "md-render.snacks_image"
local state = backend.setup(win, content)
wait_for(function()
  return vim.deep_equal(drawn_rows(), { 0, 1, 2 })
end, "initial image must occupy the three reserved rows")

-- Session rebuilds replace all rows even when an image's layout stays equal.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
backend.update(state, content)
wait_for(function()
  return vim.deep_equal(drawn_rows(), { 0, 1, 2 })
end, "same-layout rebuild left image extmarks at EOF")

-- A distinct path forces asynchronous identification while its tab is inactive.
local uncached = cache .. "/off-tab.png"
assert(vim.uv.fs_copyfile(content.image_placements[1].path, uncached))
content.image_placements[1].path = uncached
vim.cmd "tabnew"
local other_win = vim.api.nvim_get_current_win()
backend.update(state, content)
wait_for(function()
  return state.objects[1].hidden == true
end, "off-tab completion must exercise Snacks' hidden placement state")
vim.api.nvim_set_current_tabpage(tab)
wait_for(function()
  return not state.objects[1].hidden and vim.deep_equal(drawn_rows(), { 0, 1, 2 })
end, "returning to the tab must restore the completed image")

local placement = state.objects[1]
backend.cleanup(state)
assert(state.closed and placement.closed, "cleanup must retire the placement")
assert(#drawn_rows() == 0, "cleanup must remove image extmarks")
vim.api.nvim_win_close(other_win, true)
vim.fn.delete(cache, "rf")
print "Snacks image lifecycle: same-layout rebuild, off-tab completion and cleanup OK"
