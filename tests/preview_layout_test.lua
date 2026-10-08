-- Exercise window-driven layout without a terminal image backend or converter.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local preview = require "md-render.preview"
local image = require "md-render.image"
local display = require "md-render.display_utils"

assert(image.config().backend == "kitty", "native Kitty must remain the default backend")
image.supports_kitty = function()
  return true
end
image._test_cell_size = { cell_w = 10, cell_h = 20 }
-- Keep real content building and resize autocmds; skip only image transport.
display.setup_images = function() end
vim.o.columns, vim.o.lines = 160, 70
local path = vim.fn.tempname() .. ".svg"
vim.fn.writefile({ [[<svg width="2400" height="2400"></svg>]] }, path)

local function open(backend, opts)
  image.setup { backend = backend }
  local source = vim.api.nvim_create_buf(false, true)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "![Square](" .. path .. ")" })
  local win = vim.api.nvim_open_win(source, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 120,
    height = 50,
    style = "minimal",
  })
  preview.toggle(opts)
  return preview._toggle_sessions[source], win
end

local function check(session, cols, rows)
  local p = session.content.image_placements[1]
  assert(p and p.cols == cols and p.rows == rows, vim.inspect { expected = { cols, rows }, placement = p })
  assert(p.col >= 2 and p.col + p.cols <= session.opts.max_width, "image must fit after the document indent")
end

local function resize(session, win, width, height)
  local before = session.content
  vim.api.nvim_win_set_config(win, { width = width, height = height })
  -- Headless runs do not deliver the UI's resize event automatically.
  vim.api.nvim_exec_autocmds("WinResized", { pattern = tostring(win), modeline = false })
  assert(
    vim.wait(1000, function()
      return session.content ~= before
    end),
    "resizing should rebuild the preview"
  )
end

local function close(session, win)
  preview.toggle()
  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(session.source_bufnr, { force = true })
end

local session, win = open "kitty"
assert(session.opts.max_width == 80, "native automatic text width remains capped at 80")
check(session, 50, 25)
resize(session, win, 40, 20)
assert(session.opts.max_width == 40, "native preview still adapts to a narrow window")
check(session, 36, 18) -- Two indent columns and two margin columns leave 36 image columns.
close(session, win)

session, win = open "snacks"
assert(session.opts.max_width == 120, "Snacks uses the available window width")
check(session, 88, 44)
resize(session, win, 60, 50)
check(session, 56, 28)
resize(session, win, 60, 20)
check(session, 28, 14)
close(session, win)

session, win = open("snacks", { max_width = 100 })
assert(session.opts.max_width == 100, "explicit text width is preserved")
check(session, 88, 44)
resize(session, win, 60, 20)
assert(session.opts.max_width == 100, "resizing does not override explicit text width")
check(session, 28, 14) -- Height must still respond when max_width was explicit.
close(session, win)

