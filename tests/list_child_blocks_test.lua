-- Same-row accepted list children: CommonMark 0.31.2 examples 298, 299, 300, 318.
-- https://spec.commonmark.org/0.31.2/#list-items; issue #33.
-- Run: NVIM_LOG_FILE=/tmp/compat-lists-nvim.log nvim --headless -u NONE --noplugin -l tests/list_child_blocks_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.env.TMUX, vim.env.TMUX_PANE = nil, nil
local Builder = require("md-render.content_builder").ContentBuilder
local display = require "md-render.display_utils"
local Links = require "md-render.links"
local image = require "md-render.image"
image.supports_kitty = function()
  return false
end
local passed, failed = 0, 0
local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name .. ": " .. tostring(err))
  end
end
local function applied(content, fn)
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "list_child_blocks_test"
  local ok, result = pcall(function()
    display.apply_content_to_buffer(buf, ns, content)
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), content.lines, "actual buffer text")
    local spans = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
      local row, start, details = mark[2], mark[3], mark[4]
      local last = details.end_col or start
      assert(start >= 0 and last >= start and last <= #content.lines[row + 1], "actual highlight byte bounds")
      if details.hl_group then
        spans[#spans + 1] = {
          row,
          content.source_line_map[row + 1],
          start,
          last,
          details.hl_group,
          content.lines[row + 1]:sub(start + 1, last),
        }
      end
    end
    for _, link in ipairs(content.link_metadata) do
      eq(Links.at(buf, ns, link.line, link.col_start), link.url, "first label byte has full target")
      eq(Links.at(buf, ns, link.line, link.col_end - 1), link.url, "last label byte has full target")
      eq(Links.at(buf, ns, link.line, link.col_end), nil, "byte after label has no target")
    end
    return fn and fn(spans) or spans
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, result)
  return result
end
local function build(source, opts)
  local original = vim.deepcopy(source)
  local b = Builder.new()
  b:render_document(source, vim.tbl_extend("force", { max_width = 24, indent = "", text_scale = false }, opts or {}))
  eq(source, original, "source array bytes unchanged")
  local c = b:result()
  return c, applied(c)
