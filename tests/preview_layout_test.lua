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
check(session, 38, 19) -- Native retains its 25-row limit, rather than window height minus six.
close(session, win)

session, win = open "snacks"
assert(session.opts.max_width == 120, "Snacks uses the available window width")
check(session, 88, 44)
resize(session, win, 60, 50)
check(session, 58, 29)
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
        string.rep("#", level) .. " [" .. string.rep("中", 30) .. "](#target)",
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
