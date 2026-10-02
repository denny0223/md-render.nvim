-- Real window geometry; capture only terminal writes.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
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

print "Render interaction: float occlusion, recovery and timer cleanup OK"
