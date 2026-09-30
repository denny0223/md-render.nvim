-- Async layout/cache ownership and native/image interaction invariants.
vim.env.TMUX, vim.env.TMUX_PANE, vim.env.TERM_PROGRAM = nil, nil, nil
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local image = require "md-render.image"
local size = require "md-render.text_size"
local heading = require "md-render.heading_image"
local Builder = require("md-render.content_builder").ContentBuilder
vim.o.termguicolors = true
size.supports = function()
  return true
end
image.supports_kitty = function()
  return true
end
image.get_cell_size = function(exact)
  return exact and { cell_w = 19, cell_h = 44 } or { cell_w = 10, cell_h = 20 }
end
local terminal = {}
vim.api.nvim_ui_send = function(data)
  terminal[#terminal + 1] = data
end
local transmissions = 0
image.png_status = function()
  return { supported = true }
end
image.transmit_png = function(_, callback)
  callback()
  transmissions = transmissions + 1
  return transmissions
end
vim.api.nvim_set_hl(0, "Normal", { fg = 0x112233 })
vim.api.nvim_set_hl(0, "@markup.heading", { fg = 0xabcdef })
vim.api.nvim_set_hl(0, "MdRenderH2", { fg = 0xff9977, bold = false })
require("md-render").setup_highlights()
assert(vim.api.nvim_get_hl(0, { name = "MdRenderH1", link = false }).fg == 0xabcdef)
assert(vim.api.nvim_get_hl(0, { name = "MdRenderH2", link = false }).fg == 0xff9977)
local link_style = vim.api.nvim_get_hl(0, { name = "MdRenderLink", link = false })
link_style.default = nil
assert(
  link_style.fg == vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false }).fg and link_style.underline,
  "ordinary links have a theme color as well as an underline"
)
local underline = vim.api.nvim_get_hl(0, { name = "Underlined", link = false })
vim.api.nvim_set_hl(0, "Underlined", { fg = 0xaa1122, ctermfg = 5, italic = true })
vim.api.nvim_set_hl(0, "MdRenderLink", {})
require("md-render").setup_highlights()
local custom_link = vim.api.nvim_get_hl(0, { name = "MdRenderLink", link = false })
assert(custom_link.fg == 0xaa1122 and custom_link.ctermfg == 5 and custom_link.italic and not custom_link.underline)
vim.api.nvim_set_hl(0, "MdRenderLink", { fg = 0x123456, underline = false })
require("md-render").setup_highlights()
assert(vim.api.nvim_get_hl(0, { name = "MdRenderLink", link = false }).fg == 0x123456, "explicit overrides win")
local _, link_spans = require("md-render.markdown").render "[DOC](https://example.invalid)"
assert(#link_spans == 1 and link_spans[1].hl == "MdRenderLink", "an explicit link style can remove its underline")
vim.api.nvim_set_hl(0, "Underlined", underline)
vim.api.nvim_set_hl(0, "MdRenderLink", link_style)
size.setup { backend = "image" }
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
  assert(
    request.cell_width == 19 and request.cell_height == 44,
    "raster layout uses the same measured cells as placement and hit targets"
  )
  local entry = request.entries[1]
  assert(entry.bg == nil and entry.fg == 0x112233, "an unset background must not become opaque black")
  assert(entry.styles[1].fg == (index == 1 and 0xff9977 or 0xabcdef), "image styles follow user highlights")
  if entry.text == "FIRST SECOND" then
    for _, byte in ipairs { 0, 6 } do
      local style = {}
      for _, span in ipairs(entry.styles) do
        if span.start <= byte and byte < span["end"] then style = vim.tbl_extend("force", style, span) end
      end
      assert(
        style.fg == vim.api.nvim_get_hl(0, { name = "MdRenderLinkAnchor", link = false }).fg and style.underline,
        "rasterized anchors retain their destination color and underline"
      )
    end
  end
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
  "",
  "## [FIRST](#first) [SECOND](#second)",
  "Body",
  "",
  "</details>",
  "",
  "# First",
}
local details = build(details_lines)
local plain_details = build(details_lines, { text_scale = false })
assert(#details.text_placements == 1 and details.text_placements[1].text == "First", "details fallback stays local")
assert(vim.deep_equal(details.link_metadata, plain_details.link_metadata), "details links retain native coordinates")
for i, line_text in ipairs(details.lines) do
  if details.source_line_map[i] <= 7 then
    assert(line_text == plain_details.lines[i], "details retain their native prefix, background and row spacing")
    local point = details.heading_positions[i]
    if point then
      assert(
        line_text:sub(point.col + 1, point.col + point.length)
          == ("FIRST SECOND"):sub(point.byte + 1, point.byte + point.length),
        "details heading character positions exclude the container prefix"
      )
    end
  end
end
local utils = require "md-render.display_utils"
local win = vim.api.nvim_get_current_win()
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
local screenpos = vim.fn.screenpos
vim.fn.screenpos = function(_, line, col)
  return { row = line, col = col }
end
local state = assert(size.attach(win, content))
assert(vim.wait(1000, function()
  return state.drawn == 2
end))
local p = content.text_placements[1]
local osc8 = "\x1b]8;;"
local stop = "\x1b\\"
local linked_row = osc8
  .. "#first"
  .. stop
  .. "   "
  .. osc8
  .. stop
  .. " "
  .. osc8
  .. "#second"
  .. stop
  .. " "
  .. osc8
  .. stop
  .. string.rep(" ", 19)
  .. osc8
  .. stop
for row = p.line + 1, p.line + p.scale do
  assert(
    table.concat(terminal):find(string.format("\x1b[%d;%dH\x1b[0m", row, p.col + 1) .. linked_row, 1, true),
    "terminal links cover both image rows, while gaps and padding reset the URL"
  )
end
assert(state.masked and #vim.api.nvim_buf_get_extmarks(0, state.mask_ns, 0, -1, {}) == 2)
assert(vim.deep_equal(vim.api.nvim__ns_get(state.mask_ns).wins, { win }), "text masks belong to the image window")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), content.lines), "masking never changes yank text")
local masks = vim.api.nvim_buf_get_extmarks(0, state.mask_ns, 0, -1, {})
for _ = 1, 3 do
  state.last_layout = nil
  vim.api.nvim_exec_autocmds("SafeState", {})