end
local function style(spans, group)
  local result = {}
  for _, span in ipairs(spans) do
    if span[5] == group then result[#result + 1] = { span[1], span[2], span[3], span[4], span[6] } end
  end
  return result
end
local function targets(c)
  return vim.tbl_map(function(link)
    return { c.source_line_map[link.line + 1], c.lines[link.line + 1]:sub(link.col_start + 1, link.col_end), link.url }
  end, c.link_metadata)
end
local function heading_ranks(spans)
  local result, by_row = {}, {}
  for _, span in ipairs(spans) do
    local rank = span[5]:match "^MdRenderH([1-6])$"
    if rank then
      local entry = by_row[span[1]]
      if entry then
        entry[4] = entry[4] .. span[6]
      else
        entry = { span[1], span[2], tonumber(rank), span[6] }
        result[#result + 1], by_row[span[1]] = entry, entry
      end
    end
  end
  return result
end

test("CM298/299 same-row list chains retain nesting and independent counters", function()
  local c, spans = build { "- - [葉](/leaf)", "  - inner", "- outer" }
  eq(c.lines, { "• ", "  ◦ 葉", "  ◦ inner", "• outer" }, "nested bullet order and indentation")
  eq(c.source_line_map, { 1, 1, 2, 3 }, "two accepted decorations share one physical row")
  eq(
    style(spans, "Special"),
    { { 0, 1, 0, 4, "• " }, { 1, 1, 0, 6, "  ◦ " }, { 2, 2, 0, 6, "  ◦ " }, { 3, 3, 0, 4, "• " } },
    "actual nested marker spans"
  )
  eq(targets(c), { { 1, "葉", "/leaf" } }, "CJK child link")
  c, spans = build { "1. - 2. [葉](/leaf)", "     9. next", "9. outer" }
  eq(c.lines, { "1. ", "   ◦ ", "     2. 葉", "     3. next", "2. outer" }, "inner 2→3 and outer 1→2")
  eq(c.source_line_map, { 1, 1, 1, 2, 3 }, "three same-row accepted levels")
  eq(style(spans, "Special"), {
    { 0, 1, 0, 3, "1. " },
    { 1, 1, 0, 7, "   ◦ " },
    { 2, 1, 0, 8, "     2. " },
    { 3, 2, 0, 8, "     3. " },
    { 4, 3, 0, 3, "2. " },
  }, "each marker owns only its intended bytes")
  c = build({ "- - - child" }, { max_lines = 1 })
  eq(c.lines, { "• ", "... (truncated)" }, "same-row decorations obey the line budget")
end)

test("CM300 ATX and Setext item headings retain ranks, anchors and inline bytes", function()
  local c, spans = build { "- # [Foo](/head)", "- Bar", "  ---", "  baz" }
  eq(c.lines, {
    "• ",
    "  ",
    "  # Foo",
    "  " .. string.rep("═", 22),
    "• ",
    "  ",
    "  ## Bar",
    "  " .. string.rep("─", 22),
    "  baz",
  }, "item heading layout")
  eq(c.source_line_map, { 1, 1, 1, 1, 2, 2, 2, 2, 4 }, "heading and rules retain title source")
  eq(heading_ranks(spans), { { 2, 1, 1, "# Foo" }, { 6, 2, 2, "## Bar" } }, "actual H1/H2 spans")
  eq(c.heading_anchors, { foo = 2, bar = 6 }, "anchors point at headings after decorations")
  eq(targets(c), { { 1, "Foo", "/head" } }, "heading link retains full target")
  c, spans = build { "> - > - **標題** [子](/title)", ">   >   ===", ">   >   body", "> - tail" }
  eq(c.lines[4], "│   │   # 標題 子", "repeated quote/list peeling exposes Setext paragraph")
  eq(heading_ranks(spans), { { 3, 1, 1, "# 標題 子" } }, "nested Setext H1")
  eq(style(spans, "Bold"), { { 3, 1, 14, 20, "標題" } }, "nested heading bold UTF-8 range")
  eq(targets(c), { { 1, "子", "/title" } }, "nested heading link")
  eq(c.heading_anchors["標題-子"], 3, "nested heading anchor")
  for _, source in ipairs { { "- Bar", "---", "- tail" }, { "- Bar", "- ---", "- tail" } } do
    c, spans = build(source)
    eq(heading_ranks(spans), {}, "underline in another owner cannot steal the item paragraph")
    eq(c.heading_anchors, {}, "dedented and sibling underlines have no heading anchor")
  end
end)

test("multiline item Setext titles close only their accepted paragraph owner", function()
  for _, case in ipairs {
    { "", "  ", "• ", "  ", 2, 5, 22 },
    { "> ", ">   ", "│ • ", "", 2, 9, 20 },
    { "> - > ", ">   >   ", "│   │ • ", "", 3, 15, 16 },
  } do
    local first = case[1] .. "- **標題**"
    local tail = case[1] == "" and "- tail" or "> - tail"
    local source = { first, case[2] .. "[子](/title)", case[2] .. "---", case[2] .. "body", tail }
    local c, spans = build(source)
    local heading = case[1] == "" and "  ## 標題 子"
      or case[1] == "> " and "│   ## 標題 子"
      or "│   │   ## 標題 子"
    local prefix = heading:sub(1, heading:find("##", 1, true) - 1)
    local expected = {
      case[3],
      case[4],
      heading,
      prefix .. string.rep("─", case[7]),
      prefix .. "body",
      tail == "- tail" and "• tail" or "│ • tail",
    }
    local rows = { 1, 1, 1, 1, 4, 5 }
    if case[1] == "> - > " then
      table.insert(expected, 1, "│ • ")
      table.insert(rows, 1, 1)
    end
    eq(c.lines, expected, "multiline item title and following paragraph")
    eq(c.source_line_map, rows, "joined title/decorations keep first physical title row")
    eq(heading_ranks(spans), { { case[5], 1, 2, "## 標題 子" } }, "multiline item H2 rank")
    eq(style(spans, "Bold"), { { case[5], 1, case[6], case[6] + 6, "標題" } }, "multiline heading CJK style bytes")
    eq(targets(c), { { 1, "子", "/title" } }, "multiline heading full link target")
    eq(c.heading_anchors["標題-子"], case[5], "multiline anchor points at title")
  end
  for _, source in ipairs {
    { "- Foo", "bar", "  ---", "- tail" },
    { "> - Foo", "> bar", ">   ---", "> - tail" },
  } do
    local c = build(source)
    eq(c.heading_anchors["foo-bar"], 2, "a lazy text row retains its accepted paragraph owner")
    eq(c.source_line_map[3], 1, "lazy title is owned by its first physical row")
  end
  for _, source in ipairs {
    { "- Foo", "  bar", "---", "- tail" },
    { "- Foo", "  bar", "", "  ---", "- tail" },
    { "- Foo", "  bar", "- ---", "- tail" },
    { "- Foo", "14. text", "  ---", "- tail" },
    { "- Foo", "-", "  ---", "- tail" },
    { "- Foo", "  bar", "      ---", "- tail" },
    { "-     Foo", "      bar", "      ---", "- tail" },
    { "> - Foo", ">   bar", ">", ">   ---", "> - tail" },
    { "> - Foo", ">   bar", "> - ---", "> - tail" },
    { "> -     Foo", ">       bar", ">       ---", "> - tail" },
  } do
    local c, spans = build(source)
    eq(c.heading_anchors, {}, "blank/dedent/sibling/literal owners clear the candidate")
    eq(heading_ranks(spans), {}, "rejected underline cannot create a heading span")
  end
end)

test("CM318 fenced children preserve every literal payload row and sibling", function()
  for _, lang in ipairs { "", "lua" } do
    local c, spans = build { "- a", "- ```" .. lang, "  b", "", "", "  ```", "- c" }
    eq(c.lines, { "• a", "• ", "  b", "  ", "  ", "• c" }, "fence child and both blank rows")
    eq(c.source_line_map, { 1, 2, 3, 4, 5, 7 }, "code blanks preserve physical rows 4/5")
    eq(
      style(spans, "String"),
      { { 2, 3, 0, 3, "  b" }, { 3, 4, 0, 2, "  " }, { 4, 5, 0, 2, "  " } },
      "literal ownership"
    )
    if lang ~= "" then
      eq(
        c.code_blocks,
        { { language = "lua", start_line = 2, end_line = 4, prefix_len = 2, source_lines = { "b", "", "" } } },
        "exact fenced metadata payload"
      )
    end
  end
  local c, spans = build { "- ```lua", "  [r]: /evil", "- [tail](/ok)", "", "[r]" }
  eq(c.lines, { "• ", "  [r]: /evil", "• tail", "", "[r]" }, "dedent closes code before sibling")
  eq(c.source_line_map, { 1, 2, 3, 4, 5 }, "dedent source map")
  eq(c.code_blocks[1].source_lines, { "[r]: /evil" }, "dedent finishes only the literal owner")
  eq(targets(c), { { 3, "tail", "/ok" } }, "code-owned definition is unavailable outside")
  eq(heading_ranks(spans), {}, "code owns heading-looking content")
  c = build { "-\t```lua", "\t\ttext", "\t```", "- tail" }
  eq(c.lines, { "• ", "    \ttext", "• tail" }, "structural tab uses four columns; internal tab stays literal")
  eq(c.source_line_map, { 1, 2, 4 }, "tab fence source map")
  eq(c.code_blocks[1].source_lines, { "\ttext" }, "tab payload is not expanded")
  eq(c.code_blocks[1].prefix_len, 4, "tab content column is declared display margin")
  c = build { "- ```lua", "  b" }
  eq(
    c.code_blocks,
    { { language = "lua", start_line = 1, end_line = 1, prefix_len = 2, source_lines = { "b" } } },
    "EOF finalizes accepted item fence"
  )
  for _, owner in ipairs { "<!-- literal -->", "<h1>literal</h1>" } do
    c, spans = build { "123. ```lua", "     b", "    " .. owner, "    - code", "", "end" }
    eq(c.lines, { "123. ", "     b", owner, "- code", "", "end" }, "old fence ends before new root code classification")
    eq(c.source_line_map, { 1, 2, 3, 4, 5, 6 }, "new root literal first row survives")
    eq(c.code_blocks[1].source_lines, { "b" }, "new owner cannot enter old fenced payload")
    eq(heading_ranks(spans), {}, "new root code cannot become an HTML heading")
    eq(style(spans, "Special"), { { 0, 1, 0, 5, "123. " } }, "new literal code markers receive no list style")
  end
  c = build({ "- ```lua", "  abcdefghijklmnopqrstuvwxyz" }, { max_width = 12 })
  eq(c.code_blocks[1].source_lines, { "abcdefghijklmnopqrstuvwxyz" }, "EOF truncation keeps complete payload")
  eq(c.expandable_regions[1].block_id, 1, "EOF truncation keeps the accepted opener's expansion id")
end)

test("indented item children own literal definitions, comments and markers", function()
  local c, spans =
    build { "-     [r]: /evil", "      <!-- keep -->", "", "", "      - literal", "- [tail](/ok)", "", "[r]" }
  eq(
    c.lines,
    { "• ", "  [r]: /evil", "  <!-- keep -->", "  ", "  ", "  - literal", "• tail", "", "[r]" },
    "literal child payload and confirmed interior blanks"
  )
  eq(c.source_line_map, { 1, 1, 2, 3, 4, 5, 6, 7, 8 }, "literal child physical source ownership")
  eq(
    style(spans, "Special"),
    { { 0, 1, 0, 4, "• " }, { 6, 6, 0, 4, "• " } },
    "literal marker receives no Special style"
  )
  eq(targets(c), { { 6, "tail", "/ok" } }, "literal definitions do not create outside links")
  c, spans =
    build { "> -     [r]: /evil", ">       <!-- keep -->", ">", ">", ">       - literal", "> - [tail](/ok)", "", "[r]" }
  eq(c.lines, {
    "│ • ",
    "│   [r]: /evil",
    "│   <!-- keep -->",
    "│   ",
    "│   ",
    "│   - literal",
    "│ • tail",
    "",
    "[r]",
  }, "quoted literal children dedent their code and restore their owner")
  eq(c.source_line_map, { 1, 1, 2, 3, 4, 5, 6, 7, 8 }, "quoted interior blanks remain distinct")
  eq(targets(c), { { 6, "tail", "/ok" } }, "quoted literal definition is unavailable")
  eq(heading_ranks(spans), {}, "literal child has no heading rank")
end)

test("quote/list composition preserves border order and repeated child discovery", function()
  local cases = {
    {
      { "- > # [子](/head)", "  > body", "- tail" },
      { "• ", "  ", "  │ # 子", "  │ " .. string.rep("═", 20), "  │ body", "• tail" },
      { 1, 1, 1, 1, 2, 3 },
      2,
    },
    {
      { "> - # [子](/head)", ">   body", "> - tail" },
      { "│ • ", "", "│   # 子", "│   " .. string.rep("═", 20), "│   body", "│ • tail" },
      { 1, 1, 1, 1, 2, 3 },
      2,
    },
    {
      { "> - > # H", ">   > [子](/a)", "> - tail" },
      { "│ • ", "", "│   │ # H", "│   │ " .. string.rep("═", 18), "│   │ 子", "│ • tail" },
      { 1, 1, 1, 1, 2, 3 },
      2,
    },
    {
      { "- > - # H", "  >   [子](/a)", "- tail" },
      { "• ", "  │ • ", "  ", "  │   # H", "  │   " .. string.rep("═", 18), "  │   子", "• tail" },
      { 1, 1, 1, 1, 1, 2, 3 },
      3,
    },
  }
  for _, case in ipairs(cases) do
    local c, spans = build(case[1])
    eq(c.lines, case[2], "quote/list border and margin order")
    eq(c.source_line_map, case[3], "quote/list decorations and physical rows")
    eq(heading_ranks(spans)[1][3], 1, "composed child H1 rank")
    eq(
      c.heading_anchors[case[4] == 2 and case[1][1]:find("子", 1, true) and "子" or "h"],
      case[4],
      "composed heading anchor"
    )
    eq(#c.link_metadata, 1, "one composed child target")
  end
  local c, spans = build { "> - > - # [H](/h)", ">   > - tail", "> - outside" }
  eq(c.lines, {
    "│ • ",
    "│   │ • ",
    "",
    "│   │   # H",
    "│   │   " .. string.rep("═", 16),
    "│   │ • tail",
    "│ • outside",
  }, "repeat accepted helper after each quote")
  eq(c.source_line_map, { 1, 1, 1, 1, 1, 2, 3 }, "repeated composed source map")
  eq(heading_ranks(spans), { { 3, 1, 1, "# H" } }, "repeated composed H1 span")
  eq(targets(c), { { 1, "H", "/h" } }, "repeated composed target")
  c = build { "> 1. > 2. # H", ">    > 9. next", "> 9. outer" }
  eq(c.lines, {
    "│ 1. ",
    "│    │ 2. ",
    "",
    "│    │    # H",
    "│    │    " .. string.rep("═", 14),
    "│    │ 3. next",
    "│ 2. outer",
  }, "quote/list inner and outer numbering stay independent")
  c = build { ">3. > first", ">   > next", ">3. end" }
  eq(
    c.lines,
    { "│ 3. ", "│    │ first", "│ │ next", "│ 3. end" },
    "physical dedent ends the accepted intervening list"
  )
  eq(c.source_line_map, { 1, 1, 2, 3 }, "dedent prevents paragraph joining across owners")
  c = build { "   > 3.\t > first", ">     > next", "> 3. end" }
  eq(
    c.lines,
    { "│ 3. ", "│     │ first next", "│ 4. end" },
    "wide accepted tab gap stays owned on its continuation"
  )
end)

test("quoted child fences retain literal payload and owner margins", function()
  for _, case in ipairs {
    {
      { "> - ```lua", ">   b", ">", ">", ">   ```", "> - c" },
      { "│ • ", "│   b", "│   ", "│   ", "│ • c" },
      { 1, 2, 3, 4, 6 },
      6,
      { "b", "", "" },
    },
    {
      { "> - > ```lua", ">   > b", ">   > ```", "> - c" },
      { "│ • ", "│   │ b", "│ • c" },
      { 1, 2, 4 },
      10,
      { "b" },
    },
    {
      { "- > - ```lua", "  >   b", "  >   ```", "- c" },
      { "• ", "  │ • ", "  │   b", "• c" },
      { 1, 1, 2, 4 },
      8,
      { "b" },
    },
  } do
    local c, spans = build(case[1])
    eq(c.lines, case[2], "code prefix follows the accepted container order")
    eq(c.source_line_map, case[3], "quoted code and sibling source rows")
    eq(c.code_blocks[1].prefix_len, case[4], "quoted declared prefix bytes")
    eq(c.code_blocks[1].source_lines, case[5], "quoted exact literal payload")
    eq(heading_ranks(spans), {}, "quoted code owns heading syntax")
  end
end)

test("tasks, media, thematic precedence and fold exits keep their behavior", function()
  local source = { "- > [!NOTE]- Fold", "  > [內](/inside)", "- [ ] [任務](/task)", "- ![圖](/missing.png)" }
  local c = build(source)
  eq(c.lines, { "• ", "  │ 󰋽  Fold 󰅂 ", "󰄱  任務", "• 圖" }, "ordinary task and media fallback")
  eq(
    c.callout_folds,
    { { header_line = 1, source_line = 1, collapsed = true } },
    "fold is owned by physical marker row"
  )
  eq(targets(c), { { 3, "任務", "/task" }, { 4, "圖", "/missing.png" } }, "collapsed body has no active target")
  c = build(source, { fold_state = { [1] = false } })
  eq(
    targets(c),
    { { 2, "內", "/inside" }, { 3, "任務", "/task" }, { 4, "圖", "/missing.png" } },
    "expanding physical row restores only its body target"
  )
  local spans
  c, spans = build { "- [ ] # title", "- [x] [ok](/safe)" }
  eq(c.lines, { "󰄱  # title", "󰄲  ok" }, "task paragraph does not expose an ATX child")
  eq(heading_ranks(spans), {}, "task title is paragraph text")
  c = build { "- - -", "", "- * * *", "- tail" }
  eq(
    c.lines,
    { string.rep("─", 24), "• ", "  " .. string.rep("─", 22), "", "• tail" },
    "thematic break wins before marker peeling"
  )
  for _, first in ipairs { { "> [!NOTE]- hidden", "> body" }, { "- > [!NOTE]- hidden", "  > body" } } do
    for _, child in ipairs { "- # H", "- - child" } do
      c = build(vim.list_extend(vim.deepcopy(first), { child, "- tail" }))
      local marker_row
      for row, original in ipairs(c.source_line_map) do
        if original == 3 and c.lines[row] == "• " then marker_row = row end
      end
      assert(marker_row, "leaving a collapsed owner restores the accepted outer marker")
      eq(c.lines[#c.lines], "• tail", "next sibling survives fold exit")
    end
  end
end)

test("native item heading placement retains source rank and CJK link runs", function()
  local size = require "md-render.text_size"
  local supports = size.supports
  size.supports = function()
    return true
  end
  size.setup { backend = "native" }
  local ok, err = pcall(function()
    local c, spans = build({ "- ### **字** [子](/heading)" }, { text_scale = true, max_width = 40 })
    eq(c.lines, { "• ", "  ", "  字 子", "" }, "native item title uses established scaled layout")
    eq(c.source_line_map, { 1, 1, 1, 1 }, "native placement and marker share physical source")
    eq(#c.text_placements, 1, "only title content has a native placement")
    local placement = c.text_placements[1]
    eq(
      { placement.line, placement.col, placement.hl, placement.text },
      { 2, 2, "MdRenderH3", "字 子" },
      "native H3 geometry"
    )
    eq(placement.runs[1].text, "字", "native title keeps bold CJK run")
    eq(placement.runs[3].url, "/heading", "native painted link keeps complete target")
    eq(style(spans, "Bold"), { { 2, 1, 2, 5, "字" } }, "native buffer style bytes")
    eq(targets(c), { { 1, "子", "/heading" } }, "native buffer link bytes")
    eq(c.heading_anchors["字-子"], 2, "native anchor points at title content")
  end)
  size.supports = supports
  assert(ok, err)
end)

test("public narrow preview rebuild, activation and folding retain accepted owners", function()
  local preview = require "md-render.preview"
  local source = {
    "- # [標題](https://example.invalid/a?x=1&amp;y=2) **字** alpha beta gamma delta epsilon",
    "- > [!NOTE]- Fold",
    "  > [內](https://example.invalid/inside)",
    "- [ ] [任務](https://example.invalid/task)",
    "- ![圖](/missing.png)",
    "",
    "[跳](#標題-字-alpha-beta-gamma-delta-epsilon)",
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_set_current_buf(buf)
  local previous_win = vim.api.nvim_get_current_win()
  -- A real split is required: changing the sole headless window's width is ignored.
  vim.cmd "vsplit"
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_width(win, 36)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local mouse, supports, open = display.getmousepos, display.supports_osc8, vim.ui.open
  local ok, err = pcall(function()
    preview.toggle { text_scale = false }
    local session = assert(preview._toggle_sessions[buf])
    display.supports_osc8 = function()
      return false
    end
    local slug = "標題-字-alpha-beta-gamma-delta-epsilon"
    local previous_count
    for _, width in ipairs { 36, 22 } do
      vim.api.nvim_win_set_width(win, width)
      session:resize(win)
      session:rebuild()
      eq(vim.api.nvim_win_get_width(win), width, "actual public window geometry")
      eq(session.opts.max_width, width, "effective public render width")
      local title = width == 36 and { "    # 標題 字 alpha beta gamma delta", "    epsilon" }
        or { "    # 標題 字 alpha", "    beta gamma delta", "    epsilon" }
      local expected = { "  • ", "    " }
      vim.list_extend(expected, title)
      vim.list_extend(expected, {
        "    " .. string.rep("═", width - 4),
        "  • ",
        "    │ 󰋽  Fold 󰅂 ",
        "  󰄱  任務",
        "  • 圖",
        "  ",
        "  跳",
      })
      local rows = {}
      for _ = 1, #title + 3 do
        rows[#rows + 1] = 1
      end
      vim.list_extend(rows, { 2, 2, 4, 5, 6, 7 })
      eq(session.content.lines, expected, "exact public narrow layout")
      eq(session.content.source_line_map, rows, "wrapped titles and decorations preserve physical sources")
      eq(session.content.heading_anchors[slug], 2, "public anchor points at H1 rather than marker row")
      if previous_count then assert(#expected > previous_count, "the narrower window visibly reflows the heading") end
      previous_count = #expected
      for step = 1, 2 do
        local content, opened = session.content, {}
        eq(vim.api.nvim_win_get_buf(win), session.buf, "preview is displayed in the measured split")
        eq(vim.api.nvim_buf_get_lines(session.buf, 0, -1, false), expected, "actual public buffer")
        local click = vim.fn.maparg("<LeftRelease>", "n", false, true).callback
        vim.ui.open = function(url)
          opened[#opened + 1] = url
        end
        for _, link in ipairs(content.link_metadata) do
          eq(Links.at(session.buf, session.ns, link.line, link.col_start), link.url, "public first label byte")
          eq(Links.at(session.buf, session.ns, link.line, link.col_end - 1), link.url, "public last label byte")
          eq(Links.at(session.buf, session.ns, link.line, link.col_end), nil, "public byte after label")
          if link.url:sub(1, 4) == "http" or link.url:sub(1, 1) == "#" then
            display.getmousepos = function()
              return { winid = win, line = link.line + 1, column = link.col_start + 1 }
            end
            click()
            if link.url:sub(1, 1) == "#" then
              eq(
                vim.api.nvim_win_get_cursor(win)[1],
                content.heading_anchors[slug] + 1,
                "click reaches accepted item heading"
              )
            end
          end
        end
        eq(
          opened,
          { "https://example.invalid/a?x=1&y=2", "https://example.invalid/task" },
          "public full decoded targets"
        )
        if step == 1 then session:rebuild() end
        eq(session.content.lines, expected, "public rebuild retains geometry")
        eq(session.content.source_line_map, rows, "public rebuild retains sources")
      end
    end
    local fold = session.content.callout_folds[1]
    eq(fold.source_line, 2, "public fold owns the physical item row")
    display.getmousepos = function()
      return { winid = win, line = fold.header_line + 1, column = 1 }
    end
    vim.fn.maparg("<LeftRelease>", "n", false, true).callback()
    eq(session.fold_state[2], false, "click expands the list-owned callout")
    eq(session.content.callout_folds[1].collapsed, false, "expanded state survives rebuild")
    local inside
    for _, link in ipairs(session.content.link_metadata) do
      if link.url == "https://example.invalid/inside" then inside = link end
    end
    assert(inside, "expanded body target is active")
    eq(session.content.lines[inside.line + 1], "    │ 內", "expanded body keeps list and quote margins")
    eq(session.content.source_line_map[inside.line + 1], 3, "expanded body physical source")
    local opened
    vim.ui.open = function(url)
      opened = url
    end
    display.getmousepos = function()
      return { winid = win, line = inside.line + 1, column = inside.col_start + 1 }
    end
    vim.fn.maparg("<LeftRelease>", "n", false, true).callback()
    eq(opened, "https://example.invalid/inside", "expanded link activation")
    vim.api.nvim_win_set_cursor(win, { inside.line + 1, inside.col_start })
    preview.toggle()
    eq(vim.api.nvim_get_current_buf(), buf, "public close returns to the source buffer")
    eq(vim.api.nvim_win_get_cursor(win)[1], 3, "public close returns to the physical body source row")
  end)
  display.getmousepos, display.supports_osc8, vim.ui.open = mouse, supports, open
  if preview._toggle_sessions[buf] and vim.api.nvim_win_get_buf(win) == preview._toggle_sessions[buf].buf then
    vim.api.nvim_set_current_win(win)
    preview.toggle()
  end
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), source, "public close restores identical source bytes")
  eq(vim.api.nvim_buf_get_changedtick(buf), tick, "public preview never edits source changedtick")
  if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  vim.api.nvim_set_current_win(previous_win)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, err)
end)

print(string.format("list_child_blocks_test: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
