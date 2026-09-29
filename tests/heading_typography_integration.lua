-- Image typography contract, using the real Pango worker and Neovim layout/masks.
vim.env.TMUX, vim.env.TMUX_PANE, vim.env.TERM_PROGRAM = nil, nil, nil
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local image = require "md-render.image"
local size = require "md-render.text_size"
local heading = require "md-render.heading_image"
local Builder = require("md-render.content_builder").ContentBuilder
vim.o.termguicolors = true
vim.o.lines, vim.o.columns = 60, 100
vim.api.nvim_ui_send = function() end
-- Headless Neovim has no screen grid; real-window checks are captured separately.
vim.fn.screenpos = function(_, line, col)
  return { row = line, col = col }
end
size.text_area = function()
  return 1, 100, 1, 60
end
image.supports_kitty = function()
  return true
end
image.png_status = function()
  return { supported = true }
end
image.get_cell_size = function()
  return { cell_w = 19, cell_h = 44 }
end
local id = 0
image.transmit_png = function(_, callback)
  id = id + 1
  callback()
  return id
end
vim.api.nvim_set_hl(0, "Normal", { fg = 0xd8dee9, bg = 0x161b22 })
for level = 1, 6 do
  vim.api.nvim_set_hl(0, "MdRenderH" .. level, { fg = 0xd8dee9, bold = true })
end
size.setup { backend = "image" }
local ratios = { 2, 1.5, 1.25, 1, 0.875, 0.85 }
local source = { "正文開始。" }
for level = 1, 6 do
  source[#source + 1] = string.rep("#", level) .. " 共同標題文字測試 ABC"
  source[#source + 1] = "這段正文應完整保留。"
end
local function build(lines, width)
  for _ = 1, 10 do
    local builder = Builder.new()
    builder:render_document(lines, { max_width = width, indent = "" })
    local content, pending = builder:result(), false
    for _, entry in pairs(content.heading_layouts) do
      pending = pending or not entry.ready
    end
    if not pending then return content end
    assert(
      vim.wait(5000, function()
        for _, entry in pairs(content.heading_layouts) do
          if not entry.ready then return false end
        end
        return true
      end, 10),
      "Pango worker did not finish"
    )
  end
  error "heading layout did not settle"
end
for _, width in ipairs { 100, 56 } do
  local content = build(source, width)
  assert(#content.text_placements == 6, "all six sizes must render, including H5/H6")
  local base
  for _, entry in pairs(content.heading_layouts) do
    assert(entry.output, entry.error)
    local request = entry.request.entries[1]
    local calibrated = entry.output.font_pixels / request.ratio
    base = base or calibrated
    assert(math.abs(base - calibrated) < 0.001, "all levels share the same base font")
    assert(request.styles[1].bold == true, "keep the heading weight")
  end
  for level, p in ipairs(content.text_placements) do
    assert(size.spec_for(level, "image").ratio == ratios[level])
    assert(p.scale == math.ceil(ratios[level]), "small headings occupy one row")
    assert(p.col == 0 and content.lines[p.line + 1] == p.text, "no prefix or reserved gutter")
    local after = content.lines[p.line + p.scale + 1]
    if level <= 2 then
      assert(after == string.rep("─", width), "H1/H2 get a full-width separator")
      assert(not content.heading_lines[p.line + p.scale], "separator is not heading text")
    else
      assert(after == "這段正文應完整保留。", "H3-H6 do not get separators")
    end
  end
  require("md-render.display_utils").apply_content_to_buffer(0, vim.api.nvim_create_namespace "trial", content)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd "redraw"
  local state = heading.attach(0, content)
  assert(
    vim.wait(2000, function()
      return state.drawn == 6
    end, 10),
    "all test images should be visible"
  )
  for level = 5, 6 do
    local entry = state.entries[level]
    local p = entry.placement
    local native_width = vim.fn.strdisplaywidth(p.text)
    assert(entry.cols >= native_width and not entry.mask_ids, "opaque images cover text without erasing terminal cells")
    local pos = vim.fn.screenpos(state.win, p.line + 1, p.col + 1)
    local mouse, projected = heading.mouse_position {
      winid = state.win,
      screenrow = pos.row,
      screencol = pos.col + native_width - 1,
    }
    assert(projected and mouse.line == 0 and mouse.column == 0, "padded tails are not invisible click targets")
  end
  heading.detach(state)
  local long = build({ "正文。", "###### " .. string.rep("中文換行檢查", 12), "結尾。" }, width)
  assert(#long.text_placements > 1, "long small headings wrap while retaining native fallback")
  for _, line in ipairs(long.lines) do
    assert(vim.fn.strdisplaywidth(line) <= width, "native fallback must stay within the window")
  end
end

-- Every overflowing line constrains the same wrap budget; it must not deduct
-- another column just because the heading contains more lines.
for _, count in ipairs { 24, 36 } do
  local text = string.rep("中文換行檢查", count)
  local content = build({ "###### " .. text }, 20)
  assert(#content.text_placements > 0, "long H6 must not fall back because it has more lines")
  assert(
    #content.text_placements <= math.ceil(vim.fn.strdisplaywidth(text) / 20) * 2,
    "long H6 must not collapse into a column of single characters"
  )
  local fragments = {}
  for _, p in ipairs(content.text_placements) do
    assert(vim.fn.strdisplaywidth(p.text) <= 20, "native fallback fits the narrow window")
    fragments[#fragments + 1] = p.text
  end
  assert(table.concat(fragments) == text, "narrow wrapping retains every character")
end
-- Tmux already masks native text with placeholders and a blank tail. Reuse
-- the first shaped result, including opaque H5/H6, without a padding worker.
vim.env.TMUX = "/private/test,1,0"
package.loaded["md-render.heading_tmux"] = {
  EVENT = "MdRenderTmuxChanged",
  status = function()
    return { key = "test" }
  end,
}
local tmux_content = build(source, 100)
assert(#tmux_content.text_placements == 6)
for _, entry in pairs(tmux_content.heading_layouts) do
  assert(not entry.request.entries[1].native_cols, "tmux must not start a redundant opaque-padding request")
end
require("md-render.display_utils").apply_content_to_buffer(0, vim.api.nvim_create_namespace "trial", tmux_content)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local tmux_state = assert(heading.attach(0, tmux_content))
assert(vim.wait(2000, function()
  return tmux_state.drawn == 6
end, 10))
for level = 5, 6 do
  local entry = tmux_state.entries[level]
  local native_width = vim.fn.strdisplaywidth(entry.placement.text)
  assert(entry.cols < native_width and entry.mask_ids, "tmux masks the native tail without widening the PNG")
  local mark = vim.api.nvim_buf_get_extmark_by_id(0, tmux_state.mask_ns, entry.mask_ids[1], { details = true })
  assert(#mark[3].virt_text[2][1] == native_width - entry.cols, "blank the complete native tail")
end
heading.detach(tmux_state)
print "Heading typography: exact ratios, unchanged weight, H1/H2 rules, small-text masks and wrapping OK"
