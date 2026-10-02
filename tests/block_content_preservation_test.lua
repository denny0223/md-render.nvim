-- Readable block fallbacks, physical source ownership and nonblocking media.
-- Run: nvim --headless -u NONE --noplugin -l tests/block_content_preservation_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local image = require "md-render.image"
image.supports_kitty = function()
  return false
end
local Builder = require("md-render.content_builder").ContentBuilder
local display = require "md-render.display_utils"

local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end

local function build(source, opts)
  local original = vim.deepcopy(source)
  local b = Builder.new()
  b:render_document(source, vim.tbl_extend("force", { max_width = 100, indent = "", text_scale = false }, opts or {}))
  eq(source, original, "source array stays unchanged")
  local c = b:result()
  local buf = vim.api.nvim_create_buf(false, true)
  display.apply_content_to_buffer(buf, vim.api.nvim_create_namespace "block_content_preservation", c)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), #c.lines > 0 and c.lines or { "" }, "real buffer matches content")
  vim.api.nvim_buf_delete(buf, { force = true })
  eq(#c.source_line_map, #c.lines, "one source row per display row")
  for _, row in ipairs(c.source_line_map) do
    assert(row >= 1 and row <= #source + (opts and opts.source_line_offset or 0), "source row stays physical")
  end
  return c
end

local function row_with(c, text)
  local found
  for row, line in ipairs(c.lines) do
    if line:find(text, 1, true) then
      assert(not found, "displayed twice: " .. text)
      found = row
    end
  end
  return found
end

for _, opening in ipairs { "<details>", "<DETAILS OPEN>" } do
  local expanded = opening:find("OPEN", 1, true) ~= nil
  local c = build {
    opening .. '<SUMMARY><EM>MiXeD</EM></SUMMARY><a href="CaseSensitive">BODY73</a></DETAILS>TAIL73',
    "",
    "PUBLIC73",
  }
  eq(c.lines[1], (expanded and "▼ " or "▶ ") .. "MiXeD", "summary supports case-insensitive tags")
  eq(row_with(c, "BODY73") ~= nil, expanded, "only the actual details body is folded")
  eq(c.source_line_map[assert(row_with(c, "TAIL73"))], 1, "inline suffix retains its source row")
  eq(c.source_line_map[assert(row_with(c, "PUBLIC73"))], 3, "closed fold cannot swallow later paragraphs")
  for _, link in ipairs(c.link_metadata) do
    eq(link.url, "CaseSensitive", "tag matching never lowercases destinations")
  end
end

for _, source in ipairs {
  { "<details open><summary>S73</summary>FIRST73", "SECOND73", "</details>TAIL73", "", "PUBLIC73" },
  { "<details open>FIRST73", "SECOND73", "</details>TAIL73", "", "PUBLIC73" },
  { "<details open>", "<summary>S73</summary>FIRST73", "SECOND73", "</details>TAIL73", "", "PUBLIC73" },
  { "<details open>", "<summary>", "S73</summary>FIRST73", "SECOND73", "</details>TAIL73", "", "PUBLIC73" },
} do
  local c = build(source)
  for _, text in ipairs { "FIRST73", "SECOND73", "TAIL73", "PUBLIC73" } do
    local source_row
    for row, line in ipairs(source) do
      if line:find(text, 1, true) then source_row = row end
    end
    local rendered_row = assert(row_with(c, text), "details structural rows retain " .. text)
    eq(c.source_line_map[rendered_row], source_row, "details fragments retain physical source rows")
  end
  eq(c.lines[assert(row_with(c, "TAIL73"))], "TAIL73", "suffix is outside the details body")
  eq(c.lines[assert(row_with(c, "PUBLIC73"))], "PUBLIC73", "following paragraphs leave the details body")
end

for _, source in ipairs {
  { "<details>", "<summary>S73</summary>", "HIDDEN73</details>TAIL73", "", "PUBLIC73" },
  {
    "<details>",
    "<summary>S73</summary>",
    "<details><summary>I73</summary>HIDDEN73</details></details>TAIL73",
    "",
    "PUBLIC73",
  },
  {
    "<details>",
    "<summary>S73</summary>",
    "HIDDEN73 <details>",
    "</details>",
    "HIDDEN74",
    "</details>TAIL73",
    "",
    "PUBLIC73",
  },
  {
    "<details><summary>S73</summary><details>",
    "HIDDEN73",
    "</details>",
    "HIDDEN74",
    "</details>TAIL73",
    "",
    "PUBLIC73",
  },
} do
  local c = build(source)
  eq(row_with(c, "HIDDEN73"), nil, "collapsed content stays hidden before an inline closing tag")
  eq(row_with(c, "HIDDEN74"), nil, "an inner closing tag cannot release the outer collapsed body")
  eq(c.lines[assert(row_with(c, "TAIL73"))], "TAIL73", "collapsed details release their closing-row suffix")
  eq(c.lines[assert(row_with(c, "PUBLIC73"))], "PUBLIC73", "nested same-row closers release the outer fold")
end

do
  local c = build {
    "<details open>",
    "<summary>S73</summary>",
    "<details open><summary>INNER73</summary>FIRST73",
    "SECOND73",
    "</details>",
    "THIRD73",
    "</details>TAIL73",
    "",
    "PUBLIC73",
  }
  for _, text in ipairs { "INNER73", "FIRST73", "SECOND73", "THIRD73" } do
    assert(c.lines[assert(row_with(c, text))]:find("│ ", 1, true) == 1, "nested body remains inside its outer fold")
  end
  eq(c.source_line_map[assert(row_with(c, "FIRST73"))], 3, "nested opening suffix keeps its source row")
  eq(c.lines[assert(row_with(c, "TAIL73"))], "TAIL73", "nested details balance before releasing the suffix")
  eq(c.lines[assert(row_with(c, "PUBLIC73"))], "PUBLIC73", "paragraph after nested folds has no details prefix")
end

do
  local c = build {
    "<details open>",
    "<summary>S73</summary>",
    "",
    "`</details>` and \\</details>",
    "",
    "BODY73</details>TAIL73",
    "",
    "PUBLIC73",
  }
  eq(c.lines[assert(row_with(c, "BODY73"))], "│ BODY73", "code and escaped closers keep their literal ownership")
  eq(c.lines[assert(row_with(c, "TAIL73"))], "TAIL73", "the real closer ends the fold")
end

for _, opening in ipairs { "<details>", "<details open>" } do
  local expanded = opening:find("open", 1, true) ~= nil
  local c = build {
    opening,
    "<summary>S73</summary>",
    "",
    '[LINK73](</details>) and [TITLE73](/target "</details>")',
    "",
    "BODY73",
    "</details>TAIL73",
    "",
    "PUBLIC73",
  }
  eq(row_with(c, "BODY73") ~= nil, expanded, "link destinations and titles cannot end a fold")
  if expanded then
    eq(c.lines[assert(row_with(c, "BODY73"))], "│ BODY73", "body remains inside its actual enclosing details")
    local labels = {}
    for _, link in ipairs(c.link_metadata) do
      labels[#labels + 1] = { c.lines[link.line + 1]:sub(link.col_start + 1, link.col_end), link.url }
      eq(c.source_line_map[link.line + 1], 4, "details links retain their physical source row")
    end
    eq(
      labels,
      { { "LINK73", "/details" }, { "TITLE73", "/target" } },
      "complete links retain destinations and byte ranges"
    )
  else
    eq(c.link_metadata, {}, "collapsed links stay hidden with their body")
  end
  eq(c.lines[assert(row_with(c, "TAIL73"))], "TAIL73", "only the actual closing token releases its suffix")
  eq(c.lines[assert(row_with(c, "PUBLIC73"))], "PUBLIC73", "later paragraphs remain outside the fold")
end

for _, source in ipairs {
  {
    '<details><summary>S73</summary>BODY73</details><a href="/Case" title="',
    'attribute">TAIL73</a>',
    "",
    "PUBLIC73",
  },
  { "<details open>", "<summary>S73</summary>", '<a title="', 'attribute">BODY73</a></details>TAIL73', "", "PUBLIC73" },
  { "<details>", "<summary>S73</summary>", "BODY73</details", ">TAIL73", "", "PUBLIC73" },
} do
  local c = build(source, { max_width = 200 })
  for _, text in ipairs { "BODY73", "TAIL73", "PUBLIC73" } do
    local row = assert(row_with(c, text), "raw details fallback retains " .. text)
    assert(source[c.source_line_map[row]]:find(text, 1, true), "raw details fallback retains physical source rows")
  end
  eq(c.callout_folds, {}, "closers sharing multiline tokens use readable raw HTML")
  eq(c.lines[assert(row_with(c, "PUBLIC73"))], "PUBLIC73", "unsupported fold boundaries never capture later paragraphs")
  if source[1]:find('href="/Case"', 1, true) then
    local link = assert(c.link_metadata[1], "fallback retains the suffix link")
    eq(c.lines[link.line + 1]:sub(link.col_start + 1, link.col_end), "TAIL73", "multiline suffix link keeps its label")
    eq(link.url, "/Case", "fallback keeps the case-sensitive suffix destination")
  end
end

for _, tag in ipairs { "script", "STYLE", "pre", "TEXTAREA" } do
  for _, opening in ipairs { "<details>", "<details open>" } do
    local expanded = opening:find("open", 1, true) ~= nil
    local raw_open, raw_close = "<" .. tag .. ">", "</" .. tag:lower() .. " >"
    local raw_text = 'RAW73 "</details><details>"'
    for _, source in ipairs {
      {
        opening .. "<summary>S73</summary>" .. raw_open .. raw_text .. raw_close .. "BODY73</details>TAIL73",
        "PUBLIC73",
      },
      { opening, "<summary>S73</summary>", raw_open, raw_text, raw_close .. "BODY73</details>TAIL73", "PUBLIC73" },
      {
        opening,
        "<summary>S73</summary>",
        raw_open,
        "before blank",
        "",
        raw_text,
        raw_close,
        "BODY73",
        "</details>TAIL73",
        "PUBLIC73",
      },
      {
        opening,
        "<summary>S73</summary>",
        "",
        raw_open,
        raw_text,
        "",
        raw_close,
        "BODY73",
        "</details>TAIL73",
        "PUBLIC73",
      },
    } do
      local c = build(source, { max_width = 200 })
      eq(row_with(c, "RAW73") ~= nil, expanded, "raw HTML payload keeps its enclosing fold state")
      eq(row_with(c, "BODY73") ~= nil, expanded, "raw-text tags cannot open or close another details section")
      if expanded then
        local row = assert(row_with(c, "RAW73"))
        assert(c.lines[row]:find(raw_text, 1, true), "expanded raw-text payload retains its literal closer")
        assert(source[c.source_line_map[row]]:find("RAW73", 1, true), "raw-text payload keeps its physical source row")
      end
      eq(c.callout_folds[1].collapsed, not expanded, "raw-text payload preserves the established fold")
      eq(c.lines[assert(row_with(c, "TAIL73"))], "TAIL73", "same-row raw close releases the actual details suffix")
      eq(c.lines[assert(row_with(c, "PUBLIC73"))], "PUBLIC73", "actual close returns to the surrounding document")
    end
  end
end

do
  local c = build({ "intro", "continued", "", "<details><summary>OPEN73</summary>BODY73</details>TAIL73" }, {
    fold_state = { [4] = false },
  })
  eq(c.callout_folds[1].source_line, 4, "fold state uses the original source row after paragraph joining")
  assert(row_with(c, "BODY73"), "explicit expansion opens a one-line fold")
  eq(c.source_line_map[assert(row_with(c, "BODY73"))], 4, "inline body preserves physical source row")
  c = build { "<details>", "<summary>NOTE73</summary>", "HIDDEN73", "</details>TAIL73", "", "PUBLIC73" }
  eq(row_with(c, "HIDDEN73"), nil, "closed multiline details still folds its body")
  eq(c.source_line_map[assert(row_with(c, "TAIL73"))], 4, "closing-tag suffix stays visible on its own source row")
  assert(row_with(c, "PUBLIC73"), "closing-tag suffix leaves following content outside the fold")
  c = build {
    "<details><summary>OUTER73</summary><details><summary>INNER73</summary>BODY73</details></details>TAIL73",
    "",
    "PUBLIC73",
  }
  eq(row_with(c, "INNER73"), nil, "nested body stays inside the collapsed outer fold")
  assert(row_with(c, "TAIL73") and row_with(c, "PUBLIC73"), "nested inline closing tags cannot consume later text")
end

for _, case in ipairs {
  { { "<table>", "<caption>CAPTION73</caption>", "<tr><td>CELL73</td></tr>", "</table>" }, { "CAPTION73", "CELL73" } },
  { { "<table><tr><td>CELL73</td></tr></table>TAIL73" }, { "CELL73", "TAIL73" } },
  {
    {
      "<table>",
      "<tr><td>BEFORE73<table><tr><td>INNER73</td></tr></table>AFTER73</td><td>RIGHT73</td></tr>",
      "</table>",
    },
    { "BEFORE73", "INNER73", "AFTER73", "RIGHT73" },
  },
  { { "<table>OUTSIDE73<tr><td>CELL73</td></tr></table>" }, { "OUTSIDE73", "CELL73" } },
} do
  local c = build(case[1], { max_width = 300 })
  for _, text in ipairs(case[2]) do
    local row = assert(row_with(c, text), "HTML fallback lost " .. text)
    assert(case[1][c.source_line_map[row]]:find(text, 1, true), "fallback source row contains its visible text")
  end
  eq(c.table_lines, {}, "unsupported tables retain readable raw content")
end

do
  local c = build { "<TABLE><TR><TH>HEADER73</TH></TR><TR><TD><EM>MiXeD73</EM></TD></TR></TABLE>" }
  assert(next(c.table_lines), "supported uppercase table retains its table layout")
  assert(row_with(c, "MiXeD73"), "uppercase elements preserve text case")
  assert(not table.concat(c.lines, "\n"):find("<EM>", 1, true), "uppercase inline emphasis renders normally")
  c = build { "<H2><EM>MiXeD Heading</EM></H2>", "", "<DIV>BODY73</DIV>" }
  eq(c.heading_anchors["mixed-heading"], 0, "HTML heading markup is excluded from its semantic slug")
  assert(row_with(c, "BODY73"), "uppercase wrapper keeps its body")
end

for _, heading in ipairs {
  '<h2><img src="CaseSensitive" alt="LoGo"/> <em>MiXeD73</em></h2>',
  '<H2><IMG SRC="CaseSensitive" ALT="LoGo"/> <EM>MiXeD73</EM></H2>',
} do
  local c = build { heading }
  eq(c.heading_anchors["logo-mixed73"], 0, "split HTML images retain their alt text in the heading's semantic slug")
  eq(c.heading_anchors["mixed73"], nil, "layout extraction does not replace the heading source")
  eq(c.source_line_map[assert(row_with(c, "MiXeD73"))], 1, "heading remains mapped to its physical source row")
  assert(row_with(c, "LoGo"), "image presentation retains the original alt case")
end

do
  local c = build { "Text[^n]", "", "[^n]: FIRST73", "  SECOND73", "    THIRD73", "", "AFTER73" }
  local row = assert(row_with(c, "FIRST73 SECOND73 THIRD73"), "footnote owns both continuation indentation widths")
  eq(c.source_line_map[row], 3, "footnote maps to its definition, not the end of the document")
  eq(row_with(c, "SECOND73"), row, "continuation is emitted only once")
  eq(row_with(c, "THIRD73"), row, "indented continuation is not emitted again as code")
  eq(c.source_line_map[assert(row_with(c, "AFTER73"))], 7, "following body keeps its physical source row")
  c = build { "Text[^n] [^fake]", "", "[^n]: FIRST73", "    [^fake]: LITERAL73", "", "    CODE73" }
  eq(c.footnote_anchors["footnote-def-fake"], nil, "indented continuation cannot publish another definition")
  assert(row_with(c, "FIRST73 [^fake]: LITERAL73"), "definition-looking continuation stays in the owning note")
  eq(c.source_line_map[assert(row_with(c, "CODE73"))], 6, "blank ends note ownership before ordinary code")
end

-- Plain rendering must not resolve media, probe a video or launch an external tool.
do
  local saved = {}
  for _, name in ipairs { "resolve", "resolve_local", "image_dimensions", "video_dimensions", "is_video_content" } do
    saved[name] = image[name]
    image[name] = function()
      error("plain rendering called " .. name)
    end
  end
  for _, source in ipairs {
    { "![VIDEO73](literal.mp4)" },
    { '<VIDEO SRC="literal.mp4"></VIDEO>' },
    { "![IMAGE73](literal.png)" },
    { "| media |", "| --- |", "| ![VIDEO73](literal.mp4) |" },
  } do
    local c = build(source)
    assert(#c.lines > 0, "plain media fallback stays readable")
    eq(c.image_placements, {}, "plain rendering creates no graphical work")
  end
  for name, fn in pairs(saved) do
    image[name] = fn
  end
end

do
  local supports, resolve_local, dimensions, cell_size =
    image.supports_kitty, image.resolve_local, image.video_dimensions, image._test_cell_size
  local resolved, probed = {}, 0
  local literal = "`=1`.mp4"
  image.supports_kitty = function()
    return true
  end
  image._test_cell_size = { cell_w = 8, cell_h = 16 }
  image.resolve_local = function(source, directory)
    resolved[#resolved + 1] = source
    eq(directory, "/tmp", "video resolver receives the source directory")
    return "/tmp/" .. source
  end
  image.video_dimensions = function(path, cached_only)
    eq(path, "/tmp/" .. literal, "video destination remains literal")
    eq(cached_only, true, "document construction only reads cached video dimensions")
    probed = probed + 1
    return 16, 9
  end
  for _, source in ipairs {
    { "![VIDEO73](" .. literal .. ")" },
    { '<VIDEO SRC="' .. literal .. '"></VIDEO>' },
    { "| media |", "| --- |", "| ![VIDEO73](" .. literal .. ") |" },
  } do
    local c = build(source, { buf_dir = "/tmp" })
    eq(resolved[#resolved], literal, "all video display paths share literal resolution")
    eq(#c.image_placements, 1, "cached video metadata still produces a graphical placement")
  end
  eq(#resolved, 3, "standalone Markdown, HTML and table videos each resolve once")
  eq(probed, 3, "each video reads cached dimensions once")
  image.supports_kitty, image.resolve_local, image.video_dimensions, image._test_cell_size =
    supports, resolve_local, dimensions, cell_size
end

print "block_content_preservation: passed"
