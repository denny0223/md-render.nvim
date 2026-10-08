-- Rendered text must fit the window, including its display indent.
-- Run: nvim --headless -u NONE --noplugin -l tests/wrap_width_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local preview = require "md-render.preview"
local heading_prefix = "## "
local text = string.rep("甲乙丙丁", 12)
local cases = {
  { name = "paragraph", source = { text }, line = 1, prefix = "", continuation = "" },
  { name = "list", source = { "- " .. text }, line = 1, prefix = "• ", continuation = "  " },
  { name = "quote", source = { "> " .. text }, line = 1, prefix = "│ ", continuation = "│ " },
  {
    name = "heading",
    source = { "## " .. text },
    line = 1,
    prefix = heading_prefix,
    continuation = "",
    heading = true,
  },
  {
    name = "callout",
    source = { "> [!NOTE]", "> " .. text },
    line = 2,
    prefix = "│ ",
    continuation = "│ ",
  },
  {
    name = "Qiita note",
    source = { ":::note info", text, ":::" },
    line = 2,
    prefix = "│ ",
    continuation = "│ ",
  },
  {
    name = "list continuation",
    source = { "1. 項目", "", "   " .. text },
    line = 3,
    prefix = "   ",
    continuation = "   ",
  },
  {
    name = "quote in list",
    source = { "1. 項目", "", "   > " .. text },
    line = 3,
    prefix = "   │ ",
    continuation = "   │ ",
  },
  {
    name = "heading in list",
    heading = true,
    source = { "1. 項目", "", "   ## " .. text },
    line = 3,
    prefix = "   " .. heading_prefix,
    continuation = "   ",
  },
  {
    name = "definition",
    source = { "<dl>", "<dt>項目</dt>", "<dd>" .. text .. "</dd>", "</dl>" },
    line = 3,
    prefix = "  ",
    continuation = "  ",
  },
}
for level = 1, 2 do
  cases[#cases + 1] = {
    name = "H" .. level .. " in details",
    heading = true,
    source = {
      "<details open>",
      "<summary>Details</summary>",
      "",
      string.rep("#", level) .. " " .. text,
      "",
      "</details>",
    },
    line = 4,
    prefix = "│ " .. string.rep("#", level) .. " ",
    continuation = "│ ",
  }
end

