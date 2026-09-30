-- HTML comment blocks end on the closing line; its visible suffix stays literal.
-- Run: nvim --headless -u NONE --noplugin -l tests/html_comment_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

require("md-render.image").supports_kitty = function()
  return false
end
local ContentBuilder = require("md-render.content_builder").ContentBuilder
local display = require "md-render.display_utils"
local pass_count, fail_count = 0, 0

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

local function build(lines, opts)
  local original = vim.deepcopy(lines)
  local b = ContentBuilder.new()
  b:render_document(lines, vim.tbl_extend("force", { max_width = 80, indent = "", text_scale = false }, opts or {}))
  local c = b:result()
  assert_eq(lines, original, "building a preview preserves its source input")
  local buf = vim.api.nvim_create_buf(false, true)
  display.apply_content_to_buffer(buf, vim.api.nvim_create_namespace "html_comment_test", c)
  assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), #c.lines > 0 and c.lines or { "" }, "buffer matches content")
  vim.api.nvim_buf_delete(buf, { force = true })
  return c
end

local function styled_text(content, group)
  local result = {}
  for _, row in ipairs(content.highlights) do
    for _, hl in ipairs(row.groups) do
      if hl.hl == group then
        local line = content.lines[row.line + 1]
        table.insert(result, { row.line + 1, line:sub(hl.col + 1, hl.end_col == -1 and #line or hl.end_col) })
      end
    end
  end
  return result
end

-- CommonMark 0.31.2 example 177, with the same expectation for a later closer.
for _, case in ipairs {
  { { "<!-- foo -->*bar*", "*baz*" }, { 1, 2 } },
  { { "<!-- foo", "hidden", "-->*bar*", "*baz*" }, { 3, 4 } },
} do
  local c = build(case[1])
  assert_eq(c.lines, { "*bar*", "baz" }, "closing-line suffix stays literal; the next paragraph parses inlines")
  assert_eq(c.source_line_map, case[2], "visible suffix and following paragraph keep their original source lines")
  assert_eq(styled_text(c, "Italic"), { { 2, "baz" } }, "only the next paragraph receives emphasis")
end

for _, lines in ipairs {
  { "<!-- foo -->", "*baz*" },
  { "<!-- foo", "hidden", "-->", "*baz*" },
} do
  local c = build(lines)
  assert_eq(c.lines, { "baz" }, "a comment without a visible suffix remains hidden")
  assert_eq(styled_text(c, "Italic"), { { 1, "baz" } }, "control paragraph retains emphasis")
  assert_eq(c.source_line_map, { #lines }, "hidden lines do not change the paragraph's source position")
end

-- Wrapper stripping must expose comment openers consistently in every pass.
for _, tag in ipairs { "div", "span" } do
  local opening, closing = "<" .. tag .. ">", "</" .. tag .. ">"
  local c = build { opening .. "<!-- foo", "hidden", "-->", closing, "*after*" }
  assert_eq(c.lines, { "after" }, "wrapped multiline comment contents stay hidden")
  assert_eq(c.source_line_map, { 5 }, "wrapped comment retains the following source position")
  c = build { opening .. "<!-- foo", "```lua", "-->*tail*", closing, "   > quote", "*after*" }
  assert_eq(c.lines, { "*tail*", "│ quote after" }, "wrapped comment cannot leak fence or container state")
  assert_eq(c.source_line_map, { 3, 5 }, "wrapped suffix and following blocks retain source positions")
  assert_eq(#c.code_blocks, 0, "a fence inside a wrapped comment never becomes code")
  assert_eq(styled_text(c, "Italic"), { { 2, "after" } }, "only following Markdown receives emphasis")
  c = build { opening .. "<!-- foo -->*tail*" .. closing, "*after*" }
  assert_eq(c.lines, { "*tail*", "after" }, "single-line wrapper is removed without parsing the raw suffix")
  c = build { opening .. "<!-- foo", closing .. "-->tail", "*after*" }
  assert_eq(c.lines, { "tail", "after" }, "wrapper-looking comment body cannot hide the closing delimiter")
end

do
  local c = build { "before", "<!-- unclosed", "*hidden*" }
  assert_eq(c.lines, { "before" }, "an unterminated comment hides its remaining contents")
  assert_eq(c.source_line_map, { 1 }, "text preceding an unterminated comment retains its source position")
end

-- Syntax inside a hidden comment must not leak fence/HTML accumulation state.
for _, hidden in ipairs { "```", "<b>" } do
  local c = build { "<!--", hidden, "-->tail", "*next*", "ordinary" }
  assert_eq(c.lines, { "tail", "next ordinary" }, "hidden syntax does not change subsequent paragraph parsing")
  assert_eq(c.source_line_map, { 3, 4 }, "HTML accumulation cannot steal closing/following source lines")
  assert_eq(styled_text(c, "Italic"), { { 2, "next" } }, "following emphasis survives hidden syntax")
end

do
  local c = build { "<!--", "```", "-->tail", "   > quote" }
  assert_eq(c.lines, { "tail", "│ quote" }, "a hidden fence does not disable later container indentation")
  c = build { "<!--", "```", "-->tail", "\tcode" }
  assert_eq(c.lines, { "tail", "code" }, "a hidden fence does not disable later tab expansion")
  assert_eq(styled_text(c, "String"), { { 2, "code" } }, "tab-indented content still becomes an indented code block")
end

-- A comment opening can leave a list; only its hidden body is opaque.
for _, indent in ipairs { "", "  ", "\t", " \t" } do
  for _, comment in ipairs {
    { indent .. "<!-- hidden -->" },
    { indent .. "<!--", indent .. "hidden", indent .. "-->" },
  } do
    local lines = { "- item" }
    vim.list_extend(lines, comment)
    table.insert(lines, "  > quote")
    local c = build(lines)
    local quote_indent = indent == "" and "" or "  "
    assert_eq(
      c.lines,
      { "• item", quote_indent .. "│ quote" },
      "comment opening determines whether the list remains open"
    )
    assert_eq(c.source_line_map, { 1, #lines }, "comment container transition retains following source position")
  end
end

do
  local c = build { "- item", "\t<!-- hidden -->*tail*", "  > quote" }
  assert_eq(
    c.lines,
    { "• item", "  *tail*", "  │ quote" },
    "a tab-indented opener preserves the item's visible suffix"
  )
  c = build { "- item", "  <!--", "\t-->*tail*", "  > quote" }
  assert_eq(
    c.lines,
    { "• item", "  *tail*", "  │ quote" },
    "a tab-indented closer preserves the item's visible suffix"
  )
end

do
  local c = build { "- item", "  <!--", "  - hidden", "    -->", "    > quote" }
  assert_eq(c.lines, { "• item", "  │ quote" }, "list-looking comment contents cannot open a nested item")
  assert_eq(c.source_line_map, { 1, 5 }, "hidden list markers cannot change source mapping")
end

do
  local c = build { "<!-- a -->left<!-- b -->right", "after" }
  assert_eq(c.lines, { "leftright", "after" }, "retain text outside complete comments on the closing line")
  c = build { "<!-- a --><!-- b -->*tail*", "*next*" }
  assert_eq(c.lines, { "*tail*", "next" }, "adjacent complete comments stay hidden without parsing their suffix")
  assert_eq(styled_text(c, "Italic"), { { 2, "next" } }, "only the line following adjacent comments parses Markdown")
end

do
  local c = build { "<!-- foo -->*bar*", "# baz", "[qux](https://example.com)" }
  assert_eq(c.lines[1], "*bar*", "visible suffix is retained before following blocks")
  local headings = styled_text(c, "MdRenderH1")
  assert_eq(#headings, 1, "following heading is not swallowed")
  if headings[1] then assert_eq(c.source_line_map[headings[1][1]], 2, "heading maps to source line 2") end
  assert_eq(#c.link_metadata, 1, "following link is not swallowed")
  if c.link_metadata[1] then
    local link = c.link_metadata[1]
    assert_eq(link.url, "https://example.com", "following link preserves its destination")
    assert_eq(c.lines[link.line + 1]:sub(link.col_start + 1, link.col_end), "qux", "link span covers its label")
    assert_eq(c.source_line_map[link.line + 1], 3, "link maps to source line 3")
  end
end

do
  local c = build { "<!-- foo -->tail", "---", "*next*" }
  assert_eq(c.lines[1], "tail", "a following thematic break does not turn the comment into a Setext heading")
  assert_eq(#styled_text(c, "MdRenderH2"), 0, "comment closing line does not receive heading metadata")
  assert_eq(c.lines[#c.lines], "next", "text after the thematic break remains visible")
end

do
  local c = build { "```html", "<!-- foo -->*bar*", "*baz*", "```", "*after*" }
  assert_eq(c.lines, { "<!-- foo -->*bar*", "*baz*", "after" }, "fenced comments and Markdown stay literal")
  assert_eq(c.code_blocks[1].source_lines, { "<!-- foo -->*bar*", "*baz*" }, "code metadata preserves original content")
end

do
  local c = build({ "<!-- foo -->*literal* words", "*next*" }, { max_width = 10 })
  assert_eq(
    c.lines,
    { "*literal*", "words", "next" },
    "closing-line text uses ordinary wrapping without inline parsing"
  )
  assert_eq(c.source_line_map, { 1, 1, 2 }, "wrapped suffix rows retain their source position")
  assert_eq(styled_text(c, "Italic"), { { 3, "next" } }, "wrapping does not create emphasis in literal suffix")
end

-- The width budget includes display indentation and the details body prefix.
for _, case in ipairs {
  { { "<!-- hidden -->*raw* text" }, "  ", { "  *raw*", "  text" }, { 1, 1 } },
  { { "- item", "  <!-- hidden -->*raw* text" }, "", { "• item", "  *raw*", "  text" }, { 1, 2, 2 } },
  {
    { "<details open>", "<summary>s</summary>", "<!-- hidden -->*raw* text", "</details>" },
    "",
    { "▼ s", "│ *raw*", "│ text" },
    { 2, 3, 3 },
  },
} do
  local c = build(case[1], { max_width = 10, indent = case[2] })
  assert_eq(c.lines, case[3], "literal suffix wraps within its container's remaining width")
  assert_eq(c.source_line_map, case[4], "each wrapped suffix row maps to its closing source line")
  assert_eq(styled_text(c, "Italic"), {}, "wrapped raw suffix never gains emphasis")
  for _, line in ipairs(c.lines) do
    assert_eq(vim.api.nvim_strwidth(line) <= 10, true, "suffix and prefixes fit the display width")
  end
end

do
  local c = build({ "<!-- foo -->tail", "after" }, { max_lines = 1 })
  assert_eq(c.lines, { "tail", "... (truncated)" }, "visible suffix participates in the preview line limit")
end

do
  local c = build { "| h |", "| --- |", "| cell |", "<!-- foo -->tail", "after" }
  local cell_row, tail_row
  for i, line in ipairs(c.lines) do
    if line:find("cell", 1, true) then cell_row = i end
    if line == "tail" then tail_row = i end
  end
  assert_eq(cell_row ~= nil and tail_row ~= nil and cell_row < tail_row, true, "pending table is emitted before suffix")
  if tail_row then assert_eq(c.source_line_map[tail_row], 4, "suffix after a table retains its source line") end
end

for _, open in ipairs { false, true } do
  local c = build {
    open and "<details open>" or "<details>",
    "<summary>summary</summary>",
    "<!-- foo -->tail",
    "</details>",
    "after",
  }
  assert_eq(vim.tbl_contains(c.lines, "│ tail"), open, "literal suffix respects details visibility and body prefix")
  assert_eq(c.lines[#c.lines], "after", "details closing line remains functional after a comment")
end

-- Quote recursion owns comments and literal suffixes; a later paragraph admits lazy text (CommonMark 247).
for _, prefix in ipairs { "> ", "> > " } do
  local bars = prefix:gsub("> ", "│ ")
  for _, body in ipairs { { "<!-- foo -->*bar*" }, { "<!-- foo", "```", "-->*bar*" } } do
    local lines = vim.tbl_map(function(line)
      return prefix .. line
    end, body)
    vim.list_extend(lines, { prefix .. "*baz*", "after" })
    local c = build(lines)
    assert_eq(
      c.lines,
      { bars .. "*bar*", bars .. "baz after" },
      "quoted comments hide their body and retain literal suffixes"
    )
    assert_eq(c.source_line_map, { #body, #body + 1 }, "quoted comment source rows survive recursion")
    assert_eq(styled_text(c, "Italic"), { { 2, "baz" } }, "quoted suffixes do not parse emphasis")
    assert_eq(styled_text(c, "FloatBorder"), { { 1, bars }, { 2, bars } }, "quoted suffix retains its border highlight")
    assert_eq(#c.code_blocks, 0, "hidden quoted fences cannot start code blocks")
  end
end

do
  local c = build { "> <!-- hidden", "> body", "*outside*", "> *new quote*" }
  assert_eq(c.lines, { "outside", "│ new quote" }, "an unterminated comment ends at its quote container boundary")
  assert_eq(c.source_line_map, { 3, 4 }, "leaving a quoted comment keeps following source positions")
  c = build { "- item", "  > <!-- hidden", "  > -->*tail*", "  > *next*" }
  assert_eq(
    c.lines,
    { "• item", "  │ *tail*", "  │ next" },
    "comment suffix retains both list and quote containers"
  )
  c = build { "> - item", ">", ">   <!-- hidden", ">   -->*tail*", ">   *next*", "after" }
  assert_eq(
    c.lines,
    { "│ • item", "│ ", "│   *tail*", "│   next after" },
    "a list inside a quote retains its own comment indentation"
  )
  assert_eq(c.source_line_map, { 1, 2, 4, 5 }, "quote-local list comments preserve source positions")
  c = build({ "> <!-- hidden -->*raw* text", "> *next*" }, { max_width = 10, source_line_offset = 20 })
  assert_eq(c.lines, { "│ *raw*", "│ text", "│ next" }, "wrapped literal suffix repeats the quote prefix")
  assert_eq(c.source_line_map, { 21, 21, 22 }, "wrapped quoted suffix preserves source offset")
  assert_eq(
    styled_text(c, "FloatBorder"),
    { { 1, "│ " }, { 2, "│ " }, { 3, "│ " } },
    "every wrapped quote border is highlighted"
  )
  c = build { "> ```html", "> <!-- foo -->*bar*", "> ```", "> *after*" }
  assert_eq(c.lines, { "│ <!-- foo -->*bar*", "│ after" }, "quoted fenced comment text stays literal code")
  assert_eq(c.code_blocks[1].source_lines, { "<!-- foo -->*bar*" }, "quoted code metadata retains comment-looking text")
end

for _, collapsed in ipairs { false, true } do
  local c = build { "> [!NOTE]" .. (collapsed and "-" or "+"), "> <!-- hidden -->*tail*", "after" }
  assert_eq(vim.tbl_contains(c.lines, "│ *tail*"), not collapsed, "comment suffix respects callout folding")
  assert_eq(c.lines[#c.lines], "after", "comment inside a callout does not swallow following text")
  c = build {
    collapsed and "<details>" or "<details open>",
    "<summary>s</summary>",
    "<!--",
    "</details>",
    "-->*raw*",
    "*visible*",
    "</details>",
    "after",
  }
  assert_eq(
    c.lines,
    collapsed and { "▶ s", "after" } or { "▼ s", "│ *raw*", "│ visible", "after" },
    "a hidden details tag cannot change the enclosing fold state"
  )
end

-- Definition collectors must see comment boundaries, not hidden definitions or fences.
for _, opening in ipairs { "<!--", "<div><!--" } do
  local c = build { opening, "[ref]: https://hidden.example", "[^a]: hidden", "```", "-->tail", "[ref] text[^a]" }
  assert_eq(c.lines, { "tail", "[ref] text[^a]" }, "hidden definitions cannot create links or a footnote section")
  assert_eq(#c.link_metadata, 0, "comment contents never supply a link destination")
  assert_eq(c.source_line_map, { 5, 6 }, "hiding definitions preserves suffix and paragraph source rows")
end

do
  local c = build { "[ref]: https://visible.example", "<!--", "[ref]: https://hidden.example", "-->", "[label][ref]" }
  assert_eq(c.lines, { "label" }, "a visible reference still resolves after a comment")
  assert_eq(
    c.link_metadata[1].url,
    "https://visible.example",
    "hidden definitions cannot replace a visible destination"
  )
  c = build { "<!--", "[^a]: hidden", "```", "-->", "[^a]: visible", "text[^a]" }
  assert_eq(c.lines[1], "text¹", "a visible footnote still resolves after a hidden fence")
  assert_eq(c.lines[#c.lines], "¹ visible", "hidden definitions cannot replace a visible footnote")
  c = build { "[^a]: visible", "  <!-- hidden -->", "  not part of the footnote", "text[^a]" }
  assert_eq(c.lines[#c.lines], "¹ visible", "masked comments end footnote continuation instead of joining across it")
  c = build { "<!--", "[ref]: https://hidden.example", "[^a]: hidden" }
  assert_eq(c.lines, {}, "unterminated comments cannot publish hidden definitions")
  c = build { "<!-- -->[ref]: https://hidden.example", "<!-- -->[^a]: hidden", "[ref] text[^a]" }
  assert_eq(
    c.lines,
    { "[ref]: https://hidden.example", "[^a]: hidden", "[ref] text[^a]" },
    "definition-looking closing suffixes remain literal"
  )
  assert_eq(#c.link_metadata, 0, "literal closing suffixes are not definition sources")
end

-- Existing Obsidian comments and fenced code cannot lend syntax to HTML blocks.
for _, hidden in ipairs { "<!-- unterminated", "```lua", "<b>" } do
  local c = build { "%%", hidden, "%%", "*visible*", "", "[ref]: https://visible.example", "[ref]" }
  assert_eq(c.lines, { "visible", "", "ref" }, "syntax inside an Obsidian comment cannot hide following Markdown")
  assert_eq(c.source_line_map, { 4, 5, 7 }, "leaving an Obsidian comment restores source mapping")
  assert_eq(c.link_metadata[1].url, "https://visible.example", "outside reference definitions remain visible")
  c = build { "%%", hidden, "%%", "[^a]: visible", "text[^a]" }
  assert_eq(c.lines[#c.lines], "¹ visible", "outside footnotes survive hidden syntax in Obsidian comments")
end

do
  local c = build { "<!--", "%%", "-->*raw*", "*visible*" }
  assert_eq(c.lines, { "*raw*", "visible" }, "Obsidian delimiters inside HTML comments stay opaque")
  c = build { "> %%", "> <!-- unterminated", "> %%", "> *visible*", "after" }
  assert_eq(c.lines, { "│ visible after" }, "Obsidian comment boundaries also apply inside quote containers")
  assert_eq(c.source_line_map, { 4 }, "quoted Obsidian comments preserve following source positions")
  c = build { "```text", "%%", "<!--", "%%", "```", "*visible*" }
  assert_eq(c.lines, { "%%", "<!--", "%%", "visible" }, "fenced literals retain both comment syntaxes")
  assert_eq(
    c.code_blocks[1].source_lines,
    { "%%", "<!--", "%%" },
    "comment recognition preserves literal code metadata"
  )
end

print(string.format("\nhtml_comment_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
