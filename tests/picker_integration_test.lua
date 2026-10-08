-- Run: nvim --headless -u NONE --noplugin -i NONE -l tests/picker_integration_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/notes", "p")
local path = root .. "/notes/readme.md"
vim.fn.writefile({ "# Title", "", "First match", "", "![Local](picture.png)", "", "Last match" }, path)
assert(vim.uv.fs_copyfile("tests/fixtures/test_4x4.png", root .. "/notes/picture.png"))
local tab_image_name = "a\t" .. string.rep("b", 30) .. ".png"
assert(vim.uv.fs_copyfile("tests/fixtures/test_4x4.png", root .. "/" .. tab_image_name))
require("md-render.text_size").setup { enabled = false }
require("md-render.image")._set_kitty_supported(true)

-- Keep the parser and Neovim buffers real; intercept only terminal graphics.
local display = require "md-render.display_utils"
local rendered, cleaned = {}, 0
display.setup_images = function(win, content, _, opts)
  rendered[#rendered + 1] = { content = content, opts = opts }
  return { win = win }
end
display.cleanup_images = function()
  cleaned = cleaned + 1
end
local function wait_for(fn)
  assert(vim.wait(1000, fn, 5), "picker render did not finish")
end
local function expected_row(content, line)
  for row, source in ipairs(content.source_line_map) do
    if source >= line then return row end
  end
  return #content.source_line_map
end
local function assert_media_header(winid, content, backend)
  local bufnr, header = vim.api.nvim_win_get_buf(winid), content.lines[1]
  assert(
    vim.api.nvim_get_current_buf() ~= bufnr and vim.bo.tabstop == 4 and vim.bo[bufnr].tabstop == 8,
    backend .. " fixture must use a different current buffer's tab width"
  )
  assert(display.usable_win_width(winid) == 20, backend .. " fixture must have 20 text columns")
  assert(header:find("\t", 1, true), backend .. " must retain the filename's tab")
  local width = vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.strdisplaywidth(header)
  end)
  assert(width <= display.usable_win_width(winid), backend .. " measured the header in another buffer")
  assert(
    vim.api.nvim_win_text_height(winid, { start_row = 0, end_row = 0 }).all == 1,
    backend .. " media header unexpectedly wraps"
  )
end

package.preload["telescope.previewers"] = function()
  return {
    new_buffer_previewer = function(spec)
      return spec
    end,
  }
end
local telescope = require("md-render.telescope").previewer()
local win = vim.api.nvim_get_current_win()
local function select_telescope(line)
  -- new_buffer_previewer creates a scratch buffer per entry without get_buffer_by_name.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  telescope.define_preview({ state = { winid = win, bufnr = buf } }, { path = path, lnum = line })
  return buf