local checked = 0
for _, case in ipairs(cases) do
  for _, width in ipairs { 20, 21, 40, 41, 80 } do
    -- nil exercises the real two-space default; empty indent covers split mode.
    for _, opts in ipairs { {}, { indent = "" }, { indent = "    " } } do
      opts.max_width, opts.text_scale = width, false
      local indent = opts.indent or "  "
      local out = preview.build_content(case.source, opts)
      local chunks = {}
      for i, line in ipairs(out.lines) do
        assert(vim.api.nvim_strwidth(line) <= width, case.name .. " overflows " .. width .. ": " .. line)
        -- H1/H2 separators share the source line but are not document text.
        if
          out.source_line_map[i] == case.line
          and not line:match "^%s*$"
          and (not case.heading or out.heading_lines[i - 1])
        then
          local prefix = indent .. (#chunks == 0 and case.prefix or case.continuation)
          assert(line:sub(1, #prefix) == prefix, case.name .. " lost its indent")
          chunks[#chunks + 1] = line:sub(#prefix + 1)
        end
      end
      assert(table.concat(chunks) == text, case.name .. " lost or duplicated text")
      -- The first line must use all available CJK cells: this catches taking
      -- a list container's indent off the budget twice.
      local room = width - vim.api.nvim_strwidth(indent .. case.prefix)
      assert(vim.api.nvim_strwidth(chunks[1]) == math.floor(room / 2) * 2, case.name .. " wraps too early")
      checked = checked + 1
    end
  end
end

-- Rules must occupy one screen row, including indents and details bars.
do
  local display = require "md-render.display_utils"
  local icons = require "md-render.icons"
  local saved_icon_style = icons.config().style
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 40,
    height = 10,
    style = "minimal",
  })
  vim.wo[win].wrap = true
  local ns = vim.api.nvim_create_namespace "rule-width-test"
  local function check_fits(content, width)
    vim.bo[buf].modifiable = true
    display.apply_content_to_buffer(buf, ns, content)
    for row, line in ipairs(content.lines) do
      assert(vim.fn.strdisplaywidth(line) <= width, "display row overflows: " .. line)
      local height = vim.api.nvim_win_text_height(win, { start_row = row - 1, end_row = row - 1 }).all
      assert(height == 1, "a fitted buffer row must occupy one screen row: " .. line)
    end
  end
  local saved_ambiwidth = vim.o.ambiwidth
  for _, ambiwidth in ipairs { "single", "double" } do
    vim.o.ambiwidth = ambiwidth
    for _, width in ipairs { 20, 21, 40, 41, 80 } do
      vim.api.nvim_win_set_config(win, { width = width })
      for _, opts in ipairs { {}, { indent = "" }, { indent = "    " } } do
        opts.max_width, opts.text_scale = width, false
        for _, source in ipairs {
          { "---" },
          { "***" },
          { "___" },
          { "<hr>" },
          { "- item", "", "  ---" },
          { "<details open>", "<summary>Title</summary>", "", "---", "", "</details>" },
          { "<details open>", "<summary>Title</summary>", "<hr>", "</details>" },
          { "body[^1]", "", "[^1]: note" },
        } do
          local content = preview.build_content(source, opts)
          check_fits(content, width)
          local rules = 0
          for _, line in ipairs(content.lines) do
            if line:find("─", 1, true) then
              rules = rules + 1
              local cells = vim.fn.strdisplaywidth(line)
              assert(
                cells <= width and cells > width - vim.fn.strdisplaywidth "─",
                "rule must fill the available width"
              )
            end
          end
          assert(rules == 1, "each rule source must produce exactly one rule")
        end
        local code = string.rep("x", 100)
        for _, source in ipairs {
          { "<details>", "<summary>" .. text .. "</summary>", "body", "</details>" },
          { "```lua", string.rep("a\t", 6) .. "tail", "```" },
          { "> ```lua", "> " .. string.rep("a\t", 6) .. "tail", "> ```" },
          { "<details open>", "<summary>Code</summary>", "", "```lua", code, "```", "", "</details>" },
          { "<details open>", "<summary>Code</summary>", "", "    " .. code, "", "</details>" },
          { "<details open>", "<summary>Tabs</summary>", "", "```lua", "aaaa\tb\tc", "```", "", "</details>" },
          { "<details open>", "<summary>Tabs</summary>", "", "    aaaa\tb\tc", "", "</details>" },
          { "<details open>", "<summary>Tabs</summary>", "", "> ```lua", "> aa\tb\tc", "> ```", "", "</details>" },
          { "<details open>", "<summary>Tabs</summary>", "", "`aaaa\tb\tc`", "", "</details>", "", "`aaaa\tb\tc`" },
          { "<details open>", "<summary>Tabs</summary>", "<h1>aa\tb\tc</h1>", "</details>" },
          {
            "<details open>",
            "<summary>Tabs</summary>",
            "<dl>",
            "<dt>aaaa\tb\tc</dt>",
            "<dd>aa\tb\tc</dd>",
            "</dl>",
            "</details>",
          },
          {
            "<details open>",
            "<summary>Tabs</summary>",
            "<figure>",
            "<figcaption>aaaa\tb\tc</figcaption>",
            "</figure>",
            "</details>",
          },
          {
            "<details open>",
            "<summary>Tabs</summary>",
            "",
            "![aaaa\tb\tc](/tmp/width-test-missing.png)",
            "",
            "</details>",
          },
          { "<details open>", "<summary>Tabs</summary>", "<!-- comment -->aaaa\tb\tc", "</details>" },
          { "`a\t" .. string.rep("x", width - 4) .. "`" },
          { "<dl>", "<dt>" .. text .. "</dt>", "<dd>body</dd>", "</dl>" },
          { "<details open>", "<summary>Heading</summary>", "<h1>" .. text .. "</h1>", "</details>" },
          {
            "<details open>",
            "<summary>Image</summary>",
            "",
            "![" .. text .. "](/tmp/width-test-missing.png)",
            "",
            "</details>",
          },
          {
            "<details open>",
            "<summary>Terms</summary>",
            "<dl>",
            "<dt>" .. text .. "</dt>",
            "<dd>" .. text .. "</dd>",
            "</dl>",
            "</details>",
          },
        } do
          local original = vim.deepcopy(source)
          local content = preview.build_content(source, opts)
          check_fits(content, width)
          assert(vim.deep_equal(source, original), "fitting must preserve source bytes")
        end
        for _, style in ipairs { "nerd", "unicode" } do
          icons.setup { style = style }
          for _, collapsed in ipairs { true, false } do
            local source = { "> [!NOTE]" .. (collapsed and "- " or "+ ") .. text, "> body" }
            local original = vim.deepcopy(source)
            local content = preview.build_content(source, opts)
            check_fits(content, width)
            local fold = assert(content.callout_folds[1], "foldable callout lost its fold")
            assert(fold.collapsed == collapsed, "width fitting changed the fold state")
            local indicator = " " .. icons.pad_icon(icons.get_fold_icon(collapsed))
            assert(
              content.lines[fold.header_line + 1]:sub(-#indicator) == indicator,
              "fold rendering must follow the active icon profile"
            )
            assert(vim.deep_equal(source, original), "icon selection must preserve source bytes")
          end
        end
        icons.setup { style = saved_icon_style }
      end
    end
  end
  vim.o.ambiwidth = saved_ambiwidth
  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(buf, { force = true })
end

-- A rebuild may run from a different buffer with different tab settings.
do
  local source = vim.api.nvim_create_buf(false, true)
  local payload = string.rep("a\t", 6) .. "tail"
  vim.bo[source].filetype, vim.bo[source].tabstop = "markdown", 4
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "```lua", payload, "```" })
  local previous = vim.api.nvim_get_current_win()
  local background = vim.api.nvim_get_current_buf()
  local saved_tabstop = vim.bo[background].tabstop
  vim.bo[background].tabstop = 4
  local win = vim.api.nvim_open_win(source, true, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 40,
    height = 10,
    style = "minimal",
  })
  preview.toggle { max_width = 40, text_scale = false }
  local session = assert(preview._toggle_sessions[source])
  vim.bo[session.buf].tabstop = 8
  vim.api.nvim_set_current_win(previous)
  session:rebuild(true)
  for row in ipairs(session.content.lines) do
    assert(
      vim.api.nvim_win_text_height(win, { start_row = row - 1, end_row = row - 1 }).all == 1,
      "rebuild used another buffer's tab width"
    )
  end
  assert(session.content.code_blocks[1].source_lines[1] == payload, "tab measurement must preserve the literal source")
  vim.api.nvim_set_current_win(win)
  preview.toggle()
  vim.api.nvim_win_close(win, true)
  vim.api.nvim_buf_delete(source, { force = true })
  vim.bo[background].tabstop = saved_tabstop
