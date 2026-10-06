-- Real parser/buffer/backend paths; control only external producers and terminal writes.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local image = require "md-render.image"
local display = require "md-render.display_utils"
local builder = require("md-render.content_builder").ContentBuilder
local png = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"
require("md-render.text_size").setup { enabled = false }
image.setup { backend = "kitty" }
image._set_kitty_supported(true)
image._test_cell_size = { cell_w = 8, cell_h = 16 }
vim.api.nvim_ui_send = function() end
local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
local ns = vim.api.nvim_create_namespace "image_failure_test"
local function wait_for(done, message)
  assert(vim.wait(2000, done, 5), message)
end
local function failure()
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local text = mark[4].virt_text
    if text and text[1][2] == "ErrorMsg" then return mark end
  end
end
local function build(lines, opts)
  local b = builder.new()
  b:render_document(lines, opts or { max_width = 80 })
  local content = b:result()
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  display.apply_content_to_buffer(buf, ns, content)
  vim.bo[buf].modifiable, vim.bo[buf].modified = false, false
  return content
end
local function covers_progress(mark, content, row, progress)
  local line = content.lines[row + 1]
  local first, last = assert(line:find(progress, 1, true))
  assert(mark[2] == row and mark[3] <= first - 1, "failure missed the reserved progress position")
  assert(mark[3] + #mark[4].virt_text[1][1] >= last, "short failure left progress text visible")
end

-- The documented setup_images API permits callers without an auto-rebuild callback.
image.download_async = function(_, callback)
  callback(png)
end
image.transmit_image_async = function(_, callback)
  callback(nil)
end
local content = build { "![remote](https://example.invalid/failure-size.png)", "", "following block" }
local p = content.image_placements[1]
local row, reserved_rows = p.line + math.floor(p.rows / 2), p.rows
local tick, source_map = vim.api.nvim_buf_get_changedtick(buf), vim.deepcopy(content.source_line_map)
local state = display.setup_images(win, content, ns)
wait_for(failure, "resized failed transmission had no feedback")
assert(p.rows < reserved_rows, "fixture did not resize the image")
covers_progress(failure(), content, row, "Loading image...")
assert(vim.api.nvim_buf_get_changedtick(buf) == tick, "failure invalidated unchanged buffer content")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), content.lines))
assert(vim.deep_equal(content.source_line_map, source_map) and not vim.bo[buf].modified)
display.cleanup_images(state)

image.has_mmdc = function()
  return true
end
image.render_mermaid_async = function(_, callback)
  callback(nil)
end
content = build({ "```mermaid", "graph LR", " A-->B", "```", "after" }, { max_width = 16 })
p = content.image_placements[1]
row = p.line + math.floor(p.rows / 2)
state = display.setup_images(win, content, ns)
wait_for(failure, "narrow diagram failure had no feedback")
covers_progress(failure(), content, row, "Rendering mermaid diagram...")
display.cleanup_images(state)

