-- source_line_map inside a paragraph joined from several source lines.
--
-- A paragraph's lines are joined into one before it is wrapped, so the rows
-- that come out of the wrap used to be attributed to the paragraph's first
-- line, all of them. Everything that maps between the source and the render
-- (the split's shadow cursor and scroll sync, toggling between the two) then
-- treated the paragraph as one opaque block: with the cursor on its last
-- line, the shadow lit up every row of it. Each row now goes to the source
-- line its first character comes from.
--
-- Run: nvim --headless -u NONE --noplugin -l tests/paragraph_line_map_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local ContentBuilder = require("md-render.content_builder").ContentBuilder
local display = require "md-render.display_utils"
local Links = require "md-render.links"

local pass_count = 0
local fail_count = 0

local function assert_eq(actual, expected, msg)
  if vim.deep_equal(actual, expected) then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
    print("  expected: " .. vim.inspect(expected))
    print("  actual:   " .. vim.inspect(actual))
  end
end

--- Render and return `{ { source_line, text }, ... }` for every row.
local function render(lines, width)
  local b = ContentBuilder.new()
  b:render_document(lines, { max_width = width, indent = "" })
  local r = b:result()
  local rows = {}
  for i, line in ipairs(r.lines) do
    table.insert(rows, { r.source_line_map[i], line })
  end
  return rows
end

--- Just the source lines of the rows, for the cases where the text is not
--- the point.
local function sources(lines, width)
  return vim.tbl_map(function(row)
    return row[1]
  end, render(lines, width))
end

-- Test 1: CJK sentences, one per source line
do
  local rows = render({
    "あいうえおかきくけこ一行目の文です。",
    "あいうえおかきくけこ二行目の文です。",
    "あいうえおかきくけこ三行目の文です。",
  }, 30)
  assert_eq(rows, {
    { 1, "あいうえおかきくけこ一行目の文" },
    { 1, "です。あいうえおかきくけこ二行" },
    { 2, "目の文です。あいうえおかきくけ" },
    { 3, "こ三行目の文です。" },
  }, "each row goes to the source line its first character comes from")
end

-- Test 2: Latin text, joined with a space
do
  local rows = render({
    "alpha beta gamma delta",
    "epsilon zeta eta theta",
    "iota kappa lambda",
  }, 16)
  assert_eq(rows, {
    { 1, "alpha beta gamma" },
    { 1, "delta epsilon" },
    { 2, "zeta eta theta" },
    { 3, "iota kappa" },
    { 3, "lambda" },
  }, "a row starting right after the joining space belongs to the next line")
end

-- Test 3: inline markup and a link in the joined lines
do
  local rows = render({
    "one **bold** word then",
    "a [link text](https://example.com) and",
    "the third line",
  }, 14)
  assert_eq(rows, {
    { 1, "one bold word" },
    { 1, "then a link" },
    { 2, "text and the" },
    { 3, "third line" },
  }, "markers and URLs that the render drops do not shift the rows")
end

-- Test 4: a list item and its continuation lines
do
  assert_eq(
    sources({ "- item one has words and", "  continues on a second", "  and a third line", "", "after" }, 16),
    { 1, 1, 2, 2, 3, 4, 5 },
    "continuation lines of a list item get their own rows"
  )
end

-- Test 5: a blockquote paragraph
do
  assert_eq(
    sources({ "> quoted first line of words", "> quoted second line of words" }, 20),
    { 1, 1, 2, 2 },
    "the quote marker in front of the joined line does not shift the rows"
  )
end

-- Test 6: a line that starts and ends inside one row has no row of its own
-- ("two" sits in the middle of the first row)
do
  assert_eq(
    sources({ "short one", "two", "and then a much longer third line" }, 20),
    { 1, 3, 3 },
    "a source line that never starts a row is not in the map"
  )
end

-- Test 7: the first visible character must have its exact owner even when
-- emphasis markers are on different source lines.
do
  assert_eq(render({ "words before **bold that", "spans the join** and more", "words after" }, 12), {
    { 1, "words before" },
    { 1, "bold that" },
    { 2, "spans the" },
    { 2, "join and" },
    { 2, "more words" },
    { 3, "after" },
  }, "cross-line emphasis does not move the source boundary")
end

-- Test 8: paragraphs that fit on one row are unchanged
do
  assert_eq(sources({ "short", "lines", "", "next" }, 80), { 1, 3, 4 }, "an unwrapped paragraph is still one row")
end

local function style_spans(content, group)
  local found = {}
  for _, row in ipairs(content.highlights) do
    for _, hl in ipairs(row.groups) do
      if hl.hl == group then
        found[#found + 1] = { row.line, hl.col, hl.end_col, content.lines[row.line + 1]:sub(hl.col + 1, hl.end_col) }
      end
    end
  end
  return found
end

local function link_spans(content)
  local found = {}
  for _, link in ipairs(content.link_metadata) do
    found[#found + 1] = {
      link.line,
      link.col_start,
      link.col_end,
      content.lines[link.line + 1]:sub(link.col_start + 1, link.col_end),
      link.url,
    }
  end
  return found
end

-- Golden rows and byte spans are unchanged by source attribution. These
-- cases expose offsets that separately rendered source pieces cannot infer.
local boundary_cases = {
  {
    "closed CJK bold",
    { "甲乙**丙丁**", "戊己庚辛" },
    8,
    { "甲乙丙丁", "戊己庚辛" },
    { 1, 2 },
    Bold = { { 0, 6, 12, "丙丁" } },
  },
  {
    "closed CJK link",
    { "甲乙[丙丁](/target)", "戊己庚辛" },
    8,
    { "甲乙丙丁", "戊己庚辛" },
    { 1, 2 },
    MdRenderLink = { { 0, 6, 12, "丙丁" } },
    links = { { 0, 6, 12, "丙丁", "/target" } },
  },
  {
    "closed CJK code",
    { "甲乙`丙丁`", "戊己庚辛" },
    8,
    { "甲乙丙丁", "戊己庚辛" },
    { 1, 2 },
    MdRenderInlineCode = { { 0, 6, 12, "丙丁" } },
  },
  {
    "closed CJK inline HTML",
    { "甲乙<b>丙丁</b>", "戊己庚辛" },
    8,
    { "甲乙丙丁", "戊己庚辛" },
    { 1, 2 },
    Bold = { { 0, 6, 12, "丙丁" } },
  },
  {
    "next source begins with CJK bold",
    { "甲乙丙丁", "**戊己**庚辛" },
    8,
    { "甲乙丙丁", "戊己庚辛" },
    { 1, 2 },
    Bold = { { 1, 0, 6, "戊己" } },
  },
  {
    "cross-line CJK bold",
    { "甲乙**丙丁", "戊己**庚辛" },
    8,
    { "甲乙丙丁", "戊己庚辛" },
    { 1, 2 },
    Bold = { { 0, 6, 12, "丙丁" }, { 1, 0, 6, "戊己" } },
  },
  {
    "cross-line CJK link",
    { "甲乙[丙丁", "戊己](/target)庚辛" },
    8,
    { "甲乙丙丁", "戊己庚辛" },
    { 1, 2 },
    MdRenderLink = { { 0, 6, 12, "丙丁" }, { 1, 0, 6, "戊己" } },
    links = { { 0, 6, 12, "丙丁", "/target" }, { 1, 0, 6, "戊己", "/target" } },
  },
  {
    "cross-line CJK code",
    { "甲乙`丙丁", "戊己`庚辛" },
    8,
    { "甲乙丙丁", "戊己庚辛" },
    { 1, 2 },
    MdRenderInlineCode = { { 0, 6, 12, "丙丁" }, { 1, 0, 6, "戊己" } },
  },
  {
    "cross-line Latin bold",
    { "alpha **beta gamma", "delta epsilon** zeta" },
    10,
    { "alpha beta", "gamma", "delta", "epsilon", "zeta" },
    { 1, 1, 2, 2, 2 },
    Bold = { { 0, 6, 10, "beta" }, { 1, 0, 5, "gamma" }, { 2, 0, 5, "delta" }, { 3, 0, 7, "epsilon" } },
  },
  {
    "cross-line Latin link",
    { "alpha [beta gamma", "delta epsilon](/target) zeta" },
    10,
    { "alpha beta", "gamma", "delta", "epsilon", "zeta" },
    { 1, 1, 2, 2, 2 },
    MdRenderLink = { { 0, 6, 10, "beta" }, { 1, 0, 5, "gamma" }, { 2, 0, 5, "delta" }, { 3, 0, 7, "epsilon" } },
    links = {
      { 0, 6, 10, "beta", "/target" },
      { 1, 0, 5, "gamma", "/target" },
      { 2, 0, 5, "delta", "/target" },
      { 3, 0, 7, "epsilon", "/target" },
    },
  },
  {
    "cross-line Latin code",
    { "alpha `beta gamma", "delta epsilon` zeta" },
    10,
    { "alpha beta", "gamma", "delta", "epsilon", "zeta" },
    { 1, 1, 2, 2, 2 },
    MdRenderInlineCode = { { 0, 6, 10, "beta" }, { 1, 0, 5, "gamma" }, { 2, 0, 5, "delta" }, { 3, 0, 7, "epsilon" } },
  },
  {
    "CJK bold in quote continuation",
    { "> 甲乙**丙丁**", "> 戊己庚辛" },
    10,
    { "│ 甲乙丙丁", "│ 戊己庚辛" },
    { 1, 2 },
    Bold = { { 0, 10, 16, "丙丁" } },
  },
  {
    "CJK bold in list continuation",
    { "- 甲乙**丙丁**", "  戊己庚辛" },
    10,
    { "• 甲乙丙丁", "  戊己庚辛" },
    { 1, 2 },
    Bold = { { 0, 10, 16, "丙丁" } },
  },
  {
    "CJK joins do not accumulate source drift",
    { "甲乙**丙丁**", "戊己**庚辛**", "壬癸子丑" },
    8,
    { "甲乙丙丁", "戊己庚辛", "壬癸子丑" },
    { 1, 2, 3 },
    Bold = { { 0, 6, 12, "丙丁" }, { 1, 6, 12, "庚辛" } },
  },
  {
    "hidden destination source does not own visible suffix",
    { "[甲乙](", "/target", ")丙丁戊己" },
    4,
    { "甲乙", "丙丁", "戊己" },
    { 1, 3, 3 },
    MdRenderLink = { { 0, 0, 6, "甲乙" } },
    links = { { 0, 0, 6, "甲乙", "/target" } },
  },
  {
    "two CJK span boundaries retain their separator",
    { "**甲乙丙丁**", "**戊己庚辛**" },
    8,
    { "甲乙丙丁", "戊己庚辛" },
    { 1, 2 },
    Bold = { { 0, 0, 12, "甲乙丙丁" }, { 1, 0, 12, "戊己庚辛" } },
  },
  {
    "soft CJK join before hard break",
    { "甲乙**丙丁**", "戊己庚辛  ", "壬癸子丑" },
    8,
    { "甲乙丙丁", "戊己庚辛", "壬癸子丑" },
    { 1, 2, 3 },
    Bold = { { 0, 6, 12, "丙丁" } },
  },
  {
    "code physical LF counts but entity LF does not",
    { "a&#10;`b", "c`  ", "d" },
    3,
    { "a b", "c", "d" },
    { 1, 2, 3 },
    MdRenderInlineCode = { { 0, 2, 3, "b" }, { 1, 0, 1, "c" } },
  },
  {
    "code physical LF without a hard break",
    { "`ab", "cd`", "efgh" },
    4,
    { "ab", "cd", "efgh" },
    { 1, 2, 3 },
    MdRenderInlineCode = { { 0, 0, 2, "ab" }, { 1, 0, 2, "cd" } },
  },
  {
    "entity LF is inline whitespace within one source row",
    { "ab&#10;cd", "efgh" },
    4,
    { "ab", "cd", "efgh" },
    { 1, 1, 2 },
  },
  {
    "removed cross-line comment has no row of its own",
    { "甲乙丙丁 <!-- hidden", "still hidden -->", "戊己庚辛" },
    8,
    { "甲乙丙丁", "戊己庚辛" },
    { 1, 3 },
  },
  {
    "a blank source ends the paragraph",
    { "甲乙**丙丁**", "   ", "戊己庚辛" },
    8,
    { "甲乙丙丁", "", "戊己庚辛" },
    { 1, 2, 3 },
    Bold = { { 0, 6, 12, "丙丁" } },
  },
  {
    "invalid cross-line destination remains literal",
    { "甲乙[丙丁](foo", "bar)戊己" },
    8,
    { "甲乙[丙", "丁](foo", "bar)戊己" },
    { 1, 1, 2 },
  },
  {
    "HTML image alt belongs to its attribute source",
    { '前 <img data-alt="甲乙丙丁"', 'alt="甲乙丙丁" src="/image.png"> 後' },
    12,
    { "前 󰋩 甲乙丙", "丁後" },
    { 1, 2 },
    MdRenderLink = { { 0, 9, 18, "甲乙丙" }, { 1, 0, 3, "丁" } },
    links = { { 0, 4, 18, "󰋩 甲乙丙", "/image.png" }, { 1, 0, 3, "丁", "/image.png" } },
  },
  {
    "HTML image fallback basename belongs to its src source",
    { '前 <img data-src="/actual/image.png"', 'src="/actual/image.png"> 後' },
    12,
    { "前 󰋩", "image.png 後" },
    { 1, 2 },
    MdRenderLink = { { 1, 0, 9, "image.png" } },
    links = { { 0, 4, 8, "󰋩", "/actual/image.png" }, { 1, 0, 9, "image.png", "/actual/image.png" } },
  },
  {
    "HTML video fallback basename belongs to its nested src source",
    {
      '前 <video data-src="/real/movie.mp4">',
      '<source data-src="/real/movie.mp4"',
      'src="/real/movie.mp4"></video> 後',
    },
    12,
    { "前 󰋩", "movie.mp4 後" },
    { 1, 3 },
    MdRenderLink = { { 1, 0, 9, "movie.mp4" } },
    links = { { 0, 4, 8, "󰋩", "/real/movie.mp4" }, { 1, 0, 9, "movie.mp4", "/real/movie.mp4" } },
  },
  {
    "source base survives lazy quote, hard break and wrapping",
    { "> [甲乙\\", "丙丁](/dest) *tail*", "> next" },
    12,
    { "│ 甲乙", "│ 丙丁 tail", "│ next" },
    { 21, 22, 23 },
    opts = { source_line_offset = 20 },
    Italic = { { 1, 11, 15, "tail" } },
    MdRenderLink = { { 0, 4, 10, "甲乙" }, { 1, 4, 10, "丙丁" } },
    links = { { 0, 4, 10, "甲乙", "/dest" }, { 1, 4, 10, "丙丁", "/dest" } },
  },
  {
    "empty checkbox source consumes LF before visible content",
    { "- [ ]", "  甲乙丙丁", "  戊己庚辛" },
    10,
    { "󰄱  甲乙丙", "   丁戊己", "   庚辛" },
    { 2, 2, 3 },
    marker_hl = "Comment",
    Comment = { { 0, 0, 6, "󰄱  " } },
  },
  {
    "completed checkbox source consumes LF before visible content",
    { "- [x]", "  甲乙丙丁", "  戊己庚辛" },
    10,
    { "󰄲  甲乙丙", "   丁戊己", "   庚辛" },
    { 2, 2, 3 },
    marker_hl = "DiagnosticOk",
    DiagnosticOk = { { 0, 0, 6, "󰄲  " } },
  },
  {
    "hyphen checkbox source consumes LF before visible content",
    { "- [-]", "  甲乙丙丁", "  戊己庚辛" },
    10,
    { "󰡖  甲乙丙", "   丁戊己", "   庚辛" },
    { 2, 2, 3 },
    marker_hl = "DiagnosticWarn",
    DiagnosticWarn = { { 0, 0, 6, "󰡖  " } },
  },
  {
    "paragraph source gaps are relative to its original first row",
    { "甲乙**丙丁**", "戊己庚辛" },
    8,
    { "甲乙丙丁", "戊己庚辛" },
    { 101, 113 },
    source_rows = { 7, 19 },
    source_base = 101,
    Bold = { { 0, 6, 12, "丙丁" } },
  },
  {
    "hidden source gap does not assign its suffix to the destination",
    { "[甲乙](", "/target", ")丙丁戊己" },
    4,
    { "甲乙", "丙丁", "戊己" },
    { 50, 65, 65 },
    source_rows = { 4, 12, 19 },
    source_base = 50,
    MdRenderLink = { { 0, 0, 6, "甲乙" } },
    links = { { 0, 0, 6, "甲乙", "/target" } },
  },
  {
    "unwrapped paragraph first source can contain only hidden syntax",
    { "%%hidden", "%%甲乙" },
    80,
    { "甲乙" },
    { 2 },
    source_rows = { 1, 2 },
    source_base = 1,
  },
}

local style_groups = { "Bold", "Italic", "MdRenderInlineCode", "MdRenderLink" }
local ns = vim.api.nvim_create_namespace "paragraph_line_map_test"
for _, case in ipairs(boundary_cases) do
  local source = vim.deepcopy(case[2])
  local b = ContentBuilder.new()
  if case.source_rows then
    b:set_source_line(case.source_base)
    b:add_markdown_line(table.concat(source, "\n"), "", case[3], nil, nil, nil, nil, case.source_rows)
  else
    b:render_document(
      source,
      vim.tbl_extend("force", { max_width = case[3], indent = "", text_scale = false }, case.opts or {})
    )
  end
  local content = b:result()
  assert_eq(source, case[2], case[1] .. ": original source bytes")
  assert_eq(content.lines, case[4], case[1] .. ": exact rendered rows")
  assert_eq(content.source_line_map, case[5], case[1] .. ": first visible character source")
  local groups = vim.deepcopy(style_groups)
  if case.marker_hl then groups[#groups + 1] = case.marker_hl end
  for _, group in ipairs(groups) do
    assert_eq(style_spans(content, group), case[group] or {}, case[1] .. ": intended " .. group .. " substrings")
  end
  assert_eq(link_spans(content), case.links or {}, case[1] .. ": intended link labels and targets")

  local buf = vim.api.nvim_create_buf(false, true)
  local ok, err = pcall(function()
    display.apply_content_to_buffer(buf, ns, content)
    assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), case[4], case[1] .. ": real buffer rows")
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    for _, group in ipairs(groups) do
      local applied = {}
      for _, mark in ipairs(marks) do
        local _, row, col, details = unpack(mark)
        if details.hl_group == group and not details.url then
          applied[#applied + 1] = { row, col, details.end_col, case[4][row + 1]:sub(col + 1, details.end_col) }
        end
      end
      assert_eq(applied, case[group] or {}, case[1] .. ": real buffer " .. group .. " byte spans")
    end
    for _, link in ipairs(content.link_metadata) do
      assert_eq(Links.at(buf, ns, link.line, link.col_start), link.url, case[1] .. ": first label byte target")
      assert_eq(Links.at(buf, ns, link.line, link.col_end - 1), link.url, case[1] .. ": last label byte target")
    end
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, err)
end

print(string.format("paragraph_line_map_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
