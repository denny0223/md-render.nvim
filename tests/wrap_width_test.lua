-- Rendered text must fit the window, including its display indent.
-- Run: nvim --headless -u NONE --noplugin -l tests/wrap_width_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local preview = require "md-render.preview"
local heading_prefix = "## "
local text = string.rep("甲乙丙丁", 12)
local cases = {
  { name = "paragraph", source = { text }, line = 1, prefix = "", continuation = "" },
  { name = "list", source = { "- " .. text }, line = 1, prefix = "• ", continuation = "  " },
  { name = "quote", source = { "> " .. text }, line = 1, prefix = "│ ", continuation = "│ " },
  {
    name = "heading",
    source = { "## " .. text },
    line = 1,
    prefix = heading_prefix,
    continuation = "",
    heading = true,
  },
  {
    name = "callout",
    source = { "> [!NOTE]", "> " .. text },
    line = 2,
    prefix = "│ ",
    continuation = "│ ",
  },
  {
    name = "Qiita note",
    source = { ":::note info", text, ":::" },
    line = 2,
    prefix = "│ ",
    continuation = "│ ",
  },
  {
    name = "list continuation",
    source = { "1. 項目", "", "   " .. text },
    line = 3,
    prefix = "   ",
    continuation = "   ",
  },
  {
    name = "quote in list",
    source = { "1. 項目", "", "   > " .. text },
    line = 3,
    prefix = "   │ ",
    continuation = "   │ ",
  },
  {
    name = "heading in list",
    heading = true,
    source = { "1. 項目", "", "   ## " .. text },
    line = 3,
    prefix = "   " .. heading_prefix,
    continuation = "   ",
  },
  {
    name = "definition",
    source = { "<dl>", "<dt>項目</dt>", "<dd>" .. text .. "</dd>", "</dl>" },
    line = 3,
    prefix = "  ",
    continuation = "  ",
  },
}
for level = 1, 2 do
  cases[#cases + 1] = {
    name = "H" .. level .. " in details",
    heading = true,
    source = {
      "<details open>",
      "<summary>Details</summary>",
      "",
      string.rep("#", level) .. " " .. text,
      "",
      "</details>",
    },
    line = 4,
    prefix = "│ " .. string.rep("#", level) .. " ",
    continuation = "│ ",
  }
end

