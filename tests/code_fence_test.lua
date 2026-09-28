-- Test fenced code blocks that carry an indent, i.e. the ones nested under
-- a list item.  The fence must still be recognised (not collapsed into a
-- paragraph), the content keeps the item's indent, and the code_blocks entry
-- must point at the dedented source so treesitter highlights line up.
-- Run: nvim --headless -u NONE --noplugin -l tests/code_fence_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local ContentBuilder = require("md-render.content_builder").ContentBuilder

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

local function build(lines)
  local b = ContentBuilder.new()
  b:render_document(lines, { max_width = 80, indent = "" })
  return b:result()
end

--- Rendered lines with the blank ones dropped.
local function render(lines)
  local out = {}
  for _, line in ipairs(build(lines).lines) do
    if not line:match "^%s*$" then table.insert(out, line) end
  end
  return out
end

-- Test 1: a fence indented under a bullet renders as a code block
do
  local out = render { "- item", "", "  ```lua", "  local x = 1", "  ```", "", "- next" }
  assert_eq(out, { "• item", "  local x = 1", "• next" }, "indented fence should render as code")
end

-- Test 2: the code block metadata is dedented and offset by the indent
do
  local content = build { "- item", "", "  ```lua", "  local x = 1", "    local y = 2", "  ```" }
  assert_eq(#content.code_blocks, 1, "one code block should be recorded")
  local block = content.code_blocks[1]
  assert_eq(block.language, "lua", "language should come from the info string")
  assert_eq(block.prefix_len, 2, "prefix_len should cover the fence indent")
  assert_eq(block.source_lines, { "local x = 1", "  local y = 2" }, "source should be dedented by the fence indent")
end

-- Test 3: relative indentation inside the block is preserved on screen
do
  local out = render { "1. 手順です。", "", "   ```sh", "   echo hi", "     echo deeper", "   ```" }
  assert_eq(
    out,
    { "1. 手順です。", "   echo hi", "     echo deeper" },
    "inner indentation should survive the dedent/re-indent"
  )
end

-- Test 4: an unindented fence is unaffected
do
  local content = build { "```lua", "local x = 1", "```" }
  assert_eq(content.lines, { "local x = 1" }, "top-level fence should render as before")
  assert_eq(content.code_blocks[1].prefix_len, 0, "top-level fence has no prefix")
  assert_eq(content.code_blocks[1].source_lines, { "local x = 1" }, "top-level source is untouched")
end

-- Test 5: the lang:filename form works with an indent too
do
  local out = render { "- item", "", "  ```lua:init.lua", "  local x = 1", "  ```" }
  assert_eq(#out, 3, "filename header should be rendered above the code")
  assert_eq(out[2]:match "init%.lua$" ~= nil, true, "filename header should be present")
  assert_eq(out[3], "  local x = 1", "code line keeps the item's indent")
end

--- Languages of the recorded code blocks, in order.
local function langs(lines)
  local out = {}
  for _, cb in ipairs(build(lines).code_blocks) do
    table.insert(out, cb.language)
  end
  return out
end

-- Test 6: spaces between the fence and the info string (GFM example 113)
do
  assert_eq(render { "``` bash", "echo hi", "```" }, { "echo hi" }, "``` bash should render as code")
  assert_eq(langs { "``` bash", "echo hi", "```" }, { "bash" }, "language after a space should be recorded")
  assert_eq(
    langs { "~~~~    ruby startline=3 $%@#$", "def foo(x)", "~~~~~~~" },
    { "ruby" },
    "only the first word of the info string is the language"
  )
end

-- Test 7: tilde fences (GFM examples 90, 111)
do
  assert_eq(render { "~~~bash", "echo hi", "~~~" }, { "echo hi" }, "~~~ fence should render as code")
  assert_eq(langs { "~~~bash", "echo hi", "~~~" }, { "bash" }, "~~~ fence should record its language")
  assert_eq(
    render({ "foo", "---", "~~~", "bar", "~~~", "# baz" })[3],
    "bar",
    "a ~~~ block after a setext heading should render as code"
  )
end

-- Test 8: only a matching fence closes the block (GFM examples 92-95, 107, 109, 117)
do
  assert_eq(render { "```", "aaa", "~~~", "```" }, { "aaa", "~~~" }, "~~~ does not close a ``` block")
  assert_eq(render { "~~~", "aaa", "```", "~~~" }, { "aaa", "```" }, "``` does not close a ~~~ block")
  assert_eq(render { "````", "aaa", "```", "``````" }, { "aaa", "```" }, "a shorter fence does not close")
  assert_eq(render { "~~~~~~", "aaa", "~~~ ~~" }, { "aaa", "~~~ ~~" }, "a fence with trailing text does not close")
  assert_eq(render { "```", "``` aaa", "```" }, { "``` aaa" }, "an info string does not close")
  assert_eq(render { "```", "aaa", "    ```" }, { "aaa", "    ```" }, "a fence indented four columns is content")
end

-- Test 9: a backtick fence's info string may not contain a backtick (GFM examples 115-116)
do
  assert_eq(#build({ "``` aa ```", "foo" }).code_blocks, 0, "``` aa ``` is an inline code span")
  assert_eq(langs { "~~~ aa ``` ~~~", "foo", "~~~" }, { "aa" }, "a tilde fence may carry backticks")
end

-- Test 10: the same forms work inside blockquotes and callouts
do
  assert_eq(langs { "> ``` bash", "> echo hi", "> ```" }, { "bash" }, "``` bash inside a blockquote")
  assert_eq(langs { "> [!NOTE]", "> ~~~bash", "> echo hi", "> ~~~" }, { "bash" }, "~~~ inside a callout")
  local out = render { "> ````", "> ```", "> ````" }
  assert_eq(out[#out], "│ ```", "a shorter fence inside a blockquote is content")
end

-- Test 11: a tilde block nested in a list keeps the item's indent
do
  local out = render { "- item", "", "  ~~~sh", "  echo hi", "  ~~~", "", "  after" }
  assert_eq(out, { "• item", "  echo hi", "  after" }, "~~~ nested in a list keeps the item's indent")
end

-- A fence ends a footnote definition; later indented code cannot continue it.
do
  local defs = require("md-render.markdown").parse_footnotes {
    "[^n]: note",
    "```lua",
    "print(1)",
    "```",
    "    unrelated code",
  }
  assert_eq(defs, { { label = "n", text = "note" } }, "a fence terminates the preceding footnote")
end

-- Fence indentation is relative to its container, not its opening delimiter.
-- Exercise the full rendering path, including the buffer API and source rows.
local function assert_code_case(case)
  local before = vim.deepcopy(case.lines)
  local content = build(case.lines)
  assert_eq(case.lines, before, case.name .. ": source stays unchanged")
  assert_eq(#content.code_blocks, 1, case.name .. ": one code block")
  local block = content.code_blocks[1]
  if block then
    assert_eq(block.source_lines, case.code, case.name .. ": literal code content")
    assert_eq(block.prefix_len, case.prefix, case.name .. ": highlighting prefix")
    local source_rows = {}
    for row = block.start_line, block.end_line do
      table.insert(source_rows, content.source_line_map[row + 1])
    end
    assert_eq(source_rows, case.sources, case.name .. ": code source rows")
  end
  if case.after then assert_eq(content.lines[#content.lines], "after", case.name .. ": final fence closes") end
  local buf = vim.api.nvim_create_buf(false, true)
  local ok, err = pcall(
    require("md-render.display_utils").apply_content_to_buffer,
    buf,
    vim.api.nvim_create_namespace "code_fence_test",
    content
  )
  assert_eq(ok, true, case.name .. ": buffer application " .. tostring(err or ""))
  if ok then assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), content.lines, case.name .. ": buffer text") end
  vim.api.nvim_buf_delete(buf, { force = true })
end

for _, case in ipairs {
  {
    name = "top-level indented opener",
    lines = { " ```lua", " x", "    ```", " y", " ```" },
    code = { "x", "   ```", "y" },
    prefix = 1,
    sources = { 2, 3, 4 },
  },
  {
    name = "top-level tab non-closer",
    lines = { "```lua", "x", "\t```", "y", "```" },
    code = { "x", "\t```", "y" },
    prefix = 0,
    sources = { 2, 3, 4 },
  },
  {
    name = "bullet container plus opener indent",
    lines = { "- item", "", "   ```lua", "   x", "      ```", "   y", "  ```", "after" },
    code = { "x", "   ```", "y" },
    prefix = 3,
    sources = { 4, 5, 6 },
    after = true,
  },
  {
    name = "wide ordered container plus opener indent",
    lines = { "10. item", "", "     ```lua", "     x", "        ```", "     y", "    ```", "after" },
    code = { "x", "   ```", "y" },
    prefix = 5,
    sources = { 4, 5, 6 },
    after = true,
  },
  {
    name = "tab stop after list prefix",
    lines = { "- item", "", "  ```lua", "  x", "  \t```", "after" },
    code = { "x" },
    prefix = 2,
    sources = { 4 },
    after = true,
  },
  {
    name = "tab partially consumed by list prefix",
    lines = { "- item", "", "  ```lua", "\tx", "\t```", "after" },
    code = { "  x" },
    prefix = 2,
    sources = { 4 },
    after = true,
  },
  {
    name = "tab non-closer retains literal payload",
    lines = { "- item", "", "  ```lua", "  x", "  \t  ```", "  y", "  ```", "after" },
    code = { "x", "\t  ```", "y" },
    prefix = 2,
    sources = { 4, 5, 6 },
    after = true,
  },
  {
    name = "quote container plus opener indent",
    lines = { ">  ```lua", "> x", ">     ```", "> y", "> ```", "after" },
    code = { "x", "    ```", "y" },
    prefix = 4,
    sources = { 2, 3, 4 },
    after = true,
  },
  {
    name = "tab stop after quote prefix",
    lines = { "> ```lua", "> x", "> \t```", "after" },
    code = { "x" },
    prefix = 4,
    sources = { 2 },
    after = true,
  },
  {
    name = "tab partially consumed by quote prefix",
    lines = { ">```lua", ">\tx", ">\t```", "after" },
    code = { "  x" },
    prefix = 4,
    sources = { 2 },
    after = true,
  },
  {
    name = "quote inside list keeps absolute tab origin",
    lines = { "- item", "", "  > ```lua", "  > x", "  > \t```", "  > y", "  > ```", "after" },
    code = { "x", "\t```", "y" },
    prefix = 6,
    sources = { 4, 5, 6 },
    after = true,
  },
  {
    name = "wide list inside quote retains its container",
    lines = { "> 10. item", ">", ">     ```lua", ">     x", ">         ```", ">     y", ">     ```", "after" },
    code = { "    x", "        ```", "    y" },
    prefix = 4,
    sources = { 4, 5, 6 },
    after = true,
  },
  {
    name = "quoted list rejects a tab reaching four extra columns",
    lines = { "> - item", ">", ">   ```lua", ">   x", ">   \t```", ">   y", ">   ```", "after" },
    code = { "  x", "  \t```", "  y" },
    prefix = 4,
    sources = { 4, 5, 6 },
    after = true,
  },
  {
    name = "closing line keeps its own quote origin",
    lines = { "   > - item", ">", "   >   ```lua", "   >   x", ">   \t```", "   >   y", "   >   ```", "after" },
    code = { "  x", "  \t```", "  y" },
    prefix = 4,
    sources = { 4, 5, 6 },
    after = true,
  },
  {
    name = "tab after ordered marker defines its container",
    lines = { "10.\titem", "", "    ```lua", "    x", "    ```", "after" },
    code = { "x" },
    prefix = 4,
    sources = { 4 },
    after = true,
  },
  {
    name = "quoted ordered marker tab uses the quote origin",
    lines = { "> 10.\titem", ">", ">       ```lua", ">       x", ">       \t```", ">       y", ">       ```", "after" },
    code = { "      x", "      \t```", "      y" },
    prefix = 4,
    sources = { 4, 5, 6 },
    after = true,
  },
  {
    name = "synthetic Qiita quote does not shift tab stops",
    lines = { ":::note", "```lua", "x", "\t```", "y", "```", ":::", "after" },
    code = { "x", "\t```", "y" },
    prefix = 4,
    sources = { 3, 4, 5 },
    after = true,
  },
  {
    name = "indented quote keeps absolute tab origin",
    lines = { "   > ```lua", "   > x", "   > \t```", "after" },
    code = { "x" },
    prefix = 4,
    sources = { 2 },
    after = true,
  },
} do
  assert_code_case(case)
end

local fence = require "md-render.fence"
for count = 0, 4 do
  assert_eq(
    fence.closes(string.rep(" ", count) .. "```", fence.opening " ```lua"),
    count < 4,
    "closing fence at column " .. count
  )
end
assert_eq(fence.closes("\t```", fence.opening "```lua"), false, "tab at column zero reaches four")
assert_eq(fence.opening "\t```lua", nil, "a top-level tab-indented fence is indented code")

print(string.format("\ncode_fence_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
