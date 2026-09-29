-- Native rich headings must retain their Markdown bytes, styles and links.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local size = require "md-render.text_size"
local preview = require "md-render.preview"
vim.o.termguicolors = true
size.setup { backend = "auto" }
size.supports = function()
  return true
end
require("md-render.image").png_status = function()
  return { supported = false, reason = "image headings are not supported through tmux" }
end
local fixture = {
  "Body",
  "",
  "# **共同文字** Heading",
  "",
  "## [FIRST](#first) [SECOND](#second)",
  "",
  "### `:Telescope md_render` 擴充功能",
  "",
  "#### *文字 italic* and **bold**",
  "",
  "##### ~~移除文字~~ and [外部連結](https://example.com)",
  "",
  "###### `共同`**文字***測試*[連結](#first) ordinary text",
  "",
  "## First",
  "",
  "## Second",
}
for _, width in ipairs { 32, 52, 80 } do
  local out = preview.build_content(fixture, { max_width = width, indent = "" })
  assert(out.heading_backend == "native" and not out.heading_fallback, "rich content must not downgrade the document")
  local levels, urls = {}, {}
  for _, p in ipairs(out.text_placements) do
    levels[p.hl] = true
    assert(p.width <= width, "style boundaries must be included in wrapping: " .. p.text)
    local text = {}
    for _, run in ipairs(p.runs) do
      text[#text + 1] = run.text
      if run.url then urls[run.url] = (urls[run.url] or "") .. run.text end
      assert(p.text:sub(run.byte + 1, run.byte + #run.text) == run.text, "run byte offsets survive wrapping")
    end
    assert(table.concat(text) == p.text, "run splitting must preserve every byte")
    assert(out.lines[p.line + 1]:sub(p.col + 1) == p.text, "the buffer retains the same searchable text")
  end
  for level = 1, 6 do
    assert(levels["MdRenderH" .. level], "missing heading level " .. level)
  end
  assert(urls["#first"] == "FIRST連結" and urls["#second"] == "SECOND", "adjacent destinations must remain distinct")
  assert(urls["https://example.com"] == "外部連結", "external link survives wrapping")
end
local readme = preview.build_content(vim.fn.readfile "README.zh-TW.md", { max_width = 80, indent = "  " })
assert(readme.heading_backend == "native" and not readme.heading_fallback, "the real README stays native")
assert(size.status(readme):find("auto -> native", 1, true), "status reports the usable native backend")

-- OSC 66 drops controls instead of drawing Neovim's tab/control feedback.
-- Test after Markdown decoding, and preserve every source and rendered byte.
for _, case in ipairs {
  { "### `a\tb` X", "### a\tb X" },
  { "### before [a\tb](#destination) after", "### before a\tb after" },
  { "### before [a&#9;b](#destination) after", "### before a\tb after" },
  { "### a&#x7F;b", "### a\127b" },
} do
  local source = { "Body", "", "# Ordinary", "", case[1], "", "## Destination" }
  local original = vim.deepcopy(source)
  local out = preview.build_content(source, { max_width = 80, indent = "" })
  assert(out.heading_backend == "plain" and #out.text_placements == 0, "controls must not enter native runs")
  assert(
    out.heading_fallback == "native heading text contains control characters",
    "fallback explains the actual limit"
  )
  assert(size.status(out):find(out.heading_fallback, 1, true), "status reports the control-character fallback")
  assert(vim.list_contains(out.lines, case[2]), "plain fallback must retain control bytes")
  assert(vim.list_contains(out.lines, "# Ordinary"), "fallback preserves the whole document's hierarchy")
  assert(vim.deep_equal(source, original), "heading fallback must not alter the source")
end

-- Exercise emitted styles, not only layout metadata. Changing an inline group
-- must invalidate its SGR cache without rebuilding or losing the heading style.
vim.o.columns, vim.o.lines = 140, 55
vim.wo.cursorline = false
vim.cmd "nohlsearch"
for level = 1, 6 do
  vim.api.nvim_set_hl(0, "MdRenderH" .. level, { fg = 0x112233, bold = true })
end
vim.api.nvim_set_hl(0, "MdRenderInlineCode", { fg = 0x445566, bg = 0x101010 })
vim.api.nvim_set_hl(0, "MdRenderLink", { fg = 0x778899, underline = true })
local content = preview.build_content({
  "Body",
  "",
  "### `code` [外部](https://example.com) [TAB](https://example.com/a&#9;b) [DEL](https://example.com/a&#x7F;b)",
}, { max_width = 100, indent = "" })
local buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, content.lines)
local writes = {}
vim.api.nvim_ui_send = function(bytes)
  writes[#writes + 1] = bytes
end
local state = size.attach(vim.api.nvim_get_current_win(), content)
size.paint(state)
local output = table.concat(writes)
assert(output:find("38;2;68;85;102", 1, true), "code foreground must be painted")
assert(output:find("38;2;119;136;153", 1, true), "link foreground must be painted")
assert(output:find("\27[4m", 1, true), "link underline must be painted")
assert(output:find("\27]8;;https://example.com\27\\", 1, true), "terminal links cover the scaled text")
assert(output:find("\27]8;;https://example.com/a%09b\27\\", 1, true), "URL tabs must be encoded, not deleted")
assert(output:find("\27]8;;https://example.com/a%7Fb\27\\", 1, true), "URL DEL must be encoded, not deleted")
vim.api.nvim_set_hl(0, "MdRenderInlineCode", { fg = 0xabcdef })
writes = {}
size.paint(state)
assert(table.concat(writes):find("38;2;171;205;239", 1, true), "inline color changes take effect immediately")
size.detach(state)
print "Native rich headings: six levels, measured wrap, README, source bytes, styles and links OK"
