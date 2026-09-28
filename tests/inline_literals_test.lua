-- Inline code contracts from CommonMark 0.31.2, examples 14 and 328-349,
-- plus #13's HTML/Obsidian literal and consumer regressions.
-- Run: nvim --headless -u NONE --noplugin -l tests/inline_literals_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local markdown = require "md-render.markdown"
local Builder = require("md-render.content_builder").ContentBuilder
local display = require "md-render.display_utils"
local Links = require "md-render.links"
local image = require "md-render.image"
local preview = require "md-render.preview"
local pass_count, fail_count = 0, 0

local function assert_eq(actual, expected, message)
  if vim.deep_equal(actual, expected) then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. message)
    print("  expected: " .. vim.inspect(expected))
    print("  actual:   " .. vim.inspect(actual))
  end
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
      assert_eq(hl._code_span, nil, "literal provenance stays private")
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
    assert_eq(link._decoded, nil, "destination decode provenance stays private")
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
  assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), content.lines, "actual buffer has exact rendered rows")
  for _, link in ipairs(content.link_metadata) do
    assert_eq(Links.at(buf, ns, link.line, link.col_start), link.url, "link's first byte is clickable")
    assert_eq(Links.at(buf, ns, link.line, link.col_end - 1), link.url, "link's last byte is clickable")
  end
end

local function build(lines, opts)
  local b = Builder.new()
  b:render_document(lines, vim.tbl_extend("force", { max_width = 1000, indent = "", text_scale = false }, opts or {}))
  local content = b:result()
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "inline_literals_test"
  local ok, err = pcall(function()
    display.apply_content_to_buffer(buf, ns, content)
    check_buffer(buf, ns, content)
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert_eq(ok, true, "content applies to a real buffer: " .. tostring(err))
  return content
end

local function public_preview(lines, width, inspect)
  local source = vim.api.nvim_create_buf(false, true)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(source)
  local ok, err = pcall(function()
    preview.toggle { text_scale = false, max_width = width }
    local session = assert(preview._toggle_sessions[source], "preview session missing")
    inspect(session)
  end)
  if preview._toggle_sessions[source] then preview.toggle() end
  assert_eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), lines, "preview leaves source bytes unchanged")
  vim.api.nvim_buf_delete(source, { force = true })
  assert_eq(ok, true, "public preview completes: " .. tostring(err))
end

local supports_kitty = image.supports_kitty
image.supports_kitty = function()
  return false
end

-- Every case has a literal text oracle; code ranges use byte offsets in that text.
-- A missing `code` means the entire result is code; false means no code span.
local cases = {
  { "ordinary code", "`foo`", "foo" },
  { "equal runs", "`` foo ` bar ``", "foo ` bar" },
  { "skip unequal closing runs", "``a`b```c``", "a`b```c" },
  { "literal delimiter runs", "`  ``  `", " `` " },
  { "unmatched runs", "```foo``", "```foo``", code = false },
  { "unmatched then valid span", "`foo``bar``", "`foobar", code = "bar", start = 4 },
  { "escaped opener", "\\`not code`", "`not code`", code = false },
  { "backslash inside code", "`foo\\`bar`", "foo\\bar`", code = "foo\\" },
  { "even backslashes before opener", "\\\\`foo`", "\\foo", code = "foo", start = 1 },
  { "internal spaces", "`foo   bar`", "foo   bar" },
  { "trim single edge spaces", "` foo `", "foo" },
  { "trim one space at each edge", "`  foo  `", " foo " },
  { "leading space only", "` foo`", " foo" },
  { "trailing space only", "`foo `", "foo " },
  { "all spaces", "`   `", "   " },
  { "literal tabs", "`\tfoo\t`", "\tfoo\t" },
  { "nonbreaking spaces", "`\u{A0}foo\u{A0}`", "\u{A0}foo\u{A0}" },
  { "multiline edge spaces", "``\nfoo \n``", "foo " },
  { "multiline internal spaces", "`foo   bar \nbaz`", "foo   bar  baz" },
  { "hard-break spaces inside code", "`code  \nspan`", "code   span" },
  { "hard-break backslash inside code", "`code\\\nspan`", "code\\ span" },
  { "CJK code line ending", "`中\n文`", "中 文" },
  { "HTML comment literal", "`<!-- keep -->`", "<!-- keep -->" },
  { "Obsidian comment literal", "`%% keep %%`", "%% keep %%" },
  { "literal inline syntax", "`**b** [x](/file) &amp; \\_ <i>`", "**b** [x](/file) &amp; \\_ <i>" },
}