-- Tables use available width without changing native paragraph/image limits.
for _, backend in ipairs { "kitty", "snacks" } do
  session, win = open(backend)
  local table_source = { "| ID | Details |", "| --- | --- |", "| A | " .. string.rep("word ", 40) .. "TAIL73 |" }
  vim.api.nvim_buf_set_lines(session.source_bufnr, 0, -1, false, table_source)
  session:refresh_source()
  session:rebuild()
  assert(session.opts.table_max_width == 120, "both backends give tables the available width")
  local function table_width()
    local width = 0
    for _, line in ipairs(session.content.lines) do
      width = math.max(width, vim.fn.strdisplaywidth(line))
    end
    return width
  end
  assert(table_width() == 120, "long cells use all available table width")
  resize(session, win, 100, 50)
  assert(table_width() == 100, "table-only width changes trigger a rebuild")
  assert(session.opts.max_width == (backend == "kitty" and 80 or 100), "ordinary text retains its existing width")
  assert(vim.wo[win].wrap, "fitting tables retain soft wrapping for ordinary text")
  vim.api.nvim_buf_set_lines(session.source_bufnr, 0, -1, false, {
    "| 節點 | CPU | RAM | 容量 | 延遲 | 重試 | 逾時 | 狀態 |",
    "| --- | --- | --- | --- | --- | --- | --- | --- |",
    "| N1 | 4 | 8 | 128 | 12 | 2 | 30 | 就緒 |",
  })
  session:refresh_source()
  resize(session, win, 20, 50)
  assert(table_width() > 20, "glyph minima may exceed an extremely narrow window")
  assert(not vim.wo[win].wrap, "overflowing tables preserve borders and allow horizontal scrolling")
  vim.api.nvim_win_call(win, function()
    vim.cmd "normal! $zl"
    assert(vim.fn.winsaveview().leftcol > 0, "native horizontal scrolling reveals table overflow")
  end)
  vim.api.nvim_buf_set_lines(session.source_bufnr, 0, -1, false, { "Identifier: " .. string.rep("x", 160) .. "TAIL73" })
  session:refresh_source()
  session:rebuild()
  assert(vim.wo[win].wrap, "ordinary long tokens retain native soft wrapping after removing a wide table")
  assert(table.concat(session.content.lines):find("TAIL73", 1, true), "ordinary text retains its tail")
  close(session, win)

  session, win = open(backend, { max_width = 50 })
  assert(session.opts.table_max_width == 50, "explicit max_width also limits table layout")
  vim.api.nvim_win_set_config(win, { width = 40 })
  vim.api.nvim_exec_autocmds("WinResized", { pattern = tostring(win), modeline = false })
  assert(session.opts.table_max_width == 50, "resizing retains the explicit table width")
  close(session, win)
end

-- A configured cap applies to both backends and tables, while each backend
-- keeps its existing automatic policy when the setting is removed.
for _, backend in ipairs { "kitty", "snacks" } do
  vim.g.md_render_max_width = 60.9
  session, win = open(backend)
  vim.api.nvim_buf_set_lines(session.source_bufnr, 0, 0, false, {
    "| Details |",
    "| --- |",
    "| " .. string.rep("word ", 40) .. "|",
    "",
  })
  session:refresh_source()
  session:rebuild()
  assert(session.opts.max_width == 60 and session.opts.table_max_width == 60, "configured widths round down")
  assert(vim.fn.strdisplaywidth(session.content.lines[1]) == 60, "rendered tables respect the configured cap")
  resize(session, win, 40, 30)
  assert(session.opts.max_width == 40 and session.opts.table_max_width == 40, "configured caps follow narrow windows")
  vim.g.md_render_max_width = 100
  resize(session, win, 120, 50)
  assert(session.opts.max_width == 100 and session.opts.table_max_width == 100, "resizing reads a changed global cap")
  assert(vim.fn.strdisplaywidth(session.content.lines[1]) == 100, "tables rebuild at the changed cap")
  vim.g.md_render_max_width = nil
  resize(session, win, 121, 51)
  local automatic_width = backend == "kitty" and 80 or 121
  assert(
    session.opts.max_width == automatic_width and session.opts.table_max_width == 121,
    "removing the cap restores backend defaults"
  )

  -- Requesting the current automatic width must still make it fixed.
  local render_buf = session.buf
  preview.toggle()
  preview.toggle { max_width = automatic_width }
  vim.g.md_render_max_width = 30
  vim.api.nvim_win_set_config(win, { width = 50, height = 20 })
  vim.api.nvim_exec_autocmds("WinResized", { pattern = tostring(win), modeline = false })
  assert(
    session.opts.max_width == automatic_width and session.opts.table_max_width == automatic_width,
    "an equal explicit width stays fixed over global changes and resize"
  )
  if backend == "snacks" then
    assert(
      vim.wait(1000, function()
        return session.content.image_placements[1].rows == 14
      end),
      "fixed width still follows Snacks viewport height"
    )
  end
  preview.toggle()
  preview.toggle { max_width = 70 }
  assert(session.buf == render_buf and session.opts.max_width == 70, "a reused preview applies the new width")
  preview.toggle()
  preview.toggle()
  assert(session.opts.max_width == 70, "navigation re-entry retains the last explicit width")
  vim.g.md_render_max_width = nil
  close(session, win)
