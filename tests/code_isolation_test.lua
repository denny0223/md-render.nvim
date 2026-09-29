-- Fenced code is opaque to document-wide list and reference transformations.
-- Run: nvim --headless -u NONE --noplugin -l tests/code_isolation_test.lua

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

local function build(lines)
  local source = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  local b = ContentBuilder.new()
  b:render_document(vim.api.nvim_buf_get_lines(source, 0, -1, false), {
    max_width = 120,
    indent = "",
    text_scale = false,
  })
  local c = b:result()
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "code_isolation_test"
  display.apply_content_to_buffer(buf, ns, c)
  assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), c.lines, "actual buffer matches rendered text")
  assert_eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), lines, "source buffer stays unchanged")
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.api.nvim_buf_delete(source, { force = true })
  return c, marks
end

-- The original numbered sample and CommonMark 0.31.2 example 212.
do
  local c = build { "```markdown", "1. first", "1. second", "```" }
  assert_eq(c.lines, { "1. first", "1. second" }, "numbered code sample retains both source markers")
  c = build { "```", "[foo]: /url", "```", "", "[foo]" }
  assert_eq(c.lines, { "[foo]: /url", "", "[foo]" }, "unlabelled code keeps definitions literal")
  assert_eq(c.link_metadata, {}, "CommonMark example 212 has no link")
end

