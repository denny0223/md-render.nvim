-- CommonMark 0.31.2 examples 63, 68, 71, 79 and their ATX boundaries.
-- https://spec.commonmark.org/0.31.2/#atx-headings
-- https://github.com/denny0223/md-render.nvim/issues/22
-- Run: nvim --headless -u NONE --noplugin -l tests/atx_headings_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.env.TMUX, vim.env.TMUX_PANE = nil, nil
local markdown = require "md-render.markdown"
local Builder = require("md-render.content_builder").ContentBuilder
local display = require "md-render.display_utils"
local Links = require "md-render.links"
local size = require "md-render.text_size"
local image = require "md-render.image"
image.supports_kitty = function()
  return false
end
size.supports = function()
  return true
end
vim.o.termguicolors = true
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
local function build(source, opts)
  local original = vim.deepcopy(source)
  local b = Builder.new()
  b:render_document(source, vim.tbl_extend("force", { max_width = 80, indent = "", text_scale = false }, opts or {}))
  eq(source, original, "source array is unchanged")
  local content = b:result()
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "atx_headings_test"
  local ok, err = pcall(function()
    display.apply_content_to_buffer(buf, ns, content)
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), content.lines, "actual buffer text")
    for row, source_row in ipairs(content.source_line_map) do
      assert(source_row >= 1 and source_row <= #source, "source row remains in the original document")
      assert(content.lines[row], "source mapping has a rendered row")
    end
    for _, entry in ipairs(content.highlights) do
      for _, span in ipairs(entry.groups) do
        local last = span.end_col == -1 and #content.lines[entry.line + 1] or span.end_col
        assert(span.col >= 0 and span.col <= last and last <= #content.lines[entry.line + 1], "highlight byte bounds")
      end
    end
    for _, link in ipairs(content.link_metadata) do
      assert(link.col_start < link.col_end, "link is nonempty")
      eq(Links.at(buf, ns, link.line, link.col_start), link.url, "first link byte selects the target")
      eq(Links.at(buf, ns, link.line, link.col_end - 1), link.url, "last link byte selects the target")
      eq(Links.at(buf, ns, link.line, link.col_end), nil, "byte after link has no target")
    end
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, err)
  return content
end
local function headings(content)
  local rows = vim.tbl_keys(content.heading_lines)
  table.sort(rows)
  local result = {}
  for _, row in ipairs(rows) do
    result[#result + 1] = { content.lines[row + 1], content.source_line_map[row + 1] }
  end
  return result
end
local function style_text(content, group)
  local parts = {}
  for _, entry in ipairs(content.highlights) do
    for _, span in ipairs(entry.groups) do
      if span.hl == group then parts[#parts + 1] = content.lines[entry.line + 1]:sub(span.col + 1, span.end_col) end
    end
  end
  return table.concat(parts)
end

for _, case in ipairs {
  { "# foo", 1, "foo" },
  { "## foo", 2, "foo" },
  { "### foo", 3, "foo" },
  { "#### foo", 4, "foo" },
  { "##### foo", 5, "foo" },
  { "###### foo", 6, "foo" },
  { " ### foo", 3, "foo" },
  { "  ## foo", 2, "foo" },
  { "   # foo", 1, "foo" },
  { "## foo ##", 2, "foo" },
  { "  ###   bar    ###", 3, "bar" },
  { "#", 1, "" },
  { "## ", 2, "" },
  { "### ###", 3, "" },
  { "   ######\t###\t", 6, "" },
  { "#\tfoo\t###\t", 1, "foo" },
  { "# foo ################", 1, "foo" },
  { "### foo ### b", 3, "foo ### b" },
  { "# foo#", 1, "foo#" },
  { [[### foo \###]], 3, "foo ###" },
  { [[## foo #\##]], 2, "foo ###" },
  { [[# foo \#]], 1, "foo #" },
  { [[# foo\ ###]], 1, [[foo\]] },
  { "# > quoted", 1, "> quoted" },
  { "# - item", 1, "- item" },
  { "# 1. item", 1, "1. item" },
} do
  test("inline " .. case[1], function()
    local text, highlights, links, kind = markdown.render(case[1])
    eq(text, case[3], "heading inline text")
    eq(kind, "heading", "heading classification")
    eq(highlights[1], { col = 0, end_col = #text, hl = "MdRenderH" .. case[2] }, "exact heading range and level")
    eq(links, {}, "unlinked heading")
    eq(markdown.is_block_start(case[1], true), true, "heading interrupts a paragraph")
  end)
end

for _, source in ipairs { "####### foo", "#######", "#hashtag", "#5 bolt", [[\## foo]], "    # foo", "\t# foo", "#\vfoo" } do
  test("negative " .. source, function()
    local _, highlights, _, kind = markdown.render(source)
    eq(kind, nil, "not an ATX heading")
    for _, span in ipairs(highlights) do
      assert(not span.hl:match "^MdRenderH%d$", "invalid ATX has no heading style")
    end
    eq(markdown.is_block_start(source, true), false, "invalid ATX cannot interrupt a paragraph")
  end)
end

test("adjacent indented headings retain original rows and hierarchy", function()
  local content = build { " ### foo", "  ## foo", "   # foo" }
  eq(headings(content), { { "### foo", 1 }, { "## foo", 2 }, { "# foo", 3 } }, "example 68 rows")
  eq(style_text(content, "MdRenderH3"), "### foo", "H3 rank")
  eq(style_text(content, "MdRenderH2"), "## foo", "H2 rank")
  eq(style_text(content, "MdRenderH1"), "# foo", "H1 rank")
  for index, slug in ipairs { "foo", "foo-1", "foo-2" } do
    eq(content.source_line_map[content.heading_anchors[slug] + 1], index, "duplicate anchor source")
  end
end)
test("the shared helper returns raw inline content before decoding", function()
  local level, content = markdown.parse_atx_heading "   ## **x** &amp; `#` \\# ###\t"
  eq({ level, content }, { 2, "**x** &amp; `#` \\#" }, "raw inline content contract")
  eq({ markdown.parse_atx_heading "#" }, { 1, "" }, "empty differs from unrecognized")
  eq({ markdown.parse_atx_heading "####### foo" }, {}, "unrecognized returns nil")
  local control = build { "### foo ###\f" }
  eq(headings(control), { { "### foo ###\f", 1 } }, "non-space/tab suffix prevents closing hashes")
end)
test("closing hashes are syntax and empty headings retain structure", function()
  local content = build { "## foo ##", "  ###   bar    ###", "#", "## ", "### ###" }
  eq(
    headings(content),
    { { "## foo", 1 }, { "### bar", 2 }, { "# ", 3 }, { "## ", 4 }, { "### ", 5 } },
    "examples 71 and 79"
  )
  eq(vim.tbl_count(content.heading_anchors), 2, "empty headings create no invented anchors")
  for index, slug in ipairs { "foo", "bar" } do
    eq(content.source_line_map[content.heading_anchors[slug] + 1], index, "parsed heading anchor")
  end
end)
test("valid headings interrupt paragraphs; invalid seven-hash lines do not", function()
  local content = build { "before", "####### foo", "after", "   ### valid ###", "next" }
  eq(content.lines[1], "before ####### foo after", "example 63 stays in its paragraph")
  eq(content.source_line_map[1], 1, "joined paragraph maps to its first source row")
  eq(headings(content), { { "### valid", 4 } }, "only valid ATX has metadata")
  eq(content.heading_anchors.foo, nil, "ordinary paragraphs have no heading anchor")
  eq(content.source_line_map[#content.lines], 5, "paragraph after heading keeps its source row")
  local code = build { "    # foo", "\t## bar" }
  eq(headings(code), {}, "four-column indentation is code, not headings")
  eq(code.heading_anchors, {}, "code has no anchors")
  assert(table.concat(code.lines, "\n"):find("# foo", 1, true), "literal code hashes are retained")
end)
test("reference collection shares ATX paragraph boundaries", function()
  local invalid = build { "####### paragraph", "[ref]: /ignored", "", "[ref]" }
  eq(invalid.link_metadata, {}, "invalid ATX leaves the definition inside its paragraph")
  local valid = build { "#", "[ref]: /resolved", "", "[ref]" }
  eq(#valid.link_metadata, 1, "empty heading ends its block before a definition")
  eq(valid.link_metadata[1].url, "/resolved", "definition after empty heading resolves")
end)
test("image-only headings retain media presentation without stealing invalid hashes", function()
  for _, content in ipairs { "![alt](missing.png)", '<img src="missing.png" alt="alt">' } do
    eq(build({ "   ## " .. content .. " ###" }).lines, build({ "## " .. content }).lines, "parsed image heading")
    local paragraph = build { "####### " .. content }
    assert(paragraph.lines[1]:find("####### ", 1, true), "ordinary paragraph retains opening hashes")
    eq(paragraph.heading_lines, {}, "image syntax cannot make seven hashes a heading")
  end
end)
test("inline-only table headers and cells preserve block-looking text", function()
  local source = { "| # | ## **title** ## |", "| --- | --- |", "| ### | ## [body](https://example.invalid) ## |" }
  local parsed = assert(require("md-render.markdown_table").parse(source))
  eq({ parsed.headers[1].text, parsed.headers[2].text }, { "#", "## title ##" }, "literal table headers")
  eq({ parsed.rows[1][1].text, parsed.rows[1][2].text }, { "###", "## body ##" }, "literal table body")
  local content = build(source)
  eq(content.heading_lines, {}, "cells create no document headings")
  local bold = parsed.headers[2].highlights[1]
  eq(bold.hl, "Bold", "table inline bold still applies")
  eq(parsed.headers[2].text:sub(bold.col + 1, bold.end_col), "title", "table bold covers only its inline content")
  local link = content.link_metadata[1]
  eq(content.lines[link.line + 1]:sub(link.col_start + 1, link.col_end), "body", "table link label")
  eq(link.url, "https://example.invalid", "table link target")
  eq(content.source_line_map[link.line + 1], 3, "table body source row")
end)
test("inline-only consumers preserve markers, formatting and link byte ranges", function()
  for _, text in ipairs { "#", "## title ##", "> quote", "- [x] task", "1. item", [[tail\]] } do
    local rendered, _, _, kind, marker = markdown.render(text, nil, nil, nil, nil, true)
    eq(rendered, text, "inline mode retains block markers")
    eq({ kind, marker }, {}, "inline mode has no block metadata")
  end
  local text = "## **title** [link](https://example.invalid) ##"
  local html_text = '## <strong>title</strong> <a href="https://example.invalid">link</a> ##'
  for _, source in ipairs {
    { "<details open>", "<summary>" .. html_text .. "</summary>", "</details>" },
    { "<figure>", "<figcaption>" .. html_text .. "</figcaption>", "</figure>" },
    { "<dl>", "<dt>" .. html_text .. "</dt>", "<dd>#</dd>", "</dl>" },
    { "<dl>", "<dt>term</dt>", "<dd>" .. html_text .. "</dd>", "</dl>" },
    { "note[^n]", "", "[^n]: " .. text },
  } do
    local content = build(source)
    assert(
      table.concat(content.lines, "\n"):find("## title link ##", 1, true),
      "inline-only content retains its hashes"
    )
    for _, entry in ipairs(content.highlights) do
      for _, span in ipairs(entry.groups) do
        assert(not span.hl:match "^MdRenderH%d$", "inline-only content has no heading style")
      end
    end
    local found = false
    for _, link in ipairs(content.link_metadata) do
      if link.url == "https://example.invalid" then
        eq(content.lines[link.line + 1]:sub(link.col_start + 1, link.col_end), "link", "inline-only link label")
        found = true
      end
    end
    assert(found, "inline-only link remains active")
  end
end)

local rich = "   ### **粗體** [連結](https://example.invalid/a?x=1&amp;y=2) `#` ###"
test("parsed heading content preserves inline byte ranges and anchors", function()
  local level, parsed = markdown.parse_atx_heading(rich)
  eq(level, 3, "ATX opening markers determine the level")
  eq(parsed, "**粗體** [連結](https://example.invalid/a?x=1&amp;y=2) `#`", "only closing ATX markers are removed")
  local semantic = markdown.render(parsed, nil, nil, nil, nil, true, { semantic = true })
  eq(semantic, "粗體 連結 #", "the code hash and preceding source space remain semantic content")
  for _, width in ipairs { 80, 20 } do
    local content = build({ rich }, { max_width = width, indent = "  " })
    eq(style_text(content, "Bold"), "粗體", "bold covers the intended Unicode bytes")
    eq(style_text(content, "MdRenderInlineCode"), "#", "literal code hash remains content")
    eq(#content.link_metadata, 1, "one heading link")
    local link = content.link_metadata[1]
    eq(content.lines[link.line + 1]:sub(link.col_start + 1, link.col_end), "連結", "link covers its visible label")
    eq(link.url, "https://example.invalid/a?x=1&y=2", "destination decoded once")
    eq(content.source_line_map[link.line + 1], 1, "wrapped link maps to the heading source")
    -- Removing the literal # leaves its preceding space as a final hyphen.
    eq(content.heading_anchors["粗體-連結-"], 0, "anchor preserves source spaces after stripping punctuation")
    eq(content.heading_anchors["粗體-連結"], nil, "anchor does not trim a hyphen created from source whitespace")
  end
end)

test("native layout uses the same parsed levels and excludes empty placements", function()
  size.setup { backend = "native" }
  local content = build(
    { " ### foo ###", "  ## bar ##", "   # baz #", "####### literal", "#", "## ", "### ###" },
    { text_scale = true }
  )
  eq(content.heading_backend, "native", "native remains enabled")
  eq(#content.text_placements, 3, "only nonempty valid headings have placements")
  for i, level in ipairs { 3, 2, 1 } do
    eq(content.text_placements[i].hl, "MdRenderH" .. level, "native heading level")
    eq(content.source_line_map[content.text_placements[i].line + 1], i, "native source mapping")
  end
  eq(
    headings(content),
    { { "foo", 1 }, { "bar", 2 }, { "baz", 3 }, { "", 5 }, { "", 6 }, { "", 7 } },
    "native text and empty rows"
  )
  local styled = build({ rich }, { text_scale = true, max_width = 40 })
  eq(style_text(styled, "Bold"), "粗體", "native bold span")
  local labels = {}
  for _, placement in ipairs(styled.text_placements) do
    for _, run in ipairs(placement.runs) do
      if run.url then labels[#labels + 1] = { run.text, run.url } end
    end
  end
  eq(labels, { { "連結", "https://example.invalid/a?x=1&y=2" } }, "native painted target")
end)

test("direct and tmux image layouts receive only parsed nonempty content", function()
  local layout = require "md-render.heading_layout"
  local request = layout.request
  local requests, pending = {}, false
  image.png_status = function()
    return { supported = true }
  end
  image.get_cell_size = function()
    return { cell_w = 10, cell_h = 20 }
  end
  layout.request = function(input)
    local entry = input.entries[1]
    requests[#requests + 1] = entry
    assert(entry.text ~= "", "empty headings must not start image work")
    local columns, byte = {}, 0
    for _, char in ipairs(vim.fn.split(entry.text, "\\zs")) do
      for _ = 1, vim.fn.strdisplaywidth(char) do
        columns[#columns + 1] = byte
      end
      byte = byte + #char
    end
    return {
      key = entry.text,
      output = not pending and {
        lines = {
          {
            text = entry.text,
            start = 0,
            ["end"] = #entry.text,
            cols = #columns,
            columns = columns,
            transparent = true,
            data = "png",
          },
        },
      } or nil,
    }
  end
  local ok, err = pcall(function()
    size.setup { backend = "image" }
    for _, tmux in ipairs { false, true } do
      vim.env.TMUX = tmux and "/tmp/atx-test,1,0" or nil
      requests = {}
      local content = build({ rich, "#", "## ", "### ###", "####### literal" }, { text_scale = true })
      eq(content.heading_backend, "image", "image remains enabled")
      eq(#content.text_placements, 1, "only nonempty valid heading has an image")
      eq(#requests, 1, "empty and invalid headings do not request images")
      eq(requests[1].text, "粗體 連結 #", "raster content excludes ATX syntax")
      eq(style_text(content, "Bold"), "粗體", "image uses the same style bytes")
      local placement = content.text_placements[1]
      eq(placement.hl, "MdRenderH3", "image rank")
      eq(placement.raster.text, "粗體 連結 #", "raster and buffer text agree")
      eq(headings(content), { { "粗體 連結 #", 1 }, { "", 2 }, { "", 3 }, { "", 4 } }, "image heading source rows")
      local link = content.link_metadata[1]
      eq(content.lines[link.line + 1]:sub(link.col_start + 1, link.col_end), "連結", "image link label")
      eq(link.url, "https://example.invalid/a?x=1&y=2", "image link destination")
      eq(vim.tbl_count(content.heading_anchors), 1, "empty and invalid image headings have no anchors")
      pending = true
      local fallback = build({ "   ### pending ###" }, { text_scale = true })
      eq(headings(fallback), { { "pending", 1 } }, "pending image keeps parsed readable text")
      eq(#fallback.text_placements, 0, "pending layout is not painted")
      pending = false
    end
    vim.env.TMUX, requests = nil, {}
    local details = {
      "<details open>",
      "<summary>Details</summary>",
      "   ### [link](https://example.invalid) ###",
      "#",
      "</details>",
    }
    local content = build(details, { text_scale = true })
    local plain = build(details)
    eq(content.lines, plain.lines, "indented headings in details retain text layout")
    eq(content.link_metadata, plain.link_metadata, "details retain link byte coordinates")
    eq(#content.text_placements, 0, "details do not start image placements")
    eq(#requests, 0, "details do not request unsupported image geometry")
  end)
  layout.request, vim.env.TMUX = request, nil
  assert(ok, err)
end)

test("public preview rebuild preserves source, link activation and anchors", function()
  local preview = require "md-render.preview"
  local source = { rich, "", "[jump](#粗體-連結-)", "", "#", "", "####### literal" }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
  vim.api.nvim_set_current_buf(buf)
  local mouse, supports, open = display.getmousepos, display.supports_osc8, vim.ui.open
  local ok, err = pcall(function()
    preview.toggle { text_scale = false }
    local session = assert(preview._toggle_sessions[buf])
    display.supports_osc8 = function()
      return false
    end
    for step = 1, 2 do
      local click = vim.fn.maparg("<LeftRelease>", "n", false, true).callback
      local content, opened = session.content, {}
      vim.ui.open = function(url)
        opened[#opened + 1] = url
      end
      for _, link in ipairs(content.link_metadata) do
        display.getmousepos = function()
          return { winid = vim.api.nvim_get_current_win(), line = link.line + 1, column = link.col_start + 1 }
        end
        click()
        if link.url:sub(1, 1) == "#" then
          eq(
            vim.api.nvim_win_get_cursor(0)[1],
            content.heading_anchors[link.url:sub(2)] + 1,
            "click reaches parsed heading anchor"
          )
        end
      end
      eq(opened, { "https://example.invalid/a?x=1&y=2" }, "click activates exact external destination")
      if step == 1 then session:rebuild() end
    end
  end)
  display.getmousepos, display.supports_osc8, vim.ui.open = mouse, supports, open
  if preview._toggle_sessions[buf] then preview.toggle() end
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), source, "source buffer remains unchanged")
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, err)
end)

print(string.format("atx_headings_test: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