local checked = 0
for _, case in ipairs(cases) do
  for _, width in ipairs { 20, 21, 40, 41, 80 } do
    -- nil exercises the real two-space default; empty indent covers split mode.
    for _, opts in ipairs { {}, { indent = "" }, { indent = "    " } } do
      opts.max_width, opts.text_scale = width, false
      local indent = opts.indent or "  "
      local out = preview.build_content(case.source, opts)
      local chunks = {}
      for i, line in ipairs(out.lines) do
        assert(vim.api.nvim_strwidth(line) <= width, case.name .. " overflows " .. width .. ": " .. line)
        -- H1/H2 separators share the source line but are not document text.
        if
          out.source_line_map[i] == case.line
          and not line:match "^%s*$"
          and (not case.heading or out.heading_lines[i - 1])
        then
          local prefix = indent .. (#chunks == 0 and case.prefix or case.continuation)
          assert(line:sub(1, #prefix) == prefix, case.name .. " lost its indent")
          chunks[#chunks + 1] = line:sub(#prefix + 1)
        end
      end
      assert(table.concat(chunks) == text, case.name .. " lost or duplicated text")
      -- The first line must use all available CJK cells: this catches taking
      -- a list container's indent off the budget twice.
      local room = width - vim.api.nvim_strwidth(indent .. case.prefix)
      assert(vim.api.nvim_strwidth(chunks[1]) == math.floor(room / 2) * 2, case.name .. " wraps too early")
      checked = checked + 1
    end
  end
end

-- Formatting and link byte offsets must follow the newly wrapped lines.
local label = string.rep("中文", 20)
local out = preview.build_content({ "前綴 **" .. label .. "** [" .. label .. "](https://example.com)" }, {
  max_width = 20,
  text_scale = false,
})
local bold, links = {}, {}
for _, line in ipairs(out.lines) do
  assert(vim.api.nvim_strwidth(line) <= 20, "formatted text overflows")
end
for _, entry in ipairs(out.highlights) do
  for _, group in ipairs(entry.groups) do
    if group.hl == "Bold" then bold[#bold + 1] = out.lines[entry.line + 1]:sub(group.col + 1, group.end_col) end
  end
end
for _, link in ipairs(out.link_metadata) do
  assert(link.url == "https://example.com", "link target changed")
  links[#links + 1] = out.lines[link.line + 1]:sub(link.col_start + 1, link.col_end)
end
assert(table.concat(bold) == label, "bold spans lost text after wrapping")
assert(table.concat(links) == label, "link spans lost text after wrapping")

-- Input order controls overlapping styles and links; wrapping must not sort it.
do
  local Builder = require("md-render.content_builder").ContentBuilder
  local b = Builder.new()
  b:add_line "lead"
  b:set_source_line(7)
  local quote, marker = "│ ", "• "
  local offset = #quote + #marker
  b:add_wrapped_markdown(
    quote .. marker .. "中文 AB\n\n乙丙 CD",
    {
      { col = offset + 18, end_col = offset + 20, hl = "Last" },
      { col = offset - 2, end_col = offset + 17, hl = "Cross" },
      { col = #quote, end_col = offset, hl = "Special" },
      { col = 0, end_col = #quote, hl = "FloatBorder" },
      { col = offset, end_col = offset + 20, hl = "Bold" },
      { col = offset + 6, end_col = offset + 7, hl = "Gap" },
      { col = offset + 9, end_col = offset + 11, hl = "Breaks" },
      { col = offset + 11, end_col = offset + 17, hl = "Inner" },
    },
    {
      { col_start = offset + 18, col_end = offset + 20, url = "/last" },
      { col_start = offset - 1, col_end = offset + 20, url = "/all" },
      { col_start = offset, col_end = offset + 6, url = "/first" },
      { col_start = offset + 6, col_end = offset + 7, url = "/gap" },
      { col_start = offset + 9, col_end = offset + 11, url = "/break" },
      { col_start = offset + 11, col_end = offset + 17, url = "/utf8" },
      { col_start = 0, col_end = offset, url = "/marker" },
    },
    "  ",
    10,
    quote,
    marker,
    1,
    {
      { col = offset + 9, source_line = 1 },
      { col = offset + 10, source_line = 2 },
    }
  )
  local content = b:result()
  assert(
    vim.deep_equal(content.lines, {
      "lead",
      "  │ • 中文",
      "",
      "  │   AB",
      "",
      "  │   ",
      "",
      "  │   乙丙",
      "",
      "  │   CD",
      "",
    }),
    "quote/list wrapping preserves empty rows and hard breaks"
  )
  local styles, metadata = {}, {}
  for _, entry in ipairs(content.highlights) do
    for _, group in ipairs(entry.groups) do
      styles[#styles + 1] = { entry.line, group.col, group.end_col, group.hl }
    end
  end
  assert(
    vim.deep_equal(styles, {
      { 1, 10, 16, "Cross" },
      { 1, 6, 10, "Special" },
      { 1, 2, 6, "FloatBorder" },
      { 1, 10, 16, "Bold" },
      { 3, 2, 6, "FloatBorder" },
      { 3, 8, 10, "Cross" },
      { 3, 8, 10, "Bold" },
      { 5, 2, 6, "FloatBorder" },
      { 7, 2, 6, "FloatBorder" },
      { 7, 8, 14, "Cross" },
      { 7, 8, 14, "Bold" },
      { 7, 8, 14, "Inner" },
      { 9, 2, 6, "FloatBorder" },
      { 9, 8, 10, "Last" },
      { 9, 8, 10, "Bold" },
    }),
    "style order and UTF-8 byte offsets survive prefix changes"
  )
  for _, link in ipairs(content.link_metadata) do
    metadata[#metadata + 1] = { link.line, link.col_start, link.col_end, link.url }
  end
  assert(
    vim.deep_equal(metadata, {
      { 1, 10, 16, "/all" },
      { 1, 10, 16, "/first" },
      { 3, 8, 10, "/all" },
      { 7, 8, 14, "/all" },
      { 7, 8, 14, "/utf8" },
      { 9, 8, 10, "/last" },
      { 9, 8, 10, "/all" },
    }),
    "links retain row order and input order within each row"
  )
end

-- Short raw HTML rows must not scan every highlight/link for every row.
jit.off()
jit.flush()
for _, case in ipairs { { 1500, "<h1>", "<h1>", 30000000 }, { 4000, '<a href="CaseSensitive">甲</a>', "甲", 60000000 } } do
  local source = { "<div>" }
  for _ = 1, case[1] do
    source[#source + 1] = case[2]
  end
  source[#source + 1] = "</div>"
  local instructions = 0
  debug.sethook(function()
    instructions = instructions + 1000
    assert(instructions < case[4], "raw rows exceeded the bounded distribution work budget")
  end, "", 1000)
  local ok, content = pcall(preview.build_content, source, { max_width = 120, indent = "", text_scale = false })
  debug.sethook()
  assert(ok, content)
  assert(#content.lines == case[1] and #content.highlights == case[1], "large raw group retains every styled row")
  for row, line in ipairs(content.lines) do
    assert(line == case[3] and content.source_line_map[row] == row + 1, "raw rows retain physical source positions")
  end
  if case[3] == "甲" then
    assert(#content.link_metadata == case[1], "large raw group retains every link")
    for row, link in ipairs(content.link_metadata) do
      assert(
        link.line == row - 1 and link.col_start == 0 and link.col_end == #case[3] and link.url == "CaseSensitive",
        "raw links retain ordered UTF-8 byte ranges and literal destinations"
      )
    end
  end
end

-- Wrapping receives rendered text: whitespace is content, and each emitted
-- row must be an exact source slice for highlight/link byte offsets to work.
local wrap = require "md-render.wrap"
for _, case in ipairs {
  { "alpha foo   bar omega tail", 18, { "alpha foo   bar", "omega tail" } },
  { "alpha foo   bar omega tail", 14, { "alpha foo", "bar omega tail" } },
  { "alpha 中   文 omega tail", 14, { "alpha 中   文", "omega tail" } },
  { "  foo   bar  ", 20, { "  foo   bar  " } },
  { "foo\tbar tail", 20, { "foo\tbar tail" } },
  { "   ", 10, { "   " } },
  { "", 10, {} },
} do
  local lines, starts = wrap.wrap_words(case[1], case[2])
  assert(vim.deep_equal(lines, case[3]), "rendered whitespace changed: " .. vim.inspect { case[1], lines })
  for i, line in ipairs(lines) do
    assert(line == case[1]:sub(starts[i] + 1, starts[i] + #line), "wrapped row is not its indexed source slice")
  end
end

for _, glyph in ipairs { "é", "👩‍💻", "👍🏽", "🇹🇼" } do
  local glyph_text = glyph .. " " .. glyph
  local lines, starts = wrap.wrap_words(glyph_text, vim.fn.strdisplaywidth(glyph))
  assert(vim.deep_equal(lines, { glyph, glyph }), "wrapping must retain complete combining and emoji sequences")
  assert(vim.deep_equal(starts, { 0, #glyph + 1 }), "glyph wrapping retains source byte offsets")
end

print(string.format("Wrap width: %d layout cases, complete glyphs and formatting/link offsets passed", checked))