-- CommonMark 0.31.2 example 212, alongside real lists and a competing real
-- reference definition. Container display indentation remains intentional.
for _, fence in ipairs { "```", "~~~" } do
  for _, container in ipairs {
    { name = "top level", prefix = "", before = {}, display = "", code_indent = "" },
    { name = "list", prefix = "  ", before = { "- item", "" }, display = "  ", code_indent = "" },
    { name = "quote", prefix = "> ", before = {}, display = "│ ", code_indent = "" },
    { name = "callout", prefix = "> ", before = { "> [!NOTE]" }, display = "│ ", code_indent = "" },
    { name = "quote in list", prefix = "  > ", before = { "- item", "" }, display = "  │ ", code_indent = "" },
    { name = "list in quote", prefix = ">   ", before = { "> - item", ">" }, display = "│ ", code_indent = "  " },
  } do
    local name = fence .. " " .. container.name
    local lines = { "[same]: /outside", "", "1. before", "1. again", "" }
    vim.list_extend(lines, container.before)
    table.insert(lines, container.prefix .. fence .. "lua")
    local code = { "local value = 1", "1. first", "1. second", "[inside]: /inside", "[same]: /inside" }
    local expected_code, source_rows = {}, {}
    for _, line in ipairs(code) do
      table.insert(lines, container.prefix .. line)
      table.insert(source_rows, #lines)
      table.insert(expected_code, container.code_indent .. line)
    end
    table.insert(lines, container.prefix .. fence)
    vim.list_extend(lines, { "", "7. after", "1. next", "", "[inside] [same]" })
    local c, marks = build(lines)
    assert_eq(#c.code_blocks, 1, name .. ": one highlighted code block")
    local block = c.code_blocks[1]
    if block then
      assert_eq(block.source_lines, expected_code, name .. ": source numbers and definitions remain literal")
      local actual_rows, rendered_code, highlighted_rows = {}, {}, {}
      for row = block.start_line, block.end_line do
        table.insert(actual_rows, c.source_line_map[row + 1])
        table.insert(rendered_code, c.lines[row + 1])
        for _, mark in ipairs(marks) do
          if mark[2] == row and mark[4].hl_group == "String" then highlighted_rows[#highlighted_rows + 1] = row end
        end
      end
      assert_eq(actual_rows, source_rows, name .. ": code maps to original source rows")
      assert_eq(
        rendered_code,
        vim.tbl_map(function(line)
          return container.display .. line
        end, expected_code),
        name .. ": display indentation stays unchanged"
      )
      assert_eq(#highlighted_rows, #code, name .. ": actual buffer retains code highlights")
      local lua_keyword
      for _, mark in ipairs(marks) do
        if mark[2] == block.start_line and mark[4].hl_group == "@keyword.lua" then
          lua_keyword = c.lines[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col)
        end
      end
      assert_eq(lua_keyword, "local", name .. ": actual Treesitter highlights stay on the literal Lua token")
    end
    local text = table.concat(c.lines, "\n")
    assert_eq(text:find("1. before\n2. again", 1, true) ~= nil, true, name .. ": preceding list still renumbers")
    assert_eq(text:find("7. after\n8. next", 1, true) ~= nil, true, name .. ": following list starts its own count")
    assert_eq(c.lines[#c.lines], "[inside] same", name .. ": only the real reference resolves")
    local links = {}
    for _, link in ipairs(c.link_metadata) do
      table.insert(links, { link.url, c.lines[link.line + 1]:sub(link.col_start + 1, link.col_end) })
    end
    assert_eq(links, { { "/outside", "same" } }, name .. ": code cannot create or replace outside links")
  end
end

-- An unclosed quote-local fence ends with its container, not the document.
do
  local c = build { "> ```", "> 1. first", "> 1. second", "[outside]: /outside", "", "[outside]" }
  assert_eq(vim.list_slice(c.lines, 1, 2), { "│ 1. first", "│ 1. second" }, "unclosed quoted code stays literal")
  assert_eq(c.lines[#c.lines], "outside", "real reference after the quote still resolves")
  assert_eq(#c.link_metadata, 1, "quote-local fence does not mask outside definitions")
end

-- A mismatched/short/over-indented closing candidate cannot re-enable passes.
for _, candidate in ipairs { "~~~", "```", "```` trailing", "    ````", "\t````" } do
  local c = build { "````lua", candidate, "1. first", "1. second", "[inside]: /inside", "````", "[inside]" }
  assert_eq(c.code_blocks[1].source_lines, {
    candidate,
    "1. first",
    "1. second",
    "[inside]: /inside",
  }, "invalid closing candidate stays literal: " .. candidate)
  assert_eq(c.lines[#c.lines], "[inside]", "invalid closer cannot leak a definition")
  assert_eq(c.link_metadata, {}, "invalid closer cannot create an outside link")
end

for _, case in ipairs {
  { before = { "- item", "" }, prefix = "  ", candidate = "  \t  ````", code_indent = "" },
  { before = { "- item", "" }, prefix = "  > ", candidate = "  > \t````", code_indent = "" },
  { before = { "> - item", ">" }, prefix = ">   ", candidate = ">   \t````", code_indent = "  " },
} do
  local lines = vim.deepcopy(case.before)
  table.insert(lines, case.prefix .. "````lua")
  table.insert(lines, case.candidate)
  table.insert(lines, case.prefix .. "1. first")
  table.insert(lines, case.prefix .. "1. second")
  table.insert(lines, case.prefix .. "[inside]: /inside")
  table.insert(lines, case.prefix .. "````")
  vim.list_extend(lines, { "", "[inside]" })
  local c = build(lines)
  assert_eq(vim.list_slice(c.code_blocks[1].source_lines, 2), {
    case.code_indent .. "1. first",
    case.code_indent .. "1. second",
    case.code_indent .. "[inside]: /inside",
  }, "container-relative tab cannot close the fence early")
  assert_eq(c.lines[#c.lines], "[inside]", "container-relative non-closer cannot leak a definition")
  assert_eq(c.link_metadata, {}, "container-relative non-closer cannot create links")
end

-- Both earlier passes collapse rows. Exclusion must still use source positions.
do
  local c = build {
    "<span>",
    "before",
    "</span>",
    "",
    "joined",
    "paragraph",
    "",
    "```lua",
    "1. first",
    "1. second",
    "[inside]: /inside",
    "```",
    "[inside]",
  }
  local block = c.code_blocks[1]
  assert_eq(
    block.source_lines,
    { "1. first", "1. second", "[inside]: /inside" },
    "collapsed rows cannot shift code ownership"
  )
  assert_eq(
    vim.list_slice(c.source_line_map, block.start_line + 1, block.end_line + 1),
    { 9, 10, 11 },
    "mapping keeps original source rows after collapse"
  )
  assert_eq(c.lines[#c.lines], "[inside]", "reference mask survives earlier HTML collapse")
  assert_eq(c.link_metadata, {}, "no leaked link after earlier HTML and paragraph collapse")
end

-- Comment markers inside code remain literal; hidden fences outside it are inert.
for _, comment in ipairs { { "<!--", "-->" }, { "%%", "%%" } } do
  local c = build {
    comment[1],
    "```",
    comment[2],
    "~~~lua",
    comment[1],
    "1. first",
    "1. second",
    "[inside]: /inside",
    comment[2],
    "~~~",
    "[outside]: /outside",
    "",
    "[inside] [outside]",
  }
  assert_eq(c.code_blocks[1].source_lines, {
    comment[1],
    "1. first",
    "1. second",
    "[inside]: /inside",
    comment[2],
  }, "code content wins over comment delimiters")
  assert_eq(c.lines[#c.lines], "[inside] outside", "hidden fence does not swallow the real definition")
  assert_eq(#c.link_metadata, 1, "only the reference outside comments and code creates a link")
end

-- The reference collector runs before paragraph joining discovers quote-local
-- comments. Definitions and a closing-line suffix there must remain opaque.
for _, comment in ipairs { { "<!--", "-->[literal]: /literal" }, { "%%", "%%" } } do
  local c = build {
    "> " .. comment[1],
    "> ```",
    "> [hidden]: /hidden",
    "> " .. comment[2],
    "> ~~~lua",
    "> 1. first",
    "> 1. second",
    "> [inside]: /inside",
    "> ~~~",
    "",
    "[outside]: /outside",
    "",
    "[hidden] [literal] [inside] [outside]",
  }
  assert_eq(
    c.code_blocks[1].source_lines,
    { "1. first", "1. second", "[inside]: /inside" },
    "quoted comments cannot leak fence state"
  )
  assert_eq(
    c.lines[#c.lines],
    "[hidden] [literal] [inside] outside",
    "quoted literal regions define no outside references"
  )
  assert_eq(#c.link_metadata, 1, "only the definition after the quoted regions creates a link")
  assert_eq(
    c.link_metadata[1] and c.link_metadata[1].url,
    "/outside",
    "real definition after comments and code still resolves"
  )
  if comment[1] == "<!--" then
    assert_eq(c.lines[1], "│ [literal]: /literal", "quoted HTML closing suffix stays literal")
    assert_eq(c.source_line_map[1], 4, "quoted closing suffix retains its source row")
  end
end

-- Math already owns its body: a literal fence there cannot hide later refs.
for _, marker in ipairs { "```", "~~~" } do
  local c = build { "$$", marker, "a", "$$", "[r]: /x", "", "[r]" }
  assert_eq(c.lines, { marker, "a", "", "r" }, "math fence text stays literal and the following reference resolves")
  assert_eq(c.source_line_map, { 2, 3, 6, 7 }, "math fence text and outside reference keep their source rows")
  assert_eq(c.code_blocks, {}, "a fence inside math does not start code")
  assert_eq(#c.link_metadata, 1, "a literal math fence cannot mask the outside definition")
  assert_eq(c.link_metadata[1] and c.link_metadata[1].url, "/x", "outside definition retains its target")
end

do
  local c = build { "> $$", "> ```lua", "> local a = 1", "> ```", "> $$" }
  assert_eq(c.lines, { "│ $$", "│ local a = 1", "│ $$" }, "quoted math delimiters remain ordinary quote text")
  assert_eq(c.code_blocks[1].source_lines, { "local a = 1" }, "quoted literal math markers do not swallow code")
  c = build { "```lua", "$$", "1. first", "1. second", "```", "[r]: /x", "", "[r]" }
  assert_eq(c.code_blocks[1].source_lines, { "$$", "1. first", "1. second" }, "fenced code owns its math-looking text")
  assert_eq(c.lines[#c.lines], "r", "math-looking code cannot mask the following reference")
end

print(string.format("\ncode_isolation_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