end
assert(
  vim.deep_equal(vim.api.nvim_buf_get_extmarks(0, state.mask_ns, 0, -1, {}), masks),
  "graphics repaints must reuse text masks instead of triggering more redraws"
)
local mouse = { winid = win, screenrow = p.line + 2, screencol = p.col + 3, line = p.line + 2, column = 1 }
local mapped, projected = heading.mouse_position(mouse)
assert(projected and mapped.line == p.line + 1 and mapped.column == p.col + 4)
assert(state.entries[1].visible, "hover keeps a visible target")
mouse.screencol = p.col + 4
assert(heading.mouse_position(mouse).line == 0, "image padding cannot open an underlying link")
state.entries[1].visible = false
assert(heading.mouse_position(mouse) == mouse, "no invisible retained targets")
state.entries[1].visible = true
local function paint()
  vim.api.nvim_exec_autocmds("SafeState", {})
end
-- An ordinary image redraw does not physically clear terminal-only URLs.
utils.announce_repaint "image"
assert(state.linked, "redraw! must retain the outstanding terminal URL cleanup")
vim.o.termguicolors = false
paint()
assert(state.drawn == 0 and not state.masked and not state.linked, "text fallback withdraws images and their URLs")
vim.o.termguicolors = true
paint()
assert(state.drawn == 2, "restoring truecolor restores the compatible images")
vim.api.nvim_win_set_cursor(win, { p.line + 1, 0 })
paint()
assert(state.drawn == 2, "moving through the heading margin keeps its image")
vim.wo[win].cursorline = true
for _, option in ipairs { "line", "screenline", "both", "number" } do
  vim.wo[win].cursorlineopt = option
  for row = p.line + 1, p.line + p.scale do
    vim.api.nvim_win_set_cursor(win, { row, 0 })
    paint()
    assert(state.drawn == 2, "CursorLine must not replace images while navigating the heading margin")
  end