end

-- Truncation retains tabs and complete native glyphs, plus a valid byte endpoint.
local native_wrap = require "md-render.wrap"
for _, glyph in ipairs { "é", "👩‍💻", "👍🏽", "🇹🇼" } do
  local value = glyph .. glyph .. "tail"
  local clipped, byte_end = native_wrap.truncate(value, vim.fn.strdisplaywidth(glyph) + 1)
  assert(clipped == glyph .. "…" and byte_end == #glyph, "truncation split a complete glyph")
end
local clipped, byte_end = native_wrap.truncate("a\tbc", 9)
assert(clipped == "a\t…" and byte_end == 2, "truncation must measure tabs at their actual column")
clipped, byte_end = native_wrap.truncate("  aaaa\tb\tc", 18, nil, 2)
assert(clipped == "  aaaa\tb…" and byte_end == 8, "truncation must include the separately rendered details bar")

-- Formatting and link byte offsets must follow the newly wrapped lines.
local label = string.rep("中文", 20)
local out = preview.build_content({ "前綴 **" .. label .. "** [" .. label .. "](https://example.com)" }, {
  max_width = 20,
  text_scale = false,
})
local bold, links = {}, {}
for _, line in ipairs(out.lines) do
  assert(vim.api.nvim_strwidth(line) <= 20, "formatted text overflows")
end
for _, entry in ipairs(out.highlights) do
  for _, group in ipairs(entry.groups) do
    if group.hl == "Bold" then bold[#bold + 1] = out.lines[entry.line + 1]:sub(group.col + 1, group.end_col) end
  end
end
for _, link in ipairs(out.link_metadata) do
  assert(link.url == "https://example.com", "link target changed")
  links[#links + 1] = out.lines[link.line + 1]:sub(link.col_start + 1, link.col_end)
end
assert(table.concat(bold) == label, "bold spans lost text after wrapping")
assert(table.concat(links) == label, "link spans lost text after wrapping")

-- Input order controls overlapping styles and links; wrapping must not sort it.
do
  local Builder = require("md-render.content_builder").ContentBuilder
  local b = Builder.new()
  b:add_line "lead"
  b:set_source_line(7)
  local quote, marker = "│ ", "• "
  local offset = #quote + #marker
  b:add_wrapped_markdown(
    quote .. marker .. "中文 AB\n\n乙丙 CD",
    {
      { col = offset + 18, end_col = offset + 20, hl = "Last" },
      { col = offset - 2, end_col = offset + 17, hl = "Cross" },
      { col = #quote, end_col = offset, hl = "Special" },
      { col = 0, end_col = #quote, hl = "FloatBorder" },
      { col = offset, end_col = offset + 20, hl = "Bold" },
      { col = offset + 6, end_col = offset + 7, hl = "Gap" },
      { col = offset + 9, end_col = offset + 11, hl = "Breaks" },
      { col = offset + 11, end_col = offset + 17, hl = "Inner" },
    },
    {
      { col_start = offset + 18, col_end = offset + 20, url = "/last" },
      { col_start = offset - 1, col_end = offset + 20, url = "/all" },
      { col_start = offset, col_end = offset + 6, url = "/first" },
      { col_start = offset + 6, col_end = offset + 7, url = "/gap" },
      { col_start = offset + 9, col_end = offset + 11, url = "/break" },
      { col_start = offset + 11, col_end = offset + 17, url = "/utf8" },
      { col_start = 0, col_end = offset, url = "/marker" },
    },
    "  ",
    10,
    quote,
    marker,
    1,
    {
      { col = offset + 9, source_line = 1 },
      { col = offset + 10, source_line = 2 },
    }
  )
  local content = b:result()
  assert(
    vim.deep_equal(content.lines, {
      "lead",
      "  │ • 中文",
      "",
      "  │   AB",
      "",
      "  │   ",
      "",
      "  │   乙丙",
      "",
      "  │   CD",
      "",
    }),
    "quote/list wrapping preserves empty rows and hard breaks"
  )
  local styles, metadata = {}, {}
  for _, entry in ipairs(content.highlights) do
    for _, group in ipairs(entry.groups) do
      styles[#styles + 1] = { entry.line, group.col, group.end_col, group.hl }
    end
  end
  assert(
    vim.deep_equal(styles, {
      { 1, 10, 16, "Cross" },
      { 1, 6, 10, "Special" },
      { 1, 2, 6, "FloatBorder" },
      { 1, 10, 16, "Bold" },
      { 3, 2, 6, "FloatBorder" },
      { 3, 8, 10, "Cross" },
      { 3, 8, 10, "Bold" },
      { 5, 2, 6, "FloatBorder" },
      { 7, 2, 6, "FloatBorder" },
      { 7, 8, 14, "Cross" },
      { 7, 8, 14, "Bold" },
      { 7, 8, 14, "Inner" },
      { 9, 2, 6, "FloatBorder" },
      { 9, 8, 10, "Last" },
      { 9, 8, 10, "Bold" },
    }),
    "style order and UTF-8 byte offsets survive prefix changes"
  )
  for _, link in ipairs(content.link_metadata) do
    metadata[#metadata + 1] = { link.line, link.col_start, link.col_end, link.url }
  end
  assert(
    vim.deep_equal(metadata, {
      { 1, 10, 16, "/all" },
      { 1, 10, 16, "/first" },
      { 3, 8, 10, "/all" },
      { 7, 8, 14, "/all" },
      { 7, 8, 14, "/utf8" },
      { 9, 8, 10, "/last" },
      { 9, 8, 10, "/all" },
    }),
    "links retain row order and input order within each row"
  )
end

-- Short raw HTML rows must not scan every highlight/link for every row.
jit.off()
jit.flush()
for _, case in ipairs { { 1500, "<h1>", "<h1>", 30000000 }, { 4000, '<a href="CaseSensitive">甲</a>', "甲", 60000000 } } do
  local source = { "<div>" }
  for _ = 1, case[1] do
    source[#source + 1] = case[2]
  end
  source[#source + 1] = "</div>"
  local instructions = 0
  debug.sethook(function()
    instructions = instructions + 1000
    assert(instructions < case[4], "raw rows exceeded the bounded distribution work budget")
  end, "", 1000)
  local ok, content = pcall(preview.build_content, source, { max_width = 120, indent = "", text_scale = false })
  debug.sethook()
  assert(ok, content)
  assert(#content.lines == case[1] and #content.highlights == case[1], "large raw group retains every styled row")
  for row, line in ipairs(content.lines) do
    assert(line == case[3] and content.source_line_map[row] == row + 1, "raw rows retain physical source positions")
  end
  if case[3] == "甲" then
    assert(#content.link_metadata == case[1], "large raw group retains every link")
    for row, link in ipairs(content.link_metadata) do
      assert(
        link.line == row - 1 and link.col_start == 0 and link.col_end == #case[3] and link.url == "CaseSensitive",
        "raw links retain ordered UTF-8 byte ranges and literal destinations"
      )
    end
  end
end

-- Wrapping receives rendered text: whitespace is content, and each emitted
-- row must be an exact source slice for highlight/link byte offsets to work.
local wrap = require "md-render.wrap"
for _, case in ipairs {
  { "alpha foo   bar omega tail", 18, { "alpha foo   bar", "omega tail" } },
  { "alpha foo   bar omega tail", 14, { "alpha foo", "bar omega tail" } },
  { "alpha 中   文 omega tail", 14, { "alpha 中   文", "omega tail" } },
  { "  foo   bar  ", 20, { "  foo   bar  " } },
  { "foo\tbar tail", 20, { "foo\tbar tail" } },
  { "   ", 10, { "   " } },
  { "", 10, {} },
} do
  local lines, starts = wrap.wrap_words(case[1], case[2])
  assert(vim.deep_equal(lines, case[3]), "rendered whitespace changed: " .. vim.inspect { case[1], lines })
  for i, line in ipairs(lines) do
    assert(line == case[1]:sub(starts[i] + 1, starts[i] + #line), "wrapped row is not its indexed source slice")
  end
end

for _, glyph in ipairs { "é", "👩‍💻", "👍🏽", "🇹🇼" } do
  local glyph_text = glyph .. " " .. glyph
  local lines, starts = wrap.wrap_words(glyph_text, vim.fn.strdisplaywidth(glyph))
  assert(vim.deep_equal(lines, { glyph, glyph }), "wrapping must retain complete combining and emoji sequences")
  assert(vim.deep_equal(starts, { 0, #glyph + 1 }), "glyph wrapping retains source byte offsets")
end

-- Every details exit must restore the surrounding document's width and tab origin.
for _, before in ipairs {
  { "<details open>", "<summary>S</summary>", "body", "</details>" },
  { "<details open>", "<summary>S</summary>", "body</details>tail" },
  { "<details open><summary>S</summary>body</details>tail" },
  { "<details open>", "<summary>S</summary>", "<details>", "inner", "</details>", "tail", "</details>" },
  { "<details open>", "<summary>S</summary>", "", "<div>", "<details", ">", "raw", "</details>", "</div>" },
} do
  for _, payload in ipairs { "aaaa\tb\tc", string.rep("x", 18) } do
    local source = vim.list_extend(vim.deepcopy(before), { "", "```lua", payload, "```" })
    local original = vim.deepcopy(source)
    local content = preview.build_content(source, { max_width = 20, text_scale = false })
    local block = assert(content.code_blocks[1], "details exit lost the following code block")
    local line = content.lines[block.start_line + 1]
    local control = preview.build_content({ "```lua", payload, "```" }, { max_width = 20, text_scale = false })
    assert(line == "  " .. payload and line == control.lines[1], "details exit changed the following code payload")
    assert(vim.fn.strdisplaywidth(line) <= 20, "following code must fit its actual display origin")
    assert(#content.expandable_regions == 0, "a details exit must not create a spurious code expansion")
    assert(content.source_line_map[block.start_line + 1] == #before + 3, "following code lost its source row")
    assert(vim.deep_equal(source, original), "details width restoration changed source bytes")
  end
end

-- Exercise the public buffer mappings, not a synthetic fold/expand callback.
do
  local display = require "md-render.display_utils"
  local function with_session(source_lines, check)
    local previous = vim.api.nvim_get_current_win()
    local source = vim.api.nvim_create_buf(false, true)
    vim.bo[source].filetype = "markdown"
    vim.api.nvim_buf_set_lines(source, 0, -1, false, source_lines)
    local tick = vim.api.nvim_buf_get_changedtick(source)
    local win = vim.api.nvim_open_win(source, true, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 20,
      height = 12,
      style = "minimal",
    })
    preview.toggle { max_width = 20, text_scale = false }
    local session = assert(preview._toggle_sessions[source])
    local ok, err = pcall(check, session, source, win)
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(source, 0, -1, false), source_lines),
      "interaction changed source bytes"
    )
    assert(vim.api.nvim_buf_get_changedtick(source) == tick, "interaction changed source changedtick")
    session:dispose()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    vim.api.nvim_set_current_win(previous)
    vim.api.nvim_buf_delete(source, { force = true })
    assert(ok, err)
  end
  local function mapped(key)
    vim.fn.maparg(key, "n", false, true).callback()
  end
  local mouse, osc8, open = display.getmousepos, display.supports_osc8, vim.ui.open
  local function click(win, row, col)
    display.getmousepos = function()
      return { winid = win, line = row, column = (col or 0) + 1 }, false
    end
    mapped "<LeftRelease>"
  end

  with_session(
    { "<details>", "<summary>" .. text .. "</summary>", "body", "</details>" },
    function(session, source, win)
      assert(#session.content.lines > 2, "summary fixture must occupy multiple logical rows")
      for row in ipairs(session.content.lines) do
        assert(session.content.source_line_map[row] == 2, "wrapped summary lost its physical source row")
      end
      vim.api.nvim_win_set_cursor(win, { 2, 0 })
      mapped "<CR>"
      assert(not session.content.callout_folds[1].collapsed, "Enter on a summary continuation must open the fold")
      local body = #session.content.lines
      click(win, body)
      assert(not session.content.callout_folds[1].collapsed, "body text must not act as a summary header")
      click(win, 3)
      assert(session.content.callout_folds[1].collapsed, "click on a summary continuation must close the fold")
      vim.api.nvim_win_set_cursor(win, { 2, 0 })
      mapped "za"
      assert(not session.content.callout_folds[1].collapsed, "za on a summary continuation must open the fold")
      preview.toggle()
      assert(
        vim.api.nvim_get_current_buf() == source and vim.api.nvim_win_get_cursor(win)[1] == 2,
        "summary continuation must restore its physical source row"
      )
    end
  )

  local url, summary_label = "https://example.invalid/summary?x=1&y=2", string.rep("連結", 12)
  with_session(
    { "<details>", '<summary><a href="' .. url .. '">' .. summary_label .. "</a></summary>", "body", "</details>" },
    function(session, _, win)
      local slices = {}
      for _, link in ipairs(session.content.link_metadata) do
        assert(
          link.url == url and session.content.source_line_map[link.line + 1] == 2,
          "summary link lost its URL/source"
        )
        slices[#slices + 1] = session.content.lines[link.line + 1]:sub(link.col_start + 1, link.col_end)
      end
      assert(table.concat(slices) == summary_label, "summary link ranges must retain every UTF-8 label byte")
      local calls = 0
      vim.ui.open = function(target)
        assert(target == url, "summary click changed the full URL")
        calls = calls + 1
      end
      for _, supported in ipairs { false, true } do
        display.supports_osc8 = function()
          return supported
        end
        for _, link in ipairs(session.content.link_metadata) do
          click(win, link.line + 1, link.col_start)
          assert(session.content.callout_folds[1].collapsed, "summary link click must take priority over folding")
        end
      end
      assert(calls == #session.content.link_metadata, "OSC 8 summary links must be left to the terminal")
    end
  )
  with_session({
    "<details>",
    '<summary><a href="#target">' .. summary_label .. "</a></summary>",
    "body",
    "</details>",
    "",
    "# Target",
  }, function(session, _, win)
    local target = session.content.heading_anchors.target + 1
    local link = session.content.link_metadata[2]
    assert(link, "anchor fixture must reach a summary continuation")
    vim.api.nvim_win_set_cursor(win, { link.line + 1, link.col_start })
    mapped "<CR>"
    assert(
      vim.api.nvim_win_get_cursor(win)[1] == target and session.content.callout_folds[1].collapsed,
      "Enter on a summary anchor must navigate before folding"
    )
    click(win, link.line + 1, link.col_start)
    assert(
      vim.api.nvim_win_get_cursor(win)[1] == target and session.content.callout_folds[1].collapsed,
      "click on a summary anchor must navigate before folding"
    )
  end)

  display.getmousepos, display.supports_osc8, vim.ui.open = mouse, osc8, open
end

-- Prefixes can exceed an extremely narrow window; they must never split UTF-8.
local saved_ambiwidth = vim.o.ambiwidth
for _, ambiwidth in ipairs { "single", "double" } do
  vim.o.ambiwidth = ambiwidth
  for width = 1, 5 do
    for _, body in ipairs {
      { "```lua", "x=1", "```" },
      { "> ```lua", "> x=1", "> ```" },
    } do
      local source = vim.list_extend({ "<details open>", "<summary>S</summary>", "" }, body)
      vim.list_extend(source, { "", "</details>" })
      local original = vim.deepcopy(source)
      local content = preview.build_content(source, { max_width = width, text_scale = false })
      for row, line in ipairs(content.lines) do
        assert(vim.fn.strtrans(line) == line, "narrow details layout split a UTF-8 character")
        assert(
          content.source_line_map[row] >= 1 and content.source_line_map[row] <= #source,
          "narrow row lost its source"
        )
      end
      assert(
        vim.deep_equal(content.code_blocks[1].source_lines, { "x=1" }),
        "narrow clipping changed the original code"
      )
      assert(vim.deep_equal(source, original), "narrow layout changed source bytes")
    end
  end
end
vim.o.ambiwidth = saved_ambiwidth

print(string.format("Wrap width: %d layout cases, complete glyphs and formatting/link offsets passed", checked))
