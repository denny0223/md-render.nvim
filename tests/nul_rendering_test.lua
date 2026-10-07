-- CommonMark / GFM section 2.3: replace raw NUL before parsing a rendering copy.
-- Run: nvim --headless -u NONE --noplugin -l tests/nul_rendering_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local Markdown = require "md-render.markdown"
local Table = require "md-render.markdown_table"
local Builder = require("md-render.content_builder").ContentBuilder
local preview = require "md-render.preview"
local display = require "md-render.display_utils"
local Links = require "md-render.links"
local SourceMap = require "md-render.source_map"
local image = require "md-render.image"
image.supports_kitty = function()
  return false
end
local nul, checks = string.char(0), 0
local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
  checks = checks + 1
end

local function boundary(text, col)
  local byte = text:byte(col + 1)
  return col >= 0 and col <= #text and (not byte or byte < 128 or byte >= 192)
end

local function apply(content)
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "nul_rendering_test"
  display.apply_content_to_buffer(buf, ns, content)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), content.lines, "actual preview buffer text")
  eq(#content.source_line_map, #content.lines, "one physical source owner per preview row")
  for _, row in ipairs(content.lines) do
    eq(row:find(nul, 1, true), nil, "no raw NUL reaches the preview buffer")
  end
  for _, row in ipairs(content.highlights) do
    local text = content.lines[row.line + 1]
    for _, hl in ipairs(row.groups) do
      eq(boundary(text, hl.col), true, "highlight starts at a UTF-8 boundary")
      eq(hl.end_col == -1 or boundary(text, hl.end_col), true, "highlight ends at a UTF-8 boundary")
    end
  end
  for _, link in ipairs(content.link_metadata) do
    local text = content.lines[link.line + 1]
    eq(boundary(text, link.col_start) and boundary(text, link.col_end), true, "link endpoints are UTF-8 boundaries")
    eq(Links.at(buf, ns, link.line, link.col_start), link.url, "first linked byte retains its target")
    eq(Links.at(buf, ns, link.line, link.col_end - 1), link.url, "last linked byte retains its target")
    eq(Links.at(buf, ns, link.line, link.col_end), nil, "byte after the label is outside the link")
  end
  vim.api.nvim_buf_delete(buf, { force = true })
end

local function build(lines, opts)
  local original = vim.deepcopy(lines)
  local b = Builder.new()
  b:render_document(lines, vim.tbl_extend("force", { max_width = 100, indent = "", text_scale = false }, opts or {}))
  eq(lines, original, "document rendering leaves the caller's array untouched")
  local content = b:result()
  apply(content)
  return content
end

eq(Markdown.render("a" .. nul .. nul .. "b"), "a��b", "adjacent NUL characters each become U+FFFD")
eq(Markdown.render("# a" .. nul .. "b"), "a�b", "heading content is normalized")
eq(Markdown.heading_slug("a" .. nul .. "b"), Markdown.heading_slug "a�b", "heading anchors see normalized text")
eq(Markdown.render("`a" .. nul .. "b` &#0; `&#0;`"), "a�b � &#0;", "NUL normalization also applies to code")
eq(Markdown.render "&#0;&#x0;", "��", "existing numeric reference decoding is unchanged")

do
  local text, highlights, links = Markdown.render("[**a" .. nul .. "b**](/p" .. nul .. "q)")
  eq(text, "a�b", "NUL is normalized before link-label parsing")
  eq(links, { { col_start = 0, col_end = 5, url = "/p�q" } }, "destination parsing sees replacement characters")
  for _, hl in ipairs(highlights) do
    eq({ hl.col, hl.end_col }, { 0, 5 }, "link and emphasis styles cover all three replacement bytes")
  end
end

do
  local content = build { "[a" .. nul .. "b]: /x" .. nul .. "y", "", "[a" .. nul .. "b]" }
  eq(content.lines, { "", "a�b" }, "reference definitions and usages share the normalized label")
  eq(content.link_metadata, { { line = 1, col_start = 0, col_end = 5, url = "/x�y" } }, "reference target")
  eq(content.source_line_map, { 2, 3 }, "consumed definitions retain physical source rows")
end

do
  local content = build { "```text", "a" .. nul .. "b", "```", "", "    c" .. nul .. "d" }
  eq(content.lines, { "a�b", "", "c�d" }, "fenced and indented code contain replacement characters")
  eq(content.code_blocks[1].source_lines, { "a�b" }, "syntax highlighting receives the rendering copy")
  eq(content.source_line_map, { 2, 4, 5 }, "code rows retain their source owners")
end

do
  local source = "甲[**乙" .. nul .. "丙\n丁" .. nul .. "戊**](/url)己"
  local rendered = { Markdown.render(source, nil, nil, nil, nil, nil, nil, true) }
  eq(rendered[1], "甲乙�丙丁�戊己", "inline transformations preserve normalized labels")
  eq(rendered[10], { { col = 0, source_line = 1 }, { col = 12, source_line = 2 } }, "expanded bytes shift source runs")
  local content = build({ "甲[**乙" .. nul .. "丙", "丁" .. nul .. "戊**](/url)己" }, { max_width = 4 })
  eq(content.lines, { "甲乙", "�丙", "丁�", "戊己" }, "replacement characters wrap as whole glyphs")
  eq(content.source_line_map, { 1, 1, 2, 2 }, "wrapped label rows preserve physical source origins")
end

do
  local html = "甲" .. nul .. '<a href="/x' .. nul .. 'y">乙\n丙' .. nul .. "</a>丁"
  local sources = SourceMap.new(html)
  sources.runs[1].source_line, sources.runs[2].source_line = 8, 13
  local text, highlights, links = Markdown.render_html(html, false, nil, sources)
  eq(text, "甲�乙\n丙�丁", "public HTML rendering normalizes text and destinations")
  eq(links, { { col_start = 6, col_end = 16, url = "/x�y" } }, "HTML label uses rendered UTF-8 bytes")
  eq(sources.length, #text, "supplied source map follows HTML rendering")
  eq(sources.runs, { { col = 0, source_line = 8 }, { col = 10, source_line = 13 } }, "custom source owners survive")
  local content = build { "<div>a" .. nul .. 'b <a href="/x' .. nul .. 'y">c' .. nul .. "d</a></div>" }
  eq(content.lines, { "a�b c�d" }, "document HTML uses the same normalization")
  eq(content.link_metadata[1].url, "/x�y", "document HTML destination is normalized")
end

do
  local opening, closing = string.rep("<b>", 33), string.rep("</b>", 33)
  local owner = opening .. "x" .. closing
  local inner_owner = opening .. "x�y" .. closing
  local multiline_owner = opening .. "x\n�y" .. closing
  for _, case in ipairs {
    {
      source = nul .. owner .. "後",
      text = "�" .. owner .. "後",
      spans = { { 3, 3 + #owner } },
    },
    {
      source = nul .. owner .. "A" .. nul .. opening .. "x" .. nul .. "y" .. closing .. "後",
      text = "�" .. owner .. "A�" .. inner_owner .. "後",
      spans = { { 3, 3 + #owner }, { 7 + #owner, 7 + #owner + #inner_owner } },
    },
    {
      source = "頭" .. nul .. opening .. "尾" .. nul,
      text = "頭�" .. opening .. "尾�",
      spans = { { 6, 12 + #opening } },
    },
    {
      source = nul .. owner .. "後",
      text = "�" .. owner .. "後",
      spans = { { 0, 3 + #owner } },
      ranges = { { start = 1, finish = 1 + #owner } },
    },
    {
      source = "a\r\n" .. nul .. opening .. "x\r\n" .. nul .. "y" .. closing .. "後",
      text = "a\n�" .. multiline_owner .. "後",
      spans = { { 5, 5 + #multiline_owner } },
      runs = { { col = 0, source_line = 7 }, { col = 2, source_line = 14 }, { col = 106, source_line = 21 } },
    },
    {
      source = "a\r" .. nul .. owner .. "後",
      text = "a\n�" .. owner .. "後",
      spans = { { 5, 5 + #owner } },
    },
    {
      source = "a\r\n" .. opening .. "x\r\ny" .. closing .. "後",
      text = "a\n" .. opening .. "x\ny" .. closing .. "後",
      spans = { { 2, 4 + #opening + #closing + 1 } },
      runs = { { col = 0, source_line = 7 }, { col = 2, source_line = 14 }, { col = 103, source_line = 21 } },
    },
  } do
    local ranges = case.ranges or Markdown.html_literal_ranges(case.source, true)
    local original_ranges = vim.deepcopy(ranges)
    local context = { raw_html = true, literal_html_ranges = ranges }
    local original_context = vim.deepcopy(context)
    local expected_highlights = {}
    for _, span in ipairs(case.spans) do
      expected_highlights[#expected_highlights + 1] = { col = span[1], end_col = span[2], hl = "Comment" }
    end
    local sources = SourceMap.new(case.source)
    for index, run in ipairs(sources.runs) do
      run.source_line = 7 * index
    end
    local text, highlights = Markdown.render_html(case.source, false, ranges, sources)
    eq(text, case.text, "public HTML input keeps exact protected owners")
    eq(highlights, expected_highlights, "public HTML ranges follow NUL expansion and CRLF contraction")
    eq(sources.length, #text, "range adjustment does not edit the supplied source map twice")
    eq(sources.runs, case.runs or { { col = 0, source_line = 7 } }, "protected owners retain custom source rows")
    local untracked_text, untracked_highlights = Markdown.render_html(case.source, false, ranges)
    eq(untracked_text, case.text, "public HTML range adjustment also works without a source map")
    eq(untracked_highlights, expected_highlights, "untracked HTML ranges have the same byte endpoints")
    local inline_text, inline_highlights = Markdown.render(case.source, nil, nil, nil, nil, nil, context)
    eq(inline_text, case.text:gsub("\n", " "), "raw HTML context keeps the same protected content")
    eq(inline_highlights, expected_highlights, "raw HTML context rebases ranges before its first normalization")
    eq(ranges, original_ranges, "public rendering preserves caller ranges")
    eq(context, original_context, "public rendering preserves caller context")
    for _, hl in ipairs(highlights) do
      eq(boundary(text, hl.col) and boundary(text, hl.end_col), true, "protected endpoints are UTF-8 boundaries")
    end
  end
end

do
  local lines = { "| a" .. nul .. "b |", "| --- |", "| [c" .. nul .. "d](/e" .. nul .. "f) |" }
  local original = vim.deepcopy(lines)
  local parsed = assert(Table.parse(lines))
  eq(parsed.headers[1].text, "a�b", "public table header")
  eq(parsed.rows[1][1].text, "c�d", "public table label")
  eq(parsed.rows[1][1].links[1].url, "/e�f", "public table destination")
  eq(
    parsed._raw_lines,
    { "| a�b |", "| --- |", "| [c�d](/e�f) |" },
    "table media detection receives normalized source"
  )
  eq(lines, original, "public table parser preserves the caller's array")
  local rendered = Table.render(parsed, "", 100)
  eq(rendered[1], "│ a�b │", "public table rendering uses normalized widths")
  local content = build(lines)
  eq(content.lines[3], "│ c�d │", "document table rendering")
end

for _, metadata in ipairs { "key: a" .. nul .. "b", "description: |", "k" .. nul .. "ey: a" .. nul .. "b" } do
  local lines = { "---", metadata, "---", "", "[a" .. nul .. "b](/url)" }
  local original = vim.deepcopy(lines)
  local content = preview.build_content(lines, { max_width = 100, text_scale = false })
  eq(lines, original, "frontmatter rendering preserves its caller's array")
  local expected = metadata == "key: a" .. nul .. "b" and "  key: a�b"
    or metadata == "description: |" and "  description: |"
    or "  k�ey: a�b"
  eq(content.lines[2], expected, "parsed and literal frontmatter are normalized")
  eq(content.source_line_map[2], 2, "frontmatter source row")
  eq(content.link_metadata[1].url, "/url", "body parsing still works after frontmatter")
  apply(content)
end

do
  local content = preview.build_content({ "---", "tag: a" .. nul .. "b" .. nul .. "c" .. nul .. "d", "---" }, {
    max_width = 10,
    text_scale = false,
    expand_state = { [-2] = true },
  })
  local region, fragments = content.expandable_regions[1], {}
  for row = region.start_line + 1, region.end_line + 1 do
    fragments[#fragments + 1] = content.lines[row]:sub(#"  tag: " + 1)
  end
  eq(table.concat(fragments), "a�b�c�d", "expanded frontmatter wraps normalized glyphs")
  apply(content)
end

do
  local source = vim.api.nvim_create_buf(false, true)
  local lines = { "a" .. nul .. "b", "", "[c" .. nul .. "d](/e" .. nul .. "f)" }
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  local tick = vim.api.nvim_buf_get_changedtick(source)
  local session = preview._Session.new(source, "nul_rendering_session", { max_width = 100, text_scale = false })
  eq(
    vim.api.nvim_buf_get_lines(session.buf, 0, -1, false),
    { "  a�b", "  ", "  c�d" },
    "Session applies normalized text"
  )
  session:refresh_source()
  session:rebuild()
  eq(session.source_lines, lines, "Session keeps its original source snapshot after rebuild")
  eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), lines, "source buffer retains its NUL bytes")
  eq(vim.api.nvim_buf_get_changedtick(source), tick, "rendering never changes the source changedtick")
  eq(session.content.link_metadata[1].url, "/e�f", "Session retains the normalized navigation target")
  session:dispose()
  vim.api.nvim_buf_delete(source, { force = true })
end

-- Literal resource APIs keep rejecting NUL instead of changing its spelling.
eq(image.resolve_local("bad" .. nul .. ".png", vim.fn.getcwd()), nil, "literal resource path rejects NUL")
eq(Links.file_path("bad" .. nul .. ".md", vim.fn.getcwd()), nil, "literal file destination rejects NUL")
local calls, callbacks = 0, 0
image.set_download_fn(function()
  calls = calls + 1
end)
for _, download in ipairs { image.download_async, image.download_video_async } do
  download("https://example.invalid/a" .. nul .. ".png", function(path)
    eq(path, nil, "literal download URL rejects NUL")
    callbacks = callbacks + 1
  end)
end
eq({ calls, callbacks }, { 0, 2 }, "invalid downloads have no downloader side effects")
image.set_download_fn(nil)

print(string.format("nul_rendering_test: %d passed", checks))
