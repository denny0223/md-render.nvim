-- Fenced code is opaque to document-wide list and reference transformations.
-- Run: nvim --headless -u NONE --noplugin -l tests/code_isolation_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

require("md-render.image").supports_kitty = function()
  return false
end
local ContentBuilder = require("md-render.content_builder").ContentBuilder
local markdown = require "md-render.markdown"
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
  local source = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  local b = ContentBuilder.new()
  b:render_document(
    vim.api.nvim_buf_get_lines(source, 0, -1, false),
    vim.tbl_extend("force", {
      max_width = 120,
      indent = "",
      text_scale = false,
    }, opts or {})
  )
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

-- CommonMark 0.31.2 example 116 / GFM 86: the first code row can have
-- more than four columns. It must never become a joined paragraph string.
do
  local lines = { "        foo", "    bar" }
  local c, marks = build(lines)
  assert_eq(c.lines, { "    foo", "bar" }, "deep first code row retains separate literal output rows")
  assert_eq(c.source_line_map, { 1, 2 }, "deep first code row retains physical source rows")
  local strings = {}
  for _, mark in ipairs(marks) do
    if mark[4].hl_group == "String" then
      strings[#strings + 1] = { mark[2] + 1, c.lines[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col) }
    end
  end
  assert_eq(strings, { { 1, "    foo" }, { 2, "bar" } }, "each actual code row has literal String ownership")

  local preview = require "md-render.preview"
  for _, mode in ipairs { "show", "toggle" } do
    local source = vim.api.nvim_create_buf(false, true)
    vim.bo[source].filetype = "markdown"
    vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(source)
    local tick = vim.api.nvim_buf_get_changedtick(source)
    local ok, err = pcall(function()
      preview[mode] { indent = "", text_scale = false, max_width = 120 }
      local session = assert(preview._sessions[vim.api.nvim_get_current_buf()])
      local expected = vim.tbl_map(function(line)
        return (mode == "toggle" and "  " or "") .. line
      end, c.lines)
      for step = 1, 2 do
        assert_eq(session.content.lines, expected, mode .. ": public preview preserves code rows")
        assert_eq(session.content.source_line_map, { 1, 2 }, mode .. ": public preview preserves source rows")
        assert_eq(
          vim.api.nvim_buf_get_lines(session.buf, 0, -1, false),
          expected,
          mode .. ": public preview applies physical buffer rows"
        )
        if step == 1 then session:rebuild() end
      end
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      if mode == "toggle" then
        preview.toggle()
        assert_eq(vim.api.nvim_get_current_buf(), source, "toggle restores the original source buffer")
        assert_eq(vim.api.nvim_win_get_cursor(0)[1], 2, "toggle restores the mapped code source row")
      else
        preview.show()
      end
      session:dispose()
    end)
    assert_eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), lines, mode .. ": source bytes stay unchanged")
    assert_eq(vim.api.nvim_buf_get_changedtick(source), tick, mode .. ": source changedtick stays unchanged")
    vim.api.nvim_buf_delete(source, { force = true })
    assert(ok, err)
  end
end

