-- Quoted tables as readers use them in a preview split.
-- Run: nvim --headless -u NONE --noplugin -l tests/blockquote_table_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local preview = require "md-render.preview"
local tables = require "md-render.markdown_table"
local links = require "md-render.links"
local image = require "md-render.image"
image.setup { backend = "snacks" }
image._set_kitty_supported(true)
image._test_cell_size = { cell_w = 1, cell_h = 1 }
require("md-render.display_utils").setup_images = function() end

local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end

local function feed(key)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "x", false)
  assert(vim.v.errmsg == "", vim.v.errmsg)
end

local function with_split(source, check)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_set_current_buf(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  preview.split { mods = { vertical = true }, text_scale = false }
  local session = assert(preview._toggle_sessions[buf])
  vim.api.nvim_set_current_win(session.win)
  check(session)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), source, "source text")
  eq(vim.api.nvim_buf_get_changedtick(buf), tick, "navigation leaves the source untouched")
  vim.api.nvim_win_close(session.win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

local function resize(session, width)
  vim.api.nvim_win_set_width(session.win, width)
  session:resize(session.win)
  session:rebuild()
  eq(session.opts.table_max_width, width, "table uses the split width")
  eq(vim.api.nvim_buf_get_lines(session.buf, 0, -1, false), session.content.lines, "applied preview")
end

local function groups_at(session, row, byte)
  local found = {}
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(session.buf, session.ns, { row, byte }, { row, byte }, {
      details = true,
      overlap = true,
    }))
  do
    local hl = mark[4]
    if hl.hl_group and hl.end_col > byte then found[hl.hl_group] = hl end
  end
  return found
end

local function enter(session, row, byte)
  vim.api.nvim_win_set_cursor(session.win, { row, byte })
  feed "<CR>"
  return session.content.source_line_map[vim.api.nvim_win_get_cursor(session.win)[1]]
end

local raw = {
  "項目[^n] | 作業",
  "--- | ---",
  "Linux | 請先下載[完整離線使用手冊][guide]再備份",
  "備援方案",
}
local source = { "> [!WARNING]+ Restore", ">" }
for _, row in ipairs(raw) do
  table.insert(source, "> " .. row)