end
for _, line in ipairs { 3, 7 } do
  local count = #rendered
  local buf = select_telescope(line)
  wait_for(function()
    return #rendered == count + 1
  end)
  assert(vim.api.nvim_buf_line_count(buf) > 1, "same-file grep entry kept an empty replacement buffer")
  assert(
    vim.api.nvim_win_get_cursor(win)[1] == expected_row(rendered[#rendered].content, line),
    "grep hit did not move"
  )
end
local count = #rendered
select_telescope(3)
select_telescope(7)
wait_for(function()
  return #rendered == count + 1
end)
assert(
  vim.api.nvim_win_get_cursor(win)[1] == expected_row(rendered[#rendered].content, 7),
  "debounce used an old grep hit"
)
select_telescope(3)
telescope.teardown()
vim.wait(100)
assert(#rendered == count + 1 and cleaned >= 3, "teardown left a pending render or old graphics")

-- The real API can replace the preview buffer without calling define_preview.
local telescope_path, plenary_path = vim.env.MD_RENDER_TELESCOPE_PATH, vim.env.MD_RENDER_PLENARY_PATH
if telescope_path and telescope_path ~= "" and plenary_path and plenary_path ~= "" then
  vim.opt.rtp:prepend(plenary_path)
  vim.opt.rtp:prepend(telescope_path)
  package.loaded["telescope.previewers"], package.preload["telescope.previewers"] = nil, nil
  local real = require("md-render.telescope").previewer()
  local status = { layout = { preview = { winid = win } } }
  for _, line in ipairs { 3, 7 } do
    count = #rendered
    real:preview({ path = path, lnum = line }, status)
    wait_for(function()
      return #rendered == count + 1
    end)
    assert(vim.api.nvim_win_get_buf(win) == real.state.bufnr, "Telescope rendered into an old buffer")
    assert(vim.api.nvim_win_get_cursor(win)[1] == expected_row(rendered[#rendered].content, line))
  end
  count = #rendered
  real:preview({ path = path, lnum = 3 }, status)
  real:preview({ path = path, lnum = 7 }, status)
  wait_for(function()
    return #rendered == count + 1
  end)
  assert(vim.api.nvim_win_get_cursor(win)[1] == expected_row(rendered[#rendered].content, 7))

  local long_path, lines = root .. "/long.md", {}
  for i = 1, 600 do
    lines[i] = "line " .. i
  end
  vim.fn.writefile(lines, long_path)
  count = #rendered
  real:preview({ path = long_path, lnum = 500 }, status)
  wait_for(function()
    return #rendered == count + 1
  end)
  local source_map = rendered[#rendered].content.source_line_map
  assert(source_map[#source_map] <= 500, "Telescope exceeded its rendered line limit")
  real:preview({ path = long_path, lnum = 550 }, status)
  wait_for(function()
    return vim.api.nvim_buf_line_count(real.state.bufnr) == 600 and vim.api.nvim_win_get_cursor(win)[1] == 550
  end)
  assert(vim.api.nvim_buf_get_lines(real.state.bufnr, 599, 600, false)[1] == "line 600", "raw fallback lost content")

  local caller_buf, saved_tabstop = vim.api.nvim_get_current_buf(), vim.bo.tabstop
  vim.bo[caller_buf].tabstop = 4
  local narrow_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 20,
    height = 12,
    style = "minimal",
  })
  vim.wo[narrow_win].wrap = true
  count = #rendered
  real:preview({ path = root .. "/" .. tab_image_name }, { layout = { preview = { winid = narrow_win } } })
  vim.bo[real.state.bufnr].tabstop = 8
  wait_for(function()
    return #rendered == count + 1
  end)
  assert_media_header(narrow_win, rendered[#rendered].content, "real Telescope")
  vim.api.nvim_win_close(narrow_win, true)
  vim.bo[caller_buf].tabstop = saved_tabstop

  count = #rendered
  real:preview({ path = path, lnum = 3 }, status)
  wait_for(function()
    return vim.api.nvim_win_get_buf(win) == real.state.bufnr
  end)
  real:preview(nil, status) -- An empty result set uses another buffer without define_preview.
  vim.wait(100)
  assert(#rendered == count, "clearing Telescope results let stale graphics reach its empty buffer")
  real:preview({ path = path, lnum = 7 }, status)
  real:teardown()
  vim.wait(100)
  assert(#rendered == count, "Telescope teardown left a pending render")
  print "Real Telescope dependency: same-file hits, debounce, empty results, line limit and teardown OK"
else
  print "SKIP real Telescope picker contract: set MD_RENDER_TELESCOPE_PATH and MD_RENDER_PLENARY_PATH"
end

local fallback = 0
package.preload["snacks.picker.preview"] = function()
  return {
    file = function(ctx)
      fallback = fallback + 1
      assert(ctx.prev == nil, "native fallback must not skip a reset same-file preview")
      ctx.preview:reset()
      vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, { "native file preview" })
    end,
  }
end
_G.Snacks = {
  picker = {
    util = {
      path = function(item)
        return item and item.file and (item.cwd .. "/" .. item.file)
      end,
    },
  },
}
local preview = { win = { win = win, buf = vim.api.nvim_create_buf(false, true) } }
vim.api.nvim_win_set_buf(win, preview.win.buf)
function preview:reset()
  vim.bo[self.win.buf].modifiable = true
  vim.api.nvim_buf_set_lines(self.win.buf, 0, -1, false, {})
  vim.api.nvim_buf_clear_namespace(self.win.buf, -1, 0, -1)
end
function preview:set_title() end
function preview:minimal() end
local ctx = setmetatable({
  preview = preview,
  item = { cwd = root, file = "notes/readme.md", pos = { 3, 0 } },
  picker = { opts = { previewers = { file = { max_size = 1024, max_line_length = 500 } } } },
}, {
  __index = function(_, key)
    return key == "buf" and preview.win.buf or key == "win" and preview.win.win or nil
  end,
})
local snacks = require("md-render.snacks").preview()
snacks(ctx)
local content = rendered[#rendered].content
assert(content.image_placements[1].path == root .. "/notes/picture.png", "relative image used the editor cwd")
count = #rendered
ctx.item.pos = { 7, 0 }
snacks(ctx)
assert(#rendered == count, "unchanged rendered buffer should be reusable")
assert(vim.api.nvim_win_get_cursor(win)[1] == expected_row(content, 7), "Snacks same-file grep did not move")

preview:reset() -- Snacks Preview:refresh() clears the same scratch buffer on layout changes.
snacks(ctx)
assert(#rendered == count + 1 and vim.api.nvim_buf_line_count(ctx.buf) > 1, "layout reset left a blank cached preview")
preview.win.buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(win, preview.win.buf)
snacks(ctx)
assert(#rendered == count + 2 and vim.api.nvim_buf_line_count(ctx.buf) > 1, "replacement buffer reused old render")

vim.fn.writefile({ string.rep("x", 2048) }, root .. "/large.md")
local readfile = vim.fn.readfile
vim.fn.readfile = function(file, ...)
  assert(file ~= root .. "/large.md", "oversized Markdown was read before native size limit")
  return readfile(file, ...)
end
ctx.item = { cwd = root, file = "large.md", pos = { 1, 0 } }
ctx.prev = ctx.item
snacks(ctx)
vim.fn.readfile = readfile
assert(fallback == 1 and #rendered == count + 2, "oversized Markdown bypassed the native previewer")

local binary_files = { "binary-nul.md", "binary-control.md" }
for index, name in ipairs(binary_files) do
  local file = assert(io.open(root .. "/" .. name, "wb"))
  file:write("# Binary\n**literal**" .. string.char(index - 1) .. " tail\n")
  file:close()
  ctx.item = { cwd = root, file = name }
  ctx.prev = ctx.item
  snacks(ctx)
  assert(fallback == index + 1 and #rendered == count + 2, "binary Markdown entered the renderer")
end

-- Narrow picker windows must budget their gutter and keep media headers on one row.
do
  local narrow_path = root .. "/narrow.md"
  vim.fn.writefile({ "before", "", "---", "", "```lua", string.rep("x", 100), "```" }, narrow_path)
  local image_name = string.rep("long-name-", 12) .. ".png"
  assert(vim.uv.fs_copyfile("tests/fixtures/test_4x4.png", root .. "/" .. image_name))
  local narrow_buf = vim.api.nvim_create_buf(false, true)
  local narrow_win = vim.api.nvim_open_win(narrow_buf, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 20,
    height = 12,
    style = "minimal",
  })
  vim.wo[narrow_win].wrap = true
  vim.wo[narrow_win].number, vim.wo[narrow_win].signcolumn, vim.wo[narrow_win].foldcolumn = true, "yes", "1"
  local narrow_preview = { win = { win = narrow_win, buf = narrow_buf } }
  narrow_preview.reset, narrow_preview.set_title, narrow_preview.minimal =
    preview.reset, preview.set_title, preview.minimal
  local narrow_ctx = setmetatable({ preview = narrow_preview, picker = ctx.picker }, {
    __index = function(_, key)
      return key == "buf" and narrow_buf or key == "win" and narrow_win or nil
    end,
  })
  local narrow_snacks = require("md-render.snacks").preview()
  for _, backend in ipairs { "telescope", "snacks" } do
    for _, name in ipairs { "narrow.md", image_name } do
      local before = #rendered
      vim.bo[narrow_buf].modifiable = true
      if backend == "telescope" then
        telescope.define_preview({ state = { winid = narrow_win, bufnr = narrow_buf } }, { path = root .. "/" .. name })
      else
        narrow_ctx.item = { cwd = root, file = name }
        narrow_snacks(narrow_ctx)
      end
      wait_for(function()
        return #rendered == before + 1
      end)
      local output = rendered[#rendered].content
      local width = display.usable_win_width(narrow_win)
      for row, text in ipairs(output.lines) do
        assert(vim.fn.strdisplaywidth(text) <= width, backend .. " exceeds the available text columns")
        assert(
          vim.api.nvim_win_text_height(narrow_win, { start_row = row - 1, end_row = row - 1 }).all == 1,
          backend .. " unexpectedly wraps a fitted row"
        )
      end
      if name == "narrow.md" then
        local rule = assert(vim.tbl_filter(function(text)
          return text:find("─", 1, true)
        end, output.lines)[1])
        assert(vim.fn.strdisplaywidth(rule) == width - 4, backend .. " must use the real picker text width")
      else
        local placement = assert(output.image_placements[1])
        assert(placement.cols <= width - 2, backend .. " media must fit the same text area")
      end
    end
  end
  -- The picker normally owns focus while the preview uses different buffer options.
  vim.api.nvim_set_current_win(win)
  local caller_buf, saved_tabstop = vim.api.nvim_get_current_buf(), vim.bo.tabstop
  vim.bo[caller_buf].tabstop, vim.bo[narrow_buf].tabstop = 4, 8
  vim.wo[narrow_win].number, vim.wo[narrow_win].signcolumn, vim.wo[narrow_win].foldcolumn = false, "no", "0"
  for _, backend in ipairs { "telescope", "snacks" } do
    local before = #rendered
    vim.bo[narrow_buf].modifiable = true
    if backend == "telescope" then
      telescope.define_preview({ state = { winid = narrow_win, bufnr = narrow_buf } }, {
        path = root .. "/" .. tab_image_name,
      })
    else
      narrow_ctx.item = { cwd = root, file = tab_image_name }
      narrow_snacks(narrow_ctx)
    end
    wait_for(function()
      return #rendered == before + 1
    end)
    assert_media_header(narrow_win, rendered[#rendered].content, backend)
  end
  vim.bo[caller_buf].tabstop = saved_tabstop
  telescope.teardown()
  vim.api.nvim_win_close(narrow_win, true)
  vim.api.nvim_buf_delete(narrow_buf, { force = true })
end

-- Optional real dependency contract: exercise Snacks' actual reset/refresh/file methods.
local snacks_path = vim.env.MD_RENDER_SNACKS_PATH
if snacks_path and snacks_path ~= "" then
  vim.opt.rtp:prepend(snacks_path)
  package.loaded["snacks.picker.preview"], package.preload["snacks.picker.preview"] = nil, nil
  require "snacks"
  local window = Snacks.win { width = 60, height = 12, enter = false, show = true }
  preview = setmetatable({ win = window, state = {} }, { __index = require "snacks.picker.core.preview" })
  ctx.preview = preview
  ctx.item = { cwd = root, file = "notes/readme.md", pos = { 3, 0 } }
  preview.item = ctx.item
  ctx.prev = nil
  local native = require("md-render.snacks").preview()
  native(ctx)
  assert(vim.api.nvim_buf_line_count(ctx.buf) > 1, "real Snacks initial preview failed")
  count = #rendered
  preview:refresh {
    show_preview = function()
      native(ctx)
    end,
  }
  wait_for(function()
    return #rendered == count + 1
  end)
  assert(vim.api.nvim_buf_line_count(ctx.buf) > 1, "real Snacks layout refresh blanked the preview")
  ctx.item = { cwd = root, file = "large.md" }
  ctx.prev, preview.item = ctx.item, ctx.item
  native(ctx)
  assert(vim.api.nvim_buf_get_lines(ctx.buf, 0, 1, false)[1]:find("large file", 1, true), "native size warning missing")
  for _, name in ipairs(binary_files) do
    ctx.item = { cwd = root, file = name }
    ctx.prev, preview.item = nil, ctx.item
    require("snacks.picker.preview").file(ctx)
    local expected = vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false)
    preview:reset()
    ctx.prev = ctx.item
    local before = #rendered
    native(ctx)
    assert(#rendered == before, "binary Markdown entered the renderer with real Snacks")
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false), expected),
      "binary Markdown did not preserve the native raw preview"
    )
  end
  local caller_buf, saved_tabstop = vim.api.nvim_get_current_buf(), vim.bo.tabstop
  vim.bo[caller_buf].tabstop = 4
  vim.api.nvim_win_set_config(ctx.win, { width = 20 })
  preview:reset()
  vim.bo[ctx.buf].tabstop = 8
  ctx.item = { cwd = root, file = tab_image_name }
  preview.item = ctx.item
  count = #rendered
  native(ctx)
  assert_media_header(ctx.win, rendered[#rendered].content, "real Snacks")
  native(ctx)
  assert(#rendered == count + 1, "real Snacks must reuse a fitted media header")
  preview:refresh {
    show_preview = function()
      native(ctx)
    end,
  }
  wait_for(function()
    return #rendered == count + 2
  end)
  assert_media_header(ctx.win, rendered[#rendered].content, "real Snacks after refresh")
  vim.bo[caller_buf].tabstop = saved_tabstop
  window:destroy()
  print "Real Snacks dependency: layout refresh, native filesize warning and binary preview OK"
else
  print "SKIP real Snacks picker contract: set MD_RENDER_SNACKS_PATH to an installed checkout"
end

vim.fn.delete(root, "rf")
print "Picker integration: grep navigation, layout reset, source directory and native size limit OK"