-- Indented blocks keep literal rows before every document-wide transform.
-- Named examples are from CommonMark 0.31.2 (CC BY-SA 4.0):
-- https://spec.commonmark.org/0.31.2/#indented-code-blocks
for _, case in ipairs {
  {
    name = "CM48 / GFM18 thematic-looking code",
    source = { "    ***" },
    lines = { "***" },
    rows = { 1 },
    code = { { 1, "***" } },
  },
  {
    name = "CM85 indented Setext-looking rows",
    source = { "    Foo", "    ---" },
    lines = { "Foo", "---" },
    rows = { 1, 2 },
    code = { { 1, "Foo" }, { 2, "---" } },
  },
  {
    name = "CM100 / GFM70 code before a thematic break",
    source = { "    foo", "---" },
    lines = { "foo", "", string.rep("─", 120) },
    rows = { 1, 2, 2 },
    code = { { 1, "foo" } },
  },
  {
    name = "CM111 / GFM81 interior blank rows",
    source = { "    chunk1", "", "    chunk2", "  ", " ", " ", "    chunk3" },
    lines = { "chunk1", "", "chunk2", "", "", "", "chunk3" },
    rows = { 1, 2, 3, 4, 5, 6, 7 },
    code = { { 1, "chunk1" }, { 2, "" }, { 3, "chunk2" }, { 4, "" }, { 5, "" }, { 6, "" }, { 7, "chunk3" } },
  },
  {
    name = "CM112 / GFM82 whitespace-only payload",
    source = { "    chunk1", "      ", "      chunk2" },
    lines = { "chunk1", "  ", "  chunk2" },
    rows = { 1, 2, 3 },
    code = { { 1, "chunk1" }, { 2, "  " }, { 3, "  chunk2" } },
  },
  {
    name = "CM117 leading and trailing blanks stay outside code",
    source = { "", "", "    foo", "", "" },
    lines = { "", "foo", "" },
    rows = { 1, 3, 4 },
    code = { { 3, "foo" } },
  },
  {
    name = "CM118 trailing whitespace stays literal",
    source = { "    foo  \t" },
    lines = { "foo  \t" },
    rows = { 1 },
    code = { { 1, "foo  \t" } },
  },
  {
    name = "tabs beyond structural indentation stay literal",
    source = { "\t\tfoo", " \tbar", "    \tbaz", "\t\t", "    last" },
    lines = { "\tfoo", "bar", "\tbaz", "\t", "last" },
    rows = { 1, 2, 3, 4, 5 },
    code = { { 1, "\tfoo" }, { 2, "bar" }, { 3, "\tbaz" }, { 4, "\t" }, { 5, "last" } },
  },
  {
    name = "root code dedent closes a wider list container",
    source = { "123. item", "", "    first", "      second", "    3. literal", "", "3. following" },
    lines = { "123. item", "", "first", "  second", "3. literal", "", "3. following" },
    rows = { 1, 2, 3, 4, 5, 6, 7 },
    code = { { 3, "first" }, { 4, "  second" }, { 5, "3. literal" } },
  },
  {
    name = "indented code cannot interrupt a paragraph",
    source = { "foo", "    *bar*" },
    lines = { "foo bar" },
    rows = { 1 },
    code = {},
  },
  {
    name = "three columns retain ordinary inline rendering",
    source = { "   *foo*" },
    lines = { "   foo" },
    rows = { 1 },
    code = {},
  },
  {
    name = "list container owns its continuation indentation",
    source = { "- item", "", "    *bar*" },
    lines = { "• item", "", "    bar" },
    rows = { 1, 2, 3 },
    code = {},
  },
  {
    name = "quote container evaluates its own code columns",
    source = { ">     *foo*" },
    lines = { "│     *foo*" },
    rows = { 1 },
    code = { { 1, "    *foo*" } },
  },
} do
  local c, marks = build(case.source)
  assert_eq(c.lines, case.lines, case.name .. ": exact physical output rows")
  assert_eq(c.source_line_map, case.rows, case.name .. ": exact physical source ownership")
  local strings, bleed = {}, {}
  for _, mark in ipairs(marks) do
    local group = mark[4].hl_group
    if group == "String" then
      strings[#strings + 1] = { c.source_line_map[mark[2] + 1], c.lines[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col) }
    elseif group == "Special" or group == "Italic" or group == "MdRenderInlineCode" then
      for _, row in ipairs(case.code) do
        if c.source_line_map[mark[2] + 1] == row[1] then bleed[#bleed + 1] = group end
      end
    end
  end
  assert_eq(strings, case.code, case.name .. ": actual String spans own the literal bytes")
  assert_eq(bleed, {}, case.name .. ": literal rows acquire no Markdown marker or inline style")
  if case.name:match "CM100" then
    assert_eq(c.heading_anchors, {}, "code cannot acquire Setext heading ownership")
    assert_eq(c.heading_lines, {}, "code before a thematic break reserves no heading rows")
  end
end

do
  local payload = {
    "- foo",
    "3. foo",
    "# Heading",
    "[r]: /bad",
    "[^n]: note",
    "<!-- comment -->",
    "%%",
    "$$",
    "```lua",
    ":::note",
    "![x](/missing.png)",
    "&amp; *literal*",
  }
  local source = vim.tbl_map(function(line)
    return "    " .. line
  end, payload)
  vim.list_extend(source, { "", "[r] [^n]" })
  local c, marks = build(source)
  assert_eq(
    c.lines,
    vim.list_extend(vim.deepcopy(payload), { "", "[r] [^n]" }),
    "every code-looking marker stays literal"
  )
  assert_eq(c.source_line_map, vim.fn.range(1, #source), "every literal marker keeps its physical source row")
  local strings = {}
  for _, mark in ipairs(marks) do
    if mark[4].hl_group == "String" then
      strings[#strings + 1] = c.lines[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col)
    end
  end
  assert_eq(strings, payload, "lists, definitions, fences and extensions have String ownership")
  assert_eq(c.link_metadata, {}, "literal definitions create no active Markdown references")
  assert_eq(c.footnote_anchors, {}, "literal footnote definitions create no section or anchors")
  assert_eq(c.heading_anchors, {}, "literal heading text creates no heading anchors")
  assert_eq(c.code_blocks, {}, "an indented fence-looking row cannot open a nested fence")
  assert_eq(c.image_placements, {}, "literal image syntax creates no media placement")
end

-- Narrow code keeps its full target while clipping the actual clickable bytes.
do
  local url = "https://example.invalid/a?x=1&y=2"
  local source_lines = { "    prefix " .. url, "", "    - literal", "    [bad]: /bad", "", "[bad]" }
  local c = build(source_lines, { max_width = 20 })
  assert_eq(
    c.lines,
    { "prefix https://exam…", "", "- literal", "[bad]: /bad", "", "[bad]" },
    "narrow literal display"
  )
  assert_eq(c.link_metadata, {
    { line = 0, col_start = 7, col_end = 19, url = url },
  }, "narrow code keeps the full URL and excludes the ellipsis from its visible range")

  local preview = require "md-render.preview"
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
  local ok, err = pcall(function()
    preview.toggle { text_scale = false, max_width = 20 }
    local session = assert(preview._toggle_sessions[source])
    local expected = { "  prefix https://ex…", "  ", "  - literal", "  [bad]: /bad", "  ", "  [bad]" }
    for step = 1, 2 do
      assert_eq(session.content.lines, expected, "narrow public preview keeps literal payload and interior blank")
      assert_eq(session.content.source_line_map, { 1, 2, 3, 4, 5, 6 }, "narrow code rows retain original source rows")
      assert_eq(session.content.link_metadata, {
        { line = 0, col_start = 9, col_end = 19, url = url },
      }, "narrow public preview keeps exact visible URL range")
      assert_eq(vim.api.nvim_buf_get_lines(session.buf, 0, -1, false), expected, "narrow public buffer matches output")
      assert_eq(
        require("md-render.links").at(session.buf, session.ns, 0, 9),
        url,
        "actual narrow URL mark retains full target"
      )
      vim.fn.getmousepos = function()
        return { winid = session.win, line = 1, column = 10 }
      end
      vim.fn.maparg("<LeftRelease>", "n", false, true).callback()
      if step == 1 then session:rebuild() end
    end
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    preview.toggle()
    assert_eq(vim.api.nvim_get_current_buf(), source, "narrow code toggle restores source")
    assert_eq(vim.api.nvim_win_get_cursor(0)[1], 3, "narrow code toggle restores the mapped literal row")
    preview.toggle()
    assert_eq(session.content.lines, expected, "narrow code toggles back without changing its payload")
    preview.toggle()
    session:dispose()
  end)
  vim.ui.open, vim.fn.getmousepos, display.supports_osc8 = open, getmousepos, osc8
  assert_eq(opened, { url, url }, "actual narrow code activation opens the full target across rebuild")
  assert_eq(
    vim.api.nvim_buf_get_lines(source, 0, -1, false),
    source_lines,
    "narrow code preview preserves source bytes"
  )
  assert_eq(vim.api.nvim_buf_get_changedtick(source), tick, "narrow code preview preserves source changedtick")
  vim.api.nvim_buf_delete(source, { force = true })
  assert(ok, err)
end

-- The original numbered sample and CommonMark 0.31.2 example 212.
for _, delimiter in ipairs { ".", ")" } do
  local marker = "3" .. delimiter
  for _, case in ipairs {
    {
      source = { "    " .. marker .. " first", "    " .. marker .. " second" },
      lines = { marker .. " first", marker .. " second" },
      rows = { 1, 2 },
    },
    {
      source = { ">     " .. marker .. " first", ">     " .. marker .. " second" },
      lines = { "│     " .. marker .. " first", "│     " .. marker .. " second" },
      rows = { 1, 2 },
    },
    {
      source = {
        marker .. " outer",
        "",
        "       " .. marker .. " first",
        "       " .. marker .. " second",
        marker .. " last",
      },
      lines = {
        marker .. " outer",
        "       " .. marker .. " first",
        "       " .. marker .. " second",
        "4" .. delimiter .. " last",
      },
      rows = { 1, 3, 4, 5 },
    },
  } do
    local c = build(case.source)
    assert_eq(c.lines, case.lines, delimiter .. ": indented code markers stay literal")
    assert_eq(c.source_line_map, case.rows, delimiter .. ": indented code source ownership")
  end
  local c = build { "$$", marker .. " first", marker .. " second", "$$" }
  assert_eq(c.lines, { marker .. " first", marker .. " second" }, delimiter .. ": math markers stay literal")
  assert_eq(c.source_line_map, { 2, 3 }, delimiter .. ": math source ownership")
end

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

-- CommonMark limits source ordered markers to nine digits. Display numbering
-- may grow beyond that limit without changing the source container or links.
for _, delimiter in ipairs { ".", ")" } do
  local literal = "1234567890" .. delimiter .. " literal"
  local c = build { "3" .. delimiter .. " first", literal }
  assert_eq(c.lines, { "3" .. delimiter .. " first " .. literal }, "ten-digit text continues the list paragraph")
  assert_eq(c.source_line_map, { 1 }, "non-marker text shares its paragraph source")
  assert_eq(
    markdown.renumber_ordered_lists { "3" .. delimiter .. " first", literal },
    { "3" .. delimiter .. " first", literal },
    "standalone numbering preserves an invalid marker"
  )
  for _, control in ipairs { "\f", "\v", "\r" } do
    local text = control .. "3" .. delimiter .. " first"
    assert_eq(markdown.renumber_ordered_lists { text }, { text }, "non-container control bytes stay literal")
  end
  c = build { "1234567890" .. delimiter .. " [r]: /wrong", "", "[r]" }
  assert_eq(c.lines[#c.lines], "[r]", "an invalid list prefix cannot expose a reference definition")
  assert_eq(c.link_metadata, {}, "ten-digit reference-looking text cannot define a link")
  c = build { "999999999" .. delimiter .. " first", "1" .. delimiter .. " [next](/right)" }
  assert_eq(c.lines[2], "1000000000" .. delimiter .. " next", "valid source numbering may grow to ten digits")
  local link = c.link_metadata[1]
  assert_eq(c.lines[2]:sub(link.col_start + 1, link.col_end), "next", "generated marker width preserves link bytes")
  assert_eq(link.url, "/right", "generated marker width preserves the destination")
  for _, preceding in ipairs { {}, { '<h2>Heading <img src="/missing.png"></h2>', "" } } do
    local source = vim.list_extend(vim.deepcopy(preceding), {
      "999999999" .. delimiter .. " first",
      "",
      "1" .. delimiter .. " second",
    })
    c = build(source)
    assert_eq(
      vim.list_slice(c.lines, #c.lines - 1),
      { "999999999" .. delimiter .. " first", "1000000000" .. delimiter .. " second" },
      "generated numbering preserves loose-list spacing after synthetic rows"
    )
    source = vim.list_extend(vim.deepcopy(preceding), {
      "999999999" .. delimiter .. " first",
      "1" .. delimiter .. " second",
      "",
      "           continuation",
    })
    c = build(source)
    assert_eq(c.lines[#c.lines], "           continuation", "generated numbering preserves continuation indentation")
    assert_eq(c.source_line_map[#c.lines], #source, "synthetic rows cannot shift continuation source mapping")
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

-- Quoted list fences use the item's content column, even when it exceeds
-- three spaces. Relative indent 0..3 opens code; four spaces stays in text.
for _, number in ipairs { "10", "999999999" } do
  for _, extra in ipairs { 0, 3, 4 } do
    local gap = string.rep(" ", #number + 2 + extra)
    local c, marks = build {
      "> " .. number .. ") first",
      "> " .. gap .. "~~~lua",
      "> " .. gap .. "*literal*",
      "> " .. gap .. "3) item",
      "> " .. gap .. "~~~",
      "> " .. number .. ") sibling",
    }
    local name = number .. "): quote-local fence at relative indent " .. extra
    if extra <= 3 then
      assert_eq(#c.code_blocks, 1, name .. ": one labelled code block")
      assert_eq(c.source_line_map, { 1, 3, 4, 6 }, name .. ": code rows retain physical sources")
      assert_eq((c.lines[2] or ""):sub(-9), "*literal*", name .. ": code preserves emphasis markers")
      assert_eq((c.lines[3] or ""):sub(-7), "3) item", name .. ": code preserves list markers")
      local inline_bleed = false
      for _, mark in ipairs(marks) do
        if mark[2] == 1 or mark[2] == 2 then
          local group = mark[4].hl_group
          inline_bleed = inline_bleed or group == "Italic" or group == "DiagnosticDeprecated"
        end
      end
      assert_eq(inline_bleed, false, name .. ": actual code rows carry no inline styles")
    else
      assert_eq(#c.code_blocks, 0, name .. ": four extra spaces cannot open a fence")
      assert_eq(c.source_line_map, { 1, 6 }, name .. ": invalid fence remains one paragraph")
    end
    assert_eq(
      c.lines[#c.lines],
      "│ " .. tostring(tonumber(number) + 1) .. ") sibling",
      name .. ": sibling numbering survives"
    )
  end
end

-- Code ends at the source closer. A following paragraph in the same item
-- can admit lazy text, while a following heading cannot admit outside text.
for _, number in ipairs { "10", "999999999" } do
  local gap = string.rep(" ", #number + 2)
  local c, marks = build {
    "> " .. number .. ") first",
    "> " .. gap .. "```lua",
    "> " .. gap .. "# *literal*",
    "> " .. gap .. "[bad]: /bad",
    "> " .. gap .. "```",
    "> " .. gap .. "*after",
    "lazy* [good]",
    "> " .. gap .. "# Heading",
    "outside",
    "",
    "[good]: /safe",
    "[bad] [good]",
  }
  local name = number .. "): paragraph after source closer"
  assert_eq(c.lines[2], "│ " .. gap .. "# *literal*", name .. ": code keeps heading and emphasis markers")
  assert_eq(c.lines[3], "│ " .. gap .. "[bad]: /bad", name .. ": code keeps a complete reference definition")
  assert_eq(c.lines[4], "│ " .. gap .. "after lazy good", name .. ": paragraph admits eligible lazy text")
  assert_eq(c.lines[5], "│ " .. gap .. "# Heading", name .. ": existing heading text stays separate")
  assert_eq(c.lines[6], "outside", name .. ": heading cannot admit outside text")
  assert_eq(
    vim.list_slice(c.source_line_map, 1, 6),
    { 1, 3, 4, 6, 8, 9 },
    name .. ": physical paragraph and block starts survive"
  )
  assert_eq(c.lines[#c.lines], "[bad] good", name .. ": code cannot define a reference")
  local italics = {}
  for _, mark in ipairs(marks) do
    if mark[4].hl_group == "Italic" then italics[#italics + 1] = { mark[2] + 1, mark[3], mark[4].end_col } end
  end
  local first = #"│ " + #gap
  assert_eq(italics, { { 4, first, first + #"after lazy" } }, name .. ": exact italic bytes exclude code and borders")
  local targets = {}
  for _, link in ipairs(c.link_metadata) do
    targets[#targets + 1] = { link.url, c.lines[link.line + 1]:sub(link.col_start + 1, link.col_end) }
  end
  assert_eq(targets, { { "/safe", "good" }, { "/safe", "good" } }, name .. ": only real definitions activate links")
end

-- Non-1 ordered markers cannot turn an existing paragraph into compound code.
-- The renderer's existing marker-row split is outside this source-owner repair.
for _, case in ipairs {
  { first = "plain paragraph", marker = "3) > ```", prefix = "   > ", display = "   │ " },
  { first = "- plain paragraph", marker = "  3) > ```", prefix = "     > ", display = "     │ " },
} do
  local c, marks = build { case.first, case.marker, case.prefix .. "*literal*", case.prefix .. "```", "outside" }
  assert_eq(c.lines[3], case.display .. "literal", case.marker .. ": body remains inline text")
  assert_eq(c.source_line_map, { 1, 2, 3, 5 }, case.marker .. ": existing source-row layout survives")
  local styles = {}
  for _, mark in ipairs(marks) do
    local group = mark[4].hl_group
    if group == "Italic" or group == "String" then
      styles[#styles + 1] =
        { c.source_line_map[mark[2] + 1], group, c.lines[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col) }
    end
  end
  assert_eq(styles, { { 3, "Italic", "literal" } }, case.marker .. ": actual inline bytes have no code style")
end

-- Source paragraph context precedes reference consumption: definition-only
-- paragraphs and their titles also deny a following non-1 list interruption.
for _, case in ipairs {
  { before = { "plain paragraph" }, marker = "3)", last = "inside", targets = { { "/bad", "inside" } } },
  {
    before = { "[real]: /safe" },
    marker = "3)",
    after = "[inside] [real]",
    last = "inside real",
    targets = { { "/bad", "inside" }, { "/safe", "real" } },
  },
  {
    before = { "[real]: /safe", '  "Title"' },
    marker = "3)",
    after = "[inside] [real]",
    last = "inside real",
    targets = { { "/bad", "inside" }, { "/safe", "real" } },
  },
  { before = { "plain paragraph" }, marker = "1)", last = "[inside]", targets = {}, code = "   │ " },
  { before = { "plain paragraph" }, marker = "-", last = "[inside]", targets = {}, code = "  │ " },
} do
  local lines = vim.deepcopy(case.before)
  local prefix = string.rep(" ", #case.marker + 1) .. "> "
  local definition = "[inside]: /bad"
  vim.list_extend(lines, {
    case.marker .. " > ```",
    prefix .. definition,
    prefix .. "```",
    case.after or "[inside]",
  })
  local c, marks = build(lines)
  local name = table.concat(case.before, " / ") .. " then " .. case.marker
  assert_eq(c.lines[#c.lines], case.last, name .. ": only source-eligible references resolve")
  assert_eq(c.source_line_map[#c.lines], #lines, name .. ": final reference maps to its source row")
  local targets, strings = {}, {}
  for _, mark in ipairs(marks) do
    local text = c.lines[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col)
    if mark[4].url then targets[#targets + 1] = { mark[4].url, text } end
    if mark[4].hl_group == "String" then strings[#strings + 1] = text end
  end
  assert_eq(targets, case.targets, name .. ": actual link marks retain exact targets and label bytes")
  assert_eq(strings, case.code and { definition } or {}, name .. ": only a genuine owner applies code style")
  if case.code then
    assert_eq(c.lines[3], case.code .. definition, name .. ": valid interruption keeps code literal")
  end
end

-- A list marker and quote opener can share the fence's source row. The marker
-- keeps its existing layout, while all following code uses source ownership.
for _, case in ipairs {
  {
    first = "- > ```",
    prefix = "  > ",
    display = "  │ ",
    marker = "• > ```",
    sibling = "- sibling",
    last = "• sibling",
  },
  {
    first = "3) > ```",
    prefix = "   > ",
    display = "   │ ",
    marker = "3) > ```",
    sibling = "3) sibling",
    last = "4) sibling",
  },
  {
    first = "-\t> ```",
    prefix = "\t> ",
    display = "    │ ",
    marker = "• > ```",
    sibling = "- sibling",
    last = "• sibling",
  },
  {
    first = "- > ```",
    prefix = "\t> ",
    display = "  │ ",
    marker = "• > ```",
    sibling = "- sibling",
    last = "• sibling",
  },
  {
    first = "- >> ```",
    prefix = "  >> ",
    display = "  │ │ ",
    marker = "• >> ```",
    sibling = "- sibling",
    last = "• sibling",
  },
  {
    first = "> - > ```",
    prefix = ">   > ",
    display = "│ │ ",
    marker = "│ • > ```",
    sibling = "> - sibling",
    last = "│ • sibling",
  },
} do
  local body = {
    "3) first",
    "3) second",
    "~literal~",
    "[inside]: /bad",
    "<!-- literal",
    "--> *literal*",
    "# *literal*",
    "[^f]: note",
  }
  local lines, expected, rows = { case.first }, {}, {}
  for i, line in ipairs(body) do
    lines[#lines + 1] = case.prefix .. line
    expected[i], rows[i] = case.display .. line, i + 1
  end
  vim.list_extend(lines, {
    case.prefix .. "```",
    case.prefix .. "*after* [outside]",
    case.sibling,
    "",
    "[outside]: /safe",
    "[inside] [outside] [^f]",
  })
  local c, marks = build(lines)
  local name = case.first .. " / " .. case.prefix
  assert_eq(c.lines[1], case.marker, name .. ": marker layout remains unchanged")
  assert_eq(vim.list_slice(c.lines, 2, #body + 1), expected, name .. ": code bytes stay literal")
  assert_eq(vim.list_slice(c.source_line_map, 2, #body + 1), rows, name .. ": original code rows survive")
  assert_eq(c.lines[#body + 2], case.display .. "after outside", name .. ": closer does not open another fence")
  assert_eq(c.lines[#body + 3], case.last, name .. ": real sibling retains list numbering")
  assert_eq(c.lines[#c.lines], "[inside] outside [^f]", name .. ": code defines no references or footnotes")
  local targets, inline_bleed, after_italic = {}, false, false
  for _, link in ipairs(c.link_metadata) do
    targets[#targets + 1] = { link.url, c.lines[link.line + 1]:sub(link.col_start + 1, link.col_end) }
  end
  for _, mark in ipairs(marks) do
    local row, group = mark[2], mark[4].hl_group
    if
      row >= 1
      and row <= #body
      and (group == "Italic" or group == "DiagnosticDeprecated" or group == "MdRenderLink")
    then
      inline_bleed = true
    elseif row == #body + 1 and group == "Italic" then
      after_italic = c.lines[row + 1]:sub(mark[3] + 1, mark[4].end_col) == "after"
    end
  end
  assert_eq(targets, { { "/safe", "outside" }, { "/safe", "outside" } }, name .. ": only real links remain active")
  assert_eq(inline_bleed, false, name .. ": actual buffer applies no inline styles to code")
  assert_eq(after_italic, true, name .. ": normal paragraph styles resume after closer")
end

do
  local c = build { "3) > ```", "   > 3) literal", "3) sibling", "3) next" }
  assert_eq(
    c.lines,
    { "3) > ```", "   │ 3) literal", "4) sibling", "5) next" },
    "real sibling ends compound quote code"
  )
  c = build { "- >> ```", "  >> 3) literal", "  > *outside*", "3) first", "3) second" }
  assert_eq(
    c.lines,
    { "• >> ```", "  │ │ 3) literal", "  │ outside", "3) first", "4) second" },
    "shallower quote ends compound code ownership"
  )
  c = build { "- > ```", "  > 3) literal", "outside", "3) first", "3) second" }
  assert_eq(
    c.lines,
    { "• > ```", "  │ 3) literal", "outside", "3) first", "4) second" },
    "unmarked text ends compound code ownership"
  )
end

-- Fence-looking bytes inside code never open a second block. After the source
-- closer, real definitions/comments and multiline inline syntax resume.
for _, case in ipairs {
  { first = "- > ```", prefix = "  > ", display = "  │ ", marker = "• > ```", close = "```" },
  { first = "- > ~~~", prefix = "  > ", display = "  │ ", marker = "• > ~~~", close = "~~~" },
  { first = "- >> ```", prefix = "  >> ", display = "  │ │ ", marker = "• >> ```", close = "```" },
  { first = "> ```", prefix = "> ", display = "│ ", close = "```" },
} do
  local body = { case.close == "~~~" and "```" or "~~~", "```` trailing", "3) a", "3) b", "<!-- literal" }
  local lines, expected, rows = { case.first }, {}, {}
  if case.marker then expected[1] = case.marker end
  for i, line in ipairs(body) do
    lines[#lines + 1] = case.prefix .. line
    expected[#expected + 1], rows[i] = case.display .. line, i + 1
  end
  vim.list_extend(lines, {
    case.prefix .. case.close,
    case.prefix .. "[real]: /safe",
    case.prefix,
    case.prefix .. "*italic  ",
    case.prefix .. "across* [real]",
    case.prefix,
    case.prefix .. "<!-- actual comment -->",
    case.prefix .. "*after* [real]",
  })
  vim.list_extend(expected, {
    case.display,
    case.display .. "italic",
    case.display .. "across real",
    case.display,
    case.display .. "after real",
  })
  local c, marks = build(lines)
  local name = case.first .. ": source fence boundaries"
  assert_eq(c.lines, expected, name .. ": literal rows and post-closer blocks survive")
  local start = case.marker and 2 or 1
  assert_eq(vim.list_slice(c.source_line_map, start, start + #body - 1), rows, name .. ": body origins stay exact")
  local targets, applied, wanted = {}, {}, {}
  for _, link in ipairs(c.link_metadata) do
    targets[#targets + 1] = { link.url, c.lines[link.line + 1]:sub(link.col_start + 1, link.col_end) }
  end
  for _, mark in ipairs(marks) do
    if mark[4].hl_group == "Italic" then
      local end_row = mark[4].end_row or mark[2]
      for row = mark[2], end_row do
        local first = row == mark[2] and mark[3] or 0
        local last = row == end_row and mark[4].end_col or #c.lines[row + 1]
        for col = first, last - 1 do
          applied[row .. ":" .. col] = true
        end
      end
    end
  end
  for offset, word in ipairs { "italic", "across", "after" } do
    local row = start + #body + (offset == 3 and 3 or offset - 1)
    local first, last = c.lines[row + 1]:find(word, 1, true)
    if first then
      for col = first - 1, last - 1 do
        wanted[row .. ":" .. col] = true
      end
    end
  end
  assert_eq(targets, { { "/safe", "real" }, { "/safe", "real" } }, name .. ": real quote definition resumes")
  assert_eq(applied, wanted, name .. ": exact italic byte union crosses hard break without code bleed")
end

do
  local c = build {
    "- > ```",
    "  > ~literal~",
    "  > ```",
    "  > ```lua",
    "  > ~real code~",
    "  > ```",
    "  > *after*",
  }
  assert_eq(
    c.lines,
    { "• > ```", "  │ ~literal~", "  │ ~real code~", "  │ after" },
    "a genuine quote fence can follow compound code"
  )
  assert_eq(#c.code_blocks, 1, "genuine post-closer quote fence retains code metadata")
end

-- Quote normalization must retain list ancestors for both paragraph and literal rows.
for _, delimiter in ipairs { ".", ")" } do
  local marker = "3" .. delimiter
  for _, case in ipairs {
    {
      source = { "> " .. marker .. " > first", ">    > next", "> " .. marker .. " end" },
      lines = { "│ " .. marker .. " > first", "│ │ next", "│ 4" .. delimiter .. " end" },
      rows = { 1, 2, 3 },
    },
    {
      source = { "> " .. marker .. " > ```", ">    > " .. marker .. " literal", ">    > ```", "> " .. marker .. " end" },
      lines = { "│ " .. marker .. " > ```", "│ │ " .. marker .. " literal", "│ 4" .. delimiter .. " end" },
      rows = { 1, 2, 4 },
    },
  } do
    local c = build(case.source)
    assert_eq(c.lines, case.lines, "quoted descendants retain their parent list counter")
    assert_eq(c.source_line_map, case.rows, "quoted descendants retain physical source rows")
  end
end
for _, case in ipairs {
  { { ">3. > first", ">    > next", ">3. end" }, "│ 4. end" },
  { { ">3. > first", ">   > next", ">3. end" }, "│ 3. end" },
  { { "   > 3.\t first", ">    ```lua", ">    literal", ">    ```", "> 3. end" }, "│ 3. end" },
  { { "   > 3.\t > first", ">     > next", "> 3. end" }, "│ 4. end" },
  { { "> 3. > first  ", ">    > next", "lazy", "> 3. end" }, "│ 4. end" },
  { { "> 10) first", "> \t  ```lua", "> \t  literal", "> \t  ```", "> 10) end" }, "│ 11) end" },
} do
  local c = build(case[1])
  assert_eq(c.lines[#c.lines], case[2], "source indentation distinguishes list continuations from real exits")
end
do
  local c = build {
    "> 999999999) first",
    "> \t\t\t ```lua",
    "> \t\t\t literal",
    "> \t\t\t ```",
    "> 1) [*next*](/right)",
  }
  assert_eq(c.lines[#c.lines], "│ 1000000000) next", "quoted source numbering may grow to ten display digits")
  assert_eq(c.source_line_map, { 1, 3, 5 }, "display marker growth preserves quoted source rows")
  local link = c.link_metadata[1]
  assert_eq(
    link and { link.col_start, link.col_end, link.url },
    { 16, 20, "/right" },
    "quoted marker growth preserves link bytes"
  )
end

-- A source fence ends when its list owner ends, even at the same quote depth.
-- New outside quotes may be deeper; a confirmed opener owns a new local frame.
for _, case in ipairs {
  {
    source = { ">3. > ```", ">   > > [real]: /safe", ">   > >", ">   > > [real]", ">3. end" },
    blocks = {},
    link_source = 4,
  },
  {
    source = {
      "> 10) first",
      ">     ```lua",
      ">     old",
      "> [real]: /safe",
      ">",
      "> *real* [real]",
    },
    blocks = { { "    old" } },
    link_source = 6,
    italics = { { 3, 4, 8 } },
  },
  {
    source = {
      "> 10) first",
      ">     ```lua",
      ">     old",
      ">    > > [real]: /safe",
      ">    > >",
      ">    > > *real  ",
      ">    > > across* [real]",
    },
    blocks = { { "    old" } },
    link_source = 7,
    italics = { { 3, 12, 16 }, { 4, 12, 18 } },
  },
  {
    source = {
      "> 10) first",
      ">     ```lua",
      ">     old",
      ">    > > ```lua",
      ">    > > ~literal~",
      ">    > > ~~~",
      ">    > > ```",
      ">    > > [real]: /safe",
      ">    > >",
      ">    > > *real* [real]",
    },
    blocks = { { "    old" }, { "~literal~", "~~~" } },
    link_source = 10,
    italics = { { 5, 12, 16 } },
  },
  {
    source = {
      ">10) first",
      ">     ```lua",
      ">     old",
      ">    ```lua",
      ">    ~literal~",
      ">    ~~~",
      ">    ```",
      "> [real]: /safe",
      ">",
      "> *real* [real]",
    },
    blocks = { { "    old" }, { "   ~literal~", "   ~~~" } },
    link_source = 10,
    italics = { { 5, 4, 8 } },
  },
} do
  local c, marks = build(case.source)
  local blocks, targets, bleed = {}, {}, false
  local applied, wanted = {}, {}
  for _, block in ipairs(c.code_blocks) do
    blocks[#blocks + 1] = block.source_lines
  end
  for _, link in ipairs(c.link_metadata) do
    targets[#targets + 1] = {
      link.url,
      c.lines[link.line + 1]:sub(link.col_start + 1, link.col_end),
      c.source_line_map[link.line + 1],
    }
  end
  for _, mark in ipairs(marks) do
    local group = mark[4].hl_group
    if group == "Italic" then
      local end_row = mark[4].end_row or mark[2]
      for row = mark[2], end_row do
        local first = row == mark[2] and mark[3] or 0
        local last = row == end_row and mark[4].end_col or #c.lines[row + 1]
        for col = first, last - 1 do
          applied[row .. ":" .. col] = true
        end
      end
    end
    for _, block in ipairs(c.code_blocks) do
      if
        mark[2] >= block.start_line
        and mark[2] <= block.end_line
        and (group == "Italic" or group == "DiagnosticDeprecated" or group == "MdRenderLink")
      then
        bleed = true
      end
    end
  end
  for _, span in ipairs(case.italics or {}) do
    for col = span[2], span[3] - 1 do
      wanted[span[1] .. ":" .. col] = true
    end
  end
  assert_eq(blocks, case.blocks, "source ownership separates old and new quoted fence frames")
  assert_eq(targets, { { "/safe", "real", case.link_source } }, "outside definitions and original link rows resume")
  assert_eq(bleed, false, "literal code cannot acquire tilde or link styles after a frame transition")
  assert_eq(applied, wanted, "outside paragraphs restore exact emphasis bytes after source fence exit")
end

-- A table-looking pair inside an established quote fence is still literal code.
do
  local lines = { "> ```lua", "> [inside]: /bad", "> :---", "> ```", "[inside]" }
  local c, marks = build(lines)
  assert_eq(
    c.lines,
    { "│ [inside]: /bad", "│ :---", "[inside]" },
    "quoted table candidate keeps its literal definition"
  )
  assert_eq(c.source_line_map, { 2, 3, 5 }, "quoted table candidate retains every original source row")
  assert_eq(c.code_blocks[1].source_lines, { "[inside]: /bad", ":---" }, "code metadata retains the table-looking pair")
  assert_eq(c.link_metadata, {}, "literal table candidate cannot define an outside link")
  local applied = {}
  for _, mark in ipairs(marks) do
    if mark[4].url then applied[#applied + 1] = mark[4].url end
  end
  assert_eq(applied, {}, "actual buffer has no link from the literal definition")

  local preview = require "md-render.preview"
  local source = vim.api.nvim_create_buf(false, true)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(source)
  local tick = vim.api.nvim_buf_get_changedtick(source)
  local ok, err = pcall(function()
    preview.toggle { text_scale = false, max_width = 120 }
    local session = assert(preview._toggle_sessions[source])
    for step = 1, 2 do
      assert_eq(
        session.content.lines,
        { "  │ [inside]: /bad", "  │ :---", "  [inside]" },
        "public preview keeps literal code"
      )
      assert_eq(session.content.source_line_map, { 2, 3, 5 }, "public preview retains source rows")
      assert_eq(session.content.link_metadata, {}, "public preview cannot activate the literal reference")
      assert_eq(
        session.content.code_blocks[1].source_lines,
        { "[inside]: /bad", ":---" },
        "public preview retains code bytes"
      )
      assert_eq(
        vim.api.nvim_buf_get_lines(session.buf, 0, -1, false),
        session.content.lines,
        "public buffer matches its content"
      )
      local urls = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(session.buf, session.ns, 0, -1, { details = true })) do
        if mark[4].url then urls[#urls + 1] = mark[4].url end
      end
      assert_eq(urls, {}, "public buffer has no active literal-definition URL")
      if step == 1 then session:rebuild() end
    end
  end)
  if preview._toggle_sessions[source] then preview.toggle() end
  assert_eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), lines, "public preview leaves source bytes unchanged")
  assert_eq(vim.api.nvim_buf_get_changedtick(source), tick, "public preview leaves source changedtick unchanged")
  vim.api.nvim_buf_delete(source, { force = true })
  assert(ok, err)
end

-- A marked blank may omit its list indent, but cannot change quote ancestry.
do
  local cases = {
    {
      source = {
        "> 3. first",
        ">    ```lua",
        ">    old",
        ">",
        ">    [inside]: /bad",
        ">    ~literal~",
        ">    ```",
        "> 3. [real] [inside]",
        ">",
        "> [real]: /safe",
      },
      lines = {
        "│ 3. first",
        "│    old",
        "│ ",
        "│    [inside]: /bad",
        "│    ~literal~",
        "│ 4. real [inside]",
        "│ ",
      },
      rows = { 1, 3, 4, 5, 6, 8, 9 },
      blocks = { { "   old", "", "   [inside]: /bad", "   ~literal~" } },
      link_source = 8,
    },
    {
      source = {
        "> 3. first",
        ">    ```lua",
        ">    old",
        ">   >",
        ">   > [real]: /safe",
        ">   >",
        ">   > [real]",
      },
      lines = { "│ 3. first", "│    old", "│ │ ", "│ │ ", "│ │ real" },
      rows = { 1, 3, 4, 6, 7 },
      blocks = { { "   old" } },
      link_source = 7,
    },
    {
      source = { "> 3. > ```lua", ">    > old", ">", ">    > [real]: /safe", ">    >", ">    > [real]" },
      lines = { "│ 3. > ```lua", "│ │ old", "│ ", "│ │ ", "│ │ real" },
      rows = { 1, 2, 3, 5, 6 },
      blocks = {},
      link_source = 6,
    },
    {
      source = { "> 3. first", ">    ```lua", ">    old", "", "[real]: /safe", "", "[real]" },
      lines = { "│ 3. first", "│    old", "", "real" },
      rows = { 1, 3, 4, 7 },
      blocks = { { "   old" } },
      link_source = 7,
    },
  }
  local function targets(c)
    local links = {}
    for _, link in ipairs(c.link_metadata) do
      links[#links + 1] = {
        link.url,
        c.lines[link.line + 1]:sub(link.col_start + 1, link.col_end),
        c.source_line_map[link.line + 1],
      }
    end
    return links
  end
  local function bodies(c)
    return vim.tbl_map(function(block)
      return block.source_lines
    end, c.code_blocks)
  end
  local function urls(marks)
    local links = {}
    for _, mark in ipairs(marks) do
      if mark[4].url then links[#links + 1] = mark[4].url end
    end
    return links
  end
  for idx, case in ipairs(cases) do
    local c, marks = build(case.source)
    local bleed = false
    for _, mark in ipairs(marks) do
      for _, block in ipairs(c.code_blocks) do
        local group = mark[4].hl_group
        if
          mark[2] >= block.start_line
          and mark[2] <= block.end_line
          and (group == "Italic" or group == "DiagnosticDeprecated" or group == "MdRenderLink")
        then
          bleed = true
        end
      end
    end
    assert_eq(c.lines, case.lines, "marked blank preserves literals while real quote exits resume")
    assert_eq(c.source_line_map, case.rows, "blank owner transitions retain original source rows")
    assert_eq(bodies(c), case.blocks, "blank owner transitions retain the exact literal body")
    assert_eq(targets(c), { { "/safe", "real", case.link_source } }, "only the real outside reference becomes active")
    assert_eq(urls(marks), { "/safe" }, "actual buffer exposes only the real reference URL")
    assert_eq(bleed, false, "code after a marked blank cannot acquire inline styles")
    if idx == 1 then
      local preview = require "md-render.preview"
      local source = vim.api.nvim_create_buf(false, true)
      vim.bo[source].filetype = "markdown"
      vim.api.nvim_buf_set_lines(source, 0, -1, false, case.source)
      vim.api.nvim_set_current_buf(source)
      local tick = vim.api.nvim_buf_get_changedtick(source)
      local ok, err = pcall(function()
        preview.toggle { text_scale = false, max_width = 120 }
        local session = assert(preview._toggle_sessions[source])
        for step = 1, 2 do
          assert_eq(
            session.content.lines,
            vim.tbl_map(function(line)
              return "  " .. line
            end, case.lines),
            "public preview retains marked blank code and list numbering"
          )
          assert_eq(session.content.source_line_map, case.rows, "public marked blank source rows remain exact")
          assert_eq(bodies(session.content), case.blocks, "public marked blank code bytes remain exact")
          assert_eq(
            targets(session.content),
            { { "/safe", "real", case.link_source } },
            "public marked blank keeps the literal definition inactive"
          )
          assert_eq(
            vim.api.nvim_buf_get_lines(session.buf, 0, -1, false),
            session.content.lines,
            "public marked blank buffer matches rendered content"
          )
          assert_eq(
            urls(vim.api.nvim_buf_get_extmarks(session.buf, session.ns, 0, -1, { details = true })),
            { "/safe" },
            "public marked blank buffer exposes only the real URL"
          )
          if step == 1 then session:rebuild() end
        end
      end)
      if preview._toggle_sessions[source] then preview.toggle() end
      assert_eq(
        vim.api.nvim_buf_get_lines(source, 0, -1, false),
        case.source,
        "marked blank preview leaves source bytes intact"
      )
      assert_eq(vim.api.nvim_buf_get_changedtick(source), tick, "marked blank preview leaves source changedtick intact")
      vim.api.nvim_buf_delete(source, { force = true })
      assert(ok, err)
    end
  end
end

print(string.format("\ncode_isolation_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
