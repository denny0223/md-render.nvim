-- GFM table structure, examples 198-205:
-- https://github.github.com/gfm/#tables-extension-
-- https://github.com/denny0223/md-render.nvim/issues/24
-- Run: nvim --headless -u NONE --noplugin -l tests/markdown_table_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local Table = require "md-render.markdown_table"
local Builder = require("md-render.content_builder").ContentBuilder
local display = require "md-render.display_utils"
local Links = require "md-render.links"
require("md-render.image").supports_kitty = function()
  return false
end
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
  local source_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, source)
  local snapshot = vim.deepcopy(source)
  local b = Builder.new()
  b:render_document(source, vim.tbl_extend("force", { max_width = 1000, indent = "", text_scale = false }, opts or {}))
  local content = b:result()
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "markdown_table_test"
  local ok, err = pcall(function()
    display.apply_content_to_buffer(buf, ns, content)
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), content.lines, "applied buffer text")
    eq(source, snapshot, "source array unchanged")
    eq(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), snapshot, "source buffer unchanged")
    for _, group in ipairs(content.highlights) do
      local row = assert(content.lines[group.line + 1])
      for _, hl in ipairs(group.groups) do
        assert(hl.col >= 0 and hl.col <= #row, "highlight starts on a valid byte")
        assert(hl.end_col == -1 or (hl.end_col >= hl.col and hl.end_col <= #row), "highlight ends on a valid byte")
      end
    end
    for _, link in ipairs(content.link_metadata) do
      local row = assert(content.lines[link.line + 1])
      assert(link.col_start >= 0 and link.col_start < link.col_end and link.col_end <= #row, "link byte bounds")
      eq(Links.at(buf, ns, link.line, link.col_start), link.url, "first linked byte target")
      eq(Links.at(buf, ns, link.line, link.col_end - 1), link.url, "last linked byte target")
      for _, col in ipairs { link.col_start - 1, link.col_end } do
        local expected
        for _, other in ipairs(content.link_metadata) do
          if other.line == link.line and col >= other.col_start and col < other.col_end then expected = other.url end
        end
        eq(Links.at(buf, ns, link.line, col), expected, "adjacent byte target")
      end
    end
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.api.nvim_buf_delete(source_buf, { force = true })
  assert(ok, err)
  return content
end
local function texts(cells)
  return vim.tbl_map(function(cell)
    return cell.text
  end, cells)
end
local function structure(source, headers, alignments, rows)
  local parsed = assert(Table.parse(source), "recognized table")
  eq(texts(parsed.headers), headers, "header cells")
  eq(parsed.alignments, alignments, "column alignment")
  eq(vim.tbl_map(texts, parsed.rows), rows, "body cells")
  return parsed
end
local function table_prefix(content, source, refs)
  local lines, _, _, _, offsets = Table.render(assert(Table.parse(source, nil, nil, refs)), "", 1000)
  eq(vim.list_slice(content.lines, 1, #lines), lines, "builder retains the complete table")
  for i, offset in ipairs(offsets) do
    eq(content.source_line_map[i], offset + 1, "table row source")
  end
  return #lines
end

test("GFM 198 and 199: optional outer pipes preserve cells and alignment", function()
  for _, source in ipairs {
    { "| abc | defghi |", ":-: | -----------:", "bar | baz" },
    { "abc | defghi", "| :-: | -----------: |", "| bar | baz" },
    { "  abc | defghi |  ", "  :-: | -----------:  ", "  bar | baz |  " },
    { "| abc | defghi |", "| :-: | -----------: |", "| bar | baz |" },
  } do
    structure(source, { "abc", "defghi" }, { "center", "right" }, { { "bar", "baz" } })
    table_prefix(build(source), source)
  end
end)

test("GFM 200: escaped pipes stay inside formatted cells", function()
  local source = { "| f\\|oo |", "| ------ |", "b `\\|` az", "b **\\|** im" }
  local parsed = structure(source, { "f|oo" }, { "left" }, { { "b | az" }, { "b | im" } })
  eq(parsed.rows[1][1].highlights, { { col = 2, end_col = 3, hl = "MdRenderInlineCode" } }, "code pipe range")
  eq(parsed.rows[2][1].highlights, { { col = 2, end_col = 3, hl = "Bold" } }, "bold pipe range")
  table_prefix(build(source), source)
end)

test("GFM 201 and 202: block and blank boundaries terminate unpiped rows", function()
  local table_lines = { "| abc | def |", "| --- | --- |", "| bar | baz |", "bar" }
  structure(table_lines, { "abc", "def" }, { "left", "left" }, { { "bar", "baz" }, { "bar", "" } })
  for _, suffix in ipairs { { "", "bar" }, { "> bar" }, { "# next" }, { "- next" }, { "```", "literal", "```" } } do
    local source = vim.list_extend(vim.deepcopy(table_lines), suffix)
    eq(#assert(Table.parse(source)).rows, 2, "parser stops at the boundary")
    local content = build(source)
    local last = table_prefix(content, table_lines)
    assert(#content.lines > last, "following block remains visible")
    for i = last + 1, #content.lines do
      assert(content.source_line_map[i] >= 5, "following block retains its own source")
    end
    if suffix[1] == "" then
      eq(content.lines[#content.lines], "bar", "paragraph after the blank")
      eq(content.source_line_map[#content.lines], 6, "paragraph source")
    end
  end
end)

test("GFM 203: mismatched columns and pipe prose are not tables", function()
  for _, source in ipairs {
    { "| abc | def |", "| --- |", "| bar |" },
    { "prose | with pipe", "still | prose" },
    { "| ordinary prose", "continues here" },
    { "abc | def", "-- nope | ---" },
  } do
    eq(Table.parse(source), nil, "no valid header and delimiter pair")
    local content = build(source)
    assert(content.lines[1]:find(source[1], 1, true), "ordinary pipe prose remains visible")
  end
  eq(build({ "| ordinary prose", "continues here" }).lines, { "| ordinary prose continues here" }, "pipe prose joins")
end)

test("GFM 204 and 205: missing cells, excess cells and header-only tables", function()
  for _, source in ipairs {
    { "abc | def", "--- | ---", "bar", "bar | baz | boo" },
    { "| abc | def |", "| --- | --- |", "| bar |", "| bar | baz | boo |" },
  } do
    structure(source, { "abc", "def" }, { "left", "left" }, { { "bar", "" }, { "bar", "baz" } })
    table_prefix(build(source), source)
    local header = { source[1], source[2] }
    structure(header, { "abc", "def" }, { "left", "left" }, {})
    table_prefix(build(header), header)
  end
end)

test("single-column delimiters retain Setext precedence", function()
  eq(Table.parse { "heading", "---" }, nil, "plain dashes remain a Setext underline")
  eq(Table.parse { "A | B", "    - | -" }, nil, "indented delimiter cannot open a table")
  for _, delimiter in ipairs { ":---", "---|", "|---" } do
    local source = { "head", delimiter, "body" }
    structure(source, { "head" }, { "left" }, { { "body" } })
    table_prefix(build(source), source)
  end
end)

test("inline starts stay in tables while actual block starts terminate them", function()
  local prefix = { "A | B", "-|-" }
  for _, line in ipairs {
    "<em>inline</em> | tail",
    "<https://example.com> | tail",
    "![image](image.png) | tail",
    "---word | tail",
    "=== | tail",
    "#word | tail",
  } do
    local source = vim.list_extend(vim.deepcopy(prefix), { line })
    eq(#assert(Table.parse(source)).rows, 1, "inline row: " .. line)
    table_prefix(build(source), source)
  end
  for _, line in ipairs {
    "",
    "# heading",
    "> quote",
    "  > quote",
    "- item",
    "2. item",
    "    code",
    "---",
    "<!-- comment -->",
    "<div>block</div>",
    "<em>",
    "~~~",
  } do
    local source = vim.list_extend(vim.deepcopy(prefix), { line })
    eq(#assert(Table.parse(source)).rows, 0, "block boundary: " .. line)
    table_prefix(build(source), prefix)
  end
end)

test("an earlier paragraph and a later comment do not absorb or merge tables", function()
  local source = { "before", "A | B", "-|-", "one", "<!-- hidden -->", "after" }
  local content = build(source)
  eq(content.lines[1], "before", "preceding paragraph")
  eq(content.source_line_map[1], 1, "preceding source")
  eq(content.lines[#content.lines], "after", "comment ends table")
  eq(content.source_line_map[#content.lines], 6, "following source")
end)

test("unpiped reference and direct cells retain complete byte spans across widths", function()
  local source = {
    "[r]: /reference",
    "",
    "[**標題**][r] | [direct](/direct)",
    ":--- | ---:",
    "[**長標籤 alpha beta gamma**][r] | [右側](/right)",
    "[**unpiped alpha beta gamma**](/body)",
    "",
    "[outside](/outside)",
  }
  local canonical = vim.deepcopy(source)
  for i = 3, 6 do
    canonical[i] = "| " .. canonical[i] .. " |"
  end
  for _, opts in ipairs { {}, { max_width = 24 } } do
    local content, expected = build(source, opts), build(canonical, opts)
    for _, field in ipairs { "lines", "highlights", "link_metadata", "source_line_map", "expandable_regions" } do
      eq(content[field], expected[field], "outer pipes do not affect " .. field)
    end
    if not opts.max_width then
      local links = vim.tbl_map(function(link)
        return {
          content.lines[link.line + 1]:sub(link.col_start + 1, link.col_end),
          link.url,
          content.source_line_map[link.line + 1],
        }
      end, content.link_metadata)
      eq(links, {
        { "標題", "/reference", 3 },
        { "direct", "/direct", 3 },
        { "長標籤 alpha beta gamma", "/reference", 5 },
        { "右側", "/right", 5 },
        { "unpiped alpha beta gamma", "/body", 6 },
        { "outside", "/outside", 8 },
      }, "exact visible labels, targets and source rows")
    end
    local pieces = {}
    for _, link in ipairs(content.link_metadata) do
      local text = content.lines[link.line + 1]:sub(link.col_start + 1, link.col_end)
      local row = content.source_line_map[link.line + 1]
      assert(not text:find("…", 1, true), "ellipsis has no link")
      if link.url == "/body" then
        eq(row, 6, "unpiped wrapped body source")
        pieces[#pieces + 1] = text
        local bold = false
        for _, group in ipairs(content.highlights) do
          for _, hl in ipairs(group.groups) do
            if
              group.line == link.line
              and hl.hl == "Bold"
              and hl.col == link.col_start
              and hl.end_col == link.col_end
            then
              bold = true
            end
          end
        end
        assert(bold, "visible body link has the exact bold span")
      elseif link.url == "/outside" then
        eq({ text, row }, { "outside", 8 }, "following paragraph link and source")
      end
    end
    assert(#pieces > 0, "unpiped link remains interactive")
    eq(table.concat(pieces):gsub(" ", ""), "unpipedalphabetagamma", "all wrapped link text")
  end
end)

test("a bullet marker takes precedence over a table delimiter", function()
  for _, header in ipairs { "a|b", "|a|b|" } do
    for _, delimiter in ipairs { "- | -", "-\t| -" } do
      local source = { header, delimiter, "x|y" }
      eq(Table.parse(source), nil, "bullet delimiter is not a table")
      local content = build(source)
      eq(content.lines[1], header, "header stays ordinary paragraph text")
      eq(content.source_line_map[1], 1, "paragraph source")
      assert(content.lines[#content.lines]:find("x|y", 1, true), "list continuation remains visible")
      eq(content.source_line_map[#content.lines], 2, "list paragraph owns its continuation")
    end
  end
end)

test("table rows survive HTML preprocessing independently", function()
  local source = { "|a|b|", "|---|---|", "<mark>x", "y</mark>|z", "follow" }
  structure(source, { "a", "b" }, { "left", "left" }, {
    { "<mark>x", "" },
    { "y</mark>", "z" },
    { "follow", "" },
  })
  table_prefix(build(source), source)
  local linked = { "|a|b|", "|---|---|", "<mark>[X](/x)", "[Y](/y)</mark>|z", "follow" }
  local content = build(linked)
  table_prefix(content, linked)
  local spans = vim.tbl_map(function(link)
    return {
      content.lines[link.line + 1]:sub(link.col_start + 1, link.col_end),
      link.url,
      content.source_line_map[link.line + 1],
    }
  end, content.link_metadata)
  eq(spans, { { "X", "/x", 3 }, { "Y", "/y", 4 } }, "separate HTML rows retain exact link text, targets and sources")
  eq(build({ "<mark>x", "y</mark>" }).lines, { "x y" }, "HTML outside a table keeps multiline behavior")
  eq(
    build({ "<mark>", "outside", "a|b", "---|---", "end", "</mark>" }).lines,
    { "outside", "a|b", "---|---", "end" },
    "table-looking text inside HTML stays in its owner"
  )
end)

test("table boundaries distinguish empty lists from ordinary marker text", function()
  local prefix = { "|a|b|", "|---|---|" }
  for _, marker in ipairs { "1.", "1)", "123456789.", "123456789)" } do
    local source = vim.list_extend(vim.deepcopy(prefix), { marker, "tail" })
    eq(#assert(Table.parse(source)).rows, 0, "empty ordered item ends the table")
    local content = build(source)
    local last = table_prefix(content, prefix)
    assert(#content.lines > last and content.source_line_map[#content.lines] >= 3, "list remains outside the table")
  end
  local source = vim.list_extend(vim.deepcopy(prefix), {
    "<! foo",
    "1234567890. text",
    "0000000001) next",
    "9999999999. final",
  })
  structure(source, { "a", "b" }, { "left", "left" }, {
    { "<! foo", "" },
    { "1234567890. text", "" },
    { "0000000001) next", "" },
    { "9999999999. final", "" },
  })
  table_prefix(build(source), source)
end)

test("reference-looking table cells cannot define document links", function()
  for _, first_row in ipairs { false, "![alt](missing.png)", "<em>row</em>" } do
    local source = { "|a|b|", "---|---" }
    if first_row then source[#source + 1] = first_row end
    vim.list_extend(source, { "[r]: /unexpected", "[r]|tail" })
    local table_source = vim.deepcopy(source)
    vim.list_extend(source, { "", "[good]: /good", "", "[good] [r]" })
    local content = build(source)
    table_prefix(content, table_source)
    local destinations = vim.tbl_map(function(link)
      return link.url
    end, content.link_metadata)
    eq(
      destinations,
      first_row and first_row:sub(1, 1) == "!" and { "missing.png", "/good" } or { "/good" },
      "table cells cannot create reference destinations"
    )
    local link = content.link_metadata[#content.link_metadata]
    eq({ content.lines[link.line + 1], link.url, content.source_line_map[link.line + 1] }, {
      "good [r]",
      "/good",
      #source,
    }, "outside definition resolves and the table definition stays unresolved")
  end
  local source = { "```markdown", "|a|b|", "---|---", "[r]: /hidden", "```", "", "[r]" }
  local content = build(source)
  eq(#content.code_blocks, 1, "table-like code retains its code block")
  eq(content.link_metadata, {}, "code cannot define a reference")
  eq(content.lines[#content.lines], "[r]", "code reference stays unresolved")
  local quoted = build { "> ```markdown", "> |a|b|", "> ---|---", "> [r]: /hidden", "> ```", "", "[r]" }
  eq(#quoted.code_blocks, 1, "quoted table-like code retains its container")
  eq(quoted.link_metadata, {}, "quoted code cannot define a reference")
  eq(quoted.lines[#quoted.lines], "[r]", "quoted code reference stays unresolved")
end)

test("earlier table ownership rejects multiline cell definitions", function()
  for _, header in ipairs { "|a|b|", "[r]: /unexpected|b" } do
    local table_source = {
      header,
      "---|---",
      '[r]: /unexpected "title',
      "a|b",
      "---|---",
      'end"',
      "|[^note]: hidden|tail|",
    }
    local source = vim.list_extend(vim.deepcopy(table_source), { "", "[r] [^note] [**標題**](/direct)" })
    local content = build(source)
    table_prefix(content, table_source)
    eq(content.footnote_anchors, {}, "table cannot create footnote anchors")
    eq(content.lines[#content.lines], "[r] [^note] 標題", "cell definitions leave outside uses unresolved")
    eq(content.source_line_map[#content.lines], #source, "following paragraph retains its source")
    eq(content.link_metadata, {
      { line = #content.lines - 1, col_start = 12, col_end = 18, url = "/direct" },
    }, "only the explicit Unicode link is interactive")
    source = vim.list_extend(vim.deepcopy(table_source), { "", "[r]: /good", "", "[r] [^note]" })
    content = build(source)
    table_prefix(content, table_source, { r = "/good" })
    eq(content.lines[#content.lines], "r [^note]", "the later real definition resolves the outside reference")
    eq(content.source_line_map[#content.lines], #source, "outside real reference retains its source")
    eq(content.footnote_anchors, {}, "cell footnote remains opaque beside a real reference definition")
    for _, link in ipairs(content.link_metadata) do
      eq(link.url, "/good", "all references choose the real definition instead of the earlier cell")
    end
  end
end)

test("tables preserve complete headers, cells and glyphs at every width", function()
  local source = {
    "| ID | CPU | 很長的欄位說明與完整表頭 |",
    "| --- | ---: | --- |",
    "| A | 12.5 | **完整內容（不能省略）。** [LABEL73](/target) é 👩‍💻 👍🏽 🇹🇼 |",
    "| B | 8 | BCDFGHJKLMNPQRSTVWXYZ 與句尾資訊 ANCHOR73。 |",
  }
  local parsed = assert(Table.parse(source))
  for _, width in ipairs { 1, 12, 40, 80, 120 } do
    local lines, _, _, _, offsets = Table.render(parsed, "", width)
    local cells = {}
    for i, line in ipairs(lines) do
      assert(not line:find("…", 1, true), "table text must never be truncated")
      eq(vim.fn.strdisplaywidth(line), vim.fn.strdisplaywidth(lines[1]), "all table borders align")
      if offsets[i] ~= 1 and not line:find("─", 1, true) then
        local row = offsets[i]
        cells[row] = cells[row] or { "", "", "" }
        local parts = vim.split(line, "│", { plain = true })
        for col = 1, 3 do
          cells[row][col] = cells[row][col] .. vim.trim(parts[col + 1])
        end
      end
    end
    for row, expected in pairs { [0] = parsed.headers, [2] = parsed.rows[1], [3] = parsed.rows[2] } do
      for col, cell in ipairs(expected) do
        eq(cells[row][col]:gsub("%s", ""), cell.text:gsub("%s", ""), "complete cell at width " .. width)
      end
    end
    build(source, { max_width = width }) -- Apply real link/highlight spans to a Neovim buffer.
    if width >= 40 then
      assert(table.concat(lines, "\n"):find("12.5", 1, true), "short numeric cells keep their width")
    end
  end
end)

test("single-line and multiline HTML wrap identically without expandable regions", function()
  local source = {
    "<table>",
    "<tr><th>項目</th><th>很長的欄位說明與完整表頭</th></tr>",
    "<tr><td>離線回寫</td><td>裝置可以暫存離線期間建立的紀錄；必須確認伺服器回應正常，最後保留 HTML73。</td></tr>",
    "</table>",
  }
  for _, width in ipairs { 40, 80, 120 } do
    local multiline = build(source, { max_width = width })
    local single = build({ table.concat(source) }, { max_width = width })
    eq(single.lines, multiline.lines, "HTML source formatting does not affect rendered text")
    eq(single.expandable_regions, {}, "single-line HTML needs no expansion")
    eq(multiline.expandable_regions, {}, "multiline HTML needs no expansion")
    local text = table.concat(single.lines, "\n")
    assert(not text:find("…", 1, true), "HTML retains complete text")
    assert(text:find("HTML73", 1, true), "HTML tail keyword is visible initially")
  end
end)

test("table width counts container indentation and details bars exactly once", function()
  local text = string.rep("word ", 50) .. "TAIL73"
  local pipe = { "| ID | Details |", "| --- | --- |", "| A | " .. text .. " |" }
  local html = {
    "<table>",
    "<tr><th>ID</th><th>Details</th></tr>",
    "<tr><td>A</td><td>" .. text .. "</td></tr>",
    "</table>",
  }
  for _, source in ipairs { pipe, html, { table.concat(html) } } do
    for _, nested in ipairs { false, true } do
      local lines = source
      if nested then
        lines = { "1. list", "" }
        for _, line in ipairs(source) do
          lines[#lines + 1] = "   " .. line
        end
      end
      local content = build(lines, { max_width = 20, table_max_width = 80 })
      assert(next(content.table_lines), "rendered table rows have layout metadata")
      for row in pairs(content.table_lines) do
        eq(vim.api.nvim_strwidth(content.lines[row + 1]), 80, "table uses its full budget including indent")
      end
    end
  end
  local ambiwidth = vim.o.ambiwidth
  for _, mode in ipairs { "single", "double" } do
    vim.o.ambiwidth = mode
    for _, source in ipairs { html, { table.concat(html) } } do
      local lines = vim.list_extend({ "<details open>", "<summary>More</summary>" }, source)
      lines[#lines + 1] = "</details>"
      local content = build(lines, { max_width = 20, table_max_width = 40 })
      for row in pairs(content.table_lines) do
        eq(vim.api.nvim_strwidth(content.lines[row + 1]), 40, "details prefix fits within table width")
      end
    end
  end
  vim.o.ambiwidth = ambiwidth
end)

print(string.format("markdown_table_test: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
