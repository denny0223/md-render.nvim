-- Test fenced code blocks that carry an indent, i.e. the ones nested under
-- a list item.  The fence must still be recognised (not collapsed into a
-- paragraph), the content keeps the item's indent, and the code_blocks entry
-- must point at the dedented source so treesitter highlights line up.
-- Run: nvim --headless -u NONE --noplugin -l tests/code_fence_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local ContentBuilder = require("md-render.content_builder").ContentBuilder
local display = require "md-render.display_utils"
require("md-render.image").supports_kitty = function()
  return false
end

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

local function build(lines, opts)
  local b = ContentBuilder.new()
  b:render_document(lines, vim.tbl_extend("force", { max_width = 80, indent = "", text_scale = false }, opts or {}))
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
  local content = build(case.lines, case.opts)
  assert_eq(case.lines, before, case.name .. ": source stays unchanged")
  assert_eq(#content.code_blocks, 1, case.name .. ": one code block")
  local block = content.code_blocks[1]
  if block then
    assert_eq(block.source_lines, case.code, case.name .. ": literal code content")
    assert_eq(block.prefix_len, case.prefix, case.name .. ": highlighting prefix")
    if case.display then
      assert_eq(
        content.lines[block.start_line + 1],
        case.display .. case.code[1],
        case.name .. ": code prefix geometry"
      )
    end
    local source_rows = {}
    for row = block.start_line, block.end_line do
      table.insert(source_rows, content.source_line_map[row + 1])
    end
    assert_eq(source_rows, case.sources, case.name .. ": code source rows")
  end
  if case.after then assert_eq(content.lines[#content.lines], "after", case.name .. ": final fence closes") end
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "code_fence_test"
  local ok, err = pcall(display.apply_content_to_buffer, buf, ns, content)
  assert_eq(ok, true, case.name .. ": buffer application " .. tostring(err or ""))
  if ok then
    local rows = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert_eq(rows, content.lines, case.name .. ": buffer text")
    if block then
      local payload, strings, keywords, captures = {}, {}, {}, {}
      for row = block.start_line, block.end_line do
        payload[#payload + 1] = rows[row + 1]:sub(block.prefix_len + 1)
      end
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
        local group = mark[4].hl_group
        if case.captures and case.captures[group] and mark[2] >= block.start_line and mark[2] <= block.end_line then
          captures[group] = captures[group] or {}
          table.insert(captures[group], rows[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col))
        end
        if mark[2] >= block.start_line and mark[2] <= block.end_line and mark[4].hl_group == "String" then
          strings[#strings + 1] = rows[mark[2] + 1]:sub(math.max(mark[3], block.prefix_len) + 1, mark[4].end_col)
        elseif mark[2] >= block.start_line and mark[2] <= block.end_line and mark[4].hl_group == "@keyword.lua" then
          keywords[#keywords + 1] = rows[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col)
        end
      end
      assert_eq(payload, case.code, case.name .. ": buffer payload excludes the declared display prefix")
      assert_eq(strings, case.code, case.name .. ": actual String spans retain the literal payload")
      if case.keyword then
        assert_eq(keywords, { "local" }, case.name .. ": Treesitter keyword stays on literal bytes")
      end
      if case.captures then assert_eq(captures, case.captures, case.name .. ": actual Treesitter payload spans") end
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  return content
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
    name = "published quoted opener dedent",
    lines = { ">  ```lua", ">   x", "> ```" },
    code = { " x" },
    prefix = 4,
    sources = { 2 },
  },
  {
    name = "quote container plus opener indent",
    lines = { ">  ```lua", "> x", ">     ```", "> y", "> ```", "after" },
    code = { "x", "   ```", "y" },
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
    code = { "x", "    ```", "y" },
    prefix = 8,
    sources = { 4, 5, 6 },
    after = true,
  },
  {
    name = "quoted list rejects a tab reaching four extra columns",
    lines = { "> - item", ">", ">   ```lua", ">   x", ">   \t```", ">   y", ">   ```", "after" },
    code = { "x", "\t```", "y" },
    prefix = 6,
    sources = { 4, 5, 6 },
    after = true,
  },
  {
    name = "closing line keeps its own quote origin",
    lines = { "   > - item", ">", "   >   ```lua", "   >   x", ">   \t```", "   >   y", "   >   ```", "after" },
    code = { "x", "\t```", "y" },
    prefix = 6,
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
    code = { "x", "\t```", "y" },
    prefix = 10,
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

-- Details paint their body prefix before quote-code metadata is finalized.
-- Root and same-row list quotes must account for those UTF-8 bytes at every exit.
for _, details in ipairs { false, true } do
  for _, list in ipairs { false, true } do
    for _, callout in ipairs { false, true } do
      for _, ending in ipairs { "closed", "dedented", "eof" } do
        local lines = details and { "<details open>", "<summary>Code</summary>", "" } or {}
        local marker, margin = list and "- " or "", list and "  " or ""
        if callout then lines[#lines + 1] = marker .. "> [!NOTE]+ Code" end
        lines[#lines + 1] = (callout and margin or marker) .. "> ```lua"
        local payload_source = #lines + 1
        lines[#lines + 1] = margin .. "> local x = 1"
        if ending == "closed" then lines[#lines + 1] = margin .. "> ```" end
        if ending ~= "eof" then lines[#lines + 1] = marker .. "after" end
        local tail_source = #lines
        if details and ending ~= "eof" then vim.list_extend(lines, { "", "</details>" }) end
        local source = vim.api.nvim_create_buf(false, true)
        local previous = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
        vim.api.nvim_set_current_buf(source)
        local tick = vim.api.nvim_buf_get_changedtick(source)
        local name = string.format("quote details=%s list=%s callout=%s %s", details, list, callout, ending)
        local content = assert_code_case {
          name = name,
          lines = lines,
          opts = { indent = "  " },
          code = { "local x = 1" },
          display = "  " .. (details and "│ " or "") .. margin .. "│ ",
          prefix = 2 + #margin + #"│ " + (details and #"│ " or 0),
          sources = { payload_source },
          captures = { ["@keyword.lua"] = { "local" }, ["@variable.lua"] = { "x" }, ["@number.lua"] = { "1" } },
        }
        if ending ~= "eof" then
          local tail = "  " .. (details and "│ " or "") .. (list and "• " or "") .. "after"
          local tail_row = vim.fn.index(content.lines, tail) + 1
          assert_eq(tail_row > 0, true, name .. ": exit preserves the following sibling geometry")
          assert_eq(content.source_line_map[tail_row], tail_source, name .. ": following sibling physical row")
        end
        assert_eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), lines, name .. ": source buffer stays unchanged")
        assert_eq(vim.api.nvim_buf_get_changedtick(source), tick, name .. ": source changedtick stays unchanged")
        if vim.api.nvim_buf_is_valid(previous) then vim.api.nvim_set_current_buf(previous) end
        vim.api.nvim_buf_delete(source, { force = true })
      end
    end
  end
end

-- Opening indentation is removed after the owning quote/list container.
-- Less/equal/more-indented payload and blank rows use the same literal rule.
for _, context in ipairs {
  { name = "quote", before = {}, prefix = "> ", display = "│ ", after = { "after" } },
  { name = "callout", before = { "> [!NOTE]+ Code" }, prefix = "> ", display = "│ ", after = { "after" } },
  { name = "nested quote", before = {}, prefix = "> > ", display = "│ │ ", after = { "after" } },
  { name = "quote in bullet", before = { "- item", "" }, prefix = "  > ", display = "  │ ", after = { "after" } },
  {
    name = "quote in wide list",
    before = { "10. item", "" },
    prefix = "    > ",
    display = "    │ ",
    after = { "after" },
  },
  {
    name = "list in quote",
    before = { "> 10. item", ">" },
    prefix = ">     ",
    display = "│     ",
    after = { "after" },
  },
  { name = "Qiita note", before = { ":::note" }, prefix = "", display = "│ ", after = { ":::", "after" } },
} do
  for opener = 0, 3 do
    for payload_indent = 0, 5 do
      local lines = vim.deepcopy(context.before)
      local space = string.rep(" ", payload_indent)
      lines[#lines + 1] = context.prefix .. string.rep(" ", opener) .. "```lua"
      local first = #lines + 1
      vim.list_extend(lines, {
        context.prefix .. space .. "local x = '甲'",
        context.prefix .. space,
        context.prefix .. space,
        context.prefix .. space .. "*literal*",
        context.prefix .. "```",
      })
      vim.list_extend(lines, context.after)
      local retained = string.rep(" ", math.max(0, payload_indent - opener))
      assert_code_case {
        name = context.name .. ": opener " .. opener .. ", payload " .. payload_indent,
        lines = lines,
        code = { retained .. "local x = '甲'", retained, retained, retained .. "*literal*" },
        prefix = #context.display,
        sources = { first, first + 1, first + 2, first + 3 },
        keyword = true,
        after = true,
      }
    end
  end
end

-- At physical column two, a tab consumes two columns. Remove only the
-- opening indent; keep untouched tabs and the remainder of a consumed tab.
for opener, expected in pairs {
  [0] = { "\tx", "\t", "\t\tx" },
  [1] = { " x", " ", " \tx" },
  [2] = { "x", "", "\tx" },
  [3] = { "x", "", "   x" },
} do
  assert_code_case {
    name = "quoted tabs after opener indent " .. opener,
    lines = { "> " .. string.rep(" ", opener) .. "```lua", "> \tx", "> \t", "> \t\tx", "> ```", "after" },
    code = expected,
    prefix = #"│ ",
    sources = { 2, 3, 4 },
    after = true,
  }
end

-- CommonMark 0.31.2 examples 131/132/133/136 already have correct root
-- payloads. Their opening-indent display margin is intentional, not payload.
-- https://spec.commonmark.org/0.31.2/#fenced-code-blocks (CC BY-SA 4.0)
for _, case in ipairs {
  { name = "CM131", lines = { " ```", " aaa", "aaa", "```" }, code = { "aaa", "aaa" }, margin = 1, sources = { 2, 3 } },
  {
    name = "CM132",
    lines = { "  ```", "aaa", "  aaa", "aaa", "  ```" },
    code = { "aaa", "aaa", "aaa" },
    margin = 2,
    sources = { 2, 3, 4 },
  },
  {
    name = "CM133",
    lines = { "   ```", "   aaa", "    aaa", "  aaa", "   ```" },
    code = { "aaa", " aaa", "aaa" },
    margin = 3,
    sources = { 2, 3, 4 },
  },
  { name = "CM136", lines = { "   ```", "aaa", "  ```" }, code = { "aaa" }, margin = 3, sources = { 2 } },
} do
  local c = build(case.lines)
  assert_eq(
    c.lines,
    vim.tbl_map(function(line)
      return string.rep(" ", case.margin) .. line
    end, case.code),
    case.name .. ": accepted root display margin remains"
  )
  assert_eq(c.source_line_map, case.sources, case.name .. ": original root source rows remain")
  local labelled = vim.deepcopy(case.lines)
  labelled[1] = labelled[1] .. "lua"
  assert_code_case {
    name = case.name .. " labelled payload control",
    lines = labelled,
    code = case.code,
    prefix = case.margin,
    sources = case.sources,
  }
end

-- A real callout preview retains payload, source rows and byte ranges through
-- narrow rendering, expansion, folding, source recovery and rebuilds.
do
  local preview = require "md-render.preview"
  local url = "https://example.invalid/a?x=1&y=2"
  local source_lines = {
    "- item",
    "",
    "  > [!NOTE]+ Code",
    "  >  ```lua:sample.lua",
    "  >   local msg = '甲'",
    "  >   prefix " .. url,
    "  > \t \t",
    "  >",
    "  >",
    "  >   [bad]: /bad",
    "  > ```",
    "after [bad]",
  }
  local payload = { " local msg = '甲'", " prefix " .. url, "    \t", "", "", " [bad]: /bad" }
  local narrow = vim.deepcopy(payload)
  narrow[2] = " prefix https://exa…"
  local source = vim.api.nvim_create_buf(false, true)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, source_lines)
  vim.api.nvim_set_current_buf(source)
  local tick = vim.api.nvim_buf_get_changedtick(source)
  local open, getmousepos, osc8 = vim.ui.open, vim.fn.getmousepos, display.supports_osc8
  local opened = {}
  vim.ui.open = function(target)
    opened[#opened + 1] = target
  end
  display.supports_osc8 = function()
    return false
  end
  local original_win, equalalways = vim.api.nvim_get_current_win(), vim.o.equalalways
  local split, session
  local ok, err = pcall(function()
    vim.o.equalalways = false
    vim.cmd "vsplit"
    split = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(split, 28)
    preview.toggle { text_scale = false }
    session = assert(preview._toggle_sessions[source])
    assert_eq(vim.api.nvim_win_get_width(session.win), 28, "quoted code preview uses a real narrow window")
    assert_eq(session.opts.max_width, 28, "quoted code automatically uses the narrow window width")
    local function check(expected)
      local c = session.content
      local block = assert(c.code_blocks[1])
      assert_eq(block.language, "lua", "public quoted fence preserves its info language")
      assert_eq(block.prefix_len, #"    │ ", "public quoted fence declares only its owning display prefix")
      assert_eq(block.source_lines, payload, "public quoted fence retains exact dedented source payload")
      local rows, body, keyword, code_url = {}, {}, nil, nil
      for row = block.start_line, block.end_line do
        rows[#rows + 1] = c.source_line_map[row + 1]
        body[#body + 1] = c.lines[row + 1]:sub(block.prefix_len + 1)
      end
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(session.buf, session.ns, 0, -1, { details = true })) do
        if mark[4].hl_group == "@keyword.lua" then keyword = c.lines[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col) end
        if mark[4].url then code_url = { mark[4].url, c.lines[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col) } end
      end
      assert_eq(
        rows,
        { 5, 6, 7, 8, 9, 10 },
        "public quoted payload maps each literal and blank row to its physical source"
      )
      assert_eq(body, expected, "public buffer payload excludes its declared quote/list prefix")
      assert_eq(
        vim.api.nvim_buf_get_lines(session.buf, 0, -1, false),
        c.lines,
        "public quoted code applies physical buffer rows"
      )
      assert_eq(keyword, "local", "public quoted Treesitter range covers the literal keyword")
      assert_eq(
        code_url,
        { url, expected == narrow and "https://exa" or url },
        "public quoted URL range keeps the full target"
      )
      assert_eq(
        c.lines[#c.lines],
        "  after [bad]",
        "quoted fence closes before the following block without defining a reference"
      )
      local filename_source
      for row, line in ipairs(c.lines) do
        if line:match "sample%.lua$" then filename_source = c.source_line_map[row] end
      end
      assert_eq(filename_source, 4, "quoted filename header retains the opener's original source row")
      return block
    end
    for step = 1, 2 do
      local block = check(narrow)
      local link = session.content.link_metadata[1]
      assert_eq({ link.col_start, link.col_end }, { 16, 27 }, "narrow quoted link has exact visible UTF-8 byte columns")
      vim.fn.getmousepos = function()
        return { winid = session.win, line = block.start_line + 2, column = link.col_start + 1 }
      end
      vim.fn.maparg("<LeftRelease>", "n", false, true).callback()
      if step == 1 then session:rebuild() end
    end
    vim.api.nvim_win_set_width(session.win, 60)
    session:resize(session.win)
    session:rebuild()
    assert_eq(vim.api.nvim_win_get_width(session.win), 60, "quoted code preview actually widens")
    assert_eq(session.opts.max_width, 60, "quoted code render width follows window widening")
    check(payload)
    vim.api.nvim_win_set_width(session.win, 28)
    session:resize(session.win)
    session:rebuild()
    assert_eq(vim.api.nvim_win_get_width(session.win), 28, "quoted code preview returns to the narrow window")
    assert_eq(session.opts.max_width, 28, "quoted code render width follows window narrowing")
    check(narrow)
    local block = session.content.code_blocks[1]
    vim.api.nvim_win_set_cursor(0, { block.start_line + 2, block.prefix_len })
    vim.fn.maparg("<CR>", "n", false, true).callback()
    check(payload)
    assert_eq(vim.wo[session.win].wrap, false, "expanded quoted code uses the existing horizontal display policy")
    vim.fn.maparg("<CR>", "n", false, true).callback()
    check(narrow)
    local fold = session.content.callout_folds[1]
    assert_eq({ fold.source_line, fold.collapsed }, { 3, false }, "quoted code retains the expanded callout fold")
    vim.api.nvim_win_set_cursor(0, { fold.header_line + 1, 0 })
    vim.fn.maparg("za", "n", false, true).callback()
    assert_eq(session.content.callout_folds[1].collapsed, true, "public fold hides the callout body")
    assert_eq(session.content.code_blocks, {}, "folded callout emits no code body")
    assert_eq(session.content.link_metadata, {}, "folded code exposes no URL activation")
    vim.fn.maparg("za", "n", false, true).callback()
    block = check(narrow)
    vim.api.nvim_win_set_cursor(0, { block.start_line + 4, 0 })
    preview.toggle()
    assert_eq(vim.api.nvim_get_current_buf(), source, "quoted code toggle restores the original source buffer")
    assert_eq(vim.api.nvim_win_get_cursor(0)[1], 8, "quoted code toggle restores the mapped physical blank row")
    preview.toggle()
    check(narrow)
    preview.toggle()
  end)
  if session then session:dispose() end
  if split and vim.api.nvim_win_is_valid(split) then vim.api.nvim_win_close(split, true) end
  if vim.api.nvim_win_is_valid(original_win) then vim.api.nvim_set_current_win(original_win) end
  vim.o.equalalways = equalalways
  vim.ui.open, vim.fn.getmousepos, display.supports_osc8 = open, getmousepos, osc8
  assert_eq(opened, { url, url }, "public quoted code activation retains the full target across rebuild")
  assert_eq(
    vim.api.nvim_buf_get_lines(source, 0, -1, false),
    source_lines,
    "public quoted preview preserves source bytes"
  )
  assert_eq(vim.api.nvim_buf_get_changedtick(source), tick, "public quoted preview preserves source changedtick")
  vim.api.nvim_buf_delete(source, { force = true })
  assert(ok, err)
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
