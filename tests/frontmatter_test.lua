-- Test YAML frontmatter rendering: truncation of overflowing values and
-- click-to-expand (mirrors table-cell expand behavior).
-- Run: nvim --headless -u NONE --noplugin -l tests/frontmatter_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local preview = require "md-render.preview"

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

local function assert_true(val, msg)
  if val then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
  end
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

-- A value long enough to overflow a narrow render width.
local LONG_VALUE = "あいうえおかきくけこさしすせそたちつてと"
local MAX_WIDTH = 20

-- ----------------------------------------------------------------------
-- Test 1: an overflowing frontmatter value is truncated with "…" and
-- registers an expandable region with a negative (frontmatter) block id.
-- ----------------------------------------------------------------------
test("overflowing frontmatter value truncates and registers a region", function()
  local lines = { "---", "hoge: " .. LONG_VALUE, "---", "", "body" }
  local content = preview.build_content(lines, { max_width = MAX_WIDTH })

  assert_eq(#content.expandable_regions, 1, "one expandable region for the overflowing entry")
  local region = content.expandable_regions[1]
  assert_true(region.block_id < 0, "frontmatter block id is negative (got " .. region.block_id .. ")")
  assert_eq(region.expanded, false, "region starts collapsed")
  assert_eq(region.start_line, region.end_line, "collapsed entry occupies a single line")

  local line = content.lines[region.start_line + 1]
  assert_true(line:sub(1, #"  hoge: ") == "  hoge: ", "line keeps the '  hoge: ' label prefix")
  assert_true(line:match "…$" ~= nil, "collapsed line ends with the … ellipsis")
  assert_true(vim.api.nvim_strwidth(line) <= MAX_WIDTH, "collapsed line fits within max_width")
end)

-- ----------------------------------------------------------------------
-- Test 2: expanding the entry wraps the value across lines, aligned to
-- the value column, and keeps the region clickable (still registered).
-- ----------------------------------------------------------------------
test("expanded frontmatter value wraps aligned to the value column", function()
  local lines = { "---", "hoge: " .. LONG_VALUE, "---", "", "body" }

  -- First pass: discover the block id.
  local collapsed = preview.build_content(lines, { max_width = MAX_WIDTH })
  local block_id = collapsed.expandable_regions[1].block_id

  -- Second pass with that entry expanded.
  local content = preview.build_content(lines, {
    max_width = MAX_WIDTH,
    expand_state = { [block_id] = true },
  })

  local region = content.expandable_regions[1]
  assert_eq(region.expanded, true, "region reports expanded")
  assert_true(region.end_line > region.start_line, "expanded entry spans multiple lines")

  local first = content.lines[region.start_line + 1]
  assert_true(first:sub(1, #"  hoge: ") == "  hoge: ", "first line keeps the label prefix")
  assert_true(first:match "…$" == nil, "expanded first line has no ellipsis")

  -- Continuation lines are indented to align under the value (col of "hoge: ").
  local value_col = #"  hoge" + 2 -- "  hoge" + ": "
  local expected_indent = string.rep(" ", value_col)
  for l = region.start_line + 1, region.end_line do
    local line = content.lines[l + 1]
    assert_true(vim.api.nvim_strwidth(line) <= MAX_WIDTH, "wrapped line " .. l .. " fits within max_width")
  end
  local second = content.lines[region.start_line + 2]
  assert_true(second:sub(1, #expected_indent) == expected_indent, "continuation line is indented to the value column")
  assert_true(second:sub(#expected_indent + 1, #expected_indent + 1) ~= " ", "continuation content follows the indent")

  -- The concatenation of value fragments reconstructs the original value.
  local parts = {}
  table.insert(parts, first:sub(value_col + 1))
  for l = region.start_line + 1, region.end_line do
    table.insert(parts, (content.lines[l + 1]):sub(value_col + 1))
  end
  local joined = table.concat(parts)
  assert_eq(joined, LONG_VALUE, "expanded fragments reconstruct the original value")
end)

-- ----------------------------------------------------------------------
-- Test 3: a short value that fits gets no region and no ellipsis.
-- ----------------------------------------------------------------------
test("short frontmatter value is left untouched", function()
  local lines = { "---", "k: v", "---", "", "body" }
  local content = preview.build_content(lines, { max_width = MAX_WIDTH })
  assert_eq(#content.expandable_regions, 0, "no region for a value that fits")
end)

-- ----------------------------------------------------------------------
-- Test 4: multiple overflowing entries get distinct block ids.
-- ----------------------------------------------------------------------
test("multiple overflowing entries get distinct block ids", function()
  local lines = {
    "---",
    "a: " .. LONG_VALUE,
    "b: " .. LONG_VALUE,
    "---",
    "",
    "body",
  }
  local content = preview.build_content(lines, { max_width = MAX_WIDTH })
  assert_eq(#content.expandable_regions, 2, "two regions for two overflowing entries")
  local id1 = content.expandable_regions[1].block_id
  local id2 = content.expandable_regions[2].block_id
  assert_true(id1 ~= id2, "block ids are distinct (" .. id1 .. " vs " .. id2 .. ")")
  assert_true(id1 < 0 and id2 < 0, "both block ids are negative")
end)

-- ----------------------------------------------------------------------
-- Test 5: a fence carrying trailing whitespace still opens/closes the
-- block. Without this the whole frontmatter falls through to the body,
-- where the closing fence underlines the last property line as a setext
-- heading.
-- ----------------------------------------------------------------------
test("fences tolerate trailing whitespace", function()
  for _, fences in ipairs {
    { open = "--- ", close = "---" },
    { open = "---", close = "--- " },
    { open = "---\t", close = "---  " },
  } do
    local lines = { fences.open, "k: v", fences.close, "", "body" }
    local content = preview.build_content(lines, { max_width = 40 })
    assert_eq(
      content.lines[1],
      "  Properties",
      "'" .. fences.open .. "' / '" .. fences.close .. "' opens a Properties block"
    )
    assert_eq(content.lines[2], "  k: v", "the entry is rendered as a property")
  end
end)

-- ----------------------------------------------------------------------
-- Test 6: `----` is a thematic break, not a fence.
-- ----------------------------------------------------------------------
test("a four-dash rule is not a frontmatter fence", function()
  local lines = { "----", "k: v", "----", "", "body" }
  local content = preview.build_content(lines, { max_width = 40 })
  assert_true(content.lines[1] ~= "  Properties", "no Properties block for a four-dash rule")
end)

test("mixed or unsupported YAML remains literal with original source rows", function()
  for _, metadata in ipairs {
    { "title: readable", "nested:", "  child: preserve me" },
    { "title: readable", "description: |", "  **literal** [link](https://example.org)" },
    { "title: readable", "中文: 不要消失" },
    { "empty:" },
    { "items:", "  - parent", "    - child" },
  } do
    local lines = { "---" }
    vim.list_extend(lines, metadata)
    lines[#lines + 1] = "---"
    local fence_end = #lines
    vim.list_extend(lines, { "", "body" })
    local content = preview.build_content(lines, { text_scale = false })
    for row = 1, fence_end do
      assert_eq(content.lines[row], "  " .. lines[row], "unknown metadata row stays literal")
      assert_eq(content.source_line_map[row], row, "unknown metadata keeps source row")
    end
    assert_eq(#content.link_metadata, 0, "raw YAML does not acquire Markdown link actions")
    assert_eq(content.source_line_map[#content.lines], #lines, "body keeps original source offset")
  end
end)

test("simple metadata tracks its source and expansion survives width changes", function()
  local lines = { "---", "short: 123456789", "long: " .. LONG_VALUE, "---", "body" }
  local wide = preview.build_content(lines, { max_width = 24, text_scale = false })
  local id = wide.expandable_regions[1].block_id
  local narrow = preview.build_content(lines, { max_width = 12, expand_state = { [id] = true }, text_scale = false })
  assert_eq(narrow.expandable_regions[1].expanded, false, "newly overflowing entry does not inherit expansion")
  assert_eq(narrow.expandable_regions[2].expanded, true, "original property retains expansion")
  assert_eq(narrow.source_line_map[2], 2, "first property maps to its source row")
end)

test("keys wider than the viewport keep valid highlight ranges", function()
  local display = require "md-render.display_utils"
  for _, width in ipairs { 1, 2, 5, 12 } do
    local content = preview.build_content({ "---", "a_very_long_property_key: value", "---" }, { max_width = width })
    local buf = vim.api.nvim_create_buf(false, true)
    display.apply_content_to_buffer(buf, vim.api.nvim_create_namespace "frontmatter_narrow", content)
    assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), content.lines, "narrow metadata applies to a real buffer")
    vim.api.nvim_buf_delete(buf, { force = true })
  end
end)

test("expanded wide keys preserve native glyphs, tabs, source rows and styles", function()
  local key = "a_very_long_property_key"
  local value = "中文 é👩‍💻👍🏽🇹🇼\tvalue  tail "
  local source = { "---", key .. ": " .. value, "---", "body" }
  local original = vim.deepcopy(source)
  local full_line = "  " .. key .. ": " .. value
  local boundaries, offset = { [0] = true }, 0
  for _, glyph in ipairs(vim.fn.split(full_line, "\\zs")) do
    offset = offset + #glyph
    boundaries[offset] = true
  end
  local tabstop = vim.bo.tabstop
  for _, tabs in ipairs { 4, 8 } do
    vim.bo.tabstop = tabs
    for _, width in ipairs { 12, #key + 4 } do
      local content = preview.build_content(source, {
        max_width = width,
        text_scale = false,
        expand_state = { [-2] = true },
      })
      local region = assert(content.expandable_regions[1])
      local parts, labels, values = {}, {}, {}
      offset = 0
      for row = region.start_line + 1, region.end_line + 1 do
        local line = content.lines[row]
        parts[#parts + 1] = line
        offset = offset + #line
        assert_true(boundaries[offset], "wrapped row ends at a complete native glyph")
        assert_true(vim.fn.strdisplaywidth(line) <= width, "wide-key row fits with the active tabstop")
        assert_eq(content.source_line_map[row], 2, "wide-key rows retain their property source")
      end
      for _, entry in ipairs(content.highlights) do
        if entry.line >= region.start_line and entry.line <= region.end_line then
          for _, group in ipairs(entry.groups) do
            local parts_by_style = group.hl == "Comment" and labels or values
            parts_by_style[#parts_by_style + 1] = content.lines[entry.line + 1]:sub(group.col + 1, group.end_col)
          end
        end
      end
      assert_eq(table.concat(parts), full_line, "expanded rows retain all property bytes")
      assert_eq(table.concat(labels), "  " .. key, "wide-key label styles retain byte boundaries")
      assert_eq(table.concat(values), value, "wide-key value styles retain byte boundaries")
      assert_eq(region.block_id, -2, "wide-key interaction id stays tied to the source row")
    end
  end
  vim.bo.tabstop = tabstop
  assert_eq(source, original, "wide-key rendering leaves source bytes unchanged")
end)

test("wide-key wrapping bounds total native scans and source slices", function()
  for _, size in ipairs { 4096, 8192, 16384 } do
    local source = { "---", string.rep("k", size) .. ": value", "---" }
    for _, width in ipairs { 20, 80 } do
      local split, displaywidth, sub = vim.fn.split, vim.fn.strdisplaywidth, string.sub
      local bytes = 0
      local function charge(length)
        bytes = bytes + length
        assert(bytes <= 12 * #source[2], "wide-key wrapping exceeded its linear native-work budget")
      end
      vim.fn.split = function(text, ...)
        charge(#text)
        return split(text, ...)
      end
      vim.fn.strdisplaywidth = function(text, ...)
        charge(#text)
        return displaywidth(text, ...)
      end
      string.sub = function(text, ...)
        local result = sub(text, ...)
        charge(#result)
        return result
      end
      local ok, content = pcall(preview.build_content, source, {
        max_width = width,
        text_scale = false,
        expand_state = { [-2] = true },
      })
      vim.fn.split, vim.fn.strdisplaywidth, string.sub = split, displaywidth, sub
      assert(ok, content)
      local region = content.expandable_regions[1]
      assert_eq(
        table.concat(vim.list_slice(content.lines, region.start_line + 1, region.end_line + 1)),
        "  " .. source[2],
        "bounded wrapping retains the whole large property"
      )
    end
  end
end)

test("native cell wrapping tracks byte starts and prefix-dependent tabs", function()
  local wrap_cells = require("md-render.wrap").wrap_cells
  local tabstop = vim.bo.tabstop
  vim.bo.tabstop = 8
  local rows, starts = wrap_cells("a\tb\tc", 8, 2)
  assert_eq(rows, { "a\tb", "\tc" }, "each row measures tabs from the same prefix column")
  assert_eq(starts, { 0, 3 }, "hard-wrap starts are source byte offsets")
  rows, starts = wrap_cells("👩‍💻a", 1)
  assert_eq(rows, { "👩‍💻", "a" }, "an oversized native glyph remains complete")
  assert_eq(starts, { 0, #"👩‍💻" }, "oversized glyph starts retain complete UTF-8 boundaries")
  rows, starts = wrap_cells("", 8)
  assert_eq(rows, {}, "empty cell wrapping follows wrap_words")
  assert_eq(starts, {}, "empty cell wrapping has no source offsets")
  vim.bo.tabstop = tabstop
end)

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then vim.cmd "cquit 1" end
