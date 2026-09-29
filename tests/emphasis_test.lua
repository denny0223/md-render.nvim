-- CommonMark 0.31.2 delimiter rules and GFM single/double-tilde strikethrough.
-- https://github.com/denny0223/md-render.nvim/issues/18
-- Run: nvim --headless -u NONE --noplugin -l tests/emphasis_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local markdown = require "md-render.markdown"
local Builder = require("md-render.content_builder").ContentBuilder
local display = require "md-render.display_utils"
local Links = require "md-render.links"
local preview = require "md-render.preview"
local image = require "md-render.image"
local checks, failures = 0, 0

local function eq(actual, expected, message)
  checks = checks + 1
  assert(
    vim.deep_equal(actual, expected),
    message .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)
  )
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    failures = failures + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

local groups = { Bold = true, Italic = true, DiagnosticDeprecated = true }
local function sorted(spans)
  table.sort(spans, function(a, b)
    return vim.inspect(a) < vim.inspect(b)
  end)
  return spans
end

local function styles(content)
  local result = {}
  for _, row in ipairs(content.highlights) do
    for _, hl in ipairs(row.groups) do
      if groups[hl.hl] then
        result[#result + 1] =
          { row.line, hl.col, hl.end_col, hl.hl, content.lines[row.line + 1]:sub(hl.col + 1, hl.end_col) }
      end
    end
  end
  return sorted(result)
end

local function check_buffer(buf, ns, content)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), content.lines, "buffer bytes")
  local spans = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local _, row, col, detail = unpack(mark)
    if groups[detail.hl_group] then
      spans[#spans + 1] =
        { row, col, detail.end_col, detail.hl_group, content.lines[row + 1]:sub(col + 1, detail.end_col) }
    end
  end
  eq(sorted(spans), styles(content), "actual style extmarks")
  for row, line in ipairs(content.lines) do
    for col = 0, #line do
      local expected
      for _, link in ipairs(content.link_metadata) do
        if row - 1 == link.line and col >= link.col_start and col < link.col_end then expected = link.url end
      end
      eq(Links.at(buf, ns, row - 1, col), expected, "exact link hit at byte " .. col)
    end
  end
end

local function build(lines, width)
  local source = vim.deepcopy(lines)
  local builder = Builder.new()
  builder:render_document(lines, { max_width = width or 1000, indent = "", text_scale = false })
  local content = builder:result()
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "emphasis_test"
  local ok, err = pcall(function()
    display.apply_content_to_buffer(buf, ns, content)
    check_buffer(buf, ns, content)
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, err)
  eq(lines, source, "builder retains original source")
  return content
end

local function public_preview(lines, width, inspect)
  local source = vim.api.nvim_create_buf(false, true)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(source)
  local ok, err = pcall(function()
    preview.toggle { text_scale = false, max_width = width }
    local session = assert(preview._toggle_sessions[source])
    for step = 1, 2 do
      inspect(session.content)
      check_buffer(session.buf, session.ns, session.content)
      if step == 1 then session:rebuild() end
    end
  end)
  if preview._toggle_sessions[source] then preview.toggle() end
  eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), lines, "preview retains source buffer")
  vim.api.nvim_buf_delete(source, { force = true })
  assert(ok, err)
end

local supports_kitty = image.supports_kitty
image.supports_kitty = function()
  return false
end

