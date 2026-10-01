-- Enter selects table images by display column and keeps standalone row navigation.
-- Run: nvim --headless -u NONE --noplugin -l tests/table_image_selection_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local image = require "md-render.image"
image.setup { backend = "snacks" }
image._set_kitty_supported(true)
image._test_cell_size = { cell_w = 1, cell_h = 1 }
-- Keep real parsing, layout and Enter mappings; no terminal or image converter is needed.
require("md-render.display_utils").setup_images = function() end
local opened
require("md-render.image_view").open = function(path)
  opened = path
end

local root = vim.fn.getcwd()
local paths = { root .. "/tests/fixtures/test_4x4.png", root .. "/assets/demo/test.png" }
local left_caption = "地球測試ABCDEFGHIJKLMNOPQRSTUV"
local right_caption = "這是第二張圖片的很長中文標題"
vim.bo.filetype = "markdown"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "| A quite long left cell header needing width | Cat in Space (http.cat) |",
  "|---|---|",
  "| ![" .. left_caption .. "](" .. paths[1] .. ") | ![HTTP 200](" .. paths[2] .. ") |",
  "| Plain text | ![Mixed](" .. paths[1] .. ") |",
  "",
  "| A | " .. right_caption .. "與更多說明 |",
  "|---|---|",
  "| ![First](" .. paths[2] .. ") | ![" .. right_caption .. "](" .. paths[1] .. ") |",
  "",
  "<details open>",
  "<summary>Nested images</summary>",
  "<table>",
  "<tr><th>Nested left image</th><th>Nested right image</th></tr>",
  '<tr><td><img src="'
    .. paths[1]
    .. '" alt="Nested left"></td><td><img src="'
    .. paths[2]
    .. '" alt="Nested right"></td></tr>',
  "</table>",
  "</details>",
  "",
  "![Standalone](" .. paths[1] .. ")",
  "",
  "plain text",
})
local preview = require "md-render.preview"
local source = vim.api.nvim_get_current_buf()
preview.toggle { max_width = 70 }
local session = assert(preview._toggle_sessions[source])
local placements = session.content.image_placements
assert(#placements == 8, "pipe tables, nested HTML table and standalone image must render")
session.image_state = { snacks = true, objects = {} }
for idx in ipairs(placements) do
  session.image_state.objects[idx] = {
    ready = function()
      return true
    end,
  }
end

local function enter(row, byte_col, expected)
  opened = nil
  vim.v.errmsg = ""
  vim.api.nvim_win_set_cursor(session.win, { row, byte_col })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  assert(vim.v.errmsg == "", vim.v.errmsg)
  assert(
    opened == expected,
    ("row %d, byte column %d opened %s; expected %s"):format(row, byte_col, tostring(opened), tostring(expected))
  )
end

local expected_paths = { paths[1], paths[2], paths[1], paths[2], paths[1], paths[1], paths[2] }
for idx, label in ipairs { left_caption, "HTTP 200", "Mixed", "First", right_caption, "Nested left", "Nested right" } do
  local p = placements[idx]
  local caption = session.content.lines[p.line]
  local at = assert(caption:find(label, 1, true)) - 1
  enter(p.line, at, expected_paths[idx])
  enter(p.line, at + vim.fn.byteidx(label, vim.fn.strchars(label) - 1), expected_paths[idx])
  -- Image placeholders have multibyte table borders before the image's display column.
  for _, col in ipairs { p.col, p.col + p.cols - 1 } do
    for _, row in ipairs { p.line + 1, p.line + p.rows } do
      local byte_col = vim.fn.virtcol2col(session.win, row, col + 1) - 1
      enter(row, byte_col, expected_paths[idx])
    end
  end
end

-- Details adds a border after HTML table layout; image and hit bounds must follow it.
local nested_caption = session.content.lines[placements[6].line]
local borders = {}
for at in nested_caption:gmatch "()│" do
  borders[#borders + 1] = vim.fn.strdisplaywidth(nested_caption:sub(1, at - 1))
end
for idx = 6, 7 do
  local p = placements[idx]
  local first_col, end_col = borders[idx - 4] + 1, borders[idx - 3]
  assert(p.col - first_col == end_col - p.col - p.cols, "details prefix must keep the image centered in its cell")
  for _, col in ipairs { first_col, end_col - 1 } do
    enter(p.line, vim.fn.virtcol2col(session.win, p.line, col + 1) - 1, expected_paths[idx])
  end
end

-- An unloaded selected image must not open a different ready image.
session.image_state.objects[2] = nil
local right = placements[2]
enter(right.line, assert(session.content.lines[right.line]:find("HTTP 200", 1, true)) - 1, nil)

local standalone = placements[8]
enter(standalone.line, 0, paths[1])
enter(standalone.line + 1, 0, paths[1])
enter(#session.content.lines, 0, nil)

-- Fall through outside image cells, including a text cell sharing an image row.
local shorter = placements[1]
local below = shorter.line + shorter.rows + 1
enter(below, vim.fn.virtcol2col(session.win, below, shorter.col + 1) - 1, nil)
local mixed = session.content.image_placements[3]
enter(mixed.line, assert(session.content.lines[mixed.line]:find("Plain text", 1, true)) - 1, nil)
local first = session.content.image_placements[1]
local caption = session.content.lines[first.line]
enter(first.line, assert(caption:find("│", 1, true)) - 1, nil)
enter(session.content.image_placements[1].line, 0, nil)
session.image_state = nil

-- Table media detection keeps the same complete quoted token as inline display.
do
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local exact_path = directory .. "/two<!--keep-->spaces.png"
  assert(vim.uv.fs_copyfile(paths[1], exact_path))
  assert(vim.uv.fs_copyfile(paths[1], directory .. "/twospaces.png"))
  for _, case in ipairs {
    { paths[1], "a>b" },
    { paths[1], "a<!--keep-->b" },
    { exact_path, "label" },
  } do
    local source_lines = { '<table><tr><td><img src="' .. case[1] .. '" alt="' .. case[2] .. '"></td></tr></table>' }
    local source_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[source_buf].filetype = "markdown"
    vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, source_lines)
    vim.api.nvim_set_current_buf(source_buf)
    local tick = vim.api.nvim_buf_get_changedtick(source_buf)
    preview.show_tab { max_width = 100, text_scale = false }
    session = assert(preview._sessions[vim.api.nvim_get_current_buf()])
    for step = 1, 2 do
      assert(#session.content.image_placements == 1, "quoted image attributes preserve table media detection")
      local placement = session.content.image_placements[1]
      assert(placement.path == case[1], "table media keeps the full literal source filename")
      local label_at = assert(session.content.lines[placement.line]:find(case[2], 1, true)) - 1
      assert(session.content.source_line_map[placement.line] == 1, "table caption retains its physical source row")
      assert(vim.deep_equal(vim.api.nvim_buf_get_lines(session.buf, 0, -1, false), session.content.lines))
      session.image_state = { snacks = true, objects = {} }
      session.image_state.objects[1] = {
        ready = function()
          return true
        end,
      }
      enter(placement.line, label_at, case[1])
      enter(placement.line, label_at + #case[2] - 1, case[1])
      session.image_state = nil
      if step == 1 then session:rebuild() end
    end
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), source_lines))
    assert(vim.api.nvim_buf_get_changedtick(source_buf) == tick, "table media navigation preserves source changedtick")
    vim.api.nvim_buf_delete(session.buf, { force = true })
    vim.api.nvim_buf_delete(source_buf, { force = true })
  end
  vim.fn.delete(directory, "rf")
end
print "Table image selection: cell ownership, long CJK captions, image edges, readiness and standalone navigation OK"
