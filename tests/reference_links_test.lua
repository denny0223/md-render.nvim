-- Reference contracts from CommonMark 0.31.2, examples 192-218 and 527-541:
-- https://spec.commonmark.org/0.31.2/#link-reference-definitions
-- https://github.com/denny0223/md-render.nvim/issues/17
-- Run: nvim --headless -u NONE --noplugin -l tests/reference_links_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local markdown = require "md-render.markdown"
local inline = require "md-render.inline"
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
  local snapshot = vim.deepcopy(source)
  local b = Builder.new()
  b:render_document(source, vim.tbl_extend("force", { max_width = 1000, indent = "", text_scale = false }, opts or {}))
  eq(source, snapshot, "builder preserves source")
  local content = b:result()
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "reference_links_test"
  local ok, err = pcall(function()
    display.apply_content_to_buffer(buf, ns, content)
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), #content.lines == 0 and { "" } or content.lines, "buffer text")
    for _, link in ipairs(content.link_metadata) do
      local row = assert(content.lines[link.line + 1])
      assert(link.col_start >= 0 and link.col_start < link.col_end and link.col_end <= #row, "link byte bounds")
      eq(Links.at(buf, ns, link.line, link.col_start), link.url, "first link byte")
      eq(Links.at(buf, ns, link.line, link.col_end - 1), link.url, "last link byte")
      for _, col in ipairs { link.col_start - 1, link.col_end } do
        local expected
        for _, other in ipairs(content.link_metadata) do
          if other.line == link.line and col >= other.col_start and col < other.col_end then expected = other.url end
        end
        eq(Links.at(buf, ns, link.line, col), expected, "adjacent byte is outside the link")
      end
      local highlighted = false
      for _, hls in ipairs(content.highlights) do
        for _, hl in ipairs(hls.groups) do
          if hls.line == link.line and hl.hl == Links.highlight(link.url) then
            highlighted = highlighted or (hl.col == link.col_start and hl.end_col == link.col_end)
          end
        end
      end
      assert(highlighted, "link has a matching highlight")
    end
  end)
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, err)
  return content