-- Ranges below are literal byte offsets in the expected text, independent of parsing.
-- CommonMark examples 351, 352, 382; GFM examples 491, 493.
local cases = {
  { "a * foo bar*", "a * foo bar*" },
  { 'a*"foo"*', 'a*"foo"*' },
  { "__foo bar__", "foo bar", { { 0, 7, "Bold" } } },
  {
    "~~Hi~~ Hello, ~there~ world!",
    "Hi Hello, there world!",
    { { 0, 2, "DiagnosticDeprecated" }, { 10, 15, "DiagnosticDeprecated" } },
  },
  { "This will ~~~not~~~ strike.", "This will ~~~not~~~ strike." },
  {
    "*italic* **bold** ***both***",
    "italic bold both",
    { { 0, 6, "Italic" }, { 7, 11, "Bold" }, { 12, 16, "Bold" }, { 12, 16, "Italic" } },
  },
  { "___both___", "both", { { 0, 4, "Bold" }, { 0, 4, "Italic" } } },
  { "*foo **bar** baz*", "foo bar baz", { { 0, 11, "Italic" }, { 4, 7, "Bold" } } },
  { "**foo*bar**", "foo*bar", { { 0, 7, "Bold" } } },
  { "foo***bar***baz", "foobarbaz", { { 3, 6, "Bold" }, { 3, 6, "Italic" } } },
  { "*foo _bar* baz_", "foo _bar baz_", { { 0, 8, "Italic" } } },
  { "**foo **bar baz**", "**foo bar baz", { { 6, 13, "Bold" } } },
  { "~**foo**~", "foo", { { 0, 3, "Bold" }, { 0, 3, "DiagnosticDeprecated" } } },
  -- GFM core flanking skips adjacent extension markers; ~ retains its own rules.
  { "a*~~foo~~*", "afoo", { { 1, 4, "Italic" }, { 1, 4, "DiagnosticDeprecated" } } },
  { "a**~foo~**", "afoo", { { 1, 4, "Bold" }, { 1, 4, "DiagnosticDeprecated" } } },
  { "a_~~foo~~_", "a_foo_", { { 2, 5, "DiagnosticDeprecated" } } },
  { "a*~ foo~*", "a*~ foo~*" },
  { "a*\\~foo\\~*", "a*~foo~*" },
  { "a*&#126;foo&#126;*", "a*~foo~*" },
  { "a*~~~foo~~~*", "a~~~foo~~~", { { 1, 10, "Italic" } } },
  { "foo_bar_baz foo__bar__baz", "foo_bar_baz foo__bar__baz" },
  { 'a**"foo"**', 'a**"foo"**' },
  { "*foo *", "*foo *" },
  { "a ** foo**", "a ** foo**" },
  { "~foo~~", "~foo~~" },
  { "~~bar~", "~~bar~" },
  { "~ baz~", "~ baz~" },
  { "~end ~", "~end ~" },
  { 'a~"foo"~ ~~~x~~~ ~~~~y~~~~', 'a~"foo"~ ~~~x~~~ ~~~~y~~~~' },
  { "a*\u{A0}b* a**\u{2003}b**", "a*\u{A0}b* a**\u{2003}b**" },
  { "a*「foo」* a*😀bar😀*", "a*「foo」* a*😀bar😀*" },
  { "a*×b*", "a*×b*" },
  { "a*々b*", "a々b", { { 1, 5, "Italic" } } },
  { "\u{200C}_foo_", "\u{200C}_foo_" },
  { "a*\u{2028}b*", "a\u{2028}b", { { 1, 5, "Italic" } } },
  { "пристаням_стремятся_", "пристаням_стремятся_" },
  { "\\*plain* \\_\\_plain__ \\~plain~", "*plain* __plain__ ~plain~" },
  { "`*code* __code__ ~code~`", "*code* __code__ ~code~" },
  { "&#42;plain&#42; &#126;plain&#126;", "*plain* ~plain~" },
  { "&auml;_hi_", "ähi", { { 2, 4, "Italic" } } },
  { "*&#32;x*", " x", { { 0, 2, "Italic" } } },
  { "a*&auml;*", "a*ä*" },
  { "`code`_hi_", "codehi", { { 4, 6, "Italic" } } },
  { "a*`code`*", "a*code*" },
  { [[a*\"foo\"*]], 'a*"foo"*' },
  { "a*<!-- comment -->b*", "a*b*" },
  { "*[foo*](/url)", "*foo*" },
  { "[*foo](/url)*", "*foo*" },
  { "a*[foo](/url)*", "a*foo*" },
  { "*[foo](/url)*", "foo", { { 0, 3, "Italic" } } },
  { "[*foo*](/url)", "foo", { { 0, 3, "Italic" } } },
  { "[a](/url)_hi_", "ahi", { { 1, 3, "Italic" } } },
}

for _, case in ipairs(cases) do
  test(case[1], function()
    local expected_spans = {}
    for _, span in ipairs(case[3] or {}) do
      expected_spans[#expected_spans + 1] = { 0, span[1], span[2], span[3], case[2]:sub(span[1] + 1, span[2]) }
    end
    local text, highlights = markdown.render(case[1])
    eq(text, case[2], "inline text")
    eq(
      styles { lines = { text }, highlights = { { line = 0, groups = highlights } } },
      sorted(expected_spans),
      "inline styles"
    )
    local content = build { case[1] }
    eq(content.lines, { case[2] }, "document text")
    eq(styles(content), sorted(expected_spans), "document styles")
    eq(content.source_line_map, { 1 }, "original source row")
  end)
end

test("official cases and negative paragraph termination survive public rebuild", function()
  local lines, expected = {}, {}
  for i = 1, 5 do
    lines[#lines + 1], expected[#expected + 1] = cases[i][1], "  " .. cases[i][2]
    lines[#lines + 1], expected[#expected + 1] = "", "  "
  end
  -- GFM 492: a blank source row terminates delimiter matching.
  vim.list_extend(lines, { "This ~~has a", "", "new paragraph~~.", "", "a*~~foo~~*" })
  vim.list_extend(expected, { "  This ~~has a", "  ", "  new paragraph~~.", "  ", "  afoo" })
  public_preview(lines, 1000, function(content)
    eq(content.lines, expected, "official preview text")
    eq(
      styles(content),
      sorted {
        { 4, 2, 9, "Bold", "foo bar" },
        { 6, 2, 4, "DiagnosticDeprecated", "Hi" },
        { 6, 12, 17, "DiagnosticDeprecated", "there" },
        { 14, 3, 6, "Italic", "foo" },
        { 14, 3, 6, "DiagnosticDeprecated", "foo" },
      },
      "official preview styles"
    )
    for row = 1, #lines do
      eq(content.source_line_map[row], row, "public source row")
    end
  end)
end)

test("wrapped Unicode links cover exact labels and styles", function()
  local lines = { "[LEFT](/left) __中文__ ~there~ [**RIGHT**](/right)" }
  local function check(content, indent)
    eq(content.lines, { indent .. "LEFT 中文", indent .. "there RIGHT" }, "wrapped rows")
    local offset = #indent
    eq(
      styles(content),
      sorted {
        { 0, offset + 5, offset + 11, "Bold", "中文" },
        { 1, offset, offset + 5, "DiagnosticDeprecated", "there" },
        { 1, offset + 6, offset + 11, "Bold", "RIGHT" },
      },
      "wrapped style bytes"
    )
    eq(content.link_metadata, {
      { line = 0, col_start = offset, col_end = offset + 4, url = "/left" },
      { line = 1, col_start = offset + 6, col_end = offset + 11, url = "/right" },
    }, "adjacent link labels")
    eq(content.source_line_map, { 1, 1 }, "wrapped source row")
  end
  check(build(lines, 12), "")
  public_preview(lines, 14, function(content)
    check(content, "  ")
  end)
end)

test("URL shortening retains source flanking and complete destinations", function()
  local url = "https://example.com/" .. string.rep("a", 60)
  for _, marker in ipairs { "*", "__", "~" } do
    local source = marker .. "<" .. url .. ">" .. marker .. " [右](/right)"
    local content = build { source }
    local label = content.lines[1]:match "^(.-) 右$"
    eq(vim.fn.strdisplaywidth(label), 50, "long URL is shortened")
    eq(content.link_metadata, {
      { line = 0, col_start = #label + 1, col_end = #label + 4, url = "/right" },
      { line = 0, col_start = 0, col_end = #label, url = url },
    }, "shortened and adjacent link bytes")
    eq(
      styles(content),
      { { 0, 0, #label, marker == "*" and "Italic" or marker == "__" and "Bold" or "DiagnosticDeprecated", label } },
      "only displayed URL is styled"
    )
  end
  local literal = build { "a*<" .. url .. ">*" }
  eq(styles(literal), {}, "source angle punctuation prevents emphasis despite displayed URL letters")
  eq(literal.lines[1]:sub(1, 2), "a*", "literal opener")
  eq(literal.lines[1]:sub(-1), "*", "literal closer")
  local bare = build { "**https://example.com**" }
  eq(bare.lines, { "https://example.com" }, "bare URL beside matched markers")
  eq(bare.link_metadata[1].url, "https://example.com", "delimiter tokens never enter URLs")
  eq(styles(bare), { { 0, 0, 19, "Bold", "https://example.com" } }, "bare URL style")
end)

test("reference lookup and inline extensions retain source spelling", function()
  local content = build { "[__label__] ==mark== $x_i$ **A**[^note]", "", "[__label__]: /target", "", "[^note]: note" }
  eq(content.lines[1], "label mark x_i A¹", "reference, highlight, math and footnote text")
  local covered = {}
  for _, hl in ipairs(content.highlights[1].groups) do
    if hl.hl == "MdRenderHighlight" or hl.hl == "MdRenderMath" or hl.hl == "Special" then
      covered[hl.hl] = content.lines[1]:sub(hl.col + 1, hl.end_col)
    end
  end
  eq(covered, { MdRenderHighlight = "mark", MdRenderMath = "x_i", Special = "¹" }, "extension style bytes")
  eq(
    content.link_metadata[1],
    { line = 0, col_start = 16, col_end = 18, url = "#footnote-def-note" },
    "footnote anchor"
  )
  eq(content.link_metadata[2], { line = 0, col_start = 0, col_end = 5, url = "/target" }, "source reference label")
  eq(markdown.render "これは __強調__ です。", "これは強調です。", "CJK marker spaces")
  eq(markdown.render "__あ__ ~い~", "あ い", "adjacent CJK spans stay separated")
  local text, _, links = markdown.render "[[**Page**]] [[Page|__標籤__]]"
  eq(text, "Page 標籤", "Obsidian labels render emphasis")
  eq(links[1].url, "obsidian://advanced-uri?filepath=**Page**", "Obsidian target keeps source markers")
  eq(links[2].url, "obsidian://advanced-uri?filepath=Page", "Obsidian alias keeps target")
  text, _, links = markdown.render "[[**P&auml;ge**]] [[P\\*ge]]"
  eq(text, "Päge P*ge", "Obsidian labels retain entity and escape decoding")
  eq(links[1].url, "obsidian://advanced-uri?filepath=**Päge**", "Obsidian target decodes entities once")
  eq(links[2].url, "obsidian://advanced-uri?filepath=P*ge", "Obsidian target decodes escapes once")
  local highlights
  text, highlights, links = markdown.render "![[**foo**.png|100]]"
  eq(text:sub(-7), "foo.png", "embeds retain filename display rather than the size hint")
  eq(links[1].url, "obsidian://advanced-uri?filepath=**foo**.png", "embed target keeps source markers")
  eq(styles { lines = { text }, highlights = { { line = 0, groups = highlights } } }, {
    { 0, #text - 7, #text - 4, "Bold", "foo" },
  }, "embedded filename emphasis")
end)

image.supports_kitty = supports_kitty
print(string.format("emphasis_test: %d checks, %d failed groups", checks, failures))
if failures > 0 then os.exit(1) end
