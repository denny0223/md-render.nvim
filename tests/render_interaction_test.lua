-- Real window geometry, buffer mappings and extmarks; capture only terminal writes.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local display = require "md-render.display_utils"
local size = require "md-render.text_size"
local preview = require "md-render.preview"
vim.env.TMUX, vim.env.TMUX_PANE, vim.env.TERM_PROGRAM = nil, nil, nil
vim.o.termguicolors = true
size.setup { backend = "native" }
size.supports = function()
  return true
end
require("md-render").setup_highlights()
local content = preview.build_content({ "Body", "", "# Heading", "", "After" }, { max_width = 50, indent = "" })
local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
local writes = {}
vim.api.nvim_ui_send = function(bytes)
  writes[#writes + 1] = bytes
end
local state = size.attach(win, content)
vim.cmd "redraw"
size.paint(state)
local heading = assert(state.drawn[1], "native heading did not paint")
local floating = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(floating, 0, -1, false, { "FLOAT CONTENT", "SECOND ROW" })
local float = vim.api.nvim_open_win(floating, false, {
  relative = "editor",
  row = heading.row - 1,
  col = heading.col - 1,
  width = 30,
  height = 2,
  style = "minimal",
  border = "none",
})
vim.cmd "redraw"
writes = {}
size.paint(state)
assert(#state.drawn == 0, "covered heading remained drawable")
assert(not table.concat(writes):find("\27]66;", 1, true), "heading wrote OSC 66 over a float")
vim.api.nvim_win_close(float, true)
vim.cmd "redraw"
size.paint(state)
assert(#state.drawn == 1, "heading did not recover after float closed")
local timer = state.redraw_timer
size.detach(state)
assert(not timer or timer:is_closing(), "heading teardown leaked its redraw timer")

size.setup { enabled = false }
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "中文", "note", "top", "Heading", "Footnote" })
local ns = vim.api.nvim_create_namespace "render_interaction_test"
local current = { heading_anchors = { ["中文"] = 3 }, footnote_anchors = { ["fn:1"] = 4 } }
for row, url in ipairs { "#%E4%B8%AD%E6%96%87", "#fn%3A1", "#" } do
  vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { end_col = row == 1 and 6 or row == 2 and 4 or 3, url = url })
end
local opts = {
  get_content = function()
    return current
  end,
}
local rebind = display.setup_float_keymaps(buf, ns, win, current, nil, opts)
local function mapped(key)
  return vim.fn.maparg(key, "n", false, true)
end
for row, target in ipairs { 4, 5, 1 } do
  vim.api.nvim_win_set_cursor(win, { row, 0 })
  mapped("<CR>").callback()
  assert(vim.api.nvim_win_get_cursor(win)[1] == target, "Enter did not activate decoded anchor " .. row)
end
local getmousepos = display.getmousepos
display.getmousepos = function()
  return { winid = win, line = 1, column = 1 }, false
end
mapped("<LeftRelease>").callback()
assert(vim.api.nvim_win_get_cursor(win)[1] == 4, "mouse and keyboard anchor destinations diverged")
display.getmousepos = getmousepos

-- Rebinding must update context without recreating deleted/replaced user maps.
local custom = function() end
vim.keymap.set("n", "<CR>", custom, { buffer = buf })
vim.keymap.del("n", "za", { buffer = buf })
vim.keymap.set("n", "q", custom, { buffer = buf })
rebind(win, nil, { close_keys = {}, get_content = opts.get_content })
assert(vim.tbl_isempty(mapped "<Esc>"), "toggle context retained plugin close maps")
rebind(win, nil, opts)
assert(mapped("<CR>").callback == custom and mapped("q").callback == custom, "rebind overwrote a user mapping")
assert(vim.tbl_isempty(mapped "za"), "rebind recreated a user-deleted map")
assert(type(mapped("<Esc>").callback) == "function", "float context did not restore its own close map")
vim.keymap.del("n", "<Esc>", { buffer = buf })
rebind(win, nil, opts)
assert(vim.tbl_isempty(mapped "<Esc>"), "rebind recreated a user-deleted close map")
print "Render interaction: float occlusion, recovery, decoded keyboard/mouse anchors and user mappings OK"
