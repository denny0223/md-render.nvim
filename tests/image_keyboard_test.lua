-- Keyboard hints use the same image as Enter in ordinary previews and pagers.
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.cmd "runtime plugin/md-render.lua"
vim.o.columns, vim.o.lines, vim.o.mouse = 42, 24, ""
local image = require "md-render.image"
image.setup { backend = "snacks" }
image._set_kitty_supported(true)
image._test_cell_size = { cell_w = 9, cell_h = 18 }
require("md-render.display_utils").setup_images = function() end
-- Exercise the actual viewer, mappings and return path without terminal conversion.
require("md-render.async").run = function() end
local original_path = vim.env.PATH
local tools = vim.fn.tempname()
vim.fn.mkdir(tools, "p")
vim.fn.writefile({ "#!/bin/sh", "exit 0" }, tools .. "/magick")
vim.fn.setfperm(tools .. "/magick", "rwx------")
vim.env.PATH = tools
local hint = require "md-render.image_hint"
local preview = require "md-render.preview"
local hint_ns = vim.api.nvim_create_namespace "md_render_image_hint"
local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
end

for _, mode in ipairs { "tab", "pager", "float" } do
  local source = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(source)
  vim.bo.filetype = "markdown"
  local path = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"
  local lines = { "# Photos", "" }
  for i = 1, 26 do
    vim.list_extend(lines, { "Paragraph " .. i, "" })
  end
  vim.list_extend(lines, {
    "![A](" .. path .. ")",
    "",
    "| 圖片 | 旁欄 |",
    "|---|---|",
    "| ![中文圖說中文圖說中文圖說中文圖說中文圖說]("
      .. path
      .. ") | [Read the survey results and the supporting report](https://example.org/report) |",
    "",
    "[![jump](" .. path .. ")](#photos)",
  })
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  vim.bo.modified = false
  vim.cmd("MdRender " .. mode .. " width=32")
  local buf = vim.api.nvim_get_current_buf()
  local session = assert(preview._sessions[buf])
  local win = vim.api.nvim_get_current_win()
  local p, table_p = unpack(session.content.image_placements)
  assert(#session.content.image_placements == 3)
  local ready = false
  local object = {
    ready = function()
      return ready
    end,
  }
  session.image_state = { objects = { object, object, object } }
  vim.api.nvim_win_set_cursor(win, { p.line, 0 })
  vim.cmd "normal! zt"
  vim.cmd.redraw()
  local function marks()
    return vim.api.nvim_buf_get_extmarks(buf, hint_ns, 0, -1, { details = true })
  end
  hint.refresh()
  assert(#marks() == 0, "no shortcut for pending media")
  ready = true
  vim.env.PATH = "/nonexistent"
  hint.refresh()
  assert(#marks() == 0, "no shortcut without ImageMagick")
  vim.env.PATH = tools
  hint.refresh()
  local mark = assert(marks()[1], "ready image shows its key")
  assert(mark[2] == p.line - 1 and mark[4].virt_text[1][1]:find("Enter", 1, true))
  local before = vim.fn.winsaveview()
  for _, key in ipairs { "<CR>", "q", "<Esc>" } do
    feed "<CR>"
    assert(vim.bo.filetype == "md-render-image" and #marks() == 0, "open image and hide source cue")
    assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("Enter/q: back", 1, true), "visible return")
    local owner = vim.api.nvim_get_current_win()
    vim.cmd.vsplit()
    local duplicate = vim.api.nvim_get_current_win()
    feed(key)
    assert(
      not vim.api.nvim_win_is_valid(duplicate) and vim.api.nvim_get_current_win() == owner,
      "close only the split receiving " .. key
    )
    feed(key)
    assert(
      vim.wait(300, function()
        return vim.api.nvim_get_current_win() == win and #marks() == 1
      end, 5),
      mode .. " image cue restored without moving cursor"
    )
    assert(
      vim.api.nvim_get_current_buf() == buf and vim.fn.line "." == before.lnum and vim.fn.line "w0" == before.topline
    )
  end

  if mode == "tab" then
    feed "<CR>"
    local owner = vim.api.nvim_get_current_win()
    vim.cmd.vsplit()
    vim.api.nvim_win_close(owner, true)
    feed "<CR>"
    assert(vim.api.nvim_get_current_win() == win, "Enter can close the surviving image split")
  end

  -- The table's caption is full; its cue must neither shift the other column nor consume its clicks.
  local row = table_p.line
  local cell = vim.fn.virtcol2col(win, row, table_p.cell_col + 1) - 1
  vim.api.nvim_win_set_cursor(win, { row, cell })
  vim.cmd "redraw"
  local function visible_cells()
    vim.cmd.redraw()
    local cells = {}
    for r = 1, vim.o.lines do
      for c = 1, vim.o.columns do
        cells[#cells + 1] = vim.fn.screenstring(r, c)
      end
    end
    return cells
  end
  hint.hide()
  local original = visible_cells()
  hint.refresh()
  local with_hint = visible_cells()
  assert(table.concat(with_hint):find("Enter", 1, true), "narrow table shows the keyboard action")
  for i, cell_text in ipairs(original) do
    if cell_text ~= " " then assert(cell_text == with_hint[i], "the cue covered text or moved the table") end
  end
  feed "<CR>"
  assert(vim.b.md_render_image_view, "the compact hint opens the selected image")
  feed "q"
  assert(vim.wait(300, function()
    return vim.api.nvim_get_current_win() == win
  end, 5))
  if mode == "float" then
    session.image_state = nil
    vim.cmd "noautocmd close"
    vim.cmd.redraw()
    assert(
      vim.wait(300, function()
        return not vim.api.nvim_buf_is_valid(buf) or #marks() == 0
      end, 5),
      "closing the source without leave events retires its hint"
    )
    break
  end
  local links = session.content.link_metadata
  local link = assert(links[#links])
  vim.api.nvim_win_set_cursor(win, { link.line + 1, link.col_start })
  hint.refresh()
  assert(#marks() == 0, "anchor consumes Enter")
  feed "<CR>"
  assert(vim.api.nvim_win_get_cursor(win)[1] == session.content.heading_anchors.photos + 1)
  vim.api.nvim_win_set_cursor(win, { p.line, 0 })
  vim.keymap.set("n", "<CR>", function() end, { buffer = buf })
  hint.refresh()
  assert(#marks() == 0, "custom Enter mapping")
  session.image_state = nil
  vim.api.nvim_set_current_buf(source)
  vim.api.nvim_buf_delete(buf, { force = true })
end
-- With the caption scrolled offscreen, use only space outside the image.
vim.cmd.enew()
vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.fn["repeat"]({ string.rep(" ", 32) }, 60))
vim.cmd "normal! 30Gzt"
vim.cmd.redraw()
local tall = { line = 1, col = 8, rows = 59, cols = 24 }
local win = vim.api.nvim_get_current_win()
assert(hint.show(win, tall, "Enter: open image"), "the visible margin fits the return key")
local mark = vim.api.nvim_buf_get_extmarks(0, hint_ns, 0, -1, { details = true })[1]
assert(mark[2] >= vim.fn.line "w0" - 1 and mark[4].virt_text[1][1] == " Enter")
tall.col, tall.cols = 0, 32
hint.show(win, tall, "Enter: open image")
assert(vim.tbl_isempty(vim.api.nvim_buf_get_extmarks(0, hint_ns, 0, -1, {})), "keep a full-width image unobstructed")
vim.env.PATH = original_path
vim.fn.delete(tools, "rf")
print "Snacks keyboard: tab and pager hints, return mappings, narrow table, custom mapping and anchor OK"