end
vim.wo[win].cursorlineopt = "both"
vim.api.nvim_win_set_cursor(win, { p.line + 1, p.col })
state.gesture = state.entries[1]
paint()
assert(state.drawn == 2, "a held image press retains its visible target despite CursorLine")
heading.release_mouse(win)
paint()
assert(state.drawn == 1, "release reveals text when the cursor is inside the heading")
assert(#vim.api.nvim_buf_get_extmarks(0, state.mask_ns, 0, -1, {}) == 1, "revealed text is never masked")
local columns = state.entries[1].cols
state.entries[1].cols = 4
vim.api.nvim_win_set_cursor(win, { p.line + 1, p.col + #p.text - 1 })
paint()
assert(state.drawn == 1, "a compact image must not mask the cursor on wider buffer text")
state.entries[1].cols = columns
vim.api.nvim_win_set_cursor(win, { 1, 0 })
local get_mode, line = vim.api.nvim_get_mode, vim.fn.line
vim.api.nvim_get_mode = function()
  return { mode = "v" }
end
vim.fn.line = function(expr, ...)
  if expr == "v" then return p.line + 1 end
  return line(expr, ...)
end
paint()
assert(state.drawn == 1, "Visual selection leaves unrelated headings visible")
vim.fn.line = function(expr, ...)
  if expr == "v" then return 1 end
  return line(expr, ...)
end
paint()
assert(state.drawn == 2, "selecting only body text keeps all heading images")
vim.api.nvim_get_mode, vim.fn.line = get_mode, line
local feedback_ns = vim.api.nvim_create_namespace "heading_feedback_test"
vim.hl.range(0, feedback_ns, "IncSearch", { p.line, p.col }, { p.line, p.col + 4 })
paint()
assert(state.drawn == 1, "external yank/highlight feedback reveals only the affected heading")
vim.api.nvim_buf_clear_namespace(0, feedback_ns, 0, -1)
paint()
assert(state.drawn == 2, "images return after the user's highlight expires")
vim.fn.setreg("/", "Body")
vim.v.hlsearch = 1
paint()
assert(state.drawn == 2, "unrelated search does not suppress heading images")
vim.fn.setreg("/", "FIRST")
paint()
assert(state.drawn == 1 and vim.fn.getreg "/" == "FIRST" and vim.v.hlsearch == 1)
vim.cmd "nohlsearch"
paint()
assert(state.drawn == 2)
vim.wo[win].winhighlight = "Normal:Error"
paint()
assert(state.drawn == 0, "custom window highlights must not be covered by cached colors")
vim.wo[win].winhighlight = ""
-- :mode resolves Normal through winhighlight; finish the option's redraw
-- before checking the restored global colors, as a TUI does between inputs.
vim.cmd "redraw"
vim.fn.setreg("/", "first")
vim.v.hlsearch, vim.o.ignorecase = 1, false
paint()
local sensitive = state.drawn
vim.o.ignorecase = true
paint()
assert(state.drawn < sensitive, "changing regex options updates image withdrawal")
vim.o.ignorecase = false
vim.cmd "nohlsearch"
paint()
vim.cmd "botright vnew"
local other = vim.api.nvim_get_current_win()
paint()
assert(state.drawn == 2, "inactive previews remain readable")
local inactive = vim.api.nvim_get_hl(0, { name = "NormalNC", link = false })
vim.api.nvim_set_hl(0, "NormalNC", { bg = 0x334455, italic = true })
paint()
assert(state.drawn == 0 and not state.masked, "inactive window styling retains native text")
vim.api.nvim_set_hl(0, "NormalNC", inactive)
vim.cmd "tabnew"
paint()
assert(state.drawn == 0, "off-tab previews never draw")
vim.cmd "tabclose"
paint()
assert(state.drawn == 2)
vim.api.nvim_win_close(other, true)
vim.api.nvim_win_set_hl_ns(win, -1)
local custom_ns = vim.api.nvim_create_namespace "heading_custom_theme"
vim.api.nvim_set_hl(custom_ns, "Normal", { bg = 0x123456 })
vim.api.nvim_set_hl_ns(custom_ns)
paint()
assert(state.drawn == 0 and not state.masked, "global highlight namespace overrides retain native text")
vim.api.nvim_set_hl_ns(0)
paint()
assert(state.drawn == 2, "removing the global override restores images")
local anchor_style = vim.api.nvim_get_hl(0, { name = "MdRenderLinkAnchor", link = false })
vim.api.nvim_set_hl(0, "MdRenderLinkAnchor", { fg = 0x771122 })
paint()
assert(state.drawn == 0 and not state.masked and state.force_text, "direct style edits withdraw cached pixels")
vim.api.nvim_set_hl(0, "MdRenderLinkAnchor", anchor_style)
size.detach(state)
assert(state.closed and state.drawn == 0 and heading.mouse_position(mouse) == mouse)
assert(#vim.api.nvim_buf_get_extmarks(0, state.mask_ns, 0, -1, {}) == 0, "detach restores every masked character")
local float = vim.api.nvim_open_win(vim.api.nvim_get_current_buf(), true, {
  relative = "editor",
  row = 0,
  col = 0,
  width = 40,
  height = 10,
  style = "minimal",
})
local floating = assert(size.attach(float, content))
assert(
  vim.wait(1000, function()
    return floating.drawn == 2
  end),
  "minimal floats' EndOfBuffer mapping must not disable heading images"
)
vim.api.nvim_win_set_hl_ns(float, custom_ns)
paint()
assert(floating.drawn == 0 and not floating.masked, "actual window theme overrides still retain native text")
vim.api.nvim_win_close(float, true)
assert(floating.closed)
vim.fn.screenpos = screenpos

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

local doc_batch = #callbacks + 1
local doc = build { "## [DOC](https://example.invalid/heading)" }
assert(vim.wait(1000, function()
  return #callbacks == doc_batch
end))
local doc_style = {}
for _, span in ipairs(requests[doc_batch][1].entries[1].styles) do
  if span.start == 0 and span["end"] == 3 then doc_style = vim.tbl_extend("force", doc_style, span) end
end
assert(doc_style.fg == link_style.fg and doc_style.underline, "DOC image keeps the ordinary link color and underline")

local quoted_batch = #callbacks + 1
local quoted_source = { "- item", "  > > ### 界 [DOC](/quoted)", "  > > body" }
local quoted = build(quoted_source, { indent = "" })
assert(vim.wait(1000, function()
  return #callbacks == quoted_batch
end))
local quoted_entry = requests[quoted_batch][1].entries[1]
assert(quoted_entry.text == "界 DOC", "raster content excludes every list, quote and rank marker")
callbacks[quoted_batch] {
  code = 0,
  stdout = vim.json.encode {
    {
      lines = {
        {
          start = 0,
          ["end"] = #quoted_entry.text,
          text = quoted_entry.text,
          cols = 14,
          width = 266,
          height = 88,
          data = "png",
          columns = { 0, 0, 0, false, 4, 4, 5, 5, 6, 6, false, false, false, false },
          transparent = true,
        },
      },
    },
  },
}
assert(vim.wait(1000, function()
  for _, entry in pairs(quoted.heading_layouts) do
    if not entry.ready then return false end
  end
  return true
end))
quoted = build(quoted_source, { indent = "" })
local quoted_placement = assert(quoted.text_placements[1])
assert(quoted_placement.col == #"  │ │ ", "image placement uses quote prefix bytes, not display cells")
local quoted_link = assert(quoted.link_metadata[1])
assert(quoted.lines[quoted_link.line + 1]:sub(quoted_link.col_start + 1, quoted_link.col_end) == "DOC")
local quoted_plain = build(quoted_source, { indent = "", text_scale = false })
local quoted_view =
  utils.remap_view({ lnum = quoted_link.line + 1, topline = 1, col = quoted_link.col_start + 1 }, quoted, quoted_plain)
assert(
  quoted_plain.lines[quoted_view.lnum]:sub(quoted_view.col + 1, quoted_view.col + 1) == "O",
  "image-to-plain reflow retains the linked character"
)
local callout_heading = build { "> [!NOTE]+", "> ### [DOC](/quoted)", "> body" }
assert(
  #callout_heading.text_placements == 0,
  "callout heading keeps text until its background can be rasterized correctly"
)
assert(callout_heading.heading_anchors.doc and callout_heading.link_metadata[1].url == "/quoted")

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
assert(not pcall(size.setup, { image = { font_size = 0 } }))
assert(not pcall(size.setup, { backend = "unknown" }))
vim.system, vim.notify_once = system, notify

-- A child editor reaches the real idle loop; vim.wait in this script does not.
local child = vim.fn.jobstart(
  { vim.v.progpath, "--embed", "--headless", "-n", "-u", "NONE", "--noplugin", "-i", "NONE" },
  { rpc = true }
)
local ok, err = pcall(function()
  vim.rpcrequest(
    child,
    "nvim_exec_lua",
    [[
    package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. package.path
    vim.o.termguicolors = true
    local image = require "md-render.image"
    image.supports_kitty = function() return true end
    image.get_cell_size = function() return { cell_w = 13, cell_h = 30 } end
    image.png_status = function() return { supported = true } end
    image.transmit_png = function(_, callback) callback(); return 1 end
    image.put_image = function() end
    image.clear_placements = function() end
    image.delete_image = function() end
    vim.system = function() return nil end
    vim.fn.screenpos = function(_, row, col) return {row=row, col=col} end
    local content = {
      lines = {"Body", "Heading", "", "Plain", ""}, source_line_map={1,2,2,3,3},
      link_metadata={{line=1,col_start=0,col_end=7,url="https://example.invalid/\27\\\7\127"}},
      text_placements={{line=1,col=0,text="Heading",scale=2,
        raster={data="png",cols=10,width=130,height=60,transparent=true,
          columns={0,0,1,2,3,4,5,6,false,false}}},
        {line=3,col=0,text="Plain",scale=2,
          raster={data="png",cols=10,width=130,height=60,transparent=true}}},
    }
    vim.api.nvim_buf_set_lines(0,0,-1,false,content.lines)
    local state = require("md-render.heading_image").attach(vim.api.nvim_get_current_win(), content)
    assert(state.entries[1].links[1]:find("https://example.invalid/%1B\\%07%7F",1,true),
      "URL controls must not escape the OSC 8 payload")
    local events = 0
    _G.idle_events = -1
    vim.api.nvim_create_autocmd("SafeState", { callback = function() events = events + 1 end })
    vim.defer_fn(function()
      _G.idle_events = state.masked and state.linked and events or -2
      require("md-render.heading_image").detach(state)
    end, 100)
  ]],
    {}
  )
  local events
  assert(
    vim.wait(1000, function()
      events = vim.rpcrequest(child, "nvim_exec_lua", "return idle_events", {})
      return events >= 0
    end, 20),
    "child editor never reached idle"
  )
  assert(events > 0 and events < 50, "idle repaint must settle instead of waking itself: " .. events)
end)
vim.fn.jobstop(child)
assert(ok, err)
print "Heading images: async cache, style order, search, lifecycle and fallback OK"