end

local notify_once, warnings = vim.notify_once, 0
vim.notify_once = function()
  warnings = warnings + 1
end
for _, invalid in ipairs { "wide", true, 0, -1, math.huge, -math.huge, 0 / 0 } do
  vim.g.md_render_max_width = invalid
  local content = preview.build_content { "---" }
  assert(vim.fn.strdisplaywidth(content.lines[1]) == 80, "invalid caps retain a finite default")
end
assert(warnings == 7, "invalid global widths produce warnings")
session, win = open("snacks", { max_width = 70 })
assert(session.opts.max_width == 70 and warnings == 7, "explicit widths take precedence over an invalid global value")
close(session, win)
vim.g.md_render_max_width = nil
vim.notify_once = notify_once

-- A shared render buffer must preserve borders in every window, including
-- a resized window whose explicit render width does not trigger a rebuild.
local shared_source = vim.api.nvim_create_buf(false, true)
vim.bo[shared_source].filetype = "markdown"
vim.api.nvim_win_set_buf(0, shared_source)
vim.api.nvim_buf_set_lines(shared_source, 0, -1, false, {
  "| ID | Details |",
  "| --- | --- |",
  "| A | " .. string.rep("word ", 40) .. "TAIL73 |",
})
preview.toggle { max_width = 80 }
local shared = assert(preview._toggle_sessions[shared_source])
local primary = vim.api.nvim_get_current_win()
vim.cmd "rightbelow vsplit"
local secondary = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_width(secondary, 20)
vim.api.nvim_exec_autocmds("WinResized", { pattern = tostring(secondary), modeline = false })
for _, current in ipairs(vim.fn.win_findbuf(shared.buf)) do
  assert(
    vim.wo[current].wrap == (vim.api.nvim_win_get_width(current) >= 80),
    "every window preserves wide table borders"
  )
end
vim.wo[secondary].wrap = true
vim.api.nvim_exec_autocmds("BufEnter", { buffer = shared.buf, modeline = false })
assert(not vim.wo[secondary].wrap, "direct entry reapplies overflow handling")
vim.api.nvim_win_close(secondary, true)
vim.api.nvim_set_current_win(primary)
preview.toggle()
vim.api.nvim_buf_delete(shared_source, { force = true })

vim.fn.delete(path)

-- Local native limitations must not make H5 larger than its plain H3 parent.
local size = require "md-render.text_size"
size.setup { enabled = true, backend = "native" }
size.supports = function()
  return true
