-- Test CommonMark hard line breaks inside paragraphs:
--   * two or more trailing spaces  -> break
--   * trailing backslash           -> break
--   * neither (soft break)         -> lines are joined into one paragraph
-- Run: nvim --headless -u NONE --noplugin -l tests/hard_break_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local ContentBuilder = require("md-render.content_builder").ContentBuilder
local markdown = require "md-render.markdown"
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

--- Render and return the non-blank output lines with the indent stripped.
local function render(lines)
  local b = ContentBuilder.new()
  b:render_document(lines, { max_width = 80, indent = "" })
  local out = {}
  for _, line in ipairs(b:result().lines) do
    if not line:match "^%s*$" then table.insert(out, line) end
  end
  return out
end

-- Test 1: two trailing spaces break the line
do
  local out = render { "半角スペースあり。  ", "あいうえお。" }
  assert_eq(out, { "半角スペースあり。", "あいうえお。" }, "two trailing spaces should break the line")
end

-- Test 2: no trailing spaces = soft break, lines are joined
-- (no space between the two 和字, see the join tests at the bottom)
do
  local out = render { "半角スペースなし。", "かきくけこ。" }
  assert_eq(out, { "半角スペースなし。かきくけこ。" }, "soft break should join into one line")
end

-- Test 3: trailing backslash breaks the line and the marker is not shown
do
  local out = render { "backslash break.\\", "next line." }
  assert_eq(out, { "backslash break.", "next line." }, "trailing backslash should break the line")
end

-- Test 4: a single trailing space is not a hard break
do
  local out = render { "one space ", "joined." }
  assert_eq(out, { "one space joined." }, "single trailing space should not break the line")
end

-- Test 5: hard break in the middle of a longer paragraph
do
  local out = render { "a", "b  ", "c", "d" }
  assert_eq(out, { "a b", "c d" }, "only the hard-broken line should split the paragraph")
end

-- Test 6: inline constructs still span soft-broken lines
do
  local out = render { "see [the", "docs](https://example.com) here" }
  assert_eq(out, { "see the docs here" }, "multi-line link should still be joined")
end

-- Test 7: trailing spaces on the last line of a paragraph are dropped
do
  local out = render { "trailing.  " }
  assert_eq(out, { "trailing." }, "dangling hard break marker should not leave trailing spaces")
end

-- Test 7b: block-level lines already end their own line; the marker is
-- dropped instead of leaving a stray trailing space
do
  local out = render { "> 引用の一行目。  ", "> 引用の二行目。" }
  assert_eq(
    out,
    { "│ 引用の一行目。", "│ 引用の二行目。" },
    "blockquote should not keep the marker spaces"
  )

  out = render { "- リスト項目。  ", "  次の行。" }
  assert_eq(out, { "• リスト項目。", "  次の行。" }, "list item should not keep the marker spaces")
end

-- Soft break joining: a space is inserted only where it is needed.

-- Test 8: 和字 <-> 和字 across a soft break joins with no space
do
  local out = render { "禁則処理を実装しており、", "句読点が行頭に来ることを防ぎます。" }
  assert_eq(
    out,
    { "禁則処理を実装しており、句読点が行頭に来ることを防ぎます。" },
    "wide chars on both sides should join without a space"
  )
end

-- Test 9: 英字 on either side keeps the space
do
  local out = render { "BudouX", "を使います。" }
  assert_eq(out, { "BudouX を使います。" }, "latin before the break should keep the space")

  out = render { "これは", "BudouX です。" }
  assert_eq(out, { "これは BudouX です。" }, "latin after the break should keep the space")
end

-- Test 10: latin <-> latin keeps the space (CommonMark behavior)
do
  local out = render { "one", "two" }
  assert_eq(out, { "one two" }, "latin on both sides should keep the space")
end

-- Test 11: leading whitespace on a continuation line is dropped
do
  local out = render { "indented", "   continuation" }
  assert_eq(out, { "indented continuation" }, "continuation indent should collapse to one space")
end

