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
local left_caption = "地球測試ABCDEFGHIJKLMNOPQRSTUV，完整標題的句尾必須保留 CAPTION73"
local right_caption = "這是第二張圖片的很長中文標題"
vim.bo.filetype = "markdown"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "| A quite long left cell header needing width | Cat in Space (http.cat) |",
  "|---|---|",
  "| ![" .. left_caption .. "](" .. paths[1] .. ") | ![HTTP 200](" .. paths[2] .. ") |",
  "| Plain text with a long explanation that must remain readable through the final keyword TEXT73 | ![Mixed]("
    .. paths[1]
    .. ") |",
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
  local pieces = {}
  for row = p.line - p.label_rows + 1, p.line do
    local first = vim.fn.virtcol2col(session.win, row, p.cell_col + 1) - 1
    local last = vim.fn.virtcol2col(session.win, row, p.cell_col + p.cell_cols + 1) - 1
    pieces[#pieces + 1] = session.content.lines[row]:sub(first + 1, last):gsub("%s", "")
    enter(row, first, expected_paths[idx])
    enter(row, vim.fn.virtcol2col(session.win, row, p.cell_col + p.cell_cols) - 1, expected_paths[idx])
  end
  assert(table.concat(pieces):find(label:gsub("%s", ""), 1, true), "every caption retains its full text")
  -- Image placeholders have multibyte table borders before the image's display column.
  for _, col in ipairs { p.col, p.col + p.cols - 1 } do
    for _, row in ipairs { p.line + 1, p.line + p.rows } do
      local byte_col = vim.fn.virtcol2col(session.win, row, col + 1) - 1
      enter(row, byte_col, expected_paths[idx])
    end
  end
end
assert(placements[1].label_rows > 1, "long image captions must wrap")
assert(placements[3].label_rows > 1, "text sharing an image row must wrap")
assert(#session.content.expandable_regions == 0, "image tables need no expansion")
assert(vim.fn.search("CAPTION73", "nw") > 0, "image caption tail is searchable initially")
assert(vim.fn.search("TEXT73", "nw") > 0, "text beside an image remains searchable initially")

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
local right_label_row = right.line - right.label_rows + 1
enter(right_label_row, vim.fn.virtcol2col(session.win, right_label_row, right.cell_col + 1) - 1, nil)

local standalone = placements[8]
enter(standalone.line, 0, paths[1])
enter(standalone.line + 1, 0, paths[1])
enter(#session.content.lines, 0, nil)

-- Fall through outside image cells, including a text cell sharing an image row.
local shorter = placements[1]
local below = shorter.line + shorter.rows + 1
enter(below, vim.fn.virtcol2col(session.win, below, shorter.col + 1) - 1, nil)
local mixed = session.content.image_placements[3]
local mixed_label_row = mixed.line - mixed.label_rows + 1
enter(mixed_label_row, assert(session.content.lines[mixed_label_row]:find("Plain text", 1, true)) - 1, nil)
local first = session.content.image_placements[1]
local caption = session.content.lines[first.line]
enter(first.line, assert(caption:find("│", 1, true)) - 1, nil)
enter(session.content.image_placements[1].line, 0, nil)
session.image_state = nil

-- Table media detection keeps the same complete quoted token as inline display.
do
  local directory = vim.fn.tempname()
  vim.fn.mkdir(directory, "p")
  local exact_path = directory .. "/two>part<!--keep-->spaces.png"
  assert(vim.uv.fs_copyfile(paths[1], exact_path))
  assert(vim.uv.fs_copyfile(paths[1], directory .. "/twospaces.png"))
  for _, case in ipairs {
    { paths[1], "a>b" },
    { paths[1], "a<!--keep-->b" },
    { exact_path, "label" },
    { exact_path, "標題", true },
  } do
    local source_lines = { '<table><tr><td><img src="' .. case[1] .. '" alt="' .. case[2] .. '"></td></tr></table>' }
    if case[3] then
      source_lines = {
        '<details title="a > b" open>',
        "<summary>Images</summary>",
        '<table><tr><td title="a > </table>"><img title=\'src="trap.png" alt="trap"\' src="'
          .. case[1]
          .. '" alt="'
          .. case[2]
          .. '"></td></tr></table>',
        "</details>",
      }
    end
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
      assert(
        session.content.source_line_map[placement.line] == (case[3] and 3 or 1),
        "table caption retains its physical source row"
      )
      assert(vim.deep_equal(vim.api.nvim_buf_get_lines(session.buf, 0, -1, false), session.content.lines))
      session.image_state = { snacks = true, objects = {} }
      session.image_state.objects[1] = {
        ready = function()
          return true
        end,
      }
      enter(placement.line, label_at, case[1])
      enter(placement.line, label_at + vim.fn.byteidx(case[2], vim.fn.strchars(case[2]) - 1), case[1])
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

-- Multiline HTML alt is folded before table caption wrapping and image hit bounds.
local table_start = "<table><tr><th>Caption with enough room for a complete image label</th></tr><tr><td>"
for _, graphics in ipairs { false, true } do
  image._set_kitty_supported(graphics)
  for _, width in ipairs { 20, 100 } do
    for _, case in ipairs {
      { "前段\n後段 CAPTION73", "前段 後段 CAPTION73" },
      { "前段\r\n後段 CAPTION73", "前段 後段 CAPTION73" },
      { "前段\r後段 CAPTION73", "前段 後段 CAPTION73" },
      { "前段  \\字面 後段 CAPTION73", "前段  \\字面 後段 CAPTION73" },
    } do
      local tag = table_start .. '<img src="' .. paths[1] .. '" alt="' .. case[1] .. '"></td></tr></table>'
      local source_lines = vim.split(tag, "\n", { plain = true })
      vim.list_extend(source_lines, { "", "[AFTER73](/after)" })
      local source_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[source_buf].filetype = "markdown"
      vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, source_lines)
      vim.api.nvim_set_current_buf(source_buf)
      local tick = vim.api.nvim_buf_get_changedtick(source_buf)
      local opts = { max_width = width, text_scale = false }
      local folded = preview.build_content({
        table_start .. '<img src="' .. paths[1] .. '" alt="' .. case[2] .. '"></td></tr></table>',
        "",
        "[AFTER73](/after)",
      }, opts)
      preview.show_tab(opts)
      session = assert(preview._sessions[vim.api.nvim_get_current_buf()])
      for step = 1, 2 do
        local c = session.content
        assert(vim.deep_equal(c.lines, folded.lines), "CRLF/CR/LF captions lay out exactly like one space")
        assert(vim.deep_equal(c.highlights, folded.highlights), "table highlights use normalized caption bytes")
        assert(vim.deep_equal(c.image_placements, folded.image_placements), "table caption folding preserves geometry")
        if width == 100 then
          assert(table.concat(c.lines, "\n"):find(case[2], 1, true), "wide caption preserves exact literal bytes")
        end
        assert(vim.deep_equal(vim.api.nvim_buf_get_lines(session.buf, 0, -1, false), c.lines))
        assert(#c.source_line_map == #c.lines, "each output row retains a source row")
        for row, line in ipairs(c.lines) do
          assert(not line:find "[\r\n]", "table output rows contain no embedded line endings")
          if line:find("AFTER73", 1, true) then
            assert(c.source_line_map[row] == #source_lines, "caption folding cannot shift the following paragraph")
          end
        end
        for _, item in ipairs(c.highlights) do
          for _, hl in ipairs(item.groups) do
            assert(hl.col >= 0 and (hl.end_col == -1 or hl.end_col <= #c.lines[item.line + 1]))
          end
        end
        assert(vim.fn.search("CAPTION73", "nw") > 0, "complete caption tail is searchable initially and after rebuild")
        assert(#c.image_placements == (graphics and 1 or 0), "both table graphics and fallback are exercised")
        if graphics then
          local p = c.image_placements[1]
          assert(p.path == paths[1], "table caption folding preserves the actual image path")
          if width == 20 then assert(p.label_rows > 1, "narrow caption really wraps") end
          session.image_state = {
            snacks = true,
            objects = {
              {
                ready = function()
                  return true
                end,
              },
            },
          }
          for row = p.line - p.label_rows + 1, p.line do
            enter(row, vim.fn.virtcol2col(session.win, row, p.cell_col + 1) - 1, paths[1])
            enter(row, vim.fn.virtcol2col(session.win, row, p.cell_col + p.cell_cols) - 1, paths[1])
          end
          session.image_state = nil
        end
        if step == 1 then session:rebuild() end
      end
      assert(vim.deep_equal(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), source_lines))
      assert(
        vim.api.nvim_buf_get_changedtick(source_buf) == tick,
        "caption navigation and rebuild preserve source bytes"
      )
      vim.api.nvim_buf_delete(session.buf, { force = true })
      vim.api.nvim_buf_delete(source_buf, { force = true })
    end
  end
end

-- Linked image captions retain the existing anchor-before-image Enter order.
for _, width in ipairs { 20, 100 } do
  image._set_kitty_supported(true)
  local long_caption = "Standalone 長圖片標題 alpha beta gamma delta epsilon END"
  local source_lines = {
    "# Target",
    "",
    "[![" .. long_caption .. "](<" .. paths[1] .. '> "title")](https://example.invalid/outer)',
    "",
    "[![Anchor](<" .. paths[1] .. '> "title")](#target)',
    "",
    "| Image column |",
    "| --- |",
    "| [![Table reference][img]][outer] |",
    "",
    "[img]: <" .. paths[1] .. '> "title"',
    "[outer]: #target",
  }
  local source_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, source_lines)
  vim.bo[source_buf].filetype = "markdown"
  vim.api.nvim_set_current_buf(source_buf)
  local tick = vim.api.nvim_buf_get_changedtick(source_buf)
  preview.show_tab { max_width = width, text_scale = false }
  session = assert(preview._sessions[vim.api.nvim_get_current_buf()])
  assert(#session.content.image_placements == 3, "direct document and reference table images share media loading")
  session.image_state = { snacks = true, objects = {} }
  for index in ipairs(session.content.image_placements) do
    session.image_state.objects[index] = {
      ready = function()
        return true
      end,
    }
  end
  local found = 0
  for _, link in ipairs(session.content.link_metadata) do
    if link.url == "#target" then
      found = found + 1
      assert(require("md-render.links").at(session.buf, session.ns, link.line, link.col_start) == link.url)
      enter(link.line + 1, link.col_start, nil)
      assert(
        vim.api.nvim_win_get_cursor(session.win)[1] == session.content.heading_anchors.target + 1,
        "Enter follows the internal anchor before opening an image tab"
      )
    elseif link.url == "https://example.invalid/outer" then
      assert(require("md-render.links").at(session.buf, session.ns, link.line, link.col_start) == link.url)
      enter(link.line + 1, link.col_start, paths[1])
    end
  end
  assert(found >= 2, "both image captions expose their enclosing href")
  local linked_placement = session.content.image_placements[1]
  if width == 20 then assert(linked_placement.label_rows > 1, "standalone caption must really wrap") end
  for row = linked_placement.line - linked_placement.label_rows + 1, linked_placement.line do
    enter(row, 0, paths[1])
  end
  enter(linked_placement.line + 1, 0, paths[1])
  assert(vim.api.nvim_buf_get_changedtick(source_buf) == tick, "caption navigation preserves source changedtick")
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), source_lines))
  session.image_state = nil
  vim.api.nvim_buf_delete(session.buf, { force = true })
  vim.api.nvim_buf_delete(source_buf, { force = true })
end
print "Table image selection: cell ownership, long CJK captions, image edges, readiness and standalone navigation OK"