end
local heading_buf = vim.api.nvim_create_buf(false, true)
local heading_ns = vim.api.nvim_create_namespace "native_heading_fallback"
for _, example in ipairs {
  { lines = { "# Parent", "##### Child", "Body" }, width = 20 },
} do
  local opts = { max_width = example.width, indent = "" }
  local out = preview.build_content(example.lines, opts)
  local plain = preview.build_content(example.lines, vim.tbl_extend("force", opts, { text_scale = false }))
  assert(#out.text_placements == 0, "native previews use a consistent ordinary size when a heading cannot scale")
  assert(vim.deep_equal(out.lines, plain.lines), "fallback recomputes wrapping without scaled empty rows")
  assert(vim.deep_equal(out.link_metadata, plain.link_metadata), "fallback preserves clickable text")
  assert(vim.deep_equal(out.source_line_map, plain.source_line_map), "fallback preserves source mapping")
  assert(out.heading_fallback and out.heading_backend == "plain", "document fallback has an explicit reason")
  assert(size.status(out):find("native -> plain", 1, true), "status describes document fallback")
  display.apply_content_to_buffer(heading_buf, heading_ns, out)
  assert(
    vim.b[heading_buf].md_render_heading_fallback == out.heading_fallback,
    "every render entry point publishes its fallback reason"
  )
end
local simple = preview.build_content({ "### Parent", "##### Child" }, { max_width = 80 })
assert(#simple.text_placements == 2, "fully supported native headings retain their scale")
display.apply_content_to_buffer(heading_buf, heading_ns, simple)
assert(vim.b[heading_buf].md_render_heading_fallback == nil, "successful rebuilds clear the old reason")
vim.api.nvim_buf_delete(heading_buf, { force = true })

-- Plain headings retain their Markdown rank without level-based indentation.
for level = 1, 6 do
  local prefix = string.rep("#", level) .. " "
  local out = preview.build_content({ prefix .. "共同標題", "正文" }, {
    max_width = 32,
    indent = "",
    text_scale = false,
  })
  assert(out.lines[1] == prefix .. "共同標題", "plain H" .. level .. " keeps its rank at the left edge")
  assert(
    out.heading_positions[1].byte == 0 and out.heading_positions[1].col == #prefix,
    "rank markers are excluded from heading character coordinates"
  )
  if level <= 2 then
    assert(out.lines[2] == string.rep(level == 1 and "═" or "─", 32), "plain H1/H2 have distinct rules")
    assert(not out.heading_lines[1], "the rule is not heading text")
  else
    assert(out.lines[2] == "正文", "H3-H6 have no additional indentation or rule")
  end
end

local label = string.rep("中文連結", 8)
local linked = preview.build_content({ "###### [" .. label .. "](https://example.com)" }, {
  max_width = 20,
  indent = "",
  text_scale = false,
})
local fragments = {}
for _, link in ipairs(linked.link_metadata) do
  assert(link.url == "https://example.com", "plain heading link keeps its destination")
  fragments[#fragments + 1] = linked.lines[link.line + 1]:sub(link.col_start + 1, link.col_end)
end
assert(table.concat(fragments) == label, "rank markers never enter link spans")
for row, line in ipairs(linked.lines) do
  assert(vim.fn.strdisplaywidth(line) <= 20, "rank markers count toward the wrap budget")
  local point = linked.heading_positions[row]
  assert(
    point and line:sub(point.col + 1, point.col + point.length) == label:sub(point.byte + 1, point.byte + point.length),
    "wrapped heading positions refer to title bytes, not rank markers"
  )
end

local chars = { "###### 甲乙丙丁戊己庚辛壬癸" }
local scaled = preview.build_content(chars, { max_width = 80, indent = "" })
local plain = preview.build_content(chars, { max_width = 20, indent = "", text_scale = false })
local view = display.remap_view({ lnum = 1, topline = 1, col = 18 }, scaled, plain)
assert(
  plain.lines[view.lnum]:sub(view.col + 1, view.col + 3) == "庚",
  "native to plain keeps the same title character"
)
view = display.remap_view(view, plain, scaled)
assert(
  scaled.lines[view.lnum]:sub(view.col + 1, view.col + 3) == "庚",
  "plain to native keeps the same title character"
)

-- Quote bars consume display cells for wrapping, but metadata keeps UTF-8 bytes.
for _, case in ipairs {
  { { "> ###### 甲乙丙丁戊己庚辛壬癸" }, "│ ", 1 },
  { { "> > ###### 甲乙丙丁戊己庚辛壬癸" }, "│ │ ", 1 },
  { { "- item", "  > ###### 甲乙丙丁戊己庚辛壬癸" }, "  │ ", 2 },
} do
  local native = preview.build_content(case[1], { max_width = 80, indent = "" })
  local ordinary = preview.build_content(case[1], { max_width = 20, indent = "", text_scale = false })
  local placement = assert(native.text_placements[1], "quoted heading uses native layout")
  assert(placement.col == #case[2], "native placement excludes unscaled quote bars using byte columns")
  local mapped =
    display.remap_view({ lnum = placement.line + 1, topline = 1, col = placement.col + 18 }, native, ordinary)
  assert(
    ordinary.lines[mapped.lnum]:sub(mapped.col + 1, mapped.col + 3) == "庚",
    "quoted reflow keeps the title character"
  )
  mapped = display.remap_view(mapped, ordinary, native)
  assert(
    native.lines[mapped.lnum]:sub(mapped.col + 1, mapped.col + 3) == "庚",
    "quoted native restoration keeps the character"
  )
  for row, point in pairs(ordinary.heading_positions) do
    assert(ordinary.source_line_map[row] == case[3], "wrapped quoted title retains its source row")
    assert(
      ordinary.lines[row]:sub(point.col + 1, point.col + point.length)
        == ("甲乙丙丁戊己庚辛壬癸"):sub(point.byte + 1, point.byte + point.length),
      "heading positions exclude every quote and rank byte"
    )
  end
  for _, line in ipairs(ordinary.lines) do
    assert(vim.fn.strdisplaywidth(line) <= 20, "quoted heading wrap counts each quote cell")
  end
end

local quote_source = { "> > # Parent", "> > ##### Child" }
local quoted_narrow = preview.build_content(quote_source, { max_width = 20, indent = "" })
local quoted_plain = preview.build_content(quote_source, { max_width = 20, indent = "", text_scale = false })
assert(vim.deep_equal(quoted_narrow.lines, quoted_plain.lines), "narrow quoted native headings keep plain geometry")
assert(quoted_narrow.heading_backend == "plain", "unsupported quoted native geometry has document fallback")
local quoted_control = preview.build_content({ "> ###### A\tB" }, { max_width = 80, indent = "" })
assert(
  quoted_control.heading_backend == "plain" and #quoted_control.text_placements == 0,
  "quoted tabs retain usable native text"
)
local quoted_empty = preview.build_content(
  { "> ######", "outside" },
  { max_width = 20, indent = "", text_scale = false }
)
assert(
  quoted_empty.heading_lines[0] and next(quoted_empty.heading_anchors) == nil,
  "empty quoted headings retain metadata without anchors"
)
assert(quoted_empty.lines[#quoted_empty.lines] == "outside", "empty quoted heading cannot admit lazy text")

local unbroken = preview.build_content({ "###### " .. string.rep("x", 60) }, {
  max_width = 20,
  indent = "",
  text_scale = false,
})
assert(unbroken.heading_positions[1] == nil, "a marker-only row has no title characters to map")
assert(unbroken.heading_positions[2].byte == 0, "the title still begins at byte zero after a marker-only row")

local ambiwidth = vim.o.ambiwidth
vim.o.ambiwidth = "double"
for _, source in ipairs { "# A", "## B" } do
  local out = preview.build_content({ source }, { max_width = 21, indent = "", text_scale = false })
  assert(vim.fn.strdisplaywidth(out.lines[2]) <= 21, "rules respect terminal character widths")
end
-- The details bar is three cells wide with ambiwidth=double, not two.
for level = 1, 2 do
  for _, width in ipairs { 20, 40 } do
    for _, text_scale in ipairs { false, true } do
      local out = preview.build_content({
        "<details open>",
        "<summary>More</summary>",
        "",
        string.rep("#", level) .. " [" .. string.rep("中", 30) .. "](#target)",
        "",
        "</details>",
      }, { max_width = width, indent = "", text_scale = text_scale })
      if text_scale then
        assert(
          out.heading_backend == (width == 20 and "plain" or "native"),
          "only narrow native headings need document fallback"
        )
      end
      for _, line in ipairs(out.lines) do
        assert(
          vim.fn.strdisplaywidth(line) <= width,
          string.format("H%d details text and rule must fit %d columns", level, width)
        )
      end
    end
  end
end
vim.o.ambiwidth = ambiwidth
print "Preview layout: native caps, Snacks width/height resize, and explicit width OK"