-- Test 12: lines indented under a list item continue the item's paragraph
do
  local out = render { "- item", "  続きの段落です。", "  さらに続きます。" }
  assert_eq(
    out,
    { "• item 続きの段落です。さらに続きます。" },
    "list continuation lines should join the item's paragraph"
  )

  -- 和字 on both sides of the break: no space is inserted
  out = render { "- これは一行目です。続けてこの", "  行も同じ段落になるはずです。" }
  assert_eq(
    out,
    { "• これは一行目です。続けてこの行も同じ段落になるはずです。" },
    "wide chars across a list continuation should join without a space"
  )

  -- Ordered lists behave the same
  out = render { "1. first line and", "   its continuation." }
  assert_eq(out, { "1. first line and its continuation." }, "ordered list continuation should join")

  -- Lazy continuation: the follow-up line need not be indented
  out = render { "- item", "lazy continuation" }
  assert_eq(out, { "• item lazy continuation" }, "lazy continuation should join the item")

  -- A blank line ends the paragraph: the next one keeps the indent that
  -- aligns it with the item (blank lines are stripped by `render`)
  out = render { "- item", "", "  別の段落です。" }
  assert_eq(out, { "• item", "  別の段落です。" }, "a new paragraph should keep its indent")

  -- A following item starts its own paragraph
  out = render { "- 一つ目", "  の続き", "- 二つ目" }
  assert_eq(out, { "• 一つ目の続き", "• 二つ目" }, "the next item should not be absorbed")

  -- A thematic break is not a list item
  out = render { "- - -", "後続の段落。" }
  assert_eq(out[#out], "後続の段落。", "thematic break should not absorb the next line")
end

-- Test 12b: a blockquote is a container of its own: the lines inside it
-- form paragraphs the same way they do at the top level
do
  local out = render { "> 引用の一行目です。続けてこの", "> 行も同じ段落になるはずです。" }
  assert_eq(
    out,
    { "│ 引用の一行目です。続けてこの行も同じ段落になるはずです。" },
    "quoted lines should join into one paragraph"
  )

  out = render { "> first line and", "> its continuation." }
  assert_eq(out, { "│ first line and its continuation." }, "quoted latin lines should join with a space")

  -- A blank quote line separates paragraphs
  out = render { "> 一つ目の段落。", ">", "> 二つ目の段落。" }
  assert_eq(out[1], "│ 一つ目の段落。", "a blank quote line should end the paragraph")
  assert_eq(out[#out], "│ 二つ目の段落。", "the paragraph after a blank quote line stands alone")

  -- A callout header is not absorbed into the body
  out = render { "> [!NOTE]", "> 注記の一行目です。続けてこの", "> 行も連結されます。" }
  assert_eq(#out, 2, "callout header should stay on its own line")
  assert_eq(
    out[2],
    "│ 注記の一行目です。続けてこの行も連結されます。",
    "callout body should join"
  )

  -- List items inside a quote follow the list rules
  out = render { "> - 項目の一行目", ">   の続き", "> - 二つ目" }
  assert_eq(out, { "│ • 項目の一行目の続き", "│ • 二つ目" }, "quoted list continuation should join")

  -- Nested quotes recurse
  out = render { "> > 内側の一行目。", "> > 内側の続き。" }
  assert_eq(out, { "│ │ 内側の一行目。内側の続き。" }, "nested quote should join at its own level")
end

-- Test 13: half-width katakana is not treated as wide
do
  local out = render { "ｱｲｳ", "ｴｵ" }
  assert_eq(out, { "ｱｲｳ ｴｵ" }, "half-width katakana should keep the space")
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

local function spans(content, group)
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

local function check_buffer(buf, ns, content)
  assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), content.lines, "real buffer contains exact rows")
  for _, row in ipairs(content.highlights) do
    local line = content.lines[row.line + 1]
    for _, hl in ipairs(row.groups) do
      assert(hl.col >= 0 and hl.end_col > hl.col and hl.end_col <= #line, "style has a nonempty byte range")
    end
  end
  for _, link in ipairs(content.link_metadata) do
    assert(
      link.col_start >= 0 and link.col_end > link.col_start and link.col_end <= #content.lines[link.line + 1],
      "link has a nonempty byte range"
    )
    assert_eq(Links.at(buf, ns, link.line, link.col_start), link.url, "first label byte activates exact target")
    assert_eq(Links.at(buf, ns, link.line, link.col_end - 1), link.url, "last label byte activates exact target")
  end
end

local function build(lines, opts)
  local snapshot = vim.deepcopy(lines)
  local b = ContentBuilder.new()
  b:render_document(lines, vim.tbl_extend("force", { max_width = 1000, indent = "", text_scale = false }, opts or {}))
  local content = b:result()
  assert_eq(lines, snapshot, "paragraph processing preserves source bytes")
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "hard_break_test"
  local ok, err = pcall(function()
    display.apply_content_to_buffer(buf, ns, content)
    check_buffer(buf, ns, content)
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, err)
  return content
end

local rich_source = { "*[one two three  ", "four five six](/target)* [Z](/next)" }
local rich_rows = { "one two", "three", "four five", "six Z" }
local rich_italic = { { 0, 0, 7, "one two" }, { 1, 0, 5, "three" }, { 2, 0, 9, "four five" }, { 3, 0, 3, "six" } }
local rich_links = {
  { 0, 0, 7, "one two", "/target" },
  { 1, 0, 5, "three", "/target" },
  { 2, 0, 9, "four five", "/target" },
  { 3, 0, 3, "six", "/target" },
  { 3, 4, 5, "Z", "/next" },
}

-- CommonMark 633-647: an explicit break remains inside the same inline parse.
-- Exact byte spans also check the existing quote/list and CJK presentation.
local cases = {
  {
    "slash followed by one source space is a soft break",
    { "*left\\ ", "right* [旁](<two  spaces.md>)" },
    { "left\\ right 旁" },
    { 1 },
    italic = { { 0, 0, 11, "left\\ right" } },
    links = { { 0, 12, 15, "旁", "two  spaces.md" } },
  },
  {
    "slash followed by a source tab is a soft break",
    { "*left\\\t", "right* [旁](<two  spaces.md>)" },
    { "left\\ right 旁" },
    { 1 },
    italic = { { 0, 0, 11, "left\\ right" } },
    links = { { 0, 12, 15, "旁", "two  spaces.md" } },
  },
  {
    "slash before two source spaces stays literal at a hard break",
    { "*left\\  ", "right* [旁](<two  spaces.md>)" },
    { "left\\", "right 旁" },
    { 1, 2 },
    italic = { { 0, 0, 5, "left\\" }, { 1, 0, 5, "right" } },
    links = { { 1, 6, 9, "旁", "two  spaces.md" } },
  },
  {
    "CM638",
    { "*foo  ", "bar*" },
    { "foo", "bar" },
    { 1, 2 },
    italic = { { 0, 0, 3, "foo" }, { 1, 0, 3, "bar" } },
  },
  {
    "CM639",
    { "*foo\\", "bar*" },
    { "foo", "bar" },
    { 1, 2 },
    italic = { { 0, 0, 3, "foo" }, { 1, 0, 3, "bar" } },
  },
  {
    "nested strong and strike",
    { "**~foo\\", "bar~**" },
    { "foo", "bar" },
    { 1, 2 },
    bold = { { 0, 0, 3, "foo" }, { 1, 0, 3, "bar" } },
    strike = { { 0, 0, 3, "foo" }, { 1, 0, 3, "bar" } },
  },
  {
    "empty mandatory segment",
    { "*[a\\", "\\", "b](/target)*" },
    { "a", "", "b" },
    { 1, 2, 3 },
    italic = { { 0, 0, 1, "a" }, { 2, 0, 1, "b" } },
    links = { { 0, 0, 1, "a", "/target" }, { 2, 0, 1, "b", "/target" } },
  },
  {
    "soft and hard source rows",
    { "*one", "two  ", "three", "four*" },
    { "one two", "three four" },
    { 1, 3 },
    italic = { { 0, 0, 7, "one two" }, { 1, 0, 10, "three four" } },
  },
  {
    "UTF-8 link and neighbor",
    { "*[左方  ", "RIGHT](/target)* [NEXT](/next)" },
    { "左方", "RIGHT NEXT" },
    { 1, 2 },
    italic = { { 0, 0, 6, "左方" }, { 1, 0, 5, "RIGHT" } },
    links = { { 0, 0, 6, "左方", "/target" }, { 1, 0, 5, "RIGHT", "/target" }, { 1, 6, 10, "NEXT", "/next" } },
  },
  {
    "wrapped link with source offset",
    rich_source,
    rich_rows,
    { 21, 21, 22, 22 },
    opts = { max_width = 10, source_line_offset = 20 },
    italic = rich_italic,
    links = rich_links,
  },
  {
    "quote list prefixes",
    { "> - *[foo\\", ">   bar](/target)*" },
    { "│ • foo", "│   bar" },
    { 1, 2 },
    italic = { { 0, 8, 11, "foo" }, { 1, 6, 9, "bar" } },
    links = { { 0, 8, 11, "foo", "/target" }, { 1, 6, 9, "bar", "/target" } },
  },
  {
    "CJK hard break",
    { "*中  ", "文*" },
    { "中", "文" },
    { 1, 2 },
    italic = { { 0, 0, 3, "中" }, { 1, 0, 3, "文" } },
  },
  {
    "code source row accounting",
    { "*before  ", "`a  ", "b`  ", "after*" },
    { "before", "a   b", "after" },
    { 1, 2, 4 },
    italic = { { 0, 0, 6, "before" }, { 1, 0, 5, "a   b" }, { 2, 0, 5, "after" } },
    code = { { 1, 0, 5, "a   b" } },
  },
  {
    "hidden title source row accounting",
    { '*[x](/dest "title\\', 'continued")  ', "bar*" },
    { "x", "bar" },
    { 1, 3 },
    italic = { { 0, 0, 1, "x" }, { 1, 0, 3, "bar" } },
    links = { { 0, 0, 1, "x", "/dest" } },
  },
  {
    "hidden comment source row accounting",
    { "*a<!-- hidden\\", "comment -->b  ", "c*" },
    { "ab", "c" },
    { 1, 3 },
    italic = { { 0, 0, 2, "ab" }, { 1, 0, 1, "c" } },
  },
  {
    "HTML accumulated rows",
    { "<b>*a  ", "b*  ", "c</b>" },
    { "a", "b", "c" },
    { 1, 2, 3 },
    italic = { { 0, 0, 1, "a" }, { 1, 0, 1, "b" } },
    bold = { { 0, 0, 1, "a" }, { 1, 0, 1, "b" }, { 2, 0, 1, "c" } },
  },
  {
    "invalid source destination",
    { "[bad](foo  ", "bar) [ok](/ok)" },
    { "[bad](foo", "bar) ok" },
    { 1, 2 },
    links = { { 1, 5, 7, "ok", "/ok" } },
  },
  { "blank boundary", { "*foo  ", "", "bar*" }, { "*foo", "", "bar*" }, { 1, 2, 3 } },
  { "heading boundary", { "*foo  ", "### bar*" }, { "*foo", "", "### bar*" }, { 1, 2, 2 } },
  {
    "entity LF is inline",
    { "*foo&#10;bar  ", "baz*" },
    { "foo bar", "baz" },
    { 1, 2 },
    italic = { { 0, 0, 7, "foo bar" }, { 1, 0, 3, "baz" } },
  },
  { "entity markers stay literal", { "&#42;foo  ", "bar&#42;" }, { "*foo", "bar*" }, { 1, 2 } },
  {
    "even backslashes are soft",
    { "*foo\\\\", "bar*" },
    { "foo\\ bar" },
    { 1 },
    italic = { { 0, 0, 8, "foo\\ bar" } },
  },
  {
    "odd backslashes are hard",
    { "*foo\\\\\\", "bar*" },
    { "foo\\", "bar" },
    { 1, 2 },
    italic = { { 0, 0, 4, "foo\\" }, { 1, 0, 3, "bar" } },
  },
  { "CM644 terminal backslash", { "foo\\" }, { "foo\\" }, { 1 } },
}

for _, case in ipairs(cases) do
  test(case[1], function()
    local content = build(case[2], case.opts)
    assert_eq(content.lines, case[3], case[1] .. ": exact paragraph rows")
    assert_eq(content.source_line_map, case[4], case[1] .. ": physical source rows")
    assert_eq(spans(content, "Italic"), case.italic or {}, case[1] .. ": exact italic byte ranges")
    assert_eq(spans(content, "Bold"), case.bold or {}, case[1] .. ": exact bold byte ranges")
    assert_eq(spans(content, "DiagnosticDeprecated"), case.strike or {}, case[1] .. ": exact strike byte ranges")
    assert_eq(spans(content, "MdRenderInlineCode"), case.code or {}, case[1] .. ": exact code byte ranges")
    assert_eq(link_spans(content), case.links or {}, case[1] .. ": exact links and visible labels")
  end)
end

test("ninth return separates source breaks from decoded LF and protected code", function()
  local _
  local text, highlights, links, kind, marker, alert, fold, heading, breaks = markdown.render "*[foo  \nbar](/target)*"
  assert_eq(text, "foo bar", "first return remains newline-free")
  assert_eq(highlights, {
    { col = 0, end_col = 7, hl = "MdRenderLink" },
    { col = 0, end_col = 7, hl = "Italic" },
  }, "first eight returns retain the complete inline ranges")
  assert_eq(links, { { col_start = 0, col_end = 7, url = "/target" } }, "direct target is exact")
  assert_eq({ kind, marker, alert, fold, heading }, {}, "paragraph block metadata stays absent")
  assert_eq(breaks, { { col = 3, source_line = 2 } }, "separator byte and following physical source ordinal")
  text, _, _, _, _, _, _, _, breaks = markdown.render("&#10;`a  \nb`  \nc", nil, nil, nil, nil, true)
  assert_eq(text, " a   b c", "entity and code LF remain inline spaces")
  assert_eq(breaks, { { col = 6, source_line = 3 } }, "code LF counts toward source ordinal; entity LF does not")
  text, _, _, kind, _, _, _, _, breaks = markdown.render("# *foo  \nbar*", nil, nil, nil, nil, true)
  assert_eq(text, "# foo bar", "sixth inline-only argument retains block markers")
  assert_eq(kind, nil, "inline-only context does not invent a heading")
  assert_eq(breaks, { { col = 5, source_line = 2 } }, "inline-only hard-break coordinate")
  text, _, _, kind, _, alert, _, _, breaks = markdown.render "> [!NOTE] custom\ncontinued"
  assert_eq(text:find "[\r\n]", nil, "early callout return is also newline-free")
  assert_eq({ kind, alert, breaks }, { "blockquote", "NOTE", {} }, "early callout block metadata remains compatible")
end)

test("reference labels restore source markers before lookup", function()
  for _, case in ipairs { { "foo  ", "foo bar" }, { "foo\\", "foo\\ bar" } } do
    local source = { "*[" .. case[1], "bar]*", "", "[" .. case[2] .. "]: /target" }
    local content = build(source)
    assert_eq(content.lines, { "foo", "bar", "" }, "multiline shortcut label resolves as one link")
    assert_eq(
      link_spans(content),
      { { 0, 0, 3, "foo", "/target" }, { 1, 0, 3, "bar", "/target" } },
      "source label normalization preserves escaped spelling"
    )
  end
end)

test("literal and entity-produced hard-break token lookalikes remain text", function()
  local literal = "\t\u{F100A}1\u{F100B}\t"
  for _, token in ipairs { literal, "&#9;&#987146;1&#987147;&#9;" } do
    local content = build { "*a" .. token .. "  ", "b*" }
    assert_eq(content.lines, { "a" .. literal, "b" }, "token lookalike preserves literal bytes")
    assert_eq(content.source_line_map, { 1, 2 }, "token collision cannot invent or move a source break")
    assert_eq(
      spans(content, "Italic"),
      { { 0, 0, 12, "a" .. literal }, { 1, 0, 1, "b" } },
      "restoration keeps UTF-8 style coordinates"
    )
  end
end)

test("URL ownership distinguishes its slash from a link-label break", function()
  for _, url in ipairs { "https://example.com", "www.example.com" } do
    local target = url:match "^www" and "http://" .. url or url
    local content = build { url .. "\\", "bar" }
    assert_eq(content.lines, { url .. "\\ bar" }, "URL's final slash stays inside its target")
    assert_eq(link_spans(content), { { 0, 0, #url + 1, url .. "\\", target .. "\\" } }, "complete URL target")
    content = build { "[" .. url .. "\\", "bar](/target)" }
    assert_eq(content.lines, { url, "bar" }, "resolved label is ordinary inline content")
    assert_eq(
      link_spans(content),
      { { 0, 0, #url, url, "/target" }, { 1, 0, 3, "bar", "/target" } },
      "resolved label keeps its explicit target on both rows"
    )
    content = build { url .. "  ", "bar" }
    assert_eq(content.lines, { url, "bar" }, "spaces following a URL form a real hard break")
  end
end)

test("wiki and embed targets restore source breaks without leaking placeholders", function()
  local text, _, links, _, _, _, _, _, breaks = markdown.render "[[foo  \nbar|link]]"
  assert_eq(text, "link", "hidden wiki target creates no display separator")
  assert_eq(breaks, {}, "URL restoration cannot create a phantom visible break")
  assert_eq(
    links,
    { { col_start = 0, col_end = 4, url = "obsidian://advanced-uri?filepath=foo  \nbar" } },
    "wiki target retains its original source spelling"
  )
  text, _, links, _, _, _, _, _, breaks = markdown.render "![[foo\\\nbar.md]]"
  assert_eq(text, "📎 foo bar.md", "embed display stays newline-free")
  assert_eq(breaks, { { col = #"📎 foo", source_line = 2 } }, "embed display reports its visible break")
  assert_eq(
    links,
    { { col_start = 0, col_end = #text, url = "obsidian://advanced-uri?filepath=foo\\\nbar.md" } },
    "embed target contains source bytes, never a placeholder"
  )
  local content = build { "[[target|*foo  ", "bar*]]" }
  assert_eq(link_spans(content), {
    { 0, 0, 3, "foo", "obsidian://advanced-uri?filepath=target" },
    { 1, 0, 3, "bar", "obsidian://advanced-uri?filepath=target" },
  }, "wiki alias label distributes the same destination")
end)

test("public preview rebuild and source toggle preserve rows, links and source bytes", function()
  local preview = require "md-render.preview"
  local image = require "md-render.image"
  local source = vim.api.nvim_create_buf(false, true)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, rich_source)
  vim.api.nvim_set_current_buf(source)
  local tick = vim.api.nvim_buf_get_changedtick(source)
  local supports, mouse, osc8, open = image.supports_kitty, display.getmousepos, display.supports_osc8, vim.ui.open
  image.supports_kitty, display.supports_osc8 = function()
    return false
  end, function()
    return false
  end
  local ok, err = pcall(function()
    local function check(session)
      local content = session.content
      assert_eq(content.lines, { "  one two", "  three", "  four five", "  six Z" }, "preview exact wrapped rows")
      assert_eq(content.source_line_map, { 1, 1, 2, 2 }, "preview physical source ownership")
      local italic, links = vim.deepcopy(rich_italic), vim.deepcopy(rich_links)
      for _, span in ipairs(italic) do
        span[2], span[3] = span[2] + 2, span[3] + 2
      end
      for _, span in ipairs(links) do
        span[2], span[3] = span[2] + 2, span[3] + 2
      end
      assert_eq(spans(content, "Italic"), italic, "preview exact italic byte ranges")
      assert_eq(link_spans(content), links, "preview exact link ranges")
      check_buffer(session.buf, session.ns, content)
      local opened = {}
      vim.ui.open = function(url)
        opened[#opened + 1] = url
      end
      local click = vim.fn.maparg("<LeftRelease>", "n", false, true).callback
      for _, link in ipairs(content.link_metadata) do
        display.getmousepos = function()
          return { winid = vim.api.nvim_get_current_win(), line = link.line + 1, column = link.col_start + 1 }
        end
        click()
      end
      assert_eq(opened, { "/target", "/target", "/target", "/target", "/next" }, "public clicks activate exact targets")
      assert_eq(Links.at(session.buf, session.ns, 0, 0), nil, "preview indent is not a link")
      assert_eq(vim.api.nvim_buf_get_changedtick(source), tick, "preview does not modify source changedtick")
    end
    preview.toggle { text_scale = false, max_width = 12 }
    local session = assert(preview._toggle_sessions[source], "preview session exists")
    check(session)
    session:rebuild()
    check(session)
    preview.toggle()
    assert_eq(vim.api.nvim_get_current_buf(), source, "source toggle restores the original buffer")
    preview.toggle { text_scale = false, max_width = 12 }
    check(assert(preview._toggle_sessions[source]))
  end)
  image.supports_kitty, display.getmousepos, display.supports_osc8, vim.ui.open = supports, mouse, osc8, open
  if preview._toggle_sessions[source] then preview.toggle() end
  assert_eq(
    vim.api.nvim_buf_get_lines(source, 0, -1, false),
    rich_source,
    "source bytes remain unchanged after closing"
  )
  assert_eq(vim.api.nvim_buf_get_changedtick(source), tick, "source changedtick remains unchanged after closing")
  vim.api.nvim_buf_delete(source, { force = true })
  assert(ok, err)
end)

print(string.format("\nhard_break_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
