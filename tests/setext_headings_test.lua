-- CommonMark 0.31.2 examples 84-88, 95-102 and Setext container boundaries.
-- https://spec.commonmark.org/0.31.2/#setext-headings (CC BY-SA 4.0)
-- https://github.com/denny0223/md-render.nvim/issues/34
-- Run: NVIM_LOG_FILE=/tmp/compat-headings-nvim.log nvim --headless -u NONE --noplugin -l tests/setext_headings_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.env.TMUX, vim.env.TMUX_PANE = nil, nil
local markdown = require "md-render.markdown"
local Builder = require("md-render.content_builder").ContentBuilder
local display = require "md-render.display_utils"
local Links = require "md-render.links"
local size = require "md-render.text_size"
local image = require "md-render.image"
image.supports_kitty = function()
  return false
end
size.supports = function()
  return true
end
vim.o.termguicolors = true
local passed, failed = 0, 0
local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name .. ": " .. tostring(err))
  end
end
local function build(source, opts)
  local original = vim.deepcopy(source)
  local b = Builder.new()
  b:render_document(source, vim.tbl_extend("force", { max_width = 60, indent = "", text_scale = false }, opts or {}))
  eq(source, original, "source array is unchanged")
  local content = b:result()
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "setext_headings_test"
  local ok, err = pcall(function()
    display.apply_content_to_buffer(buf, ns, content)
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), content.lines, "actual buffer text")
    for row, source_row in ipairs(content.source_line_map) do
      assert(source_row >= 1 and source_row <= #source and content.lines[row], "original source-row correspondence")
    end
    for _, entry in ipairs(content.highlights) do
      for _, span in ipairs(entry.groups) do
        local last = span.end_col == -1 and #content.lines[entry.line + 1] or span.end_col
        assert(span.col >= 0 and span.col <= last and last <= #content.lines[entry.line + 1], "highlight byte bounds")
      end
    end
    for _, link in ipairs(content.link_metadata) do
      assert(link.col_start < link.col_end, "nonempty link")
      eq(Links.at(buf, ns, link.line, link.col_start), link.url, "first link byte")
      eq(Links.at(buf, ns, link.line, link.col_end - 1), link.url, "last link byte")
      eq(Links.at(buf, ns, link.line, link.col_end), nil, "byte after link")
    end
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, err)
  return content
end
local function headings(content)
  local rows, result = vim.tbl_keys(content.heading_lines), {}
  table.sort(rows)
  for _, row in ipairs(rows) do
    result[#result + 1] = { content.lines[row + 1], content.source_line_map[row + 1] }
  end
  return result
end
local function spans(content, group)
  local result = {}
  for _, entry in ipairs(content.highlights) do
    for _, span in ipairs(entry.groups) do
      if span.hl == group then
        result[#result + 1] =
          { entry.line, span.col, span.end_col, content.lines[entry.line + 1]:sub(span.col + 1, span.end_col) }
      end
    end
  end
  return result
end

test("CM84/GFM54: heading and underline indentation may differ", function()
  local content = build { "   Foo", "---", "", "  Foo", "-----", "", "  Foo", "  ===" }
  eq(headings(content), { { "## Foo", 1 }, { "## Foo", 4 }, { "# Foo", 7 } }, "three headings")
  eq(#spans(content, "MdRenderH2"), 2, "two H2 ranks")
  eq(#spans(content, "MdRenderH1"), 1, "one H1 rank")
  for i, slug in ipairs { "foo", "foo-1", "foo-2" } do
    eq(content.source_line_map[content.heading_anchors[slug] + 1], (i - 1) * 3 + 1, "duplicate anchor source")
  end
  for _, row in ipairs(content.source_line_map) do
    assert(row ~= 2 and row ~= 5 and row ~= 8, "underlines are consumed")
  end
end)
test("CM86/GFM56: zero through three columns and trailing spaces/tabs", function()
  for level, marker in ipairs { "=", "-" } do
    for indent = 0, 3 do
      local content = build { "Foo", string.rep(" ", indent) .. string.rep(marker, 4) .. " \t  " }
      eq(headings(content), { { string.rep("#", level) .. " Foo", 1 } }, "accepted underline")
      eq(#spans(content, "MdRenderH" .. level), 1, "underline rank")
      eq(content.heading_anchors.foo, 0, "heading anchor")
    end
  end
end)
test("CM87/GFM57 and CM88/GFM58: invalid underlines retain paragraph/HR ownership", function()
  for _, underline in ipairs { "    ---", "\t===", "= =", "=\t=", "=-=", "===\v" } do
    local content = build { "Foo", underline }
    eq(headings(content), {}, "invalid underline makes no heading")
    eq(content.heading_anchors, {}, "invalid underline makes no anchor")
  end
  eq(build({ "Foo", "    ---" }).lines, { "Foo ---" }, "four-column underline continues paragraph")
  eq(build({ "Foo", "= =" }).lines, { "Foo = =" }, "internal equals spaces remain literal")
  local hr = build { "Foo", "--- -" }
  eq(hr.lines, { "Foo", "", string.rep("─", 60) }, "internal dashes form a thematic break")
  eq(hr.source_line_map, { 1, 2, 2 }, "thematic break uses its physical row")
end)
test("CM85/GFM55 and CM100/GFM70: code is never a heading candidate", function()
  local content = build { "    foo", "---" }
  eq(content.lines, { "foo", "", string.rep("─", 60) }, "code followed by thematic break")
  eq(content.source_line_map, { 1, 2, 2 }, "literal code and HR source rows")
  eq(headings(content), {}, "code has no heading metadata")
  eq(content.heading_anchors, {}, "code has no anchor")
  content = build { "    Foo", "    ---", "", "    Foo", "---" }
  eq(headings(content), {}, "CM85 code remains literal")
  assert(table.concat(content.lines, "\n"):find("Foo\n---", 1, true), "code underline stays literal")
  for _, source in ipairs {
    { "```", "Foo", "===", "```" },
    { ">     Foo", "> ===" },
    { "# Foo", "===" },
    { "---", "---" },
    { "- Foo", "---" },
    { "> Foo", "---" },
    { "Foo", "> ===" },
    { "<!-- Foo -->", "===" },
  } do
    eq(vim.tbl_count(build(source).heading_lines), source[1] == "# Foo" and 1 or 0, "existing block/container control")
  end
end)
test("paragraph eligibility accepts ordinary punctuation and numbers", function()
  for _, title in ipairs { "123 Foo", "#not-atx", "*not-list", "|pipe", "Foo #", "Foo ###", "\\> Foo", "===" } do
    local content = build { title, "===" }
    local expected = title == "\\> Foo" and "> Foo" or title
    eq(headings(content), { { "# " .. expected, 1 } }, "paragraph candidate " .. title)
  end
  eq(headings(build { "===" }), {}, "isolated equals has no heading")
  eq(build({ "===", "ordinary" }).lines, { "=== ordinary" }, "isolated equals can begin a paragraph")
  eq(headings(build { "---" }), {}, "isolated hyphens are a thematic break")
end)
test("CM95/GFM65: multiline title and hard breaks use paragraph source rows", function()
  local content = build { "Foo *bar", "baz*", "   ---", "tail" }
  eq(headings(content), { { "## Foo bar baz", 1 } }, "multiline heading")
  eq(spans(content, "Italic"), { { 0, #"## Foo ", #"## Foo bar baz", "bar baz" } }, "multiline inline range")
  eq(content.source_line_map[#content.lines], 4, "paragraph after heading keeps physical row")
  content = build { "*甲乙  ", "丙丁*", "===" }
  eq(headings(content), { { "# 甲乙", 1 }, { "丙丁", 2 } }, "hard-break heading rows")
  local atx = Builder.new()
  atx.text_scale = false
  atx:set_source_line(1)
  atx:add_markdown_line("# *甲乙  \n丙丁*", "", 60, nil, nil, nil, nil, { 1, 2 })
  eq(atx:result().lines, content.lines, "ATX sibling shifts the same hard-break bytes")
  eq(atx:result().source_line_map, content.source_line_map, "ATX sibling source rows")
  content = build { "> *甲乙  ", "> 丙丁*", "> ===" }
  eq(headings(content), { { "│ # 甲乙", 1 }, { "│ 丙丁", 2 } }, "quoted heading hard-break rows")
  atx = Builder.new()
  atx.text_scale = false
  atx:set_source_line(1)
  atx:add_markdown_line("> # *甲乙  \n丙丁*", "", 60, nil, nil, nil, nil, { 1, 2 })
  eq(atx:result().lines, content.lines, "quoted ATX sibling subtracts the same quote-prefix bytes")
  eq(atx:result().source_line_map, content.source_line_map, "quoted ATX sibling source rows")
end)
test("explicit quotes keep heading rank, containers and consumed underline rows", function()
  for _, case in ipairs {
    { { "> Foo", "> ===" }, "│ # Foo", 1 },
    { { "> > Foo", "> >   ---" }, "│ │ ## Foo", 2 },
    { { "- item", "", "  > Foo", "  > ===" }, "  │ # Foo", 1 },
  } do
    local content = build(case[1])
    eq(headings(content), { { case[2], #case[1] - 1 } }, "explicit quote heading")
    eq(#spans(content, "MdRenderH" .. case[3]), 1, "quoted heading rank")
    eq(content.source_line_map[content.heading_anchors.foo + 1], #case[1] - 1, "quoted heading anchor source")
  end
  local content = build { "> Foo", "> ===", "outside" }
  eq(headings(content), { { "│ # Foo", 1 } }, "explicit underline closes the quote paragraph")
  eq(content.lines[#content.lines], "outside", "new paragraph cannot lazily continue a finished heading")
  eq(content.source_line_map[#content.lines], 3, "outside paragraph source row")
end)

local rich = "**粗體** [連結](https://example.invalid/a?x=1&amp;y=2) #"
test("Setext title keeps exact Unicode inline ranges and literal closing hashes", function()
  local content = build { rich, "===" }
  eq(headings(content), { { "# 粗體 連結 #", 1 } }, "raw Setext title")
  eq(spans(content, "Bold"), { { 0, 2, #"# 粗體", "粗體" } }, "exact bold range")
  eq(content.link_metadata, {
    { line = 0, col_start = #"# 粗體 ", col_end = #"# 粗體 連結", url = "https://example.invalid/a?x=1&y=2" },
  }, "exact link byte range")
  eq(content.heading_anchors["粗體-連結"], 0, "raw title anchor")
  local inline = { markdown.render("Foo #", nil, nil, nil, nil, true, { heading_level = 1 }) }
  eq(inline[1], "Foo #", "inline-only context retains markers")
  eq(inline[4], nil, "inline-only context has no heading")
end)
test("native Setext policy matches existing ATX layout", function()
  size.setup { backend = "native" }
  local content = build({ rich, "===" }, { text_scale = true })
  local atx = build({ "# **粗體** [連結](https://example.invalid/a?x=1&amp;y=2) \\#" }, { text_scale = true })
  eq(content.lines, atx.lines, "same native layout")
  eq(content.text_placements, atx.text_placements, "same native paint/link runs")
  eq(content.link_metadata, atx.link_metadata, "same native link coordinates")
  eq(content.heading_backend, "native", "native backend selected")
end)
test("image Setext policy receives raw title and shares ATX geometry", function()
  local layout = require "md-render.heading_layout"
  local request = layout.request
  local requests = {}
  image.png_status = function()
    return { supported = true }
  end
  image.get_cell_size = function()
    return { cell_w = 10, cell_h = 20 }
  end
  layout.request = function(input)
    local entry = input.entries[1]
    requests[#requests + 1] = entry.text
    local columns, byte = {}, 0
    for _, char in ipairs(vim.fn.split(entry.text, "\\zs")) do
      for _ = 1, vim.fn.strdisplaywidth(char) do
        columns[#columns + 1] = byte
      end
      byte = byte + #char
    end
    return {
      key = entry.text,
      output = {
        lines = {
          {
            text = entry.text,
            start = 0,
            ["end"] = #entry.text,
            cols = #columns,
            columns = columns,
            transparent = true,
            data = "png",
          },
        },
      },
    }
  end
  local ok, err = pcall(function()
    size.setup { backend = "image" }
    for _, tmux in ipairs { false, true } do
      vim.env.TMUX = tmux and "/tmp/setext-test,1,0" or nil
      local content = build({ rich, "===" }, { text_scale = true })
      local atx = build({ "# **粗體** [連結](https://example.invalid/a?x=1&amp;y=2) \\#" }, { text_scale = true })
      eq(content.heading_backend, "image", "image backend selected")
      eq(content.lines, atx.lines, "same image layout")
      eq(content.text_placements, atx.text_placements, "same image geometry and paint bytes")
      eq(content.link_metadata, atx.link_metadata, "same image link coordinates")
      eq(requests[#requests], "粗體 連結 #", "raw title preserves closing hash")
    end
  end)
  layout.request, vim.env.TMUX = request, nil
  assert(ok, err)
end)
test("scaled hard-break headings use the existing document fallback and keep activation", function()
  local preview = require "md-render.preview"
  local source =
    { "> *甲乙  ", "> 丙丁* [連結](https://example.invalid)", "> ===", "", "[jump](#甲乙-丙丁-連結)" }
  for _, backend in ipairs { "native", "image" } do
    size.setup { backend = backend }
    for _, input in ipairs { source, { "*甲乙  ", "丙丁* [連結](https://example.invalid)", "===" } } do
      local b = Builder.new()
      b:render_document(input, { max_width = 60, indent = "", text_scale = true })
      eq(b.native_heading_fallback, "heading contains hard line breaks", "existing document fallback reason")
      eq(b:result().lines, build(input).lines, "scaled fallback keeps physical hard-break rows")
      eq(b:result().source_line_map, build(input).source_line_map, "scaled fallback source rows")
    end
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].filetype = "markdown"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
    vim.api.nvim_set_current_buf(buf)
    vim.cmd "vsplit"
    local win = vim.api.nvim_get_current_win()
    local mouse, supports, open = display.getmousepos, display.supports_osc8, vim.ui.open
    local ok, err = pcall(function()
      preview.toggle { text_scale = true }
      local session = assert(preview._toggle_sessions[buf])
      display.supports_osc8 = function()
        return false
      end
      for step = 1, 2 do
        if step == 2 then
          vim.api.nvim_win_set_width(win, 24)
          session:resize(win)
          session:rebuild()
          eq(session.opts.max_width, 24, "fallback uses the actual narrow window budget")
        end
        local content, opened = session.content, {}
        eq(content.heading_fallback, "heading contains hard line breaks", "public document fallback")
        eq(content.text_placements, {}, "no scaled rows flatten mandatory breaks")
        eq(vim.api.nvim_buf_get_lines(session.buf, 0, -1, false), content.lines, "fallback public buffer")
        local row = assert(content.heading_anchors["甲乙-丙丁-連結"])
        eq(content.source_line_map[row + 1], 1, "fallback anchor retains title start")
        vim.ui.open = function(url)
          opened[#opened + 1] = url
        end
        for _, link in ipairs(content.link_metadata) do
          display.getmousepos = function()
            return { winid = vim.api.nvim_get_current_win(), line = link.line + 1, column = link.col_start + 1 }
          end
          vim.fn.maparg("<LeftRelease>", "n", false, true).callback()
          if link.url:sub(1, 1) == "#" then
            eq(vim.api.nvim_win_get_cursor(0)[1], row + 1, "fallback anchor activation")
          end
        end
        eq(opened, { "https://example.invalid" }, "fallback external activation")
      end
    end)
    display.getmousepos, display.supports_osc8, vim.ui.open = mouse, supports, open
    if preview._toggle_sessions[buf] then preview.toggle() end
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), source, "scaled fallback keeps source unchanged")
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
    assert(ok, err)
  end
end)
test("public preview/rebuild keeps Setext anchors and activation at narrow widths", function()
  local preview = require "md-render.preview"
  local source = {
    rich .. " extended heading title",
    "  ===",
    "",
    "[jump](#粗體-連結-extended-heading-title)",
    "",
    "> quoted",
    "> ---",
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
  vim.api.nvim_set_current_buf(buf)
  vim.cmd "vsplit"
  local win = vim.api.nvim_get_current_win()
  local mouse, supports, open = display.getmousepos, display.supports_osc8, vim.ui.open
  local ok, err = pcall(function()
    preview.toggle { text_scale = false }
    local session = assert(preview._toggle_sessions[buf])
    display.supports_osc8 = function()
      return false
    end
    for _, width in ipairs { 60, 22 } do
      vim.api.nvim_win_set_width(win, width)
      session:resize(win)
      session:rebuild()
      local content, opened = session.content, {}
      eq(vim.api.nvim_win_get_width(win), width, "requested preview window width")
      eq(session.opts.max_width, width, "renderer uses actual preview width")
      if width == 22 then assert(#headings(content) > 2, "narrow preview reflows the long heading") end
      eq(vim.api.nvim_buf_get_lines(session.buf, 0, -1, false), content.lines, "public preview buffer")
      local click = vim.fn.maparg("<LeftRelease>", "n", false, true).callback
      vim.ui.open = function(url)
        opened[#opened + 1] = url
      end
      for _, link in ipairs(content.link_metadata) do
        display.getmousepos = function()
          return { winid = vim.api.nvim_get_current_win(), line = link.line + 1, column = link.col_start + 1 }
        end
        click()
        if link.url:sub(1, 1) == "#" then
          eq(
            vim.api.nvim_win_get_cursor(0)[1],
            content.heading_anchors[link.url:sub(2)] + 1,
            "Setext anchor activation"
          )
        end
      end
      eq(opened, { "https://example.invalid/a?x=1&y=2" }, "external activation target")
      assert(content.heading_anchors.quoted, "explicit quoted Setext remains a heading")
    end
  end)
  display.getmousepos, display.supports_osc8, vim.ui.open = mouse, supports, open
  if preview._toggle_sessions[buf] then preview.toggle() end
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), source, "source buffer is unchanged")
  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, err)
end)

print(string.format("setext_headings_test: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
