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
  assert(
    vim.fn.strdisplaywidth(line:sub(1, mark[3]) .. mark[4].virt_text[1][1]) >= vim.fn.strdisplaywidth(line:sub(1, last)),
    "short failure left progress text visible"
  )
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
image.has_plantuml, image.render_plantuml_async = image.has_mmdc, image.render_mermaid_async
for _, lang in ipairs { "mermaid", "plantuml" } do
  for _, width in ipairs { 8, 14, 16 } do
    content = build({ "```" .. lang, "A-->B", "```", "after" }, { max_width = width })
    p = content.image_placements[1]
    row = p.line + math.floor(p.rows / 2)
    state = display.setup_images(win, content, ns)
    wait_for(failure, "narrow diagram failure had no feedback")
    assert(vim.fn.strdisplaywidth(content.lines[row + 1]) <= width, "narrow progress must fit its reserved row")
    covers_progress(failure(), content, row, vim.trim(content.lines[row + 1]))
    display.cleanup_images(state)
  end
end

-- Async completion can run in another buffer with a different native tab width.
local saved_tabstop = vim.bo[buf].tabstop
vim.bo[buf].tabstop = 8
content = build({ "<details open>", "<summary>M</summary>", "", "```mermaid", "A-->B", "```", "", "</details>" }, {
  max_width = 20,
  indent = "\t",
})
p = content.image_placements[1]
row = p.line + math.floor(p.rows / 2)
local prefix_end = vim.fn.match(content.lines[row + 1], "\\%" .. (p.col + 1) .. "v")
local expected_prefix = content.lines[row + 1]:sub(1, prefix_end)
assert(expected_prefix:find("│ ", 1, true), "fixture must contain the details bar before the image")
local details_win = vim.api.nvim_open_win(buf, false, {
  relative = "editor",
  row = 0,
  col = 0,
  width = 20,
  height = 25,
  style = "minimal",
})
local caller = vim.api.nvim_create_buf(false, true)
vim.bo[caller].tabstop = 4
vim.api.nvim_win_set_buf(win, caller)
state = display.setup_images(details_win, content, ns)
wait_for(failure, "details diagram failure had no feedback")
assert(vim.api.nvim_get_current_buf() == caller, "async completion must retain the caller buffer")
local details_mark = failure()
covers_progress(details_mark, content, row, vim.trim(content.lines[row + 1]))
assert(
  details_mark[4].virt_text[1][1]:sub(1, #expected_prefix) == expected_prefix,
  "failure must retain the native tab and UTF-8 details prefix"
)
assert(not details_mark[4].virt_text[1][1]:find("Ren", 1, true), "failure retained progress in the details prefix")
display.cleanup_images(state)
vim.api.nvim_win_close(details_win, true)
vim.api.nvim_win_set_buf(win, buf)
vim.api.nvim_buf_delete(caller, { force = true })
vim.bo[buf].tabstop = saved_tabstop

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
    vim.bo.tabstop = 8
    vim.api.nvim_ui_send = function() end
    vim.wo.wrap, vim.wo.number, vim.wo.relativenumber = true, false, false
    vim.wo.signcolumn, vim.wo.foldcolumn = "no", "0"
    vim.o.laststatus, vim.o.showtabline = 0, 0
  ]]
  for _, case in ipairs {
    { 8, "  " },
    { 10, "  " },
    { 12, "  " },
    { 14, "  " },
    { 16, "  " },
    { 16, "　" },
    { 18, "│ 日本語 " },
    { 20, "\t", true },
    { 80, "  " },
  } do
    vim.rpcrequest(child, "nvim_ui_try_resize", case[1], 32)
    child_lua(
      [[
      local width, indent, details = ...
      local display = require "md-render.display_utils"
      if _G.failure_state then display.cleanup_images(_G.failure_state) end
      local b = require("md-render.content_builder").ContentBuilder.new()
      local source = {"before", "```mermaid", "graph LR", " A-->B", "```", "after"}
      if details then
        source = {"before", "<details open>", "<summary>M</summary>", "", "```mermaid", "A-->B", "```", "", "</details>", "after"}
      end
      b:render_document(source, {max_width=width, indent=indent})
      local content = b:result()
      local placement = content.image_placements[1]
      _G.failure_progress_row = placement.line + math.floor(placement.rows / 2)
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
    local output = child_lua [[
      local lines = {}
      for row = 1, vim.o.lines do
        local cells = {}
        for col = 1, vim.o.columns do cells[#cells+1] = vim.fn.screenstring(row, col) end
        lines[#lines+1] = table.concat(cells)
      end
      local progress = vim.fn.screenpos(vim.api.nvim_get_current_win(), _G.failure_progress_row + 1, 1).row
      return { text = table.concat(lines, "\n"), progress = lines[progress] }
    ]]
    local screen = output.text
    assert(screen:find("failed", 1, true) or screen:find("Failed", 1, true) or screen:find("!", 1, true), screen)
    for _, progress in ipairs { "Ren", "mermaid", "diagram", "..." } do
      assert(not screen:find(progress, 1, true), "wrapped progress remains visible: " .. screen)
    end
    assert(
      output.progress and not output.progress:find("…", 1, true),
      "progress ellipsis remains visible: " .. screen
    )
    if case[3] then
      local prefix = string.rep(" ", vim.fn.strdisplaywidth(case[2])) .. "│ "
      assert(output.progress:sub(1, #prefix) == prefix, "failure moved or hid the details bar: " .. screen)
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
