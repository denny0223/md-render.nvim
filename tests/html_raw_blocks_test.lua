-- Raw block grammar: CommonMark 0.31.2 examples 148/162 (GFM 0.29-gfm 118/132).
-- Specification examples are CC BY-SA 4.0: https://spec.commonmark.org/0.31.2/#html-blocks
-- Run: NVIM_LOG_FILE=/tmp/compat-html-nvim.log nvim --headless -u NONE --noplugin -l tests/html_raw_blocks_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
require("md-render.image").supports_kitty = function()
  return false
end
local Builder = require("md-render.content_builder").ContentBuilder
local display = require "md-render.display_utils"
local Links = require "md-render.links"
local markdown = require "md-render.markdown"
local checks = 0
local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    label .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)
  )
  checks = checks + 1
end
local function build(source, opts)
  local original = vim.deepcopy(source)
  local b = Builder.new()
  b:render_document(source, vim.tbl_extend("force", { max_width = 100, indent = "", text_scale = false }, opts or {}))
  local c = b:result()
  eq(source, original, "builder preserves source bytes")
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "html_raw_blocks_test"
  display.apply_content_to_buffer(buf, ns, c)
  eq(
    vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    #c.lines > 0 and c.lines or { "" },
    "actual buffer matches physical output rows"
  )
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  for row, line in ipairs(c.lines) do
    eq(line:find("\n", 1, true), nil, "output row has no embedded newline")
    eq(
      c.source_line_map[row] >= 1 and c.source_line_map[row] <= #source,
      true,
      "source row stays in the original buffer"
    )
  end
  for _, mark in ipairs(marks) do
    local details = mark[4]
    if details.end_col then
      eq(details.end_col <= #c.lines[details.end_row + 1], true, "actual extmark end is within UTF-8 byte range")
    end
  end
  for _, link in ipairs(c.link_metadata) do
    eq(Links.at(buf, ns, link.line, link.col_start), link.url, "first actual link byte retains its full target")
    eq(Links.at(buf, ns, link.line, link.col_end - 1), link.url, "last actual link byte retains its full target")
    for _, col in ipairs { link.col_start - 1, link.col_end } do
      local expected
      for _, other in ipairs(c.link_metadata) do
        if other.line == link.line and col >= other.col_start and col < other.col_end then expected = other.url end
      end
      eq(Links.at(buf, ns, link.line, col), expected, "adjacent actual byte stays outside the link")
    end
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  return c, marks
end
local function styled(c, name)
  local result = {}
  for _, row in ipairs(c.highlights) do
    for _, hl in ipairs(row.groups) do
      if hl.hl == name then
        local text = c.lines[row.line + 1]
        result[#result + 1] =
          { c.source_line_map[row.line + 1], text:sub(hl.col + 1, hl.end_col == -1 and #text or hl.end_col) }
      end
    end
  end
  return result
end
local function targets(c)
  local result = {}
  for _, link in ipairs(c.link_metadata) do
    result[#result + 1] =
      { c.source_line_map[link.line + 1], c.lines[link.line + 1]:sub(link.col_start + 1, link.col_end), link.url }
  end
  return result
end
local function urls(marks)
  local result = {}
  for _, mark in ipairs(marks) do
    if mark[4].url then result[#result + 1] = mark[4].url end
  end
  table.sort(result)
  return result
end
local function marker_spans(marks)
  local result = {}
  for _, mark in ipairs(marks) do
    if mark[4].hl_group == "Special" then result[#result + 1] = { mark[2], mark[3], mark[4].end_col } end
  end
  return result
end

local anchor_source = { '<a href="foo">', "*bar*", "</a>" }
local quoted_href_source = { '<a href="two<!--keep-->spaces.md">', "*別*", "</a>" }
local heading_attribute_target = "foo<img src='evil.png' alt='trap'>bar"
local heading_attribute_source = { '<h1><a href="' .. heading_attribute_target .. '">label</a></h1>' }
local ordered_heading_images_source = { '<h1><img src="a.png" alt="first"><img src="b.png" alt="second"></h1>' }
local mixed_heading_images_source = {
  '<h1><a href="' .. heading_attribute_target .. '">label</a><img src="a.png" alt="actual"></h1>',
}

-- Attribute contents never supply wrapper, table, media or fold syntax.
local token_body = '*別* <em>斜體</em> <a href="two>part<!--keep-->spaces.md">連結</a>'
for _, source in ipairs {
  { '<div title="VALUE">' .. token_body .. "</div>" },
  { "<span title='VALUE'>" .. token_body .. "</span>" },
  { '<p title="VALUE">' .. token_body .. "</p>" },
  { '<h2 title="VALUE">' .. token_body .. "</h2>" },
  { '<div title="VALUE">', token_body, "</div>" },
  { '<table title="VALUE"><tr><th>' .. token_body .. "</th></tr></table>" },
  { '<table><tr title="VALUE"><th>' .. token_body .. "</th></tr></table>" },
  { "<table>", '<tr><th title="VALUE">' .. token_body .. "</th></tr>", "</table>" },
  { "<table>", '<tr><td title="VALUE">' .. token_body .. "</td></tr>", "</table>" },
  { '<figure title="VALUE">', "<figcaption>" .. token_body .. "</figcaption>", "</figure>" },
  { '<details title="VALUE" open>', "<summary>" .. token_body .. "</summary>", "*raw*", "</details>" },
  { '<hr title="VALUE">' },
} do
  local function replace(value)
    return vim.tbl_map(function(line)
      return (line:gsub("VALUE", value))
    end, source)
  end
  local control = build(replace "plain")
  local c = build(replace "a > </table></tr></th></td><tr><td>TRAP</td></tr> <img src=evil>")
  eq(c.lines, control.lines, "quoted syntax cannot change supported HTML presentation")
  eq(c.source_line_map, control.source_line_map, "complete tokens retain physical source ownership")
  eq(targets(c), targets(control), "attribute syntax cannot create or truncate a target")
  eq(styled(c, "Italic"), styled(control, "Italic"), "real HTML styles retain exact UTF-8 label bytes")
  eq(c.heading_lines, control.heading_lines, "heading rank is independent of quoted syntax")
  eq(c.callout_folds, control.callout_folds, "fold state is independent of quoted syntax")
end
do
  local c = build { '<a title=\'href="trap"\' href="real">別</a>' }
  eq(c.lines, { "別" }, "anchor displays its body")
  eq(targets(c), { { 1, "別", "real" } }, "only the actual href supplies the complete target")
  for _, attrs in ipairs { 'title="open"', 'title="a > open"', 'data-open="true"' } do
    local folded = build { "<details " .. attrs .. ">", "<summary>標題</summary>", "*body*", "</details>" }
    eq(folded.lines, { "▶ 標題" }, "open-looking attribute values do not expand details")
    eq(folded.callout_folds[1].collapsed, true, "details without an open attribute defaults closed")
  end
  for _, attrs in ipairs { 'title="a > b" open', 'open="false"', "OPEN" } do
    local expanded = build { "<details " .. attrs .. ">", "<summary>標題</summary>", "*body*", "</details>" }
    eq(expanded.lines, { "▼ 標題", "│ *body*" }, "the actual boolean open attribute expands details")
    eq(expanded.callout_folds[1].collapsed, false, "present open uses HTML boolean semantics")
  end
  local plain = build { '<table><tr><th align="left">Longheading</th></tr><tr><td>x</td></tr></table>' }
  local attrs =
    build { '<table><tr><th title=\'align="right"\' align="left">Longheading</th></tr><tr><td>x</td></tr></table>' }
  eq(attrs.lines, plain.lines, "alignment comes from the actual quoted attribute")
  local commented = build { "<table><!-- <tr><th>TRAP</th></tr> --><tr><th>Longheading</th></tr></table>" }
  local bare = build { "<table><tr><th>Longheading</th></tr></table>" }
  eq(commented.lines, bare.lines, "comment payload never creates table rows or cells")
  local literal = '<custom title="<em>TRAP</em><img src=evil>">*BODY*</custom>'
  local unsupported = build { "<div>", literal, "</div>" }
  eq(unsupported.lines, { literal }, "unsupported complete tokens remain readable and intact")
  eq(styled(unsupported, "Italic"), {}, "a fake supported tag inside an attribute cannot add a style")
  eq(unsupported.image_placements, {}, "a fake image inside an attribute cannot create media")
  for _, line in ipairs { '<div title="unclosed>BODY</div>', "<division>BODY</division>", "<detailsx>BODY</detailsx>" } do
    eq(build({ line }).lines, { line }, "invalid tokens and lookalike names are not display wrappers")
  end
end

for _, name in ipairs { "dt", "dd" } do
  local href = "x</" .. name .. ">y<br>z"
  local c = build { "<dl>", "<" .. name .. '><a href="' .. href .. '">名</a></' .. name .. ">", "</dl>" }
  eq(
    c.lines,
    { (name == "dd" and "  " or "") .. "名", "" },
    "only real definition-list closing and break tokens split text"
  )
  eq(targets(c), { { 2, "名", href } }, "definition-list anchors preserve fake structural bytes in their target")
end
do
  local c = build { "<dl>", '<dt><a href="x<br>y">名</a><br>Second</dt>', "</dl>" }
  eq(c.lines, { "名", "Second", "" }, "a real br splits definition text after the complete anchor")
  eq(targets(c), { { 2, "名", "x<br>y" } }, "quoted br data does not split the anchor target")
  for _, source in ipairs { "<p/>KEEP", "<p>KEEP", '<p title="a > b">KEEP', "<p/>KEEP</p>" } do
    eq(build({ source }).lines, { source }, "unsupported paragraph forms retain their complete readable payload")
  end
  for _, name in ipairs { "a", "video" } do
    local attrs = name == "a" and 'href="real"' or 'src="clip.mp4"'
    local wiki =
      build { "[[outer|<" .. name .. " " .. attrs .. '>BODY<custom title="</' .. name .. '>">tail</custom>]]' }
    eq(#wiki.link_metadata, 1, "a fake closer cannot block the eligible wiki target")
    eq(
      wiki.link_metadata[1].url,
      "obsidian://advanced-uri?filepath=outer",
      "missing real closer preserves extension eligibility"
    )
    local actual = build { "[[outer|<" .. name .. " " .. attrs .. ">BODY</" .. name .. " >]]" }
    eq(#actual.link_metadata, 1, "a real whitespace closing tag retains standard target priority")
    eq(
      actual.link_metadata[1].url,
      name == "a" and "real" or "clip.mp4",
      "supported HTML target owns the competing label"
    )
  end
end

-- Physical rows inside a complete multi-line token retain its literal ownership.
local multiline_attribute_source =
  { "<div>", "<a", 'href="x', '<!-- trap -->y">*BODY*</a>', "*raw*", "</div>", "", "*after*" }
do
  local c = build(multiline_attribute_source)
  eq(c.lines, { "*BODY*", "*raw*", "", "after" }, "a quoted comment-looking row cannot hide the anchor or body")
  eq(c.source_line_map, { 4, 5, 7, 8 }, "multi-line anchor body and resumed paragraph keep physical rows")
  eq(targets(c), { { 4, "*BODY*", "x\n<!-- trap -->y" } }, "multi-line quoted href retains all source bytes")
  eq(styled(c, "Italic"), { { 8, "after" } }, "only the paragraph after the raw boundary parses emphasis")
  local literal = { '<div title="a >', "<!-- trap", 'b">BODY</div>', "", "*after*" }
  local raw = build(literal)
  eq(
    raw.lines,
    { literal[1], literal[2], literal[3], "", "after" },
    "a comment-looking attribute cannot erase raw rows"
  )
  eq(raw.source_line_map, { 1, 2, 3, 4, 5 }, "readable multi-line opener preserves every physical row")
end
for _, source in ipairs {
  { "<div>", '<a title="a', "VALUE", 'b" href="real">*別*</a>', "</div>", "", "*after*" },
  { "> <div>", '> <a title="a', "> VALUE", '> b" href="real">*別*</a>', "> </div>", "", "*after*" },
  { "- <div>", '  <a title="a', "  VALUE", '  b" href="real">*別*</a>', "  </div>", "", "*after*" },
  { "> - <div>", '>   <a title="a', ">   VALUE", '>   b" href="real">*別*</a>', ">   </div>", "", "*after*" },
  { "<table>", '<tr><td title="a', "VALUE", 'b">*別*</td></tr>', "</table>", "", "*after*" },
  { "<h2>", '<a title="a', "VALUE", 'b" href="real">*別*</a>', "</h2>" },
  {
    "<details open>",
    "<summary>",
    '<a title="a',
    "VALUE",
    'b" href="real">*別*</a>',
    "</summary>",
    "*body*",
    "</details>",
  },
  { "<details open>", '<summary><a title="VALUE', 'tail" href="real">*別*</a>', "</summary>", "*body*", "</details>" },
  { '<details open><summary><a title="VALUE', 'tail" href="real">*別*</a>', "</summary>", "*body*", "</details>" },
  {
    "<details open>",
    "<summary>",
    '<a title="a',
    "VALUE",
    'b" href="real">*別*</a></summary>',
    "*body*",
    "</details>",
  },
} do
  local function replace(value)
    return vim.tbl_map(function(line)
      return (line:gsub("VALUE", value))
    end, source)
  end
  local control = build(replace "plain")
  for _, token_text in ipairs {
    "<!-- trap -->",
    "</table><table><tr><td>TRAP</td></tr>",
    "<div><p><details open><img src=evil>",
    "</h2></summary></details>",
    "</summary>",
    "</details>",
  } do
    local c = build(replace(token_text))
    eq(c.lines, control.lines, "cross-line attribute syntax cannot change display structure")
    eq(c.source_line_map, control.source_line_map, "cross-line token ownership remains physical")
    eq(targets(c), targets(control), "cross-line attribute syntax cannot change real targets")
    eq(styled(c, "Italic"), styled(control, "Italic"), "cross-line attribute syntax cannot add emphasis")
    eq(c.heading_lines, control.heading_lines, "fake cross-line closer cannot retire the heading")
    eq(c.callout_folds, control.callout_folds, "fake cross-line closer cannot retire details")
    eq(c.image_placements, control.image_placements, "fake cross-line image cannot create media")
  end
end

-- Inline-started comments are opaque to both raw display and block presentation.
local multiline_comment_source = { "<div>", "prefix <!--", "<h2>TRAP</h2>", "-->", "*raw*", "</div>", "", "*after*" }
for _, payload in ipairs {
  { "<h2>TRAP</h2>" },
  { "<details open>", "<summary>TRAP</summary>", "</details>" },
  { "<table><tr><td>TRAP</td></tr></table>" },
  { '<img src="evil.png" alt="TRAP">' },
} do
  local source = { "<div>", "prefix <!--" }
  vim.list_extend(source, payload)
  vim.list_extend(source, { "-->", "*raw*", "</div>", "", "*after*" })
  local c = build(source)
  eq(c.lines, { "prefix ", "*raw*", "", "after" }, "inline-started comment payload never reaches display handlers")
  eq(
    c.source_line_map,
    { 2, #source - 3, #source - 1, #source },
    "hidden comment rows preserve following physical owners"
  )
  eq(c.heading_lines, {}, "comment headings cannot create a heading presentation")
  eq(c.callout_folds, {}, "comment details cannot create a fold")
  eq(c.image_placements, {}, "comment images cannot create a placement")
  eq(targets(c), {}, "comment payload cannot create a target")
  eq(styled(c, "Italic"), { { #source, "after" } }, "emphasis resumes only after the raw owner ends")
end

do
  local c, marks = build(anchor_source)
  eq(c.lines, { "*bar*" }, "CM162 preserves stars in HTML anchor text")
  eq(c.source_line_map, { 2 }, "anchor text maps to its physical source row")
  eq(
    c.link_metadata,
    { { line = 0, col_start = 0, col_end = 5, url = "foo" } },
    "supported anchor has exact literal label bytes and full target"
  )
  eq(styled(c, "Italic"), {}, "Markdown emphasis cannot style HTML anchor text")
  eq(urls(marks), { "foo" }, "actual buffer exposes the HTML-derived target only")
end
local table_boundary = { "<table><tr><td>", "<pre>", "**Hello**,", "", "_world_.", "</pre>", "</td></tr></table>" }
local summary_boundary = { "<details open>", "<summary>", "*raw*", "", "*after*", "</summary>", "</details>" }
local dl_boundary = { "<dl>", "<dt>*raw*</dt>", "", "*after*", "</dl>" }
do
  local c = build(table_boundary)
  eq(
    c.lines,
    { "<table><tr><td>", "<pre>", "**Hello**,", "", "world. </pre>", "</td></tr></table>" },
    "CM148 releases the table at its blank-line boundary"
  )
  eq(c.source_line_map, { 1, 2, 3, 4, 5, 7 }, "CM148 raw physical rows and following paragraph retain source ownership")
  eq(styled(c, "Bold"), {}, "Hello remains literal before the table boundary")
  eq(styled(c, "Italic"), { { 5, "world" } }, "world receives Markdown emphasis after the table boundary")
end

-- Types 1–5 include same-line closers and closing-line suffixes, even across blanks.
for _, form in ipairs {
  { "<pre>", "</style>", 1 },
  { "<script>", "</TEXTAREA>", 1 },
  { "<style>", "</pre>", 1 },
  { "<textarea>", "</script>", 1 },
  { "<!--", "-->", 2 },
  { "<?php", "?>", 3 },
  { "<!doctype", ">", 4 },
  { "<![CDATA[", "]]>", 5 },
} do
  local opening, closing, kind = unpack(form)
  local source = { opening, "*owned*", "", "# literal", closing .. "*tail*", "*after*" }
  local c = build(source)
  if kind == 2 then
    eq(c.lines, { "*tail*", "after" }, "comment hiding keeps the closing-line suffix literal")
    eq(c.source_line_map, { 5, 6 }, "comment suffix and resumed paragraph source rows")
  else
    eq(
      c.lines,
      { opening, "*owned*", "", "# literal", closing .. "*tail*", "after" },
      "raw form owns blank rows and literal block/inline markers " .. opening
    )
    eq(c.source_line_map, { 1, 2, 3, 4, 5, 6 }, "raw physical rows remain mapped " .. opening)
  end
  eq(styled(c, "Italic"), { { 6, "after" } }, "only text following the actual closer parses Markdown " .. opening)
  eq(c.code_blocks, {}, "raw fence-looking payload never becomes code " .. opening)
  local same = build { opening .. closing .. "*tail*", "*after*" }
  eq(styled(same, "Italic"), { { 2, "after" } }, "same-line close owns its suffix only " .. opening)
  local eof = build { opening, "*owned*", "# literal" }
  eq(styled(eof, "Italic"), {}, "EOF keeps the last owned row literal " .. opening)
  eq(eof.heading_lines, {}, "EOF raw headings stay literal " .. opening)
end

-- Type 6/7 ignore balanced inner tags and stop only at blank/container/EOF.
for _, opening in ipairs { "<div>", "<search>", "<source>", '<custom-tag key="value">', "</div>", "</x>" } do
  local c = build { opening, "*owned*", "</pre>", "*still owned*", "", "*after*" }
  eq(styled(c, "Italic"), { { 6, "after" } }, "blank ends current raw owner regardless of inner closer " .. opening)
  local found = {}
  for row, text in ipairs(c.lines) do
    if text == "*owned*" or text == "*still owned*" then found[#found + 1] = { c.source_line_map[row], text } end
  end
  eq(
    found,
    { { 2, "*owned*" }, { 4, "*still owned*" } },
    "each literal raw payload retains its physical row " .. opening
  )
  local eof = build { opening, "*owned*" }
  eq(styled(eof, "Italic"), {}, "type 6/7 owns literal payload through EOF " .. opening)
end

-- Raw HTML payload cannot open a second block-comment namespace.
for _, marker in ipairs { "%%", "<!--" } do
  for _, container in ipairs {
    { "<div>", "", "" },
    { "> <div>", "> ", ">" },
    { "- <div>", "  ", "" },
    { "> - > <div>", ">   > ", ">   >" },
  } do
    local c = build { container[1], container[2] .. marker, container[2] .. "*raw*", container[3], "*after*" }
    eq(styled(c, "Italic"), { { 5, "after" } }, "raw comment-looking payload ends at its HTML owner boundary")
    if marker == "%%" then
      local raw_row
      for row, text in ipairs(c.lines) do
        if text:find("*raw*", 1, true) then raw_row = c.source_line_map[row] end
      end
      eq(raw_row, 3, "raw Obsidian-looking payload remains literal and physically mapped")
    end
  end
end
for _, source in ipairs {
  { "<div>", "%%", "*raw*", "%%", "</div>", "", "*after*" },
  { "<pre>", "%%", "*raw*", "</pre>", "*after*" },
  { "<div>%%", "*raw*", "", "*after*" },
  { "> <div>%%", "> *raw*", ">", "*after*" },
} do
  local c = build(source)
  eq(styled(c, "Italic"), { { #source, "after" } }, "raw Obsidian markers cannot hide later Markdown")
  eq(table.concat(c.lines, "\n"):find("*raw*", 1, true) ~= nil, true, "raw Obsidian markers preserve literal payload")
end

do
  local source = {
    "<div>",
    "# heading",
    "9. first",
    "1. second",
    "[r]: /inside",
    "[^n]: hidden",
    "```lua",
    "[[wiki]] ![[media.png]] $math$ [r] [^n]",
    "| a |",
    "| --- |",
    "</div>",
    "",
    "*after* [r] [^n]",
  }
  local c, marks = build(source)
  eq(c.lines, {
    "# heading",
    "9. first",
    "1. second",
    "[r]: /inside",
    "[^n]: hidden",
    "```lua",
    "[[wiki]] ![[media.png]] $math$ [r] [^n]",
    "| a |",
    "| --- |",
    "",
    "after [r] [^n]",
  }, "every preprocessing/inline claimant leaves raw syntax literal")
  eq(
    c.source_line_map,
    { 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 13 },
    "opaque rows survive joining and numbering with physical source rows"
  )
  eq(c.code_blocks, {}, "raw fence is not reopened")
  eq(c.heading_lines, {}, "raw heading has no heading metadata")
  eq(c.footnote_anchors, {}, "raw footnote never enters the document namespace")
  eq(targets(c), {}, "raw definitions and wiki/embed syntax cannot activate targets")
  eq(urls(marks), {}, "actual buffer has no URL from raw Markdown syntax")
  eq(styled(c, "Italic"), { { 13, "after" } }, "Markdown resumes after raw blank boundary")
end

-- Paragraph context: types 1–6 interrupt; type 7 and invalid tags stay inline.
for _, opening in ipairs { "<pre>", "<!--", "<?x", "<!doctype", "<![CDATA[", "<div>", "<search>" } do
  local c = build { "before", opening, "*owned*" }
  eq(c.lines[1], "before", "interrupting HTML starts after a paragraph " .. opening)
  eq(styled(c, "Italic"), {}, "interrupting raw owner retains stars " .. opening)
end
for _, opening in ipairs { "<custom-tag>", "<span>", "<source>", '<a href="foo">', '<invalid-tag attr="unclosed>' } do
  local c = build { "before", opening, "*parsed*" }
  eq(styled(c, "Italic"), { { 1, "parsed" } }, "noninterrupting token stays in the existing paragraph " .. opening)
end
do
  local c = build { '[r]: /url "title', "<custom-tag>", 'end"', "", "[r]" }
  eq(c.lines, { "", "r" }, "noninterrupting complete tag may remain inside a valid reference title")
  eq(c.source_line_map, { 4, 5 }, "consumed reference title keeps the later physical use row")
  eq(targets(c), { { 5, "r", "/url" } }, "reference collection still resolves a title containing a type-7 tag")
  local interrupted = build { '[r]: /url "title', "<div>", 'end"', "", "[r]" }
  eq(
    interrupted.lines,
    { '[r]: /url "title', 'end"', "", "[r]" },
    "interrupting raw block prevents a multiline reference title"
  )
  eq(interrupted.source_line_map, { 1, 3, 4, 5 }, "reference interruption retains literal physical source rows")
  eq(targets(interrupted), {}, "raw title interruption cannot create a reference destination")
end

for _, container in ipairs {
  { "> ", "│ ", { "*after*" }, "after" },
  { "- <div>", "", { "*after*" }, "after" },
} do
  local source
  if container[1] == "> " then
    source = { "> <div>", "> *owned*", "> </div>", "*after*" }
  else
    source = { "- <div>", "  *owned*", "  </div>", "*after*" }
  end
  local c = build(source)
  eq(styled(c, "Italic"), { { 4, "after" } }, "container exit releases an unterminated blank-ended raw owner")
  eq(c.lines[#c.lines], "after", "container exit resumes root Markdown")
  eq(c.source_line_map[#c.lines], 4, "container exit source row stays physical")
end
for _, prefix in ipairs { "> ", "- " } do
  local source = prefix == "> " and { "> <pre>", "> *owned*", "*after*" } or { "- <pre>", "  *owned*", "*after*" }
  local c = build(source)
  eq(styled(c, "Italic"), { { 3, "after" } }, "container exit ends a type-1 owner without a closing tag")
end
for _, opening in ipairs { "<pre>", "<!--", "<?x", "<!doctype", "<![CDATA[", "<div>", "<custom-tag>" } do
  for _, quote in ipairs { false, true } do
    local source = quote and { "> " .. opening, "> *owned*", "*after*" } or { "- " .. opening, "  *owned*", "*after*" }
    local c = build(source)
    eq(
      styled(c, "Italic"),
      { { 3, "after" } },
      "every raw form ends at an explicit list/quote container exit " .. opening
    )
    eq(c.code_blocks, {}, "container-local HTML never leaks code ownership " .. opening)
    eq(c.link_metadata, {}, "container-local raw text cannot become Markdown links " .. opening)
  end
end
do
  local c = build { "<div>", "    **raw**", "\t*raw tab*", "</div>", "", "*after*" }
  eq(
    c.lines,
    { "    **raw**", "\t*raw tab*", "", "after" },
    "active HTML owner prevents indented code and preserves tabs"
  )
  eq(c.source_line_map, { 2, 3, 5, 6 }, "indented raw text keeps exact physical source rows")
  eq(c.code_blocks, {}, "code may not open within active raw HTML")
  eq(styled(c, "String"), {}, "indented raw HTML never gets code styling")
  eq(styled(c, "Bold"), {}, "indented raw Markdown stars remain literal")
  eq(styled(c, "Italic"), { { 6, "after" } }, "Markdown resumes after the indented raw owner")
end
for _, pending_blank in ipairs { false, true } do
  local source = { "    before" }
  if pending_blank then source[#source + 1] = "" end
  vim.list_extend(source, { "<div>", "    **raw**", "</div>", "", "    after" })
  local c = build(source)
  local shift = pending_blank and 1 or 0
  eq(
    c.lines,
    pending_blank and { "before", "", "    **raw**", "", "after" } or { "before", "    **raw**", "", "after" },
    "root code closes before HTML and may reopen after the raw boundary"
  )
  eq(
    c.source_line_map,
    pending_blank and { 1, 2, 3 + shift, 5 + shift, 6 + shift } or { 1, 3, 5, 6 },
    "code and HTML ownership keep each physical payload row"
  )
  eq(
    styled(c, "String"),
    { { 1, "before" }, { 6 + shift, "after" } },
    "pending code blanks cannot claim raw indented payload"
  )
  eq(styled(c, "Bold"), {}, "raw stars stay literal between two root code owners")
end
for _, byte in ipairs { 1, 11, 12 } do
  local opening = "<x a=" .. string.char(byte) .. ">"
  local c = build { opening, "*owned*", "", "*after*" }
  eq(
    c.lines,
    { opening, "*owned*", "", "after" },
    "explicit unquoted-attribute grammar accepts non-whitespace control byte " .. byte
  )
  eq(c.source_line_map, { 1, 2, 3, 4 }, "control-byte opening preserves physical ownership")
  eq(styled(c, "Italic"), { { 4, "after" } }, "control-byte tag owns following literal stars")
end
do
  local c = build { '> <a href="foo">', "> *owned*", "> </a>", "*after*" }
  eq(c.lines, { "│ *owned*", "after" }, "quoted supported anchor keeps stars and quote prefix")
  eq(targets(c), { { 2, "*owned*", "foo" } }, "quoted anchor maps exact label and target to physical source row")
end

-- Supported terminal tags retain semantics; their payload never becomes Markdown.
for _, case in ipairs {
  { "two<!--keep-->spaces.md", "two<!--keep-->spaces.md" },
  { "two&amp;<!--keep-->spaces.md", "two&<!--keep-->spaces.md" },
  { "two&lt;!--keep--&gt;spaces.md", "two<!--keep-->spaces.md" },
  { "two&amp;lt;!--keep--&amp;gt;spaces.md", "two&lt;!--keep--&gt;spaces.md" },
  { "two\\<!--keep-->spaces.md", "two\\<!--keep-->spaces.md" },
  { "two>spaces.md", "two>spaces.md" },
} do
  local c = build { '<a href="' .. case[1] .. '">', "*別*", "</a>" }
  eq(c.lines, { "*別*" }, "quoted HTML attributes preserve literal tag-looking bytes")
  eq(targets(c), { { 2, "*別*", case[2] } }, "quoted HTML target remains complete and decodes once")
  eq(styled(c, "Italic"), {}, "literal stars in raw anchor text do not activate emphasis")
end
do
  local tag = '<x attr="a<!--keep-->b>c">'
  eq(build({ tag }).lines, { tag }, "unsupported complete tag keeps every quoted attribute byte")
  eq(build({ "<!-- hidden -->" .. tag }).lines, { tag }, "comment closing suffix preserves quoted attributes")
  local c = build { "<div>", '<a href="two<!--keep-->spaces.md">*別*</a><!-- hidden -->' }
  eq(targets(c), { { 2, "*別*", "two<!--keep-->spaces.md" } }, "real comment outside attributes remains hidden")
end
for _, case in ipairs { { "a>b", "a>b" }, { "a&gt;b", "a>b" }, { "a<!--keep-->b", "a<!--keep-->b" } } do
  local icons = require "md-render.icons"
  local label = icons.pad_icon(icons.get_image_icon "a.png") .. " " .. case[2]
  local c = build { "<div>", 'before <img src="a.png" alt="' .. case[1] .. '"> after', "</div>" }
  eq(c.lines, { "before " .. label .. " after" }, "complete image attribute supplies the literal label")
  eq(targets(c), { { 2, label, "a.png" } }, "inline image preserves its target and displayed label range")
  eq(styled(c, "MdRenderLink"), { { 2, case[2] } }, "inline image target color covers the displayed label")
end
do
  local icons = require "md-render.icons"
  local label = icons.pad_icon(icons.get_image_icon "a.png") .. " a>b"
  local c = build { '<img src="a.png" alt="a>b">' }
  eq(c.lines, { label }, "standalone image keeps its existing media header presentation")
  eq(c.link_metadata, {}, "standalone media header preserves its existing link policy")
  local heading = build { '<h1>title<img src="a.png" alt="a>b"></h1>' }
  eq(heading.lines[#heading.lines], label, "heading image extraction retains the complete quoted tag")
  eq(heading.source_line_map[#heading.lines], 1, "synthetic heading image keeps its physical source row")
end
do
  local icons = require "md-render.icons"
  local image_icon = icons.pad_icon(icons.get_image_icon "a.png") .. " "
  local heading_lines = { "# label", string.rep("═", 100) }
  for _, source in ipairs { heading_attribute_source, mixed_heading_images_source } do
    local c = build(source)
    local expected = vim.deepcopy(heading_lines)
    if source == mixed_heading_images_source then expected[#expected + 1] = image_icon .. "actual" end
    eq(c.lines, expected, "heading attributes cannot manufacture image rows or change heading presentation")
    eq(
      targets(c),
      { { 1, "label", heading_attribute_target } },
      "heading image extraction preserves the full quoted href"
    )
    eq(
      c.source_line_map,
      source == heading_attribute_source and { 1, 1 } or { 1, 1, 1 },
      "heading and media retain their original source row"
    )
  end
  local ordered = build(ordered_heading_images_source)
  eq(
    ordered.lines,
    { image_icon .. "first", image_icon .. "second" },
    "actual heading images preserve their source order"
  )
  eq(ordered.source_line_map, { 1, 1 }, "every synthetic heading image retains its original physical source row")
  eq(ordered.link_metadata, {}, "heading media preserves the standalone image link policy")
end
do
  local c = build { "<div>", "<b>*literal* <em>styled</em></b>", '<a href="/a?x=1&amp;y=2">**label**</a>', "</div>" }
  eq(c.lines, { "*literal* styled", "**label**" }, "supported paired tags preserve literal Markdown punctuation")
  eq(styled(c, "Bold"), { { 2, "*literal* styled" } }, "HTML b supplies the only bold style")
  eq(styled(c, "Italic"), { { 2, "styled" } }, "HTML em supplies the only italic style")
  eq(targets(c), { { 3, "**label**", "/a?x=1&y=2" } }, "HTML anchor target decodes once with full label range")
end
for _, entity in ipairs { { "&#10;", "\n" }, { "&#13;", "\r" }, { "&NewLine;", "\n" } } do
  local spelling, value = unpack(entity)
  local c, marks = build { '<a href="/a' .. spelling .. 'b">', "L" .. spelling .. "R", "</a>" }
  eq(c.lines, { "L R" }, "decoded HTML display entity stays on one physical row " .. spelling)
  eq(c.source_line_map, { 2 }, "display entity does not add or shift a physical source row " .. spelling)
  eq(
    targets(c),
    { { 2, "L R", "/a" .. value .. "b" } },
    "raw HTML anchor preserves the decoded full target " .. spelling
  )
  eq(urls(marks), { "/a" .. value .. "b" }, "actual anchor URL mark preserves the decoded target " .. spelling)
  local inline = build { 'before <a href="/a' .. spelling .. 'b">label</a>' }
  eq(
    targets(inline),
    { { 1, "label", "/a" .. value .. "b" } },
    "ordinary inline HTML target remains unchanged " .. spelling
  )

  local icons = require "md-render.icons"
  local image_target = "/a" .. value .. "b.png"
  local image_label = icons.pad_icon(icons.get_image_icon(image_target)) .. " L R"
  local image, image_marks = build {
    "<div>",
    'before <img src="/a' .. spelling .. 'b.png" alt="L' .. spelling .. 'R">',
    "</div>",
  }
  eq(image.lines, { "before " .. image_label }, "image display entity stays on one physical row " .. spelling)
  eq(image.source_line_map, { 2 }, "image entity display retains its physical source row " .. spelling)
  eq(
    targets(image),
    { { 2, image_label, image_target } },
    "raw HTML image preserves its full decoded target " .. spelling
  )
  eq(urls(image_marks), { image_target }, "actual image URL mark preserves the decoded target " .. spelling)

  local video_target = "/a" .. value .. "b.mp4"
  local video_label = icons.pad_icon(icons.get_image_icon(video_target)) .. " a b.mp4"
  local video, video_marks = build { "<div>", 'before <video src="/a' .. spelling .. 'b.mp4"></video>', "</div>" }
  eq(video.lines, { "before " .. video_label }, "video filename entity stays on one physical row " .. spelling)
  eq(video.source_line_map, { 2 }, "video entity display retains its physical source row " .. spelling)
  eq(
    targets(video),
    { { 2, video_label, video_target } },
    "raw HTML video preserves its full decoded target " .. spelling
  )
  eq(urls(video_marks), { video_target }, "actual video URL mark preserves the decoded target " .. spelling)
end
do
  local c = build { "<h2>*literal* <em>styled</em></h2>" }
  eq(c.lines[1], "## *literal* styled", "HTML heading reuses title presentation without stripping stars")
  eq(styled(c, "Italic"), { { 1, "styled" } }, "HTML heading italic comes from its em tag")
  eq(c.heading_lines[0], true, "supported HTML heading keeps navigation metadata")
end
do
  local c = build { "<h2>", "*raw*", "", "*parsed*", "</h2>" }
  eq(c.lines, { "<h2>", "*raw*", "", "parsed", "</h2>" }, "HTML heading collector releases its raw owner at the blank")
  eq(c.source_line_map, { 1, 2, 3, 4, 5 }, "unbalanced HTML heading keeps physical raw and paragraph rows")
  eq(styled(c, "Italic"), { { 4, "parsed" } }, "HTML heading boundary resumes Markdown emphasis")
  eq(c.heading_lines, {}, "a heading collector cannot synthesize a heading across raw owners")
end
local quoted_heading_source = { "> <h2>", "> *title*", "> </h2>", "", "after" }
for _, case in ipairs {
  {
    quoted_heading_source,
    { "│ <h2>", "│ *title*", "│ </h2>", "", "after" },
    { 1, 2, 3, 4, 5 },
  },
  {
    { "> - > <h4>", ">   > *title*", ">   > </h4>", "> - sibling" },
    { "│ • ", "│   │ <h4>", "│   │ *title*", "│   │ </h4>", "│ • sibling" },
    { 1, 1, 2, 3, 4 },
  },
  {
    { "- > <h6>", "  > *title*", "  > </h6>", "- sibling" },
    { "• ", "  │ <h6>", "  │ *title*", "  │ </h6>", "• sibling" },
    { 1, 1, 2, 3, 4 },
  },
  {
    { "> <h2>*title*</h2>", "after" },
    { "│ <h2>*title*</h2>", "after" },
    { 1, 2 },
  },
} do
  local c = build(case[1])
  eq(c.lines, case[2], "quoted tag heading retains readable title and closing rows")
  eq(c.source_line_map, case[3], "quoted tag heading retains every physical source row")
  eq(c.heading_lines, {}, "quoted tag heading keeps its existing ordinary navigation behavior")
  eq(styled(c, "Italic"), {}, "quoted tag heading's raw title stars remain literal")
end
do
  local c = build { "<h2>", '<a href="two  spaces.md">*literal*</a> <em>styled</em>', "</h2>", "", "after" }
  eq(c.lines[1], "##  *literal* styled ", "supported unquoted multiline heading keeps its presentation")
  eq(c.source_line_map[1], 1, "supported multiline heading keeps its opening-row cursor policy")
  eq(c.heading_lines[0], true, "supported multiline heading retains navigation metadata")
  eq(styled(c, "Italic"), { { 1, "styled" } }, "supported multiline heading styles only the HTML em tag")
  eq(
    c.link_metadata,
    { { line = 0, col_start = 4, col_end = 13, url = "two  spaces.md" } },
    "supported multiline heading keeps exact literal label bytes and its full target"
  )
end
do
  local c = build { "> <h2>", '> <a href="two  spaces.md">*literal*</a> <em>styled</em>', "> </h2>", "", "after" }
  eq(
    c.lines,
    { "│ <h2>", "│ *literal* styled", "│ </h2>", "", "after" },
    "quoted heading retains supported title tags"
  )
  eq(c.source_line_map, { 1, 2, 3, 4, 5 }, "quoted linked title retains its physical payload row")
  eq(c.heading_lines, {}, "quoted linked title retains existing ordinary navigation")
  eq(styled(c, "Italic"), { { 2, "styled" } }, "quoted title styles only the supported em tag")
  eq(
    c.link_metadata,
    { { line = 1, col_start = 4, col_end = 13, url = "two  spaces.md" } },
    "quoted title keeps exact literal label bytes and its full target"
  )
end
do
  local c = build {
    "<details open>",
    "<summary>*literal* <em>styled</em></summary>",
    "*raw body*",
    "",
    "*Markdown body*",
    "",
    "</details>",
  }
  eq(c.lines[1], "▼ *literal* styled", "details summary preserves raw text and supported styling")
  eq(c.lines[2], "│ *raw body*", "details body remains raw until blank")
  eq(
    styled(c, "Italic"),
    { { 2, "styled" }, { 5, "Markdown body" } },
    "fold display ownership spans distinct raw/Markdown owners"
  )
  eq(
    c.callout_folds,
    { { header_line = 0, source_line = 1, collapsed = false } },
    "details keeps its supported fold contract"
  )
end
do
  local c = build(summary_boundary)
  eq(
    c.lines,
    { "▼ *raw*", "│ ", "│ after", "│ </summary>" },
    "unfinished details summary releases its raw owner at the blank"
  )
  eq(c.source_line_map, { 2, 4, 5, 6 }, "released summary and Markdown body retain physical source rows")
  eq(styled(c, "Italic"), { { 5, "after" } }, "details summary cannot suppress Markdown after its owner")
  eq(
    c.callout_folds,
    { { header_line = 0, source_line = 1, collapsed = false } },
    "summary release preserves the display fold"
  )
  local eof = build { "<details open>", "<summary>", "*raw*" }
  eq(eof.lines, { "▼ *raw*" }, "EOF preserves unfinished summary text")
  eq(eof.source_line_map, { 2 }, "EOF partial summary maps to its opening source row")
  local closed = build { "<details open>", "<summary>", "*raw*", "</summary>", "*body*", "</details>" }
  eq(closed.lines, { "▼ *raw*", "│ *body*" }, "same-owner summary remains a supported header")
  eq(closed.source_line_map, { 4, 5 }, "completed summary keeps the existing closing-row cursor policy")
end
do
  local c = build { "<figure>", "<figcaption>*literal* <em>styled</em></figcaption>", "</figure>" }
  eq(styled(c, "Italic"), { { 2, "styled" } }, "caption styles only HTML-derived em text")
  eq(c.lines[1]:match "%*literal%* styled$", "*literal* styled", "figure caption retains literal stars")
  local dl = build { "<dl>", "<dt>*term*</dt>", "<dd>*description* <em>styled</em></dd>", "</dl>" }
  eq(styled(dl, "Italic"), { { 3, "styled" } }, "description-list cells never acquire Markdown emphasis")
  eq(styled(dl, "Bold"), { { 2, "*term*" } }, "HTML definition term keeps its terminal bold style")
end
do
  local c = build(dl_boundary)
  eq(c.lines, { "*raw*", "", "after", "</dl>" }, "definition-list display state ends with its raw owner")
  eq(c.source_line_map, { 2, 3, 4, 5 }, "definition list cannot discard later physical Markdown rows")
  eq(styled(c, "Bold"), { { 2, "*raw*" } }, "supported term keeps HTML-derived bold")
  eq(styled(c, "Italic"), { { 4, "after" } }, "definition-list blank boundary resumes Markdown")
  local unmatched = build { "<dl>", "*readable*", "<dt>term</dt>*tail*", "</dl>" }
  eq(
    unmatched.lines,
    { "*readable*", "term", "*tail*", "" },
    "unrecognized definition-list content remains readable and literal"
  )
  eq(unmatched.source_line_map, { 2, 3, 3, 4 }, "definition-list terminal layout retains the original source rows")
  eq(styled(unmatched, "Italic"), {}, "unrecognized raw definition-list text cannot activate Markdown")
end
do
  local caption = string.rep(" ", 47) .. "*raw*"
  local c = build { "<figure>", "<figcaption>*raw*</figcaption>", "", "*after*", "</figure>" }
  eq(c.lines, { caption, "", "after", "</figure>" }, "figure caption is emitted before Markdown beyond its raw owner")
  eq(c.source_line_map, { 2, 3, 4, 5 }, "released caption preserves source row and document order")
  eq(styled(c, "Italic"), { { 4, "after" } }, "figure blank boundary resumes Markdown emphasis")
  local eof = build { "<figure>", "<figcaption>*raw*</figcaption>" }
  eq(eof.lines, { caption }, "EOF preserves a pending figure caption")
  eq(eof.source_line_map, { 2 }, "EOF caption retains its original source row")
end
do
  local icons = require "md-render.icons"
  local icon = icons.pad_icon(icons.get_image_icon "/x") .. " "
  local c = build { "<div>", "<img", 'src="/x" alt="foo', 'bar">', "*raw*", "</div>" }
  eq(c.lines, { icon .. "foo bar", "*raw*" }, "multiline media labels fold attribute breaks without adding source rows")
  eq(c.source_line_map, { 2, 5 }, "multiline image attributes cannot shift or lose later raw rows")
  eq(targets(c), { { 2, icon .. "foo bar", "/x" } }, "multiline image retains exact displayed bytes and full target")
  eq(styled(c, "Italic"), {}, "raw text following multiline media stays literal")
  local video_icon = icons.pad_icon(icons.get_image_icon "/multi\nline.mp4") .. " "
  local video = build { "<div>", '<video src="/multi', 'line.mp4"></video>', "*raw*", "</div>" }
  eq(video.lines, { video_icon .. "multi line.mp4", "*raw*" }, "multiline video filename keeps one display row")
  eq(video.source_line_map, { 2, 4 }, "multiline video preserves later physical raw rows")
  eq(
    targets(video),
    { { 2, video_icon .. "multi line.mp4", "/multi\nline.mp4" } },
    "video display folding keeps the full source target"
  )
end
do
  local raw = build { "<table>", "<tr><td>*literal* <em>styled</em></td></tr>", "</table>" }
  eq(styled(raw, "Italic"), { { 1, "styled" } }, "HTML table cells use only HTML-derived emphasis")
  eq(raw.lines[1]:find("*literal*", 1, true) ~= nil, true, "HTML table cells preserve literal stars")
  local pipe = build { "| h |", "| --- |", "| *Markdown* |" }
  eq(styled(pipe, "Italic"), { { 3, "Markdown" } }, "GFM pipe cells keep ordinary inline Markdown parsing")
  eq(markdown.render("*inline*", nil, nil, nil, nil, true), "inline", "inline_only still parses ordinary Markdown")
end

-- Generated pipe syntax cannot split literal HTML cells or mutate their data.
for count = 0, 3 do
  local value = "L" .. string.rep("\\", count) .. "|R"
  local body = build { "<table><tr><td>" .. value .. "</td><td>right</td></tr></table>" }
  eq(
    body.lines,
    { "│ " .. value .. " │ right │" },
    "literal cell pipes preserve prior backslashes and two columns"
  )
  local header = build {
    "<table><tr><th>" .. value .. "</th><th>right</th></tr><tr><td>data</td><td>other</td></tr></table>",
  }
  local width = math.max(#value, 4)
  eq(header.lines, {
    "│ " .. value .. string.rep(" ", width - #value) .. " │ right │",
    "│" .. string.rep("─", width + 2) .. "│───────│",
    "│ data" .. string.rep(" ", width - 4) .. " │ other │",
  }, "literal header pipes preserve the actual header/body column structure")
  local target = "/L" .. string.rep("\\", count) .. "|R"
  local c = build { '<table><tr><td><a href="' .. target .. '">label</a></td></tr></table>' }
  eq(c.lines, { "│ label │" }, "literal href pipes keep the supported label cell intact")
  eq(targets(c), { { 1, "label", target } }, "literal href pipes preserve the full original target bytes")
end
do
  local c = build { '<table><tr><td><a href="/a|b|c">*L|R*</a></td><td>right</td></tr></table>' }
  eq(c.lines, { "│ *L|R* │ right │" }, "multiple pipes in attributes and raw labels remain cell data")
  eq(targets(c), { { 1, "*L|R*", "/a|b|c" } }, "multiple literal target pipes remain interactive")
  eq(styled(c, "Italic"), {}, "literal Markdown markers in HTML cells remain opaque")
  local entity = build { "<table><tr><td>*a&vert;b*</td><td>right</td></tr></table>" }
  eq(entity.lines, { "│ *a|b* │ right │" }, "an encoded pipe decodes once inside its original HTML cell")
end

-- Negative owners: existing code and nonconflicting extensions remain active.
do
  local c =
    build { "```html", '<a href="/bad">', "*literal*", "</a>", "```", "", "[r]: /good", "", "[doc][r] [[wiki]] $math$" }
  eq(c.code_blocks[1].source_lines, { '<a href="/bad">', "*literal*", "</a>" }, "code takes precedence over HTML")
  eq(
    targets(c),
    { { 9, "wiki", "obsidian://advanced-uri?filepath=wiki" }, { 9, "doc", "/good" } },
    "standard references and nonconflicting wiki links remain active"
  )
  eq(styled(c, "MdRenderMath"), { { 9, "math" } }, "nonconflicting math remains active")
end

-- Accepted list markers keep their ordinary styling and counters; their raw
-- payload stays opaque. Physical gaps between quote borders are applied once.
local interleaved_source = { "> - > <div>", ">   > *raw*", ">   >", "> - sibling" }
for _, case in ipairs {
  {
    interleaved_source,
    { "│ • ", "│   │ *raw*", "│   │ ", "│ • sibling" },
    { 1, 2, 3, 4 },
    { { 0, 4, 8 }, { 3, 4, 8 } },
  },
  {
    { "- - <div>", "    *raw*", "", "- sibling" },
    { "• ", "  ◦ ", "    *raw*", "", "• sibling" },
    { 1, 1, 2, 3, 4 },
    { { 0, 0, 4 }, { 1, 0, 6 }, { 4, 0, 4 } },
  },
  {
    { "1. <div>", "   *raw*", "", "1. sibling" },
    { "1. ", "   *raw*", "", "2. sibling" },
    { 1, 2, 3, 4 },
    { { 0, 0, 3 }, { 3, 0, 3 } },
  },
  {
    { "> 1. <div>", ">    *raw*", ">", "> 1. sibling" },
    { "│ 1. ", "│    *raw*", "│ ", "│ 2. sibling" },
    { 1, 2, 3, 4 },
    { { 0, 4, 7 }, { 3, 4, 7 } },
  },
  {
    { "1. first", "2. <div>", "   *raw*", "", "1. sibling" },
    { "1. first", "2. ", "   *raw*", "", "3. sibling" },
    { 1, 2, 3, 4, 5 },
    { { 0, 0, 3 }, { 1, 0, 3 }, { 4, 0, 3 } },
  },
  {
    { "1. 1. <div>", "      *raw*", "", "   1. inner sibling", "1. outer sibling" },
    { "1. ", "   1. ", "      *raw*", "", "   2. inner sibling", "2. outer sibling" },
    { 1, 1, 2, 3, 4, 5 },
    { { 0, 0, 3 }, { 1, 0, 6 }, { 4, 0, 6 }, { 5, 0, 3 } },
  },
  {
    { "1. <div>", "   8. *raw*", "", "1. sibling" },
    { "1. ", "   8. *raw*", "", "2. sibling" },
    { 1, 2, 3, 4 },
    { { 0, 0, 3 }, { 3, 0, 3 } },
  },
  {
    { "999999999. first", "1. <div>", "   *raw*", "", "1. sibling" },
    { "999999999. first", "1000000000. ", "   *raw*", "", "1000000001. sibling" },
    { 1, 2, 3, 4, 5 },
    { { 0, 0, 11 }, { 1, 0, 12 }, { 4, 0, 12 } },
  },
  {
    { "0) <div>", "   *raw*", "", "9) sibling" },
    { "0) ", "   *raw*", "", "1) sibling" },
    { 1, 2, 3, 4 },
    { { 0, 0, 3 }, { 3, 0, 3 } },
  },
  {
    { "1. <!-- hidden -->", "1. sibling" },
    { "1. ", "2. sibling" },
    { 1, 2 },
    { { 0, 0, 3 }, { 1, 0, 3 } },
  },
  {
    { "1. <!--", "   hidden", "   -->", "1. sibling" },
    { "1. ", "2. sibling" },
    { 1, 4 },
    { { 0, 0, 3 }, { 1, 0, 3 } },
  },
  {
    { "> - > <table>", ">   > *raw*", ">   >", "> - sibling" },
    { "│ • ", "│   │ <table>", "│   │ *raw*", "│   │ ", "│ • sibling" },
    { 1, 1, 2, 3, 4 },
    { { 0, 4, 8 }, { 4, 4, 8 } },
  },
} do
  local c, marks = build(case[1])
  eq(c.lines, case[2], "HTML list rendering retains accepted marker and body geometry")
  eq(c.source_line_map, case[3], "HTML list rendering retains each physical source row")
  eq(marker_spans(marks), case[4], "actual HTML list markers retain the ordinary Special byte spans")
  eq(styled(c, "Italic"), {}, "raw apparent marker and emphasis stay literal")
end
do
  local c, marks = build {
    "> - > <div>",
    '>   > <a href="/raw&#10;x">*raw*</a>',
    ">   >",
    "> - sibling [after](/after)",
  }
  eq(
    c.lines,
    { "│ • ", "│   │ *raw*", "│   │ ", "│ • sibling after" },
    "raw target uses accepted quote gaps"
  )
  eq(c.source_line_map, { 1, 2, 3, 4 }, "raw anchor and sibling retain physical source rows")
  eq(targets(c), { { 2, "*raw*", "/raw\nx" }, { 4, "after", "/after" } }, "raw and Markdown full targets survive")
  eq(c.link_metadata, {
    { line = 1, col_start = 10, col_end = 15, url = "/raw\nx" },
    { line = 3, col_start = 16, col_end = 21, url = "/after" },
  }, "raw and Markdown byte edges include the physical prefix exactly once")
  eq(marker_spans(marks), { { 0, 4, 8 }, { 3, 4, 8 } }, "raw target geometry retains marker styling")
  eq(styled(c, "Italic"), {}, "stars in linked raw text remain literal")
end
for _, blank in ipairs { ">   >", ">   > " } do
  local c, marks = build {
    "> - > <div>",
    ">   > *raw*",
    blank,
    ">   >  ```lua",
    ">   >   x",
    ">   >  ```",
    "> - sibling",
  }
  eq(
    c.lines,
    { "│ • ", "│   │ *raw*", "│   │ ", "│   │  x", "│ • sibling" },
    "HTML blank releases to quoted code"
  )
  eq(c.source_line_map, { 1, 2, 3, 5, 7 }, "literal code keeps its physical payload row")
  eq(c.code_blocks[1].source_lines, { " x" }, "code payload retains its literal leading space")
  eq(c.code_blocks[1].prefix_len, 10, "code prefix preserves the accepted interleaved list margin")
  eq(marker_spans(marks), { { 0, 4, 8 }, { 4, 4, 8 } }, "HTML and sibling markers remain styled across code")
end
do
  local c, marks = build { "- <div>", "  *raw*", "", "  ```lua", "  x", "  ```", "- sibling" }
  eq(c.lines, { "• ", "  *raw*", "", "  x", "• sibling" }, "root item HTML releases to its own fence")
  eq(c.source_line_map, { 1, 2, 3, 5, 7 }, "root item HTML and fence retain source rows")
  eq(c.code_blocks[1].source_lines, { "x" }, "root item fence retains exact payload")
  eq(c.code_blocks[1].prefix_len, 2, "root item fence keeps its existing list margin")
  eq(marker_spans(marks), { { 0, 0, 4 }, { 4, 0, 4 } }, "root HTML opener and sibling both have real marker styles")
end
do
  local c, marks = build { "- > - <div>", '  >   <a href="/raw">*raw*</a>', "  >", "  > - sibling" }
  eq(
    c.lines,
    { "• ", "  │ • ", "  │   *raw*", "  │ ", "  │ • sibling" },
    "margin after the last quote is applied once"
  )
  eq(c.source_line_map, { 1, 1, 2, 3, 4 }, "composed item markers and raw payload retain their source rows")
  eq(targets(c), { { 2, "*raw*", "/raw" } }, "composed raw item keeps its supported full target")
  eq(
    c.link_metadata,
    { { line = 2, col_start = 8, col_end = 13, url = "/raw" } },
    "remaining item margin shifts the raw target bytes exactly once"
  )
  eq(marker_spans(marks), { { 0, 0, 4 }, { 1, 6, 10 }, { 4, 6, 10 } }, "composed raw item markers retain real styling")
end
for _, case in ipairs {
  {
    { "> > <div>", "> > *raw*", "> >", "> >  ```lua", "> >   x", "> >  ```" },
    { "│ │ *raw*", "│ │ ", "│ │  x" },
    { 2, 3, 5 },
  },
  {
    { "> - > <div>", ">   > *raw*", ">  >", ">  >  ```lua", ">  >   x", ">  >  ```", "> - sibling" },
    { "│ • ", "│   │ *raw*", "│ │ ", "│ │  x", "│ • sibling" },
    { 1, 2, 3, 5, 7 },
  },
} do
  local c = build(case[1])
  eq(c.lines, case[2], "ordinary quotes and physically dedented blank markers retain their own geometry")
  eq(c.source_line_map, case[3], "a different quote scaffold retains exact physical source rows")
  eq(c.code_blocks[1].source_lines, { " x" }, "dedented quote control preserves literal code payload")
  eq(c.code_blocks[1].prefix_len, 8, "a different physical scaffold cannot inherit the former item gap")
end

-- Fresh public tab preview and rebuild use the same source, literal bytes and links.
for _, source in ipairs {
  anchor_source,
  quoted_href_source,
  multiline_attribute_source,
  multiline_comment_source,
  {
    "<details open>",
    '<summary><a title="</summary>',
    'tail" href="real">*別*</a>',
    "</summary>",
    "*body*",
    "</details>",
  },
  heading_attribute_source,
  ordered_heading_images_source,
  mixed_heading_images_source,
  table_boundary,
  summary_boundary,
  dl_boundary,
  interleaved_source,
  quoted_heading_source,
  { "<div>", "%%", "*raw*", "", "*after*" },
  { "<div>", "<!--", "*raw*", "", "*after*" },
  { "<table><tr><td>left|part</td><td>right</td></tr></table>" },
  { '<table><tr><td><a href="/a|b">label</a></td></tr></table>' },
} do
  local expected, expected_marks = build(source, { max_width = 98 }) -- Public preview reserves two indent columns.
  local preview = require "md-render.preview"
  local source_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[source_buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, source)
  vim.api.nvim_set_current_buf(source_buf)
  local tick = vim.api.nvim_buf_get_changedtick(source_buf)
  preview.show_tab { text_scale = false, max_width = 100 }
  local session = assert(preview._sessions[vim.api.nvim_get_current_buf()])
  for step = 1, 2 do
    local visible = vim.tbl_map(function(line)
      return "  " .. line
    end, expected.lines)
    eq(session.content.lines, visible, "public tab preview preserves exact literal output")
    eq(session.content.source_line_map, expected.source_line_map, "public tab preview keeps physical ownership")
    eq(targets(session.content), targets(expected), "public tab preview preserves HTML-derived targets and labels")
    eq(
      styled(session.content, "Italic"),
      styled(expected, "Italic"),
      "public tab preview preserves the raw boundary style split"
    )
    local marker_edges = vim.tbl_map(function(span)
      return { span[1], span[2] + 2, span[3] + 2 }
    end, marker_spans(expected_marks))
    eq(
      marker_spans(vim.api.nvim_buf_get_extmarks(session.buf, session.ns, 0, -1, { details = true })),
      marker_edges,
      "public preview and rebuild retain actual list-marker byte spans"
    )
    eq(
      vim.api.nvim_buf_get_lines(session.buf, 0, -1, false),
      session.content.lines,
      "public rendered buffer matches content"
    )
    eq(
      urls(vim.api.nvim_buf_get_extmarks(session.buf, session.ns, 0, -1, { details = true })),
      urls(expected_marks),
      "public actual URL marks match supported anchors"
    )
    if step == 1 then session:rebuild() end
  end
  vim.api.nvim_set_current_buf(source_buf)
  eq(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), source, "public preview preserves source bytes")
  eq(vim.api.nvim_buf_get_changedtick(source_buf), tick, "public preview preserves source changedtick")
  vim.api.nvim_buf_delete(session.buf, { force = true })
  vim.api.nvim_buf_delete(source_buf, { force = true })
end
do
  local preview = require "md-render.preview"
  local source = { '<a href="https://example.invalid/a&#10;b">', "label&#10;tail", "</a>" }
  local target = "https://example.invalid/a\nb"
  local source_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[source_buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, source)
  vim.api.nvim_set_current_buf(source_buf)
  local tick = vim.api.nvim_buf_get_changedtick(source_buf)
  local open, getmousepos, osc8 = vim.ui.open, vim.fn.getmousepos, display.supports_osc8
  local opened, session = {}, nil
  vim.ui.open = function(url)
    opened[#opened + 1] = url
  end
  display.supports_osc8 = function()
    return false
  end
  local ok, err = pcall(function()
    preview.show_tab { text_scale = false, max_width = 100 }
    session = assert(preview._sessions[vim.api.nvim_get_current_buf()])
    for step = 1, 2 do
      eq(session.content.lines, { "  label tail" }, "public HTML display entity remains one physical row")
      eq(session.content.source_line_map, { 2 }, "public HTML entity label keeps its physical source row")
      eq(
        session.content.link_metadata,
        { { line = 0, col_start = 2, col_end = 12, url = target } },
        "public HTML URL retains the full decoded target and exact label bytes"
      )
      eq(Links.at(session.buf, session.ns, 0, 2), target, "public first label byte retains the full target")
      eq(Links.at(session.buf, session.ns, 0, 11), target, "public last label byte retains the full target")
      eq(Links.at(session.buf, session.ns, 0, 1), nil, "public prefix stays outside the entity target")
      eq(Links.at(session.buf, session.ns, 0, 12), nil, "public adjacent byte stays outside the entity target")
      vim.fn.getmousepos = function()
        return { winid = session.win, line = 1, column = 3 }
      end
      vim.fn.maparg("<LeftRelease>", "n", false, true).callback()
      if step == 1 then session:rebuild() end
    end
  end)
  vim.ui.open, vim.fn.getmousepos, display.supports_osc8 = open, getmousepos, osc8
  vim.api.nvim_set_current_buf(source_buf)
  if session then vim.api.nvim_buf_delete(session.buf, { force = true }) end
  eq(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), source, "HTML target activation preserves source bytes")
  eq(vim.api.nvim_buf_get_changedtick(source_buf), tick, "HTML target activation preserves source changedtick")
  vim.api.nvim_buf_delete(source_buf, { force = true })
  assert(ok, err)
  eq(opened, { target, target }, "public click opens the full decoded target before and after rebuild")
end
print("html_raw_blocks_test: " .. checks .. " passed")