end
vim.list_extend(
  source,
  { "", "> Outside", ">", "> Plain", "", "# Target", "", "[guide]: #target", "[^n]: 表頭定義" }
)
with_split(source, function(s)
  local parsed = assert(tables.parse(raw, nil, nil, { guide = "#target" }, nil, { n = 1 }))
  for _, width in ipairs { 24, 52 } do
    resize(s, width)
    local c, rendered, rows = s.content, {}, {}
    for i, line in ipairs(c.lines) do
      if c.table_lines[i - 1] then
        table.insert(rendered, line)
        table.insert(rows, i)
      end
    end
    local expected, _, _, _, offsets = tables.render(parsed, "│ ", width)
    eq(rendered, expected, "callout fits the complete table within one quoted prefix")
    for i, row in ipairs(rows) do
      eq(c.source_line_map[row], 3 + offsets[i], "physical source of header, delimiter and wrapped cells")
      local outer, inner = groups_at(s, row - 1, 0), groups_at(s, row - 1, #"│ ")
      assert(
        outer.MdRenderAlertWarning and outer.MdRenderAlertWarningBg and outer.MdRenderAlertWarningBg.hl_eol,
        "the warning paints its outer bar and background"
      )
      assert(inner.FloatBorder and not inner.MdRenderAlertWarning, "the inner table retains its border colour")
    end
    local destinations = { ["#target"] = 12, ["#footnote-def-n"] = 15, ["#footnote-ref-n"] = 3 }
    local clicked, label = {}, {}
    for _, link in ipairs(c.link_metadata) do
      local url = link.url
      local text = c.lines[link.line + 1]:sub(link.col_start + 1, link.col_end)
      if url == "#target" then
        table.insert(label, text)
      else
        eq(text, "¹", "linked superscript")
      end
      eq(links.at(s.buf, s.ns, link.line, link.col_end - 1), url, "last linked byte")
      eq(enter(s, link.line + 1, link.col_start), destinations[url], "Enter reaches the intended source row")
      clicked[url] = true
    end
    eq(vim.tbl_count(clicked), 3, "reference link and both footnote directions are clickable")
    eq(table.concat(label), "完整離線使用手冊", "complete CJK link after wrapping")

    local fold, last = c.callout_folds[1], rows[#rows]
    eq({ fold.end_line + 1, fold.end_source_line }, { last, 6 }, "fold includes its last table row")
    vim.api.nvim_win_set_cursor(s.win, { last, #c.lines[last] - #"│" - 1 })
    feed "zc"
    assert(
      s.content.callout_folds[1].collapsed and not next(s.content.table_lines),
      "closing from the last cell hides the table"
    )
    local outside = s:source_to_rendered(8)
    eq(s.content.lines[outside], "│ Outside", "next quote remains visible")
    eq(vim.trim(s.content.lines[s:source_to_rendered(9)]), "│", "quoted blank separates ordinary paragraphs")
    assert(not groups_at(s, outside - 1, 0).MdRenderAlertWarningBg, "warning background ends with its quote")
    feed "zo"
    assert(not s.content.callout_folds[1].collapsed and next(s.content.table_lines), "opening restores the table")
  end
end)

local png = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"
with_split({
  "<details open>",
  "<summary>Media</summary>",
  "",
  "> 說明 | 圖",
  "> --- | ---",
  "> [中文指南][doc] | ![橘圖](" .. png .. ")",
  ">",
  "> 結語",
  "",
  "</details>",
  "",
  "# Target",
  "",
  "[doc]: #target",
}, function(s)
  resize(s, 40)
  local c = s.content
  eq(#c.image_placements, 1, "image in the quoted details table")
  local p = c.image_placements[1]
  eq(p.path, png, "resolved image")
  local link = assert(c.link_metadata[1])
  local line = c.lines[link.line + 1]
  eq(line:sub(link.col_start + 1, link.col_end), "中文指南", "CJK link starts after both container borders")
  local divider = assert(line:match "^│ │ │ .-()│", "details, quote and table each have a border")
  eq(
    p.cell_col,
    vim.fn.strdisplaywidth(line:sub(1, divider - 1) .. "│"),
    "right image cell starts after the shared divider"
  )
  eq(p.cell_cols, vim.fn.strdisplaywidth(line:sub(divider + #"│", -#"│" - 1)), "width of the visible image cell")
  assert(p.col >= p.cell_col and p.col + p.cols <= p.cell_col + p.cell_cols, "graphic fits inside the right cell")
  for row = p.line - p.label_rows + 1, p.line + p.rows do
    eq(c.source_line_map[row], 6, "caption and image rows retain the physical source")
    local outer = groups_at(s, row - 1, 0)
    assert(
      c.table_lines[row - 1] and outer.MdRenderDetailsBar and outer.MdRenderDetailsBg and outer.MdRenderDetailsBg.hl_eol,
      "details styles include image placeholders"
    )
  end
  local paragraph = s:source_to_rendered(8)
  eq(c.lines[paragraph], "│ │ 結語", "a quoted blank ends the table before the next paragraph")
  assert(not c.table_lines[paragraph - 1])
  eq(enter(s, link.line + 1, link.col_start), 12, "Enter on the left cell follows its reference")
  local opened
  require("md-render.image_view").open = function(path)
    opened = path
  end
  s.image_state = { snacks = true, objects = { {
    ready = function()
      return true
    end,
  } } }
  local caption = vim.fn.searchpos("橘圖", "nw")
  eq(c.source_line_map[caption[1]], 6, "wrapped caption remains searchable")
  enter(s, caption[1], caption[2] - 1)
  eq(opened, png, "Enter on the adjacent caption opens the image")
  opened = nil
  enter(s, p.line + 1, vim.fn.virtcol2col(s.win, p.line + 1, p.col + 1) - 1)
  eq(opened, png, "Enter on the image placement opens the same image")
  s.image_state = nil
  feed "zc"
  eq(s.content.callout_folds[1].collapsed, true, "image placeholder belongs to details")
  eq(s.content.image_placements, {}, "collapsed details release image targets")
  eq(s.content.link_metadata, {}, "collapsed details release cell links")
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(s.buf, s.ns, 0, -1, { details = true })) do
    assert(not mark[4].url, "collapsed details remove clickable extmarks")
  end
end)

for _, kind in ipairs { "details", "callout" } do
  local details = kind == "details"
  local fold_source = details and { "<details>", "" } or { "> [!NOTE]- Fold" }
  local header = #fold_source + 1
  vim.list_extend(fold_source, { "> - A|B", ">   -|-", ">   x|y" })
  if details then vim.list_extend(fold_source, { "", "</details>" }) end
  with_split(fold_source, function(s)
    vim.api.nvim_win_set_cursor(s.win, { s.content.callout_folds[1].header_line + 1, 0 })
    feed "zo"
    local marker = s:source_to_rendered(header)
    assert(s.content.lines[marker]:find("•", 1, true), "the list marker is visible in the open fold")
    eq(s.content.source_line_map[marker + 1], header, "marker and table header share their source")
    assert(s.content.table_lines[marker], "table header follows its list marker")
    assert(
      groups_at(s, marker - 1, 0)[details and "MdRenderDetailsBg" or "MdRenderAlertNoteBg"],
      "fold styles include the marker"
    )
    vim.api.nvim_win_set_cursor(s.win, { marker, 0 })
    feed "zc"
    assert(
      s.content.callout_folds[1].collapsed and not next(s.content.table_lines),
      "closing from the marker hides its table"
    )
    assert(not table.concat(s.content.lines):find("•", 1, true), "a closed fold hides the list marker")
  end)
end

local function build(lines, max_lines)
  local builder = require("md-render.content_builder").ContentBuilder.new()
  builder:render_document(lines, { indent = "", max_width = 40, max_lines = max_lines })
  return builder:result()
end

local limited = build({
  "> Media | More",
  "> --- | ---",
  "> ![Pic](" .. png .. ") | [link](#target)[^n]",
  "",
  "[^n]: Note",
  "",
  "# Target",
}, 2)
eq(limited.table_lines, { [0] = true, [1] = true }, "only header and delimiter fit the row budget")
eq({ #limited.lines, limited.lines[3] }, { 3, "... (truncated)" }, "one truncation notice follows the table")
eq({ limited.link_metadata, limited.footnote_anchors, limited.image_placements }, { {}, {}, {} }, "hidden cell targets")

local root_table = { "H | B", "-|-", "x | y", "", "after" }
local full = build(root_table)
eq({ full.lines[4], full.lines[5], #full.lines }, { "", "after", 5 }, "root table keeps the blank before prose")
local at_blank = build(root_table, 4)
eq(
  { at_blank.lines[4], at_blank.lines[5], #at_blank.lines },
  { "", "... (truncated)", 5 },
  "source blank counts towards the budget"
)
print "Quoted tables: split reflow, callout folds, footnotes and image hit testing OK"