for _, case in ipairs(cases) do
  test(case[1], function()
    local input, expected = case[2], case[3]
    local code = case.code == nil and expected or case.code
    local start = case.start or 0
    local function check(content, indent)
      assert_eq(content.lines, { indent .. expected }, case[1] .. ": exact text")
      local expected_code = code and { { 0, #indent + start, #indent + start + #code, code } } or {}
      assert_eq(spans(content, "MdRenderInlineCode"), expected_code, case[1] .. ": exact code range")
      assert_eq(link_spans(content), {}, case[1] .. ": literal syntax creates no link")
    end

    local text, highlights, links = markdown.render(input)
    check({ lines = { text }, highlights = { { line = 0, groups = highlights } }, link_metadata = links }, "")
    local lines = vim.split(input, "\n", { plain = true })
    check(build(lines), "")
    public_preview(lines, 1000, function(session)
      for step = 1, 2 do
        check(session.content, "  ")
        check_buffer(session.buf, session.ns, session.content)
        if step == 1 then session:rebuild() end
      end
    end)
  end)
end

test("literal protection retains normal outside processing", function()
  local literal = "%% keep %%|<!-- keep -->|&amp; **x** \\_"
  local input = "`%% keep %%`%% drop %%|`<!-- keep -->`<!-- drop -->|`&amp; **x** \\_`|&amp;|**B**|[L](/file)"
  local content = build { input }
  assert_eq(content.lines, { literal .. "|&|B|L" }, "comments, entities, emphasis and links still work outside code")
  assert_eq(spans(content, "MdRenderInlineCode"), {
    { 0, 0, #"%% keep %%", "%% keep %%" },
    { 0, #"%% keep %%|", #"%% keep %%|<!-- keep -->", "<!-- keep -->" },
    { 0, #"%% keep %%|<!-- keep -->|", #literal, "&amp; **x** \\_" },
  }, "only valid code spans retain comment and entity syntax")
  assert_eq(spans(content, "Bold"), { { 0, #literal + 3, #literal + 4, "B" } }, "outside bold stays aligned")
  assert_eq(link_spans(content), { { 0, #literal + 5, #literal + 6, "L", "/file" } }, "outside URL stays aligned")
  assert_eq(
    build({ "中文", "下一行" }).lines,
    { "中文下一行" },
    "ordinary CJK soft breaks retain existing joining"
  )
  assert_eq(build({ "one  two" }).lines, { "one two" }, "ordinary prose still collapses display spaces")
end)

test("wrapped paragraphs preserve code spaces and neighboring links", function()
  local lines = { "[LEFT](/left) `a  b` [RIGHT](/right)" }
  local function check(content, indent)
    local offset = #indent
    assert_eq(content.lines, { indent .. "LEFT a  b", indent .. "RIGHT" }, "wrapped rows preserve interior spaces")
    assert_eq(spans(content, "MdRenderInlineCode"), { { 0, offset + 5, offset + 9, "a  b" } }, "wrapped code range")
    assert_eq(link_spans(content), {
      { 0, offset, offset + 4, "LEFT", "/left" },
      { 1, offset, offset + 5, "RIGHT", "/right" },
    }, "wrapped link ranges")
  end
  check(build(lines, { max_width = 12 }), "")
  public_preview(lines, 14, function(session)
    check(session.content, "  ")
    check_buffer(session.buf, session.ns, session.content)
  end)
end)

test("headings and list items keep adjacent link ranges", function()
  local body = "[LEFT](/left) `` foo ` bar `` [中文](/right)"
  for _, context in ipairs { { "## ", "## ", true }, { "- ", "• " } } do
    local content = build({ context[1] .. body }, { max_width = 80 })
    local prefix = context[2]
    local expected = { prefix .. "LEFT foo ` bar 中文" }
    if context[3] then expected[#expected + 1] = string.rep("─", 80) end
    assert_eq(content.lines, expected, "container text retains the plain heading rank and underline")
    assert_eq(
      spans(content, "MdRenderInlineCode"),
      { { 0, #prefix + 5, #prefix + 14, "foo ` bar" } },
      "container code range"
    )
    assert_eq(link_spans(content), {
      { 0, #prefix, #prefix + 4, "LEFT", "/left" },
      { 0, #prefix + 15, #prefix + 21, "中文", "/right" },
    }, "links on both sides of code target complete labels")
  end
end)

test("hard breaks outside matched spans keep their source lines", function()
  local content = build({ "before  ", "`a  ", "b`  ", "after" }, { source_line_offset = 10 })
  assert_eq(content.lines, { "before", "a   b", "after" }, "only the newline inside matched code becomes a space")
  assert_eq(spans(content, "MdRenderInlineCode"), { { 1, 0, 5, "a   b" } }, "code survives between two hard breaks")
  assert_eq(content.source_line_map, { 11, 12, 14 }, "each hard-break chunk keeps its original first source line")

  content = build { "`open  ", "next" }
  assert_eq(content.lines, { "`open", "next" }, "an unmatched opener cannot suppress a hard break")
  assert_eq(spans(content, "MdRenderInlineCode"), {}, "unmatched code is literal")
  assert_eq(content.source_line_map, { 1, 2 }, "unmatched hard-break source map")
  assert_eq(build({ "first\\\\", "next" }).lines, { "first\\ next" }, "an escaped trailing backslash is a soft break")
end)

test("real block boundaries cannot be consumed by code matching", function()
  for _, middle in ipairs {
    { "" },
    { "# H" },
    { "- item" },
    { "```text", "x", "```" },
    { "<!-- hidden -->" },
    { "%%", "hidden", "%%" }, -- Existing Obsidian block-comment extension.
  } do
    local lines = { "`A" }
    vim.list_extend(lines, middle)
    lines[#lines + 1] = "B`"
    local content = build(lines, { max_width = 40 })
    assert_eq(spans(content, "MdRenderInlineCode"), {}, "backticks cannot pair across " .. middle[1])
    assert_eq(content.lines[1], "`A", "the opening backtick remains visible")
    assert_eq(
      table.concat(content.lines, "\n"):find("B`", 1, true) ~= nil,
      true,
      "the closing backtick remains visible"
    )
  end
end)

test("continuation indentation is structural while internal whitespace is literal", function()
  for _, continuation in ipairs { "\tb`", "  b`" } do
    local content = build { "`a", continuation }
    assert_eq(content.lines, { "a b" }, "paragraph continuation indentation is removed before code normalization")
    assert_eq(spans(content, "MdRenderInlineCode"), { { 0, 0, 3, "a b" } }, "continuation code range")
  end
  for _, case in ipairs {
    { { "- `a  ", "  b` [L](/left)" }, "• " },
    { { "> `a  ", "> b` [L](/left)" }, "│ " },
  } do
    local content, prefix = build(case[1]), case[2]
    assert_eq(content.lines, { prefix .. "a   b L" }, "container markers are removed before code normalization")
    assert_eq(
      spans(content, "MdRenderInlineCode"),
      { { 0, #prefix, #prefix + 5, "a   b" } },
      "multiline container code range"
    )
    assert_eq(link_spans(content), { { 0, #prefix + 6, #prefix + 7, "L", "/left" } }, "container's following link")
    assert_eq(content.source_line_map, { 1 }, "multiline container retains its first source line")
  end
end)

test("HTML consumers retain inline code spaces", function()
  local content = build({ "<h2>`a  b`", "[L](/left)</h2>" }, { max_width = 40 })
  assert_eq(content.lines, { "## a  b L", string.rep("─", 40) }, "multiline HTML heading preserves code spaces")
  assert_eq(spans(content, "MdRenderInlineCode"), { { 0, 3, 7, "a  b" } }, "HTML heading code range")
  assert_eq(link_spans(content), { { 0, 8, 9, "L", "/left" } }, "HTML heading link range")

  content = build {
    "<table>",
    "<tr><th>C</th><th>L</th></tr>",
    "<tr><td>`a  b`</td><td>[LEFT](/left)</td></tr>",
    "</table>",
  }
  assert_eq(
    content.lines,
    { "│ C    │ L    │", "│──────│──────│", "│ a  b │ LEFT │" },
    "HTML cells preserve code spaces"
  )
  assert_eq(spans(content, "MdRenderInlineCode"), { { 2, #"│ ", #"│ a  b", "a  b" } }, "HTML cell code range")
  assert_eq(
    link_spans(content),
    { { 2, #"│ a  b │ ", #"│ a  b │ LEFT", "LEFT", "/left" } },
    "HTML cell link range"
  )
end)

test("bare URL truncation measures decoded text without exposing tokens", function()
  local base = "https://example.com/"
  for _, case in ipairs {
    { 28, "\\*", "*", string.rep("a", 28) .. "*" },
    { 29, "\\*", "*", string.rep("a", 29) .. "*" },
    { 30, "\\*", "*", string.rep("a", 29) .. "…" },
    { 27, "&amp;tail", "&tail", string.rep("a", 27) .. "&t…" },
    { 28, "&#x4E2D;", "中", string.rep("a", 28) .. "中" },
    { 29, "&#x4E2D;", "中", string.rep("a", 29) .. "…" },
  } do
    local source = base .. string.rep("a", case[1]) .. case[2]
    local visible = base .. case[4]
    local destination = base .. string.rep("a", case[1]) .. case[3]
    local content = build { source }
    assert_eq(content.lines, { visible }, "URL display cutoff uses decoded text width")
    assert_eq(
      link_spans(content),
      { { 0, 0, #visible, visible, destination } },
      "truncated label targets the complete decoded URL"
    )
  end

  local literal = "\u{F1002}1\u{F1003}"
  local destination = base .. string.rep("a", 28) .. "*"
  public_preview({ "`" .. literal .. "` " .. base .. string.rep("a", 28) .. "\\* `END`" }, 1000, function(session)
    local content, prefix = session.content, "  " .. literal .. " "
    local ending = #prefix + #destination + 1
    assert_eq(content.lines, { prefix .. destination .. " END" }, "literal PUA bytes survive around a bare URL")
    assert_eq(spans(content, "MdRenderInlineCode"), {
      { 0, 2, 2 + #literal, literal },
      { 0, ending, ending + 3, "END" },
    }, "code ranges remain exact before and after a URL")
    assert_eq(
      link_spans(content),
      { { 0, #prefix, #prefix + #destination, destination, destination } },
      "URL next to code retains its full label and destination"
    )
    check_buffer(session.buf, session.ns, content)
  end)
end)

test("code immediately after a bare URL stays outside its link and width budget", function()
  local base, code = "https://example.com/", "中  文"
  for _, padding in ipairs { 1, 40 } do
    local destination = base .. string.rep("a", padding)
    local visible = padding == 1 and destination or (base .. string.rep("a", 29) .. "…")
    local source = { destination .. "`" .. code .. "`" }
    local function check(content, indent)
      local ending = #indent + #visible
      assert_eq(content.lines, { indent .. visible .. code }, "adjacent code is not truncated with its URL")
      assert_eq(
        link_spans(content),
        { { 0, #indent, ending, visible, destination } },
        "the bare URL excludes adjacent literal code"
      )
      assert_eq(
        spans(content, "MdRenderInlineCode"),
        { { 0, ending, ending + #code, code } },
        "complete adjacent code range follows the URL label"
      )
    end
    check(build(source), "")
    public_preview(source, 1000, function(session)
      check(session.content, "  ")
      check_buffer(session.buf, session.ns, session.content)
      assert_eq(Links.at(session.buf, session.ns, 0, 2 + #visible), nil, "the code's first byte is not clickable")
    end)
  end
end)

test("public table expansion preserves code spaces and adjacent URLs", function()
  local lines = {
    "| C | L |",
    "| --- | --- |",
    "| `a  b` | [RIGHT-TARGET-DOCUMENT](/right) |",
    "| long-left | . |",
  }
  public_preview(lines, 25, function(session)
    for step = 1, 3 do
      local content = session.content
      check_buffer(session.buf, session.ns, content)
      local code = spans(content, "MdRenderInlineCode")
      assert_eq(#code, 1, "one complete table code span")
      if code[1] then
        assert_eq(
          code[1],
          { 2, #"  │ ", #"  │ a  b", "a  b" },
          "table preserves exact internal spaces and code range"
        )
      end
      local labels = {}
      for _, link in ipairs(link_spans(content)) do
        labels[#labels + 1] = link[4]
        assert_eq(link[5], "/right", "table link destination")
      end
      assert_eq(table.concat(labels), step == 2 and "RIGHT-TARGET-DOCUMENT" or "RIGHT-TARGE", "table link coverage")
      if step < 3 then
        local region = assert(content.expandable_regions[1], "expandable table missing")
        vim.api.nvim_win_set_cursor(session.win, { region.start_line + 1, 0 })
        assert(vim.fn.maparg("<CR>", "n", false, true).callback)()
        assert_eq(session.expand_state[region.block_id], step == 1, "real Enter mapping toggles table expansion")
      end
    end
  end)
end)

test("raw autolinks keep escapes literal and do not create code spans", function()
  for _, tail in ipairs { [[\`a\`]], [[\*]], [[\&amp;]] } do
    local url = "https://x/" .. tail
    local input = "A <" .. url .. "> Z"
    local text, highlights, links = markdown.render(input)
    assert_eq(text, "A " .. url .. " Z", "raw autolink display is literal")
    assert_eq(highlights, { { col = 2, end_col = 2 + #url, hl = "MdRenderLink" } }, "autolink owns its ticks")
    assert_eq(links, { { col_start = 2, col_end = 2 + #url, url = url } }, "raw autolink destination is literal")
    local content = build { input }
    assert_eq(content.lines, { text }, "autolink applies unchanged to the buffer")
    assert_eq(spans(content, "MdRenderInlineCode"), {}, "autolink does not produce inline code")
  end
end)

image.supports_kitty = supports_kitty
print(string.format("inline_literals_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
