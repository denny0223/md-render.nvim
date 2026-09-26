-- Project shaped byte ranges into usable native text, styles and links.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local image = require "md-render.image"
local size = require "md-render.text_size"
local Builder = require("md-render.content_builder").ContentBuilder
vim.o.termguicolors = true
size.supports = function()
  return true
end
image.supports_kitty = function()
  return true
end
image.get_cell_size = function()
  return { cell_w = 19, cell_h = 44 }
end
vim.api.nvim_ui_send = function() end
vim.api.nvim_set_hl(0, "Normal", { fg = 0x112233 })
vim.api.nvim_set_hl(0, "@markup.heading", { fg = 0xabcdef })
vim.api.nvim_set_hl(0, "MdRenderH2", { fg = 0xff9977, bold = false })
require("md-render").setup_highlights()
assert(vim.api.nvim_get_hl(0, { name = "MdRenderH1", link = false }).fg == 0xabcdef)
assert(vim.api.nvim_get_hl(0, { name = "MdRenderH2", link = false }).fg == 0xff9977)
-- Exercise the internal image path before public setup enables it.
size.config = function()
  return {
    backend = "image",
    image = { font = "Noto Sans Mono,Noto Sans Mono CJK TC", font_size = "auto", python = "python3" },
  }
end
local callbacks, requests = {}, {}
local system = vim.system
vim.system = function(_, opts, callback)
  requests[#requests + 1] = vim.json.decode(opts.stdin).requests
  callbacks[#callbacks + 1] = callback
  return { kill = function() end }
end
local function build(lines, opts)
  local builder = Builder.new()
  builder:render_document(
    lines or { "Body", "## [FIRST](#first) [SECOND](#second)", "# First" },
    vim.tbl_extend("force", { max_width = 40, indent = "  " }, opts or {})
  )
  return builder:result()
end
local initial = build()
assert(#initial.text_placements == 0, "pending layout keeps immediately usable text")
assert(vim.wait(1000, function()
  return #callbacks == 1
end))
local repeated = build()
vim.wait(20)
assert(#callbacks == 1, "concurrent builds share their layout work")
local outputs = {}
for index, request in ipairs(requests[1]) do
  local entry = request.entries[1]
  assert(entry.bg == nil and entry.fg == 0x112233, "an unset background must not become opaque black")
  assert(entry.styles[1].fg == (index == 1 and 0xff9977 or 0xabcdef), "image styles follow user highlights")
  local columns = { 0, 0, 3, false, 6 }
  for col = 1, 24 do
    columns[col] = columns[col] and columns[col] < #entry.text and columns[col] or false
  end
  outputs[index] = {
    lines = {
      {
        start = 0,
        ["end"] = #entry.text,
        text = entry.text,
        cols = 24,
        width = 456,
        height = 88,
        data = "png",
        columns = columns,
        transparent = entry.bg == nil,
      },
    },
  }
end
callbacks[1] { code = 0, stdout = vim.json.encode(outputs) }
assert(vim.wait(1000, function()
  for _, entry in pairs(initial.heading_layouts) do
    if not entry.ready then return false end
  end
  return true
end))
local content = build()
assert(#content.text_placements == 2)
assert(next(repeated.heading_layouts) ~= nil)
vim.wait(20)
assert(#callbacks == 1, "unchanged headings reuse shaped PNGs")
vim.o.termguicolors = false
local indexed = build()
assert(#indexed.text_placements == 0 and next(indexed.heading_layouts) == nil, "indexed colors retain native text")
vim.o.termguicolors = true
for _, entry in pairs(initial.heading_layouts) do
  if entry.request.entries[1].text == "FIRST SECOND" then
    local columns = entry.output.lines[1].columns
    entry.output.lines[1].columns = vim.tbl_map(function(byte)
      return byte and byte < 6 and byte or false
    end, columns)
    local unclickable = build()
    assert(
      #unclickable.text_placements == 1 and #unclickable.link_metadata == 2,
      "unsampled links retain clickable text"
    )
    entry.output.lines[1].columns = columns
  end
end
local details_lines = {
  "<details open>",
  "<summary>Study</summary>",
  "## [FIRST](#first) [SECOND](#second)",
  "Body",
  "</details>",
  "# First",
}
local details = build(details_lines)
local plain_details = build(details_lines, { text_scale = false })
assert(#details.text_placements == 1 and details.text_placements[1].text == "First", "details fallback stays local")
assert(vim.deep_equal(details.link_metadata, plain_details.link_metadata), "details links retain native coordinates")
for i, line_text in ipairs(details.lines) do
  if details.source_line_map[i] <= 5 then
    assert(line_text == plain_details.lines[i], "details retain their native prefix, background and row spacing")
  end
end
local utils = require "md-render.display_utils"
utils.apply_content_to_buffer(0, vim.api.nvim_create_namespace "heading_test", content)
local view = utils.remap_view({ lnum = 2, topline = 2, col = 10 }, {
  lines = { "body", "  FIRST SECOND" },
  source_line_map = { 1, 2 },
  heading_positions = { [2] = { byte = 0, col = 2, length = 12 } },
}, {
  lines = { "body", "  FIRST ", "", "  SECOND" },
  source_line_map = { 1, 2, 2, 2 },
  heading_positions = { [2] = { byte = 0, col = 2, length = 6 }, [4] = { byte = 6, col = 2, length = 6 } },
})
assert(view.lnum == 4 and view.col == 4 and view.topline == 2, "reflow preserves the heading character")
local marks = vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })
local spans, stacked = {}, false
for _, mark in ipairs(marks) do
  if content.heading_lines[mark[2]] and mark[4].hl_group then
    assert(mark[4].priority < vim.hl.priorities.user, "Markdown must not cover user yank highlights")
    local key = table.concat({ mark[2], mark[3], mark[4].end_col }, ":")
    if spans[key] then
      assert(mark[4].priority ~= spans[key], "overlapping styles must have distinct priorities")
      stacked = true
    end
    spans[key] = mark[4].priority
  end
end
assert(stacked, "overlapping Markdown styles use ordered highlight groups")
local normal_float = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
vim.api.nvim_set_hl(0, "NormalFloat", { italic = true })
local float_batch = #callbacks + 1
local float_content = build(nil, { heading_normal = "NormalFloat" })
assert(vim.wait(1000, function()
  return #callbacks == float_batch
end))
for _, request in ipairs(requests[float_batch]) do
  local styles = request.entries[1].styles
  assert(styles[1].italic and styles[2].fg, "float attributes precede heading and inline attributes")
end
callbacks[float_batch] { code = 0, stdout = vim.json.encode(outputs) }
assert(vim.wait(1000, function()
  for _, entry in pairs(float_content.heading_layouts) do
    if not entry.ready then return false end
  end
  return true
end))
assert(#build(nil, { heading_normal = "NormalFloat" }).text_placements == 2)
vim.api.nvim_set_hl(0, "NormalFloat", { reverse = true })
local reversed_float = build(nil, { heading_normal = "NormalFloat" })
assert(
  #reversed_float.text_placements == 0 and next(reversed_float.heading_layouts) == nil,
  "unsupported float effects retain native text"
)
vim.api.nvim_set_hl(0, "NormalFloat", normal_float)

-- Unsupported custom effects keep Neovim's real highlighting and operable text.
vim.api.nvim_set_hl(0, "MdRenderH2", { reverse = true })
assert(#build().text_placements == 1)
vim.api.nvim_set_hl(0, "MdRenderH2", { fg = 0x010203 })
local notify, warning = vim.notify_once, nil
vim.notify_once = function(message)
  warning = message
end
vim.system = function()
  error "missing-python"
end
local failed = build()
assert(vim.wait(1000, function()
  return warning ~= nil
end))
assert(warning:find "missing%-python", "failure includes actionable diagnostics")
assert(#failed.text_placements == 1)
vim.system, vim.notify_once = system, notify

print "Heading content: shared layouts, styles, links, reflow and text fallback OK"