-- Table placements use display columns; UTF-8 indentation and borders use more bytes.
content = build({ "| 中文 | 圖片 |", "| --- | --- |", "| 相鄰內容 | ![圖](tests/fixtures/test_4x4.png) |" }, {
  max_width = 80,
  indent = "　",
  buf_dir = vim.fn.getcwd(),
})
p = assert(content.image_placements[1], "fixture has no table image")
assert(p.cell_cols)
display.show_image_error(buf, ns, p)
local mark = failure()
assert(mark[2] == p.line and vim.fn.strdisplaywidth(content.lines[p.line + 1]:sub(1, mark[3])) == p.col)
assert(#mark[4].virt_text[1][1] <= p.cols, "failure covered a neighboring table cell")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), content.lines))

-- Cached diagrams reserve blank rows, so the image column may lie beyond EOL.
local cached = image.get_mermaid_cached
image.get_mermaid_cached = function()
  return png
end
content = build { "```mermaid", "graph LR", " A-->B", "```" }
p = content.image_placements[1]
local line = content.lines[p.line + 1]
assert(vim.fn.strdisplaywidth(line) < p.col, "cached fixture must place its image beyond EOL")
tick = vim.api.nvim_buf_get_changedtick(buf)
display.show_image_error(buf, ns, p)
mark = failure()
local overlay = mark[4].virt_text[1][1]
assert(mark[2] == p.line and vim.fn.strdisplaywidth(line:sub(1, mark[3]) .. overlay:match "^ *") == p.col)
assert(overlay:find("!", 1, true), "tiny cached diagram must show a failure")
assert(vim.api.nvim_buf_get_changedtick(buf) == tick)
image.get_mermaid_cached = cached

-- A real attached UI verifies wrapped screen rows, not just extmark byte ranges.
local child = vim.fn.jobstart(
  { vim.v.progpath, "--embed", "--headless", "-n", "-u", "NONE", "--noplugin", "-i", "NONE" },
  { rpc = true }
)
local function child_lua(code, args)
  return vim.rpcrequest(child, "nvim_exec_lua", code, args or {})
end
local ok, err = pcall(function()
  vim.rpcrequest(child, "nvim_ui_attach", 16, 32, { rgb = true })
  child_lua [[
    package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
    require("md-render.text_size").setup {enabled = false}
    local image = require "md-render.image"
    image._set_kitty_supported(true)
    image._test_cell_size = {cell_w = 8, cell_h = 16}
    image.has_mmdc = function() return true end
    image.render_mermaid_async = function(_, callback) callback(nil) end
    vim.api.nvim_ui_send = function() end
    vim.wo.wrap, vim.wo.number, vim.wo.relativenumber = true, false, false
    vim.wo.signcolumn, vim.wo.foldcolumn = "no", "0"
    vim.o.laststatus, vim.o.showtabline = 0, 0
  ]]
  for _, case in ipairs { { 16, "  " }, { 16, "　" }, { 18, "│ 日本語 " }, { 80, "  " } } do
    vim.rpcrequest(child, "nvim_ui_try_resize", case[1], 32)
    child_lua(
      [[
      local width, indent = ...
      local display = require "md-render.display_utils"
      if _G.failure_state then display.cleanup_images(_G.failure_state) end
      local b = require("md-render.content_builder").ContentBuilder.new()
      b:render_document({"before", "```mermaid", "graph LR", " A-->B", "```", "after"}, {max_width=width, indent=indent})
      local content = b:result()
      local ns = vim.api.nvim_create_namespace "failure-screen"
      vim.bo.modifiable = true
      vim.api.nvim_buf_clear_namespace(0, -1, 0, -1)
      display.apply_content_to_buffer(0, ns, content)
      vim.bo.modifiable, vim.bo.modified = false, false
      local buf, tick = vim.api.nvim_get_current_buf(), vim.api.nvim_buf_get_changedtick(0)
      _G.failure_state = display.setup_images(vim.api.nvim_get_current_win(), content, ns)
      assert(vim.wait(2000, function()
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {details=true})) do
          if mark[4].virt_text and mark[4].virt_text[1][2] == "ErrorMsg" then return true end
        end
      end, 5), "missing UI failure overlay")
      assert(vim.api.nvim_buf_get_changedtick(buf) == tick and not vim.bo.modified)
      assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), content.lines))
    ]],
      case
    )
    vim.rpcrequest(child, "nvim_command", "redraw!")
    local screen = child_lua [[
      local lines = {}
      for row = 1, vim.o.lines do
        local cells = {}
        for col = 1, vim.o.columns do cells[#cells+1] = vim.fn.screenstring(row, col) end
        lines[#lines+1] = table.concat(cells)
      end
      return table.concat(lines, "\n")
    ]]
    assert(screen:find("failed", 1, true) or screen:find("Failed", 1, true), screen)
    for _, progress in ipairs { "Rendering", "mermaid", "diagram", "..." } do
      assert(not screen:find(progress, 1, true), "wrapped progress remains visible: " .. screen)
    end
    assert(screen:find("before", 1, true) and screen:find("after", 1, true), "adjacent content disappeared")
    if case[1] == 80 then assert(screen:find(":checkhealth md-render", 1, true), screen) end
  end
end)
vim.fn.jobstop(child)
assert(ok, err)

-- Same-file grep navigation must reuse failed content; external resets still invalidate it.
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.writefile(
  { "# Title", "", "![remote](https://example.invalid/picker-failure.png)", "", "first", "", "last" },
  root .. "/readme.md"
)
local pending, resets = {}, 0
image.download_async = function(_, callback)
  pending[#pending + 1] = callback
end
_G.Snacks = { picker = { util = {
  path = function(item)
    return item.cwd .. "/" .. item.file
  end,
} } }
local preview = { win = { win = win, buf = buf } }
function preview:reset()
  resets = resets + 1
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
  vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
end
function preview:set_title() end
function preview:minimal() end
local ctx = {
  preview = preview,
  win = win,
  buf = buf,
  item = { cwd = root, file = "readme.md", pos = { 5, 0 } },
  picker = { opts = { previewers = { file = { max_size = 1024 } } } },
}
local render = require("md-render.snacks").preview()
render(ctx)
wait_for(function()
  return #pending == 1
end, "picker download did not start")
tick = vim.api.nvim_buf_get_changedtick(buf)
pending[1](nil)
wait_for(function()
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    if m[4].virt_text and m[4].virt_text[1][2] == "ErrorMsg" then return true end
  end
end, "picker failure had no feedback")
assert(vim.api.nvim_buf_get_changedtick(buf) == tick)
local first_hit = vim.api.nvim_win_get_cursor(win)[1]
ctx.item.pos = { 7, 0 }
render(ctx)
assert(resets == 1 and #pending == 1, "same-file selection retried failed media")
assert(vim.api.nvim_win_get_cursor(win)[1] > first_hit, "same-file grep navigation stopped working")
preview:reset()
render(ctx)
wait_for(function()
  return #pending == 2
end, "external reset did not rebuild media content")
assert(resets == 3 and vim.api.nvim_buf_line_count(buf) > 1)
pending[2](nil)
vim.api.nvim_exec_autocmds("WinClosed", { pattern = tostring(win), modeline = false })
vim.fn.delete(root, "rf")
print "Image failure: reserved rows, narrow diagrams, UTF-8 table cells, unchanged ticks and picker reset/navigation OK"
