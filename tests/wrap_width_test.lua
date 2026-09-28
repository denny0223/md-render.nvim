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
    source = { "<details open>", "<summary>Details</summary>", string.rep("#", level) .. " " .. text, "</details>" },
    line = 3,
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

print(string.format("Wrap width: %d layout cases and formatting/link offsets passed", checked))
