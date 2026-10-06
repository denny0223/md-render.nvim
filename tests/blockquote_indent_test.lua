-- Test blockquotes that carry an indent.  CommonMark allows up to three
-- spaces in front of a `>` (four is an indented code block), and a quote
-- nested in a list item sits at the item's content column on top of that.
-- The indent in front of the marker is not content, so a top-level quote
-- renders flush left while one in a list item renders under the item.
-- Run: nvim --headless -u NONE --noplugin -l tests/blockquote_indent_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local ContentBuilder = require("md-render.content_builder").ContentBuilder
local display = require "md-render.display_utils"
local links = require "md-render.links"
require("md-render.image").supports_kitty = function()
  return false
end
require("md-render").setup_highlights()

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
  local original = vim.deepcopy(lines)
  local b = ContentBuilder.new()
  b:render_document(lines, vim.tbl_extend("force", { max_width = 60, indent = "", text_scale = false }, opts or {}))
  local c = b:result()
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "blockquote_test"
  display.apply_content_to_buffer(buf, ns, c)
  assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), c.lines, "quote output applies to a real buffer")
  assert_eq(lines, original, "quote source stays unchanged")
  for row, source_row in ipairs(c.source_line_map) do
    local offset = opts and opts.source_line_offset or 0
    assert(source_row > offset and source_row <= #lines + offset and c.lines[row], "original quote source rows")
  end
  for _, info in ipairs(c.highlights) do
    for _, group in ipairs(info.groups) do
      local last = group.end_col == -1 and #c.lines[info.line + 1] or group.end_col
      assert(group.col >= 0 and group.col <= last and last <= #c.lines[info.line + 1], "quote highlight byte bounds")
    end
  end
  for _, link in ipairs(c.link_metadata) do
    assert_eq(links.at(buf, ns, link.line, link.col_start), link.url, "quoted link starts at its label")
    assert_eq(links.at(buf, ns, link.line, link.col_end - 1), link.url, "quoted link ends at its label")
    assert_eq(links.at(buf, ns, link.line, link.col_end), nil, "byte after quoted link has no target")
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  return c
end

--- Render and return the non-blank output lines.
local function render(lines)
  local out = {}
  for _, line in ipairs(build(lines).lines) do
    if not line:match "^%s*$" then table.insert(out, line) end
  end
  return out
end

-- Test 1: up to three spaces in front of the marker (spec example 230).
-- The indent is not content, so all of these render flush left and form a
-- single blockquote.
do
  local out = render { "   > # Foo", "   > bar", " > baz" }
  assert_eq(
    out,
    { "│ # Foo", "│ " .. string.rep("═", 58), "│ bar baz" },
    "indented quoted H1 retains its rank and rule"
  )
end

-- Test 2: four spaces is too many (spec example 231) — an indented code
-- block, with the `>` as content
do
  local out = render { "    > # Foo" }
  assert_eq(out, { "> # Foo" }, "four spaces should not make a blockquote")
end

-- Test 3: a quote indented to a bullet item's content column belongs to it
do
  local out = render { "- item", "", "  > 項目の中の引用。", "  > その続き。" }
  assert_eq(
    out,
    { "• item", "  │ 項目の中の引用。その続き。" },
    "quote should render under its list item"
  )

  -- No blank line needed: a blockquote can interrupt the item's paragraph
  out = render { "- item", "  > 引用です。" }
  assert_eq(out, { "• item", "  │ 引用です。" }, "quote should interrupt the item's paragraph")
end

-- Test 4: the content column follows the marker width
do
  local out = render { "1. 手順", "", "   > 補足。" }
  assert_eq(out, { "1. 手順", "   │ 補足。" }, "ordered item content column is 3")

  out = render { "10. 手順", "", "    > 補足。" }
  assert_eq(out, { "10. 手順", "    │ 補足。" }, "a wider marker moves the content column")

  out = render { "-   item", "", "    > 引用。" }
  assert_eq(out, { "• item", "    │ 引用。" }, "extra spaces after the marker move the content column")
end

-- Test 5: quotes in different items are different blockquotes
do
  local out = render { "- a", "  - b", "    > 深い引用。", "  > 浅い引用。" }
  assert_eq(
    out,
    { "• a", "  ◦ b", "    │ 深い引用。", "  │ 浅い引用。" },
    "quotes in different containers must not be joined"
  )
end

-- Test 6: callouts, nested quotes and code fences work inside an item
do
  local out = render { "- item", "", "  > [!WARNING] 注意", "  > 本文です。", "  > 続きます。" }
  assert_eq(#out, 3, "callout header and body should both be indented")
  assert_eq(out[3], "  │ 本文です。続きます。", "callout body should join under the item")

  out = render { "- item", "", "  > 外側", "  > > 内側" }
  assert_eq(out, { "• item", "  │ 外側", "  │ │ 内側" }, "nested quote should keep the item's indent")

  out = render { "- item", "", "  > ```lua", "  > local x = 1", "  > ```" }
  assert_eq(out, { "• item", "  │ local x = 1" }, "code fence inside an indented quote should render")
end

-- Test 7: leaving the item puts the quote back at the top level
do
  local out = render { "- a", "  > 引用。", "普通の段落。", "> トップの引用。" }
  assert_eq(
    out,
    { "• a", "  │ 引用。普通の段落。", "│ トップの引用。" },
    "a quote after the list should render flush left"
  )
  out = render { "- a", "  > 引用。", "", "普通の段落。", "> トップの引用。" }
  assert_eq(
    out,
    { "• a", "  │ 引用。", "普通の段落。", "│ トップの引用。" },
    "a blank ends the lazy paragraph"
  )
end

-- An ATX heading owns callout-shaped title text before alert detection.
for _, title in ipairs { "[!NOTE]", "[!NOTE]- Fold", "[!WARNING] Title" } do
  local c = build { "> ### " .. title, "> tail" }
  assert_eq(c.lines, { "│ ### " .. title, "│ tail" }, "quoted heading preserves its callout-shaped title")
  assert_eq(c.heading_lines[0], true, "callout-shaped title remains a quoted heading")
  assert_eq(#c.callout_folds, 0, "heading title cannot create a callout fold")
end

-- CommonMark 228/232/233/238/250/251: only an open paragraph permits omitted markers.
do
  local c = build { "> # Foo", "> bar", "baz" }
  assert_eq(c.heading_anchors.foo, 0, "quoted H1 has an undecorated anchor")
  assert_eq(c.heading_lines[0], true, "quoted H1 has heading metadata")
  assert_eq(c.lines[#c.lines], "│ bar baz", "a later paragraph admits lazy text after a heading")
  assert_eq(c.source_line_map[#c.lines], 2, "joined paragraph retains its first physical row")
  c = build { "> \t## Tab heading", "outside" }
  assert_eq(c.heading_anchors["tab-heading"], 0, "leading structural tab uses the physical quote column")
  assert_eq(c.lines[#c.lines], "outside", "a tab-indented heading cannot admit lazy text")
  for _, case in ipairs {
    { { "> bar", "baz", "> foo" }, "│ bar baz foo" },
    { { "> > > foo", "bar" }, "│ │ │ foo bar" },
    { { ">>> foo", "> bar", ">>baz" }, "│ │ │ foo bar baz" },
    { { "> foo", "    - bar" }, "│ foo - bar" },
    { { "> foo", "\t# literal" }, "│ foo # literal" },
    { { "> ***foo", "bar***" }, "│ foo bar" },
    { { "> first", "> 3) literal", "> tail" }, "│ first 3) literal tail" },
  } do
    assert_eq(build(case[1]).lines, { case[2] }, "accepted leaf continuation keeps all quote levels")
  end
  for _, source in ipairs {
    { "> bar", "", "outside" },
    { "> bar", ">", "outside" },
    { "> # Heading", "outside" },
    { "> #", "outside" },
    { "> ```lua", "> literal", "> ```", "outside" },
    { "> <!-- hidden -->suffix", "outside" },
    { "> [!NOTE]", "outside" },
    { "> h | v", "> --- | ---", "> x | y", "outside" },
    { "> Heading", "> ===", "outside" },
    { "> - # Heading", "outside" },
  } do
    c = build(source)
    assert_eq(c.lines[#c.lines], "outside", "a non-paragraph leaf cannot admit lazy text")
    assert_eq(c.source_line_map[#c.lines], #source, "outside text retains its actual row")
  end
  c = build { "- a", "  > first", "lazy", "  > last" }
  assert_eq(c.lines, { "• a", "  │ first lazy last" }, "lazy text preserves the enclosing list for resumed markers")
  c = build { "- a", "  - b", "    > first", "lazy", "    > last" }
  assert_eq(c.lines, { "• a", "  ◦ b", "    │ first lazy last" }, "nested list ownership survives lazy text")
  c = build { "> 3) first", "> 3) second", "", "> 7) new", "> 7) next" }
  assert_eq(
    c.lines,
    { "│ 3) first", "│ 4) second", "", "│ 7) new", "│ 8) next" },
    "existing quoted lists keep sibling numbering"
  )
end

-- Invalid ordered markers are paragraph text, including empty-looking markers.
for _, delimiter in ipairs { ".", ")" } do
  for _, suffix in ipairs { " literal", "" } do
    local number = "1234567890" .. delimiter .. suffix
    local c = build { "> first", number, "> tail" }
    assert_eq(c.lines, { "│ first " .. number .. " tail" }, "ten-digit text cannot open an outside list")
    assert_eq(c.source_line_map, { 1 }, "invalid marker keeps the quoted paragraph source")
  end
end

-- A complete type-7 HTML tag cannot interrupt an open paragraph, including lazy rows.
for _, tag in ipairs { "<span>", "</span>", '<span class="note">', "<custom-tag>" } do
  for _, marker in ipairs { "> ", "" } do
    local c = build { "> first", marker .. tag, "last" }
    assert_eq(c.lines, { "│ first " .. tag .. " last" }, "inline HTML preserves lazy quote ownership")
    assert_eq(c.source_line_map, { 1 }, "inline HTML remains in one source paragraph")
  end
end
do
  local c = build { "> > first", "> > <span>", "last" }
  assert_eq(c.lines, { "│ │ first <span> last" }, "inline HTML preserves all quote levels")
  c = build { "> *first  ", "> <span>", "last* [doc](/right)" }
  assert_eq(c.lines, { "│ first", "│ <span> last doc" }, "inline HTML stays in the paragraph across a hard break")
  assert_eq(c.source_line_map, { 1, 2 }, "hard-break segments keep physical source rows")
  local italics = {}
  for _, info in ipairs(c.highlights) do
    for _, group in ipairs(info.groups) do
      if group.hl == "Italic" then italics[#italics + 1] = c.lines[info.line + 1]:sub(group.col + 1, group.end_col) end
    end
  end
  assert_eq(italics, { "first", "<span> last" }, "emphasis spans inline HTML without styling quote borders")
  for _, source in ipairs {
    { "> first", "<div>", "last" },
    { "> first", "> <div>", "last" },
    { "> first", "> <span>", "", "last" },
    { "> # Heading", "> <span>", "last" },
  } do
    c = build(source)
    assert_eq(c.lines[#c.lines], "last", "a new HTML block, blank or heading cannot admit lazy text")
    assert_eq(c.source_line_map[#c.lines], #source, "outside text retains its physical source row")
  end
end

-- Definitions are parsed after quote ownership, using their original row IDs.
do
  local c = build { "> [DOC][r]", "[r]: /wrong" }
  assert_eq(c.lines, { "│ [DOC][r] [r]: /wrong" }, "definition-looking continuation remains paragraph text")
  assert_eq(#c.link_metadata, 0, "a lazy continuation cannot define a reference inside an existing paragraph")
  c = build { "> [r]:", "/right", "", "[DOC][r]", "", "[r]: /wrong" }
  assert_eq(c.lines[2], "DOC", "lazy text can complete a reference definition")
  assert_eq(c.link_metadata[1].url, "/right", "first definition retains precedence")
  c = build { "> [r]: /right", "outside [DOC][r]" }
  assert_eq(c.lines, { "│ outside DOC" }, "a provisional definition row can still admit a following lazy paragraph")
  c = build { "<b>", "earlier", "</b>", "", "> [r]:", "/right", "", "[DOC][r]" }
  assert_eq(c.lines[#c.lines], "DOC", "earlier HTML joins cannot change quote reference ownership")
  assert_eq(c.source_line_map[#c.lines], 8, "reference projection retains the original row after HTML grouping")
  assert_eq(c.link_metadata[1].url, "/right", "projected lazy definition retains its destination")
end

do
  local c = build({ "> [甲乙\\", "丙丁](/dest) *tail*", "> next" }, { max_width = 12, source_line_offset = 20 })
  assert_eq(c.lines, { "│ 甲乙", "│ 丙丁 tail", "│ next" }, "hard breaks and wrapping retain quote ownership")
  assert_eq(c.source_line_map, { 21, 22, 23 }, "mandatory segments and wrapped rows retain physical source rows")
  local labels = {}
  for _, link in ipairs(c.link_metadata) do
    labels[#labels + 1] = c.lines[link.line + 1]:sub(link.col_start + 1, link.col_end)
  end
  assert_eq(labels, { "甲乙", "丙丁" }, "quote bars stay outside UTF-8 link byte spans")
  c = build { "> *alpha  ", "beta*", "> tail" }
  assert_eq(c.lines, { "│ alpha", "│ beta tail" }, "emphasis spans a lazy hard break")
  c = build { "> `alpha  ", "beta`", "> tail" }
  assert_eq(c.lines, { "│ alpha   beta tail" }, "code spans suppress source hard breaks")
end

-- Physical tab stops belong to source markers; generated prefixes consume no columns.
do
  local c = build { ">\t>\t```markdown", ">\t>\t# literal\t[r]: /wrong", ">\t>\t```", "", "[r]" }
  assert_eq(
    c.lines[1],
    "│ │ # literal\t[r]: /wrong",
    "nested quote fences remove the opener's tab remainder and retain literal bytes"
  )
  assert_eq(c.heading_anchors.literal, nil, "code text cannot become a quoted heading")
  assert_eq(c.code_blocks[1].prefix_len, #"│ │ ", "nested code prefix uses UTF-8 bytes")
  assert_eq(
    c.code_blocks[1].source_lines,
    { "# literal\t[r]: /wrong" },
    "code metadata removes only the opening fence's physical indentation"
  )
  assert_eq(c.lines[#c.lines], "[r]", "code-owned definition text cannot bind a reference")
  c = build { " >\t\t# literal", " >\t\t[r]: /hidden", "", "[r]" }
  assert_eq(
    c.lines,
    { "│  \t# literal", "│  \t[r]: /hidden", "", "[r]" },
    "tab-indented quote code keeps literal rows separate"
  )
  assert_eq(c.source_line_map, { 1, 2, 3, 4 }, "indented quote code retains each original row")
  assert_eq(c.heading_anchors.literal, nil, "indented quote code cannot become a heading")
  assert_eq(#c.link_metadata, 0, "indented quote definition text cannot bind a reference")
  c = build { "> > ```markdown", "> > # literal", "> outside" }
  assert_eq(c.lines, { "│ │ # literal", "│ outside" }, "quoted fence stops at its actual quote depth")
  assert_eq(c.code_blocks[1].source_lines, { "# literal" }, "terminated quote fence retains its code metadata")
end

-- CommonMark 93/GFM63: a missing quote marker cannot promote a possible Setext underline.
-- https://spec.commonmark.org/0.31.2/#example-93 (CC BY-SA 4.0)
-- https://github.com/denny0223/md-render.nvim/issues/35
do
  for _, case in ipairs {
    { { "> foo", "bar", "===" }, { "│ foo bar ===" }, 1 },
    { { "> foo", "bar", "   === \t" }, { "│ foo bar ===" }, 1 },
    { { "> > foo", "bar", "===" }, { "│ │ foo bar ===" }, 2 },
    { { "> > foo", "> bar", "===" }, { "│ │ foo bar ===" }, 2 },
    { { "- item", "  > foo", "bar", "===" }, { "• item", "  │ foo bar ===" }, 1 },
    { { "> foo", "bar", "--" }, { "│ foo bar --" }, 1 },
  } do
    local c = build(case[1])
    assert_eq(c.lines, case[2], "possible underline stays inside its lazy paragraph")
    assert_eq(c.heading_lines, {}, "lazy underline creates no heading metadata")
    assert_eq(c.heading_anchors, {}, "lazy underline creates no heading anchor")
    for _, token in ipairs { "foo", "bar", case[1][#case[1]]:match "[=-]+" } do
      local found = false
      for row, line in ipairs(c.lines) do
        local first = line:find(token, 1, true)
        if first then
          local _, depth = line:sub(1, first - 1):gsub("│ ", "")
          assert_eq(depth, case[3], "every intended substring retains its quote depth")
          assert_eq(c.source_line_map[row], #case[1] == 4 and 2 or 1, "joined quote uses its paragraph source row")
          found = true
        end
      end
      assert_eq(found, true, "lazy paragraph retains " .. token)
    end
  end
  -- A genuine thematic break exits the quote, while one dash opens an empty list.
  local c = build { "> foo", "---" }
  assert_eq(c.lines, { "│ foo", "", string.rep("─", 60) }, "CM92/GFM62 thematic break remains outside")
  assert_eq(c.source_line_map, { 1, 2, 2 }, "outside thematic break physical row")
  assert_eq(c.heading_lines, {}, "CM92 creates no heading")
  c = build { "> foo", "-" }
  assert_eq(c.lines[1], "│ foo", "single dash ends the quote paragraph")
  assert_eq(c.lines[#c.lines]:find("│", 1, true), nil, "empty list marker stays outside the quote")
  assert_eq(c.source_line_map[#c.lines], 2, "empty list retains its physical source row")
  -- Explicit underlines still form headings; actual block starts and blanks still end laziness.
  c = build { "> foo", "bar", "> ===", "outside" }
  assert_eq(c.lines[1], "│ # foo bar", "explicit quoted underline owns its title")
  assert_eq(c.heading_lines[0], true, "explicit quote control remains a heading")
  assert_eq(c.lines[#c.lines], "outside", "finished heading cannot accept lazy text")
  for _, source in ipairs {
    { "> foo", "bar", "", "===" },
    { "> foo", "bar", ">", "===" },
    { "> foo", "bar", "# heading", "outside" },
    { "> foo", "bar", "```", "outside", "```" },
    { "- item", "  > foo", "bar", "", "===" },
  } do
    c = build(source)
    assert_eq(
      c.lines[1]:find("foo bar", 1, true) ~= nil or c.lines[2]:find("foo bar", 1, true) ~= nil,
      true,
      "prior quote paragraph remains intact"
    )
    assert_eq(c.lines[#c.lines]:find("│", 1, true), nil, "blank or block start ends quote ownership")
    assert_eq(
      c.source_line_map[#c.lines],
      source[#source] == "```" and #source - 1 or #source,
      "outside block source row"
    )
  end
end
do
  local source = { "> *甲乙  ", "丙丁* [連結](https://example.invalid/a?x=1&amp;y=2)", "===" }
  local c = build(source)
  assert_eq(c.lines, { "│ 甲乙", "│ 丙丁 連結 ===" }, "Unicode hard breaks preserve the lazy underline")
  assert_eq(c.source_line_map, { 1, 2 }, "hard-break segments retain physical source rows")
  local italics = {}
  for _, info in ipairs(c.highlights) do
    for _, group in ipairs(info.groups) do
      if group.hl == "Italic" then italics[#italics + 1] = { info.line, group.col, group.end_col } end
    end
  end
  assert_eq(italics, { { 0, #"│ ", #"│ 甲乙" }, { 1, #"│ ", #"│ 丙丁" } }, "exact UTF-8 italic byte spans")
  assert_eq(c.link_metadata, {
    { line = 1, col_start = #"│ 丙丁 ", col_end = #"│ 丙丁 連結", url = "https://example.invalid/a?x=1&y=2" },
  }, "exact quoted link bytes and full destination")
  c = build { "> [!NOTE]- Fold", "> foo", "bar", "===", "", "outside" }
  assert_eq(c.callout_folds[1].source_line, 1, "callout fold keeps its original source row")
  assert_eq(c.lines[#c.lines], "outside", "collapsed fold stops at container exit")
  c = build({ "> [!NOTE]- Fold", "> foo", "bar", "===", "", "outside" }, { fold_state = { [1] = false } })
  assert_eq(vim.list_contains(c.lines, "│ foo bar ==="), true, "expanded callout retains lazy underline")
  c = build { "> ```markdown", "> foo", "> ===", "> ```", "outside" }
  assert_eq(c.lines, { "│ foo", "│ ===", "outside" }, "quoted code remains literal and cannot become a heading")
  assert_eq(c.heading_lines, {}, "quoted literal code has no heading")

  local preview = require "md-render.preview"
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
  vim.api.nvim_set_current_buf(buf)
  vim.cmd "vsplit"
  local win = vim.api.nvim_get_current_win()
  local mouse, supports, open = display.getmousepos, display.supports_osc8, vim.ui.open
  local ok, err = pcall(function()
    preview.toggle { text_scale = false }
    local session = assert(preview._toggle_sessions[buf])
    display.supports_osc8 = function()
      return false
    end
    for _, width in ipairs { 60, 14 } do
      vim.api.nvim_win_set_width(win, width)
      session:resize(win)
      session:rebuild()
      c = session.content
      assert_eq(vim.api.nvim_win_get_width(win), width, "requested lazy preview window width")
      assert_eq(session.opts.max_width, width, "lazy renderer uses actual preview width")
      if width == 14 then assert(#c.lines > 2, "narrow lazy preview reflows the literal underline") end
      assert_eq(vim.api.nvim_buf_get_lines(session.buf, 0, -1, false), c.lines, "lazy quote public preview buffer")
      assert_eq(c.heading_lines, {}, "preview lazy underline has no heading")
      for _, line in ipairs(c.lines) do
        if line:find("===", 1, true) then
          assert_eq(line:match "^%s*(│ )", "│ ", "rebuild keeps underline quoted")
        end
      end
      local activated = {}
      vim.ui.open = function(url)
        activated[#activated + 1] = url
      end
      for _, link in ipairs(c.link_metadata) do
        display.getmousepos = function()
          return { winid = vim.api.nvim_get_current_win(), line = link.line + 1, column = link.col_start + 1 }
        end
        vim.fn.maparg("<LeftRelease>", "n", false, true).callback()
      end
      assert_eq(activated, { "https://example.invalid/a?x=1&y=2" }, "lazy quoted link activates exact destination")
    end
  end)
  display.getmousepos, display.supports_osc8, vim.ui.open = mouse, supports, open
  if preview._toggle_sessions[buf] then preview.toggle() end
  assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), source, "lazy public preview keeps source unchanged")
  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, err)
end

do
  local source = { "> one", "two", "", "> [!NOTE]- Fold", "> body", "lazy", "> tail", "", "outside" }
  local c = build(source)
  assert_eq(c.callout_folds[1].source_line, 4, "callout keys use original rows after earlier joins")
  assert_eq(c.lines[#c.lines], "outside", "collapsed callout ends at the blank boundary")
  c = build(source, { fold_state = { [4] = false } })
  assert_eq(vim.list_contains(c.lines, "│ body lazy tail"), true, "original fold override reveals the lazy body")
  c = build { "- item", "  > [!NOTE]- Fold", "  > hidden", "> visible" }
  assert_eq(c.lines[#c.lines], "│ visible", "a collapsed callout cannot hide another list container's quote")
end

-- Test 8: a quote inside a fenced code block is content, not a quote
do
  local out = render { "```markdown", "  > これはコードの中身。", "```" }
  assert_eq(out, { "  > これはコードの中身。" }, "code block content must not be touched")

  out = render { "- item", "", "  ```markdown", "  > コードの中身。", "  ```" }
  assert_eq(out, { "• item", "  > コードの中身。" }, "code block in a list item must not be touched")
end

print(string.format("\nblockquote_indent_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