end
local function visible(content)
  local lines = {}
  for _, line in ipairs(content.lines) do
    if line:find "%S" then lines[#lines + 1] = line end
  end
  return lines
end
local function link_texts(content)
  local links = {}
  for _, link in ipairs(content.link_metadata) do
    links[#links + 1] = {
      content.lines[link.line + 1]:sub(link.col_start + 1, link.col_end),
      link.url,
      content.source_line_map[link.line + 1],
    }
  end
  return links
end

test("an unresolved link returns no optional byte position", function()
  local first, last, url = inline.link_bounds("[missing]", 1, {})
  eq({ first, last, url }, {}, "missing bounds use nil, not a boolean")
end)

local definitions = {
  { "same line title", { '[foo]: /url "title"' }, "/url" },
  { "multiline destination", { "[foo]:", "/url" }, "/url" },
  { "indented title", { "   [foo]:", "      /url", "           'title'" }, "/url" },
  { "multiline title", { "[foo]: /url '", "title", "line1", "line2", "'" }, "/url" },
  { "multiline label", { "[", "foo", "]: /url" }, "/url" },
  { "empty destination", { "[foo]: <>" }, "" },
  { "angle destination", { "[foo]: <my url>" }, "my url" },
  { "multiline angle destination", { "[foo]:", "<my url>", "'title'" }, "my url" },
  { "escaped destination", { '[foo]: /url\\bar\\*baz "foo\\"bar\\baz"' }, "/url\\bar*baz" },
  { "decoded destination", { "[foo]: /a&amp;b&#92;&#42;" }, "/a&b\\*" },
  { "first definition", { "[foo]: first", "[FOO]: second" }, "first" },
  { "quoted definition", { "> [foo]: /url" }, "/url" },
  { "quoted multiline definition", { "> > [foo]:", "> > /url", "> > 'title'" }, "/url" },
  { "list definition", { "- [foo]: /url" }, "/url" },
}
for _, case in ipairs(definitions) do
  test(case[1], function()
    local refs, consumed = markdown.parse_reference_links(case[2])
    eq(refs.foo, case[3], "definition target")
    for i = 1, #case[2] do
      eq(consumed[i], true, "definition line consumed")
    end
    eq(visible(build(case[2])), {}, "unused definition is invisible")
    local source = vim.list_extend({ "[foo]", "" }, case[2])
    local content = build(source)
    eq(visible(content), { "foo" }, "definition is consumed")
    eq(link_texts(content), { { "foo", case[3], 1 } }, "target and source mapping")
  end)
end

test("malformed definitions and unresolved uses remain text", function()
  for _, lines in ipairs {
    { "[foo]:" },
    { "[foo]: <bar>(baz)" },
    { '[foo]: /url "title" ok' },
    { "[foo]: /url 'title", "", "with blank line'" },
    { "[foo]: /unbalanced(" },
    { "[foo]: <broken" },
    { "[ ]: /url" },
    { "[a[b]]: /url" },
    { "[" .. string.rep("a", 1000) .. "]: /url" },
  } do
    local refs, consumed = markdown.parse_reference_links(lines)
    eq(refs, {}, "invalid definition map")
    eq(consumed, {}, "invalid lines are not consumed")
    local content = build(vim.list_extend(vim.deepcopy(lines), { "", "[foo]" }))
    eq(content.link_metadata, {}, "unresolved use has no target")
    assert(table.concat(content.lines, "\n"):find("[foo]", 1, true), "unresolved use remains")
  end
end)
test("the first valid definition wins after an invalid candidate", function()
  local refs, consumed =
    markdown.parse_reference_links { '[foo]: /wrong "title" trailing', "", "[foo]: /first", "[FOO]: /second" }
  eq(refs, { foo = "/first" }, "first valid target")
  eq(consumed, { [3] = true, [4] = true }, "all and only valid rows consumed")
  eq(markdown.is_reference_link_def '[foo]: /wrong "title" trailing', false, "single-line validity helper")
end)
test("definitions cannot cross masked blank rows", function()
  eq(markdown.parse_reference_links { "[foo]:", "", "/hidden" }, {}, "destination cannot jump a blank")
  local refs, consumed = markdown.parse_reference_links { "[foo]: /url", "", '"title"' }
  eq(refs.foo, "/url", "destination remains valid")
  eq(consumed, { true }, "title cannot jump a blank")
end)
test("destination-only fallback does not consume malformed next-line title", function()
  local content = build { "[foo]: /url", '"title" ok', "", "[foo]" }
  eq(visible(content), { '"title" ok', "foo" }, "next-line title remains")
  eq(link_texts(content), { { "foo", "/url", 4 } }, "remaining source line")
end)
test("definitions cannot interrupt paragraphs or cross quote boundaries", function()
  local content = build { "paragraph", "[foo]: /url", "", "[foo]" }
  eq(content.link_metadata, {}, "paragraph text cannot define a reference")
  assert(table.concat(content.lines, "\n"):find("[foo]: /url", 1, true), "definition-like paragraph remains")
  eq(markdown.parse_reference_links { "> [foo]:", "/outside" }, {}, "quote boundary")
end)
test("definition removal preserves the next block's source", function()
  local content = build { "[foo]:", "/url", "'unused title'", "bar", "===", "", "[foo]" }
  eq(link_texts(content), { { "foo", "/url", 7 } }, "mapping past multiline definition")
  for i, line in ipairs(content.lines) do
    if line:find("bar", 1, true) then eq(content.source_line_map[i], 4, "heading source") end
  end
  content = build { "[Foo bar]:", "<my url>", "'title'", "", "[Foo bar]" }
  eq(visible(content), { "Foo bar" }, "CommonMark 195 angle destination is not an HTML block")
  eq(link_texts(content), { { "Foo bar", "my url", 5 } }, "CommonMark 195 original source row")
end)
test("completed blocks allow definitions while indented paragraph continuation does not", function()
  for _, preceding in ipairs { { "    code" }, { "$$", "x", "$$" } } do
    local lines = vim.list_extend(vim.deepcopy(preceding), { "[x]: /url", "", "[x]" })
    eq(link_texts(build(lines)), { { "x", "/url", #lines } }, "definition after block")
  end
  eq(
    build({ "paragraph", "    continuation", "[x]: /url", "", "[x]" }).link_metadata,
    {},
    "paragraph cannot be interrupted"
  )
  eq(markdown.parse_reference_links { "-     [x]: /code" }, {}, "indented code inside a list is literal")
end)
test("labels share Unicode folding and whitespace normalization", function()
  for _, case in ipairs {
    { "ΑΓΩ", "αγω", "αγω" },
    { "SS", "ẞ", "ss" },
    { "ß", "SS", "ss" },
    { "Σ", "ς", "σ" },
    { "FFI", "ﬃ", "ffi" },
    { "İ", "i\u{0307}", "i\u{0307}" },
    { "  Foo\t bar  ", "foo bar", "foo bar" },
    { "Foo\n bar", "foo bar", "foo bar" },
  } do
    eq(inline.normalize_reference_label(case[1]), case[3], "normalized definition")
    eq(inline.normalize_reference_label(case[2]), case[3], "normalized use")
    local source = vim.split("[" .. case[1] .. "]: /url\n\n[" .. case[2] .. "]", "\n", { plain = true })
    eq(link_texts(build(source)), { { case[2], "/url", #source } }, "Unicode reference")
  end
  eq(inline.normalize_reference_label "İ", "i\u{0307}", "dotted I is not plain i")
  assert(inline.normalize_reference_label "ı" ~= inline.normalize_reference_label "I", "dotless I stays distinct")
  eq(markdown.render("[i]", nil, nil, markdown.parse_reference_links { "[İ]: /url" }), "[i]", "no false fold")
end)
test("full collapsed shortcut and raw escaped labels", function()
  local refs = markdown.parse_reference_links { "[Foo]: /url", "[Foo*bar\\]]:my_(url) 'title'" }
  local text, _, links = markdown.render("[X][FOO] [foo][] [Foo] [Foo*bar\\]]", nil, nil, refs)
  eq(text, "X foo Foo Foo*bar]", "reference forms")
  eq(
    vim.tbl_map(function(link)
      return link.url
    end, links),
    { "/url", "/url", "/url", "my_(url)" },
    "targets"
  )
end)
test("label limits count Unicode characters and retain source spelling", function()
  for _, char in ipairs { "中", "😀" } do
    local label = string.rep(char, 999)
    local refs = markdown.parse_reference_links { "[" .. label .. "]: /url" }
    eq(refs[label], "/url", "999 Unicode characters are allowed")
    eq(markdown.parse_reference_links { "[" .. label .. char .. "]: /url" }, {}, "1000 characters are invalid")
    eq(markdown.render("[x][" .. label .. "]", nil, nil, refs), "x", "full reference accepts 999 characters")
  end
  local escaped_label = string.rep("a", 997) .. "\\!"
  local escaped_refs = markdown.parse_reference_links { "[" .. escaped_label .. "]: /url" }
  eq(
    markdown.render("[x][" .. escaped_label .. "]", nil, nil, escaped_refs),
    "x",
    "escape tokens do not inflate source character count"
  )
  local folded_label = string.rep("a", 998) .. "ß"
  local folded_refs = markdown.parse_reference_links { "[" .. folded_label .. "]: /url" }
  for _, suffix in ipairs { "]", "][]" } do
    local _, _, links = markdown.render("[" .. string.rep("a", 998) .. "ss" .. suffix, nil, nil, folded_refs)
    eq(links, {}, "1000-character shortcut/collapsed labels cannot match a folded 999-character definition")
  end
  local spaced_label = string.rep("a", 997) .. "  b"
  local spaced_refs = { [string.rep("a", 997) .. " b"] = "/url" }
  for _, source in ipairs { "[x][" .. spaced_label .. "]", "[" .. spaced_label .. "]", "[" .. spaced_label .. "][]" } do
    local _, _, links = markdown.render(source, nil, nil, spaced_refs)
    eq(links, {}, "display-space collapse cannot shorten a 1000-character source label")
  end
  local refs = markdown.parse_reference_links { "[&amp;]: /entity", "[foo\\!]: /escape" }
  local text, _, links = markdown.render("[&amp;] [&] [foo!] [foo\\!]", nil, nil, refs)
  eq(text, "& [&] [foo!] foo!", "entities and escapes retain raw identifier spelling")
  eq(
    vim.tbl_map(function(link)
      return link.url
    end, links),
    { "/entity", "/escape" },
    "raw targets"
  )
end)
test("shared destination scanner retains explicit validation", function()
  eq(inline.link_end("(/a\127b)", 1), nil, "DEL is not allowed in a bare destination")
  eq(markdown.parse_reference_links { "[r]: /a\127b" }, {}, "definition uses the same control boundary")
  for _, source in ipairs { "[x]( )", "[x](\t)" } do
    local text, _, links = markdown.render(source)
    eq(text, "x", "empty explicit label")
    eq(links[1].url, "", "empty destination excludes separator whitespace")
  end
end)
test("Unicode references own label backticks before code scanning", function()
  local refs = markdown.parse_reference_links { "[SS`label]: /url" }
  eq(inline.code_spans("[x][ẞ`label] y`", refs), {}, "reference label owns backtick")
  local content = build { "[x][ẞ`label] y`", "", "[SS`label]: /url" }
  eq(visible(content), { "x y`" }, "same scanner and render resolution")
  eq(link_texts(content), { { "x", "/url", 1 } }, "reference range")
  eq(visible(build { "[foo`][ref]`", "", "[ref]: /url" }), { "[foo][ref]" }, "code takes precedence")
end)
test("nested labels use existing link precedence", function()
  local refs = { ref = "/url" }
  local text, _, links = markdown.render("[link [foo [bar]]][ref]", nil, nil, refs)
  eq(text, "link [foo [bar]]", "balanced label")
  eq(#links, 1, "one outer link")
  local _, _, attribute_links = markdown.render('[foo <bar attr="][ref]">', nil, nil, refs)
  eq(attribute_links, {}, "raw HTML owns reference-looking attribute text")
  text, _, links = markdown.render("[foo [bar](/inner)][ref]", nil, nil, refs)
  eq(text, "[foo bar]ref", "inner link prevents outer reference")
  eq(
    vim.tbl_map(function(link)
      return link.url
    end, links),
    { "/inner", "/url" },
    "nested targets"
  )
end)
test("table headers and expanded rows receive references with exact byte ranges", function()
  local source =
    { "[r]: /url", "", "| [標題][r] | other |", "| --- | --- |", "| [長標籤 alpha beta gamma][r] | tail |" }
  local wide = build(source)
  eq(link_texts(wide), { { "標題", "/url", 3 }, { "長標籤 alpha beta gamma", "/url", 5 } }, "wide table")
  for _, expanded in ipairs { false, true } do
    local content = build(source, { max_width = 24, expand_state = { [3] = expanded } })
    local pieces, headers = {}, {}
    for _, link in ipairs(link_texts(content)) do
      eq(link[2], "/url", "wrapped target")
      if link[3] == 5 then
        pieces[#pieces + 1] = link[1]
      else
        eq(link[3], 3, "header source")
        headers[#headers + 1] = link[1]
      end
      assert(not link[1]:find("…", 1, true), "ellipsis is not clickable")
    end
    eq(headers, { "標題" }, "narrow table keeps its linked header")
    if expanded then
      eq(table.concat(pieces):gsub(" ", ""), "長標籤alphabetagamma", "all wrapped label bytes")
    else
      eq(pieces, { "長標籤 alpha " }, "truncated body keeps its visible linked text")
    end
  end
end)
test("comment definitions stay hidden and footnotes and wikilinks remain separate", function()
  local content = build { "<!--", "[foo]: /hidden", "-->", "", "[foo]" }
  assert(visible(content)[1]:find("[foo]", 1, true), "comment cannot define reference")
  local text, _, links = markdown.render("[^note]", nil, nil, { foo = "/url" }, { note = 1 })
  eq(text, "¹", "footnote display remains")
  eq(links[1].url, "#footnote-def-note", "footnote target remains")
  text, _, links = markdown.render("[[Page]]", nil, nil, { page = "/url" })
  eq(text, "Page", "wikilink display remains")
  eq(links[1].url, "obsidian://advanced-uri?filepath=Page", "wikilink target remains")
end)
test("public preview preserves source bytes and reference mappings", function()
  local preview = require "md-render.preview"
  local lines = { "[first]:", "/first", "", "[first]", "", "| [HEAD][first] |", "| --- |", "| [BODY][first] |" }
  local source = vim.api.nvim_create_buf(false, true)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(source)
  local ok, err = pcall(function()
    preview.toggle { text_scale = false, max_width = 30 }
    local session = assert(preview._toggle_sessions[source], "preview session exists")
    eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), lines, "source is unchanged while preview is open")
    local destinations = {}
    for _, link in ipairs(session.content.link_metadata) do
      destinations[#destinations + 1] = link.url
    end
    eq(destinations, { "/first", "/first", "/first" }, "preview receives the full reference context")
  end)
  if preview._toggle_sessions[source] then preview.toggle() end
  eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), lines, "source is unchanged after closing preview")
  vim.api.nvim_buf_delete(source, { force = true })
  assert(ok, err)
end)

print(string.format("reference_links_test: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
