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
      -- Media icons stay outside the destination color; the target starts after it.
      local styled_start = link.col_start
      for _, icon in ipairs { "📎 ", "󰋩 " } do
        if row:sub(link.col_start + 1, link.col_start + #icon) == icon then styled_start = styled_start + #icon end
      end
      for _, hls in ipairs(content.highlights) do
        for _, hl in ipairs(hls.groups) do
          if hls.line == link.line and hl.hl == Links.highlight(link.url) then
            highlighted = highlighted or (hl.col == styled_start and hl.end_col == link.col_end)
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

test("hidden comments retain the source identity of resolved standard references", function()
  for _, comment in ipairs { "<!--bar-->", "%%bar%%" } do
    local label = "*前* foo " .. comment .. "後"
    for _, case in ipairs {
      { "[[" .. label .. "]]", "[" .. label .. ']: <two  spaces.md> "title"', "two  spaces.md" },
      { "[[" .. label .. "][]]", "[" .. label .. "]: <two  spaces.md>", "two  spaces.md" },
      { "[[" .. label .. "][r]]", "[r]: <two  spaces.md>", "two  spaces.md" },
      { "[[" .. label .. "](/explicit)]", nil, "/explicit" },
    } do
      local source = { case[1] }
      if case[2] then
        source[2], source[3] = "", case[2]
      end
      local content = build(source)
      eq(visible(content), { "[前 foo 後]" }, "hidden comment retains literal outer brackets")
      eq(
        link_texts(content),
        { { "前 foo 後", case[3], 1 } },
        "original reference owner retains exact target/label/source"
      )
      local italic = {}
      for _, row in ipairs(content.highlights) do
        for _, hl in ipairs(row.groups) do
          if hl.hl == "Italic" then italic[#italic + 1] = { hl.col, hl.end_col } end
        end
      end
      eq(italic, { { 1, 1 + #"前" } }, "comment hiding retains the intended UTF-8 italic span")
    end
    local witness = build { "[[foo " .. comment .. "]]", "", "[foo " .. comment .. "]: /ref" }
    eq(visible(witness), { "[foo ]" }, "exact comment identity witness retains outer brackets")
    eq(link_texts(witness), { { "foo ", "/ref", 1 } }, "exact comment identity witness retains its standard owner")
    local unresolved = build { "[fo" .. comment .. "o]", "", "[foo]: /wrong" }
    eq(visible(unresolved), { "[foo]" }, "unresolved source still uses accepted comment hiding")
    eq(unresolved.link_metadata, {}, "hiding a comment cannot manufacture a reference identifier")
    local wiki = build { "[[note " .. comment .. "]]" }
    eq(
      link_texts(wiki),
      { { "note ", "obsidian://advanced-uri?filepath=note%20", 1 } },
      "nonconflicting wiki keeps comment display policy"
    )
  end
  local html = 'before <x title="a<!--keep-->b %%keep%%"> after'
  eq(visible(build { html }), { html }, "HTML attribute bytes stay opaque to comment display transformations")
  local code = build { "`foo<!--keep--> %%keep%%`" }
  eq(visible(code), { "foo<!--keep--> %%keep%%" }, "code retains literal comment bytes")
end)

test("escaped comment openers retain literal bytes and reference identity", function()
  for _, comment in ipairs { "<!--bar-->", "%%bar%%" } do
    local label = "foo \\" .. comment
    local content = build { "[[" .. label .. "]]", "", "[" .. label .. "]: /ref" }
    eq(visible(content), { "[foo " .. comment .. "]" }, "escaped comment opener stays literal")
    eq(
      link_texts(content),
      { { "foo " .. comment, "/ref", 1 } },
      "escaped source identifier retains its reference owner"
    )
    content = build { "[[foo \\" .. comment .. "]]", "", "[foo " .. comment .. "]: /wrong" }
    eq(
      vim.uri_decode(content.link_metadata[1].url),
      "obsidian://advanced-uri?filepath=foo " .. comment,
      "escaped and unescaped identifiers stay distinct"
    )
    eq(visible(content), { "foo " .. comment }, "ordinary unresolved wiki retains escaped literal bytes")
    content = build { "before \\" .. comment .. " end" }
    eq(visible(content), { "before " .. comment .. " end" }, "escaped comment opener remains literal in ordinary text")
    content = build { "before " .. comment .. " end" }
    eq(visible(content), { "before end" }, "real comment remains hidden in ordinary text")
    content = build { "[[foo \\\\" .. comment .. "]]", "", "[foo \\\\" .. comment .. "]: /ref" }
    eq(visible(content), { "[foo \\]" }, "an escaped backslash leaves a real comment opener")
    eq(link_texts(content), { { "foo \\", "/ref", 1 } }, "escaped backslash control retains exact source ownership")
  end
  local mixed = build { "before \\<!--bar--> after <!--hidden--> end" }
  eq(visible(mixed), { "before <!--bar--> after end" }, "a real HTML comment after an escaped opener stays hidden")
  local inside = build { "[[foo <!--\\-->]]", "", "[foo <!--\\-->]: /ref" }
  eq(visible(inside), { "[foo ]" }, "escapes inside real comments cannot protect their closer")
  eq(link_texts(inside), { { "foo ", "/ref", 1 } }, "real comment with backslash retains its raw identifier")
  local destination = build { '[label](/a%%keep%%b "<!--title-->")' }
  eq(link_texts(destination), { { "label", "/a%%keep%%b", 1 } }, "destination/title comment-looking bytes stay opaque")
end)

test("HTML media replacement retains mixed UTF-8 link and style spans", function()
  for _, media in ipairs {
    { "<img src='a.png' alt='image'>", "󰋩 image", "a.png" },
    {
      "<img src='a.png' alt='圖像名稱長於原始標籤資料'>",
      "󰋩 圖像名稱長於原始標籤資料",
      "a.png",
    },
    { "<video src='a.mp4'></video>", "󰋩 a.mp4", "a.mp4" },
    { "<video><source src='a.mp4'></video>", "󰋩 a.mp4", "a.mp4" },
  } do
    for _, prefix in ipairs { "before ", "前方 " } do
      local content = build { prefix .. media[1] .. " [*標籤*](<two  spaces.md>) after [[note]]" }
      eq(visible(content), { prefix .. media[2] .. " 標籤 after note" }, "mixed HTML media exact display")
      local actual = {}
      for _, link in ipairs(content.link_metadata) do
        actual[link.url] =
          { content.lines[link.line + 1]:sub(link.col_start + 1, link.col_end), link.col_start, link.col_end }
      end
      local label_col = #prefix + #media[2] + 1
      eq(
        actual["two  spaces.md"],
        { "標籤", label_col, label_col + #"標籤" },
        "standard target covers exact UTF-8 label bytes"
      )
      eq(actual[media[3]], { media[2], #prefix, #prefix + #media[2] }, "media target covers exact display bytes")
      eq(
        actual["obsidian://advanced-uri?filepath=note"],
        { "note", label_col + #"標籤 after ", label_col + #"標籤 after note" },
        "following extension target retains its span"
      )
      local italic = {}
      for _, row in ipairs(content.highlights) do
        for _, hl in ipairs(row.groups) do
          if hl.hl == "Italic" then italic[#italic + 1] = { hl.col, hl.end_col } end
        end
      end
      eq(italic, { { label_col, label_col + #"標籤" } }, "media insertion preserves the intended italic span")
      eq(content.source_line_map, { 1 }, "mixed media stays on its physical source row")
    end
  end
end)

test("standalone embeds retain safe styled captions and reject competing standard owners", function()
  local image = require "md-render.image"
  local kitty = image.supports_kitty
  image.supports_kitty = function()
    return true
  end
  local ok, err = pcall(function()
    local path = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"
    for _, caption in ipairs { "caption", "`caption`", "<b>caption</b>", "<code>caption</code>", "<a>caption</a>" } do
      local content = build { "![[" .. path .. "|" .. caption .. "]]" }
      eq(#content.image_placements, 1, "target-safe caption retains the existing media placement")
      eq(content.image_placements[1].path, path, "caption styling cannot change the image destination")
      eq(content.lines[1], "󰋩  " .. caption, "caption retains the existing literal media header display")
      eq(content.link_metadata, {}, "safe media caption cannot create a competing Obsidian target")
      for _, owner in ipairs(content.source_line_map) do
        eq(owner, 1, "media rows retain their physical embed source")
      end
    end
    for _, caption in ipairs { "[caption](/std)", "![caption](/std)", '<a href="/std">caption</a>', "<https://std.test>" } do
      local content = build { "![[" .. path .. "|" .. caption .. "]]" }
      eq(content.image_placements, {}, "a competing standard caption target suppresses the embed")
      eq(#content.link_metadata, 1, "the standard caption target remains the sole target")
      eq(
        content.link_metadata[1].url,
        caption:find("https://", 1, true) and "https://std.test" or "/std",
        "standard caption keeps its full destination"
      )
      assert(
        content.lines[1]:find("![[" .. path .. "|", 1, true),
        "suppressed embed retains literal outer source bytes"
      )
    end
    local target = build { "![[photo`note`.png|caption]]" }
    eq(visible(target), { "![[photonote.png|caption]]" }, "code in a destination keeps standard code ownership")
    eq(target.image_placements, {}, "protected code cannot manufacture a media destination")
    eq(target.link_metadata, {}, "protected destination cannot create an extension link")
    local resolved = build { "![[" .. path .. "|`caption`]]", "", "[" .. path .. "|`caption`]: /std" }
    eq(resolved.image_placements, {}, "a valid complete reference label owns the styled embed-looking source")
    eq(
      link_texts(resolved),
      { { path .. "|caption", "/std", 1 } },
      "resolved reference keeps exact label bytes and physical owner"
    )
  end)
  image.supports_kitty = kitty
  assert(ok, err)
end)

test("an unresolved link returns no optional byte position", function()
  local first, last, url = inline.link_bounds("[missing]", 1, {})
  eq({ first, last, url }, {}, "missing bounds use nil, not a boolean")
end)

test("forwarded reference results do not enable inline-only rendering", function()
  local source = { "[r]: /url" }
  local refs = markdown.parse_reference_links(source)
  local captured = { markdown.render("# [r]", nil, nil, refs) }
  eq(captured[1], "r", "heading text")
  eq(captured[4], "heading", "captured reference retains heading metadata")
  eq(
    { markdown.render("# [r]", nil, nil, markdown.parse_reference_links(source)) },
    captured,
    "additional reference results cannot become a boolean option"
  )
  eq({ markdown.render("# [r]", nil, nil, refs, nil, false) }, captured, "explicit false retains heading parsing")
  local text, _, _, kind = markdown.render("# [r]", nil, nil, refs, nil, true)
  eq(text, "# r", "explicit true keeps the inline marker")
  eq(kind, nil, "explicit true suppresses heading metadata")
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

test("reference titles cannot define footnotes", function()
  local content = build { '[ref]: /url "title', "[^note]: hidden footnote", '"', "", "[ref] [^note]" }
  eq(visible(content), { "ref [^note]" }, "consumed title remains opaque to footnote collection")
  eq(link_texts(content), { { "ref", "/url", 5 } }, "real reference still resolves on its original row")
end)

test("multiline reference titles retain table-looking source rows", function()
  for _, definition in ipairs {
    { '[ref]: /url "title', "|a|b|", "|---|---|", 'end"' },
    { "[ref]: /url", "'title", "a|b", "---|---", "end'" },
  } do
    local source = vim.list_extend(vim.deepcopy(definition), { "", "[ref] [**標題**][ref]" })
    local content = build(source)
    eq(content.lines, { "", "ref 標題" }, "definition does not become a table")
    eq(content.source_line_map, { #source - 1, #source }, "definition removal preserves physical source rows")
    eq(link_texts(content), { { "ref", "/url", #source }, { "標題", "/url", #source } }, "both references resolve")
    local bold = {}
    for _, group in ipairs(content.highlights) do
      for _, hl in ipairs(group.groups) do
        if hl.hl == "Bold" then bold[#bold + 1] = { group.line, hl.col, hl.end_col } end
      end
    end
    eq(bold, { { 1, 4, 10 } }, "Unicode label retains its exact bold bytes")
  end
end)

test("a completed reference title still permits a later table", function()
  local source = {
    '[ref]: /url "title',
    "|a|b|",
    "|---|---|",
    'end"',
    "",
    "[other]: /other",
    "|real|[**標題**][ref]|",
    "|---|---|",
    "[ref]|tail",
    "",
    "[ref] [other]",
  }
  local content = build(source)
  eq(content.lines, {
    "",
    "│ real │ 標題 │",
    "│──────│──────│",
    "│ ref  │ tail │",
    "",
    "ref other",
  }, "only the later table renders")
  eq(content.source_line_map, { 5, 7, 8, 9, 10, 11 }, "later table retains each physical source row")
  eq(link_texts(content), {
    { "標題", "/url", 7 },
    { "ref", "/url", 9 },
    { "ref", "/url", 11 },
    { "other", "/other", 11 },
  }, "definitions remain available inside and after the table")
end)

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

test("outer links display reference-image alt text for every reference form", function()
  local refs = { image = "/image.png", alt = "/image.png", ["**alt**"] = "/image.png" }
  for _, label in ipairs { "![alt][image]", "![alt][]", "![alt]", "![**alt**][image]", "![**alt**][]" } do
    local source = "前 [" .. label .. "](/outer) 後 [end](/end)"
    local text, highlights, links = markdown.render(source, nil, nil, refs)
    eq(text, "前 alt 後 end", "nested image displays only its semantic label")
    eq(#links, 2, "image target does not replace the outer target")
    eq({ links[1].url, links[2].url }, { "/outer", "/end" }, "outer and following targets")
    for i, expected in ipairs { "alt", "end" } do
      eq(text:sub(links[i].col_start + 1, links[i].col_end), expected, "UTF-8 byte range after image syntax removal")
    end
    if label:find("**", 1, true) then
      local bold = {}
      for _, hl in ipairs(highlights) do
        if hl.hl == "Bold" then bold[#bold + 1] = text:sub(hl.col + 1, hl.end_col) end
      end
      eq(bold, { "alt" }, "image alt emphasis retains its byte range")
    end
  end
  local text, _, links = markdown.render("[^n] [![alt][image]](/outer) [^n]", nil, nil, refs, { n = 1 })
  local labels = {}
  for _, link in ipairs(links) do
    labels[#labels + 1] = { text:sub(link.col_start + 1, link.col_end), link.url }
  end
  eq(
    labels,
    { { "¹", "#footnote-def-n" }, { "¹", "#footnote-def-n" }, { "alt", "/outer" } },
    "preexisting footnote ranges follow nested image removal"
  )
end)

test("image descriptions flatten nested links and images without leaking their targets", function()
  local refs = { image = "image.png", outer = "/outer" }
  for _, source in ipairs {
    '![caption **bold** [label](/inner) ![child](child.png)](image.png "title")',
    "![caption **bold** [label](/inner) ![child](child.png)][image]",
  } do
    local text, _, links = markdown.render("前 " .. source .. " 後 [end](/end)", nil, nil, refs)
    eq(text, "前 caption bold label child 後 end", "plain image alt in prose")
    eq(#links, 2, "description destinations do not become competing links")
    eq({ links[1].url, links[2].url }, { "image.png", "/end" }, "source and following link stay distinct")
    eq(text:sub(links[1].col_start + 1, links[1].col_end), "caption bold label child", "complete image fallback range")
  end
  local text, _, links = markdown.render("前 [text ![child][image] tail][outer] 後", nil, nil, refs)
  eq(text, "前 text child tail 後", "image labels inside ordinary links retain adjacent prose")
  eq(#links, 1, "one enclosing target")
  eq(links[1].url, "/outer", "outer reference destination")
  for _, case in ipairs {
    { "<https://example.com>", "https://example.com" },
    { '<a href="/inner">label</a>', "label" },
    { "<span>label</span>", "label" },
  } do
    for _, outer in ipairs { false, true } do
      local image = "![" .. case[1] .. "](image.png)"
      local alt_text, _, alt_links =
        markdown.render("before " .. (outer and "[" .. image .. "](/outer)" or image) .. " after")
      eq(alt_text, "before " .. case[2] .. " after", "supported HTML and autolink content yields plain image alt")
      eq(#alt_links, 1, "image-description HTML cannot create a competing link")
      eq(alt_links[1].url, outer and "/outer" or "image.png", "image or outer destination retains ownership")
      eq(alt_text:sub(alt_links[1].col_start + 1, alt_links[1].col_end), case[2], "plain alt has exact byte bounds")
    end
  end
end)

test("links and images decode escaped destinations once, including reference forms", function()
  for _, case in ipairs {
    { "a\\&amp;.png", "a&amp;.png" },
    { "a\\\\*.png", "a\\*.png" },
    { "a\\\\&amp;.png", "a\\&.png" },
  } do
    local refs = markdown.parse_reference_links { "[r]: " .. case[1] }
    eq(refs.r, case[2], "reference destination decodes once")
    local text, _, links =
      markdown.render("[text](" .. case[1] .. ") ![caption](" .. case[1] .. ") ![reference][r]", nil, nil, refs)
    eq(text, "text caption reference", "escaped destination never enters display text")
    eq(
      vim.tbl_map(function(link)
        return link.url
      end, links),
      { case[2], case[2], case[2] },
      "ordinary links, direct images and reference images agree"
    )
  end
end)

-- Record the actual local media resolver arguments; the existing PNG needs no
-- downloads, converters, terminal display or external image backend.
do
  local image = require "md-render.image"
  local kitty, resolve, cell_size = image.supports_kitty, image.resolve_local, image._test_cell_size
  local paths, graphics, available
  image.supports_kitty = function()
    return graphics
  end
  image._test_cell_size = { cell_w = 1, cell_h = 1 }
  local fixture = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"
  image.resolve_local = function(path)
    paths[#paths + 1] = path
    local resolved = available == true or (type(available) == "function" and available(#paths))
    return resolved and fixture or nil
  end
  local image_definitions = {
    '[r]: image.png "reference title"',
    "[caption]: image.png (title)",
    '[outer]: </outer?a=1&amp;b=2> "title"',
    '[escaped]: a\\&amp;.png "title"',
  }
  test("document and image-only table cells share Markdown destinations and reference media", function()
    for _, case in ipairs {
      { '![caption](image.png "title")', "image.png", "caption" },
      { "![caption](<image.png> 'title')", "image.png", "caption" },
      { "![caption](<two spaces.png>)", "two spaces.png", "caption" },
      { "![caption](a\\(b\\).png)", "a(b).png", "caption" },
      { "![caption](a(b(c)).png)", "a(b(c)).png", "caption" },
      { "![caption](a&amp;b&#x28;c&#41;.png)", "a&b(c).png", "caption" },
      { "![caption](a\\&amp;.png)", "a&amp;.png", "caption" },
      { "![caption](a\\\\*.png)", "a\\*.png", "caption" },
      { "![caption](a\\\\&amp;.png)", "a\\&.png", "caption" },
      { "![caption][escaped]", "a&amp;.png", "caption" },
      { "![caption](a<!-->b.png)", "a<!-->b.png", "caption" },
      { "<!-- leading -->![caption](image.png)<!-- trailing -->", "image.png", "caption", table_only = true },
      { "![caption][r]", "image.png", "caption" },
      { "![caption][]", "image.png", "caption" },
      { "![caption]", "image.png", "caption" },
      { "![caption **bold** [label](/inner) ![child](child.png)](image.png)", "image.png", "caption bold label child" },
      { '![<a href="/inner">caption</a>](image.png)', "image.png", "caption" },
      { "![<span>caption</span>](image.png)", "image.png", "caption" },
      { "![<https://example.com>](image.png)", "image.png", "https://example.com" },
      { '[![<a href="/inner">caption</a>](image.png)](/outer)', "image.png", "caption", "/outer" },
      { '[![caption][r]](</outer?a=1&amp;b=2> "title")', "image.png", "caption", "/outer?a=1&b=2" },
      { "[![caption][r]][outer]", "image.png", "caption", "/outer?a=1&b=2" },
      { "[![caption [child](/inner)](image.png)](/outer)", "image.png", "caption child", "/outer" },
      { "[![caption [child](/inner)][r]][outer]", "image.png", "caption child", "/outer?a=1&b=2" },
    } do
      -- A document line beginning with an HTML comment belongs to an HTML block.
      for _, table_cell in ipairs(case.table_only and { true } or { false, true }) do
        local source = table_cell and { "| Image |", "| --- |", "| " .. case[1] .. " |" } or { case[1] }
        vim.list_extend(source, { "", "[AFTER](/after)", "" })
        vim.list_extend(source, image_definitions)
        local source_buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, source)
        local tick = vim.api.nvim_buf_get_changedtick(source_buf)
        for _, width in ipairs { 18, 100 } do
          for _, mode in ipairs { { false, false }, { true, false }, { true, true } } do
            graphics, available, paths = mode[1], mode[2], {}
            local content = build(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), { max_width = width })
            eq(paths, graphics and { case[2] } or {}, "exact decoded resolver destination")
            eq(#content.image_placements, graphics and available and 1 or 0, "reference image shares media capability")
            if #content.image_placements > 0 then
              eq(content.image_placements[1].path, fixture, "actual resolved media path")
            end
            local display_text = table.concat(content.lines):gsub("[│%s]", "")
            assert(display_text:find(case[3]:gsub("%s", ""), 1, true), "full caption survives wrapping and fallback")
            assert(
              not display_text:find("![", 1, true),
              "recognized image markers never leak into the label: "
                .. vim.inspect { case[1], table_cell, graphics, available, content.lines }
            )
            local enclosing = {}
            for _, link in ipairs(link_texts(content)) do
              if link[2] == case[4] then
                enclosing[#enclosing + 1] = link[1]
                eq(link[3], table_cell and 3 or 1, "enclosing href keeps image source row")
              elseif link[2] == "/after" then
                eq(link[3], table_cell and 5 or 3, "following link keeps its physical source row")
              else
                assert(not case[4], "image source or description cannot replace its enclosing link")
                eq(link[2], case[2], "image-description targets never leak into fallback metadata")
              end
            end
            if case[4] then
              eq(
                table.concat(enclosing):gsub("%s", ""),
                case[3]:gsub("%s", ""),
                "enclosing target covers every wrapped caption byte"
              )
            end
            eq(vim.api.nvim_buf_get_changedtick(source_buf), tick, "rendering preserves source changedtick")
            eq(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), source, "rendering preserves source buffer")
          end
        end
        vim.api.nvim_buf_delete(source_buf, { force = true })
      end
    end
  end)
  test("each source image retains its caption and href in order, including failed media", function()
    local source = {
      "![first](same.png) [![第二長 caption words END](same.png)](/second) [![third](same.png)][outer]",
      "",
      image_definitions[3],
    }
    for _, width in ipairs { 18, 100 } do
      for _, mode in ipairs {
        { false, false, 0 },
        { true, false, 0 },
        { true, true, 3 },
        {
          true,
          function(index)
            return index == 2
          end,
          1,
        },
      } do
        graphics, available, paths = mode[1], mode[2], {}
        local content = build(source, { max_width = width })
        eq(
          paths,
          graphics and { "same.png", "same.png", "same.png" } or {},
          "duplicate paths remain three resolver occurrences"
        )
        eq(#content.image_placements, mode[3], "each occurrence retains its own resolution result")
        local rendered = table.concat(content.lines):gsub("%s", "")
        local first = assert(rendered:find("first", 1, true))
        local second = assert(rendered:find("第二長captionwordsEND", 1, true))
        local third = assert(rendered:find("third", 1, true))
        assert(first < second and second < third, "every caption remains in source order")
        local labels = { ["/second"] = {}, ["/outer?a=1&b=2"] = {} }
        for _, link in ipairs(link_texts(content)) do
          labels[link[2]][#labels[link[2]] + 1] = link[1]
        end
        eq(
          table.concat(labels["/second"]):gsub("%s", ""),
          "第二長captionwordsEND",
          "second occurrence keeps its own href"
        )
        eq(table.concat(labels["/outer?a=1&b=2"]), "third", "third occurrence keeps its own href")
      end
    end
    graphics, available, paths = true, true, {}
    local separate_rows =
      build { "![first](same.png)", "[![second](same.png)](/second)", "![third](same.png)", "", "[AFTER](/after)" }
    for _, placement in ipairs(separate_rows.image_placements) do
      local caption = separate_rows.lines[placement.line]
      local owner = caption:find("first", 1, true) and 1 or caption:find("second", 1, true) and 2 or 3
      eq(
        separate_rows.source_line_map[placement.line],
        owner,
        "joined media occurrences keep separate physical source rows"
      )
    end
    for _, link in ipairs(link_texts(separate_rows)) do
      eq(link[3], link[2] == "/second" and 2 or 5, "links across image boundaries retain their source rows")
    end
    graphics, available, paths = true, true, {}
    local special = build { "![first](same.png) [![badge](https://img.shields.io/badge/foo-bar)](/badge) ![empty]()" }
    eq(paths, { "same.png" }, "badge and empty destination keep their text fallback without resource loading")
    eq(#special.image_placements, 1, "only the ordinary image uses a media placement")
    assert(
      table.concat(special.lines):find("badge", 1, true) and table.concat(special.lines):find("empty", 1, true),
      "all special image occurrences retain their captions"
    )
    eq(link_texts(special), { { "badge", "/badge", 1 } }, "badge keeps its enclosing target in text fallback")
    graphics, available, paths = true, true, {}
    for _, literal in ipairs {
      "![undefined][missing]",
      "![caption](two spaces.png)",
      "![caption](a<!-- comment -->b.png)",
    } do
      for _, table_cell in ipairs { false, true } do
        local invalid_source = table_cell and { "| Image |", "| --- |", "| " .. literal .. " |" } or { literal }
        eq(build(invalid_source).image_placements, {}, "invalid or undefined image stays literal")
        eq(paths, {}, "invalid media destination never reaches a resolver")
      end
    end
  end)
  image.supports_kitty, image.resolve_local, image._test_cell_size = kitty, resolve, cell_size
end
test("table headers and wrapped rows receive references with exact byte ranges", function()
  local source =
    { "[r]: /url", "", "| [標題][r] | other |", "| --- | --- |", "| [長標籤 alpha beta gamma][r] | tail |" }
  local wide = build(source)
  eq(link_texts(wide), { { "標題", "/url", 3 }, { "長標籤 alpha beta gamma", "/url", 5 } }, "wide table")
  for _, width in ipairs { 24, 40 } do
    local content = build(source, { max_width = width })
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
    eq(table.concat(pieces):gsub(" ", ""), "長標籤alphabetagamma", "all wrapped label bytes")
  end
end)
test("comment definitions stay hidden and footnotes and wikilinks remain separate", function()
  local content = build { "<!--", "[foo]: /hidden", "-->", "", "[foo]" }
  assert(visible(content)[1]:find("[foo]", 1, true), "comment cannot define reference")
  local text, _, links = markdown.render("[^note]", nil, nil, { foo = "/url" }, { note = 1 })
  eq(text, "¹", "footnote display remains")
  eq(links[1].url, "#footnote-def-note", "footnote target remains")
  text, _, links = markdown.render("[[Page]]", nil, nil, { other = "/url" })
  eq(text, "Page", "wikilink display remains")
  eq(links[1].url, "obsidian://advanced-uri?filepath=Page", "wikilink target remains")
end)

-- CommonMark 0.31.2 example 559 / GFM example 568 (CC BY-SA 4.0):
-- https://spec.commonmark.org/0.31.2/#example-559
-- https://github.github.com/gfm/#example-568
test("standard link ownership wins over overlapping wiki syntax", function()
  local definitions = { '[*foo* bar]: /url "title"', "[r]: /full", "[標籤]: /unicode", "[photo.png]: /standard" }
  for _, case in ipairs {
    { "[[*foo* bar]]", "[foo bar]", "foo bar", "/url", "foo" },
    { "[[*foo* bar][]]", "[foo bar]", "foo bar", "/url", "foo" },
    { "[[*foo* bar][r]]", "[foo bar]", "foo bar", "/full", "foo" },
    { "[[*foo* bar](/explicit)]", "[foo bar]", "foo bar", "/explicit", "foo" },
    { "中 [[*標籤*](/unicode)] 後", "中 [標籤] 後", "標籤", "/unicode", "標籤" },
    { "中 [[標籤]] 後", "中 [標籤] 後", "標籤", "/unicode" },
    { "![[photo.png]]", "![photo.png]", "photo.png", "/standard" },
    { "[![*foo* bar](/image)]", "[foo bar]", "foo bar", "/image", "foo" },
    { "[![*foo* bar][r]]", "[foo bar]", "foo bar", "/full", "foo" },
    { "[![*foo* bar][]]", "[foo bar]", "foo bar", "/url", "foo" },
    { "[![*foo* bar]]", "[foo bar]", "foo bar", "/url", "foo" },
    { "[[note]](/outer)", "[note]", "[note]", "/outer" },
    { "[before [[note]] after][r]", "before [[note]] after", "before [[note]] after", "/full" },
    { "a ![[note]](/image)", "a [note]", "[note]", "/image" },
    { "[x](<[[note]]>)", "x", "x", "[[note]]" },
    { '[x](/file "[[note]] $x$ [^n]")', "x", "x", "/file" },
    { "[x[^n]](/file)", "x[^n]", "x[^n]", "/file" },
  } do
    local source = { case[1], "" }
    vim.list_extend(source, definitions)
    local content = build(source)
    eq(visible(content), { case[2] }, "owned bytes: " .. case[1])
    eq(link_texts(content), { { case[3], case[4], 1 } }, "one standard target: " .. case[1])
    local italic = {}
    for _, row in ipairs(content.highlights) do
      for _, hl in ipairs(row.groups) do
        if hl.hl == "Italic" then italic[#italic + 1] = content.lines[row.line + 1]:sub(hl.col + 1, hl.end_col) end
      end
    end
    eq(italic, case[5] and { case[5] } or {}, "emphasis covers intended label bytes: " .. case[1])
  end
end)

test("unresolved extensions and invalid nested definitions retain the accepted dialect", function()
  for _, source in ipairs { "[[note]]", "[[note|alias]]", "![[note]]" } do
    local text, _, links = markdown.render(source, nil, nil, {})
    eq(#links, 1, "one unresolved extension")
    eq(links[1].url, "obsidian://advanced-uri?filepath=note", "unresolved target")
    local expected = source == "[[note|alias]]" and "alias" or "note"
    eq(text:sub(-#expected), expected, "unresolved display")
  end
  -- CM 548/590 define invalid nested-bracket labels; no standard reference exists.
  for _, definition in ipairs { "[foo [bar]]: /url", "[[foo]]: /url" } do
    eq(markdown.parse_reference_links { definition }, {}, "nested labels cannot define references")
  end
  local text, _, links = markdown.render("[[foo]]", nil, nil, markdown.parse_reference_links { "[[foo]]: /url" })
  eq(text, "foo", "invalid definition does not suppress wiki")
  eq(links[1].url, "obsidian://advanced-uri?filepath=foo", "invalid definition cannot supply /url")
end)

test("escape code and HTML tokens protect extension-looking bytes", function()
  for _, source in ipairs { "\\[\\[note\\]\\]", "`[[note]] ![[note]] [^n] $x$`" } do
    local text, _, links = markdown.render(source, nil, nil, {}, { n = 1 })
    eq(links, {}, "literal source creates no competing target")
    eq(text, source:sub(1, 1) == "`" and source:sub(2, -2) or "[[note]]", "literal bytes")
  end
  for _, source in ipairs { "[[`note`]]", "![[`note`]]", "![[photo`note`.png]]" } do
    local text, highlights, links = markdown.render(source)
    eq(text, source:gsub("`", ""), "outer brackets preserve code ownership")
    eq(links, {}, "code tokens cannot become extension targets")
    eq(build({ source }).lines, { text }, "standalone media detection respects code ownership")
    local code = vim.tbl_filter(function(hl)
      return hl.hl == "MdRenderInlineCode"
    end, highlights)
    eq(#code, 1, "one code span")
    eq(text:sub(code[1].col + 1, code[1].end_col), "note", "code covers its literal bytes")
  end
  local text, highlights, links = markdown.render "[[Page|`note`]]"
  eq(text, "note", "nonconflicting code alias remains")
  eq(links[1].url, "obsidian://advanced-uri?filepath=Page", "code alias cannot alter the target")
  eq(
    vim.tbl_map(
      function(hl)
        return text:sub(hl.col + 1, hl.end_col)
      end,
      vim.tbl_filter(function(hl)
        return hl.hl == "MdRenderInlineCode"
      end, highlights)
    ),
    { "note" },
    "alias retains its standard code style"
  )
  local tag = '<span title="[[note]] ![[note]] [^n] $x$ ==hi== *em*">'
  text, highlights, links = markdown.render("a " .. tag .. "b", nil, nil, {}, { n = 1 })
  eq(text, "a " .. tag .. "b", "HTML attribute bytes stay literal")
  eq(links, {}, "HTML attributes cannot create links")
  for _, hl in ipairs(highlights) do
    assert(hl.hl ~= "Italic" and hl.hl ~= "MdRenderMath" and hl.hl ~= "MdRenderHighlight", "attributes are opaque")
  end
  text, highlights, links = markdown.render('<a href="[[note]]">label</a>', nil, nil, {})
  eq(text, "label", "supported HTML label remains")
  eq(highlights, { { col = 0, end_col = #"label", hl = "MdRenderLink" } }, "supported HTML keeps its link style")
  eq(
    vim.tbl_map(function(link)
      return link.url
    end, links),
    { "[[note]]" },
    "HTML destination keeps its source bytes"
  )
end)

test("overlapping references retain full targets through wrapping", function()
  local source =
    { "前 [[*長標籤 alpha beta gamma delta*]] 後", "", "[*長標籤 alpha beta gamma delta*]: <two  spaces.md>" }
  local content = build(source, { max_width = 14 })
  local fragments, italic = {}, {}
  for _, link in ipairs(link_texts(content)) do
    eq(link[2], "two  spaces.md", "wrapped full target")
    eq(link[3], 1, "wrapped source row")
    fragments[#fragments + 1] = link[1]
    assert(not link[1]:find("[", 1, true) and not link[1]:find("]", 1, true), "outer brackets are outside links")
  end
  for _, row in ipairs(content.highlights) do
    for _, hl in ipairs(row.groups) do
      if hl.hl == "Italic" then italic[#italic + 1] = content.lines[row.line + 1]:sub(hl.col + 1, hl.end_col) end
    end
  end
  eq(table.concat(fragments):gsub(" ", ""), "長標籤alphabetagammadelta", "all linked UTF-8 bytes")
  eq(table.concat(italic):gsub(" ", ""), "長標籤alphabetagammadelta", "all italic UTF-8 bytes")
end)

test("supported HTML targets own wiki aliases while targetless styles remain", function()
  for _, case in ipairs {
    { '<a href="/html">alias</a>', "alias", "/html" },
    { '<img src="/image" alt="alias">', "󰋩 alias", "/image" },
    { '<video src="/movie.mp4"></video>', "󰋩 movie.mp4", "/movie.mp4" },
    { '<video><source src="/movie.mp4"></video>', "󰋩 movie.mp4", "/movie.mp4" },
  } do
    local text, highlights, links = markdown.render("[[Page|" .. case[1] .. "]]")
    eq(text, "[[Page|" .. case[2] .. "]]", "standard HTML target retains literal wiki framing")
    eq(links, { { col_start = #"[[Page|", col_end = #"[[Page|" + #case[2], url = case[3] } }, "one supported target")
    local buf, ns = vim.api.nvim_create_buf(false, true), vim.api.nvim_create_namespace "html_alias_targets"
    display.apply_content_to_buffer(buf, ns, {
      lines = { text },
      highlights = { { line = 0, groups = highlights } },
      link_metadata = { vim.tbl_extend("force", links[1], { line = 0 }) },
    })
    local styled_start = #"[[Page|" + (case[3] == "/html" and 0 or #"󰋩 ")
    eq(
      vim.tbl_filter(function(hl)
        return hl.hl == "MdRenderLink"
      end, highlights),
      { { col = styled_start, end_col = #"[[Page|" + #case[2], hl = "MdRenderLink" } },
      "supported target has exact label style bytes"
    )
    eq(Links.at(buf, ns, 0, #"[[Page|"), case[3], "HTML target first byte")
    eq(Links.at(buf, ns, 0, #"[[Page|" + #case[2] - 1), case[3], "HTML target last byte")
    eq(Links.at(buf, ns, 0, #"[[Page|" - 1), nil, "outer literal prefix is not linked")
    eq(Links.at(buf, ns, 0, #"[[Page|" + #case[2]), nil, "outer literal suffix is not linked")
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  for _, tag in ipairs { "em", "strong", "code" } do
    local text, highlights, links = markdown.render("[[Page|<" .. tag .. ">alias</" .. tag .. ">]]")
    eq(text, "alias", "nonconflicting HTML style alias remains")
    eq(
      links,
      { { col_start = 0, col_end = #"alias", url = "obsidian://advanced-uri?filepath=Page" } },
      "style alias has its wiki target"
    )
    local style = tag == "em" and "Italic" or tag == "strong" and "Bold" or "MdRenderInlineCode"
    eq(
      vim.tbl_filter(function(hl)
        return hl.hl == style
      end, highlights),
      { { col = 0, end_col = #"alias", hl = style } },
      "HTML alias retains exact supported style bytes"
    )
  end
  for _, label in ipairs { "<a>alias</a>", "alias</a>", '<a href="/unpaired">alias' } do
    local _, _, links = markdown.render("[[Page|" .. label .. "]]")
    eq(#links, 1, "targetless markup does not invent another target")
    eq(links[1].url, "obsidian://advanced-uri?filepath=Page", "targetless markup retains the wiki target")
  end
end)

test("standard references coexist with outside extensions and literal code URLs", function()
  local content = build { "[[note]] [[*foo* bar]] ![[attach.md]] $x$", "", '[*foo* bar]: /url "title"' }
  eq(link_texts(content), {
    { "📎 attach.md", "obsidian://advanced-uri?filepath=attach.md", 1 },
    { "note", "obsidian://advanced-uri?filepath=note", 1 },
    { "foo bar", "/url", 1 },
  }, "outside targets have exact label bytes")
  local text, _, links = markdown.render("[x[^n]](/file) [^n]", nil, nil, nil, { n = 1 })
  eq(text, "x[^n] ¹", "footnotes remain available outside owned standard labels")
  eq(
    vim.tbl_map(function(link)
      return { text:sub(link.col_start + 1, link.col_end), link.url }
    end, links),
    { { "¹", "#footnote-def-n" }, { "x[^n]", "/file" } },
    "footnote and standard targets remain separate"
  )
  text, _, links = markdown.render("[^n] [[note]] [x](/file)", nil, nil, nil, { n = 1 })
  eq(
    vim.tbl_map(function(link)
      return { text:sub(link.col_start + 1, link.col_end), link.url }
    end, links),
    { { "note", "obsidian://advanced-uri?filepath=note" }, { "¹", "#footnote-def-n" }, { "x", "/file" } },
    "outside footnotes adjust preceding extension ranges"
  )
  local code_builder = Builder.new()
  code_builder:render_document({ "    [[note]] https://example.test/path" }, { max_width = 1000, indent = "" })
  content = code_builder:result()
  eq(content.lines, { "[[note]] https://example.test/path" }, "literal code bytes stay unchanged")
  eq(
    link_texts(content),
    { { "https://example.test/path", "https://example.test/path", 1 } },
    "literal URL stays active"
  )
  local buf, ns = vim.api.nvim_create_buf(false, true), vim.api.nvim_create_namespace "reference_literal_url"
  display.apply_content_to_buffer(buf, ns, content)
  eq(Links.at(buf, ns, 0, 9), "https://example.test/path", "literal URL first byte stays active")
  eq(Links.at(buf, ns, 0, #content.lines[1] - 1), "https://example.test/path", "literal URL last byte stays active")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("mixed HTML media dispatches the following standard target after public rebuild", function()
  local preview = require "md-render.preview"
  local mouse, osc8, open = display.getmousepos, display.supports_osc8, vim.ui.open
  display.supports_osc8 = function()
    return false
  end
  local ok, err = pcall(function()
    for _, media in ipairs { "<img src='a.png' alt='image'>", "<video src='a.mp4'></video>" } do
      local lines = { "before " .. media .. " [*標籤*](/std)" }
      local source = vim.api.nvim_create_buf(false, true)
      vim.bo[source].filetype = "markdown"
      vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
      vim.api.nvim_set_current_buf(source)
      preview.toggle { text_scale = false }
      local session = assert(preview._toggle_sessions[source])
      session:rebuild()
      local found = false
      for _, link in ipairs(session.content.link_metadata) do
        if link.url == "/std" then
          found = true
          eq(
            session.content.lines[link.line + 1]:sub(link.col_start + 1, link.col_end),
            "標籤",
            "public media keeps the standard label range"
          )
          local opened = {}
          vim.ui.open = function(url)
            opened[#opened + 1] = url
          end
          display.getmousepos = function()
            return { winid = session.win, line = link.line + 1, column = link.col_start + 1 }
          end
          assert(vim.fn.maparg("<LeftRelease>", "n", false, true).callback)()
          eq(opened, { "/std" }, "public mixed-media click dispatches exact standard target")
        end
      end
      assert(found, "public mixed-media standard target exists")
      preview.toggle()
      eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), lines, "mixed-media activation preserves source bytes")
      vim.api.nvim_buf_delete(source, { force = true })
    end
  end)
  display.getmousepos, display.supports_osc8, vim.ui.open = mouse, osc8, open
  assert(ok, err)
end)

test("standard priority survives public tab preview rebuild clicks and source toggle", function()
  local preview = require "md-render.preview"
  local lines = { "before", "", "[[*foo* bar]]", "", '[*foo* bar]: /url "title"' }
  local mouse, osc8, open = display.getmousepos, display.supports_osc8, vim.ui.open
  display.supports_osc8 = function()
    return false
  end
  for _, mode in ipairs { "tab", "toggle" } do
    local source = vim.api.nvim_create_buf(false, true)
    vim.bo[source].filetype = "markdown"
    vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(source)
    local tick = vim.api.nvim_buf_get_changedtick(source)
    local ok, err = pcall(function()
      if mode == "tab" then
        preview.show_tab { text_scale = false }
      else
        preview.toggle { text_scale = false }
      end
      local session = assert(preview._sessions[vim.api.nvim_get_current_buf()], "public session exists")
      for step = 1, 2 do
        eq(visible(session.content), { "  before", "  [foo bar]" }, "public exact text")
        eq(link_texts(session.content), { { "foo bar", "/url", 3 } }, "public link and physical source")
        eq(vim.api.nvim_buf_get_lines(session.buf, 0, -1, false), session.content.lines, "public buffer rows")
        local link = assert(session.content.link_metadata[1])
        eq(Links.at(session.buf, session.ns, link.line, link.col_start), "/url", "public first byte")
        eq(Links.at(session.buf, session.ns, link.line, link.col_end - 1), "/url", "public last byte")
        eq(Links.at(session.buf, session.ns, link.line, link.col_start - 1), nil, "outer opening bracket is literal")
        eq(Links.at(session.buf, session.ns, link.line, link.col_end), nil, "outer closing bracket is literal")
        local italic = {}
        for _, row in ipairs(session.content.highlights) do
          for _, hl in ipairs(row.groups) do
            if hl.hl == "Italic" then italic[#italic + 1] = { row.line, hl.col, hl.end_col } end
          end
        end
        eq(italic, { { link.line, link.col_start, link.col_start + #"foo" } }, "public italic owns only foo bytes")
        local opened = {}
        vim.ui.open = function(url)
          opened[#opened + 1] = url
        end
        display.getmousepos = function()
          return { winid = session.win, line = link.line + 1, column = link.col_start + 1 }
        end
        assert(vim.fn.maparg("<LeftRelease>", "n", false, true).callback)()
        eq(opened, { "/url" }, "public click dispatches standard destination")
        vim.api.nvim_win_set_cursor(session.win, { link.line + 1, link.col_start })
        if step == 1 then session:rebuild() end
      end
      if mode == "tab" then
        preview.show_tab()
      else
        preview.toggle()
        eq(vim.api.nvim_win_get_cursor(0)[1], 3, "source toggle returns to physical reference row")
        preview.toggle { text_scale = false }
        eq(
          link_texts(assert(preview._toggle_sessions[source]).content),
          { { "foo bar", "/url", 3 } },
          "source reopen retains target"
        )
        preview.toggle()
      end
      eq(vim.api.nvim_get_current_buf(), source, "public close returns to original buffer")
      eq(vim.api.nvim_buf_get_changedtick(source), tick, "public rebuild never changes source")
    end)
    if preview._toggle_sessions[source] and vim.api.nvim_get_current_buf() ~= source then preview.toggle() end
    vim.api.nvim_buf_delete(source, { force = true })
    assert(ok, err)
  end
  display.getmousepos, display.supports_osc8, vim.ui.open = mouse, osc8, open
end)

test("overlapping reference dispatch follows the full relative filename", function()
  local preview = require "md-render.preview"
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = assert(vim.uv.fs_realpath(dir))
  local lines = { "before", "", "[[*foo* bar]]", "", '[*foo* bar]: <two  spaces.txt> "title"' }
  vim.fn.writefile({ "destination" }, dir .. "/two  spaces.txt")
  local source = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(source, dir .. "/source.md")
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(source)
  local ok, err = pcall(function()
    preview.toggle { text_scale = false }
    local session = assert(preview._toggle_sessions[source])
    local link = assert(session.content.link_metadata[1])
    eq(link.url, "two  spaces.txt", "full relative filename")
    vim.api.nvim_win_set_cursor(0, { link.line + 1, link.col_start })
    assert(vim.fn.maparg("gf", "n", false, true).callback)()
    eq(vim.api.nvim_buf_get_name(0), dir .. "/two  spaces.txt", "gf dispatch opens exact relative file")
    eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "destination" }, "dispatched file contents")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-o>", true, false, true), "x", false)
    vim.wait(30)
    eq(vim.api.nvim_get_current_buf(), session.buf, "jump returns to rendered reference")
    preview.toggle()
    eq(vim.api.nvim_get_current_buf(), source, "source toggle returns original buffer")
    eq(vim.api.nvim_win_get_cursor(0)[1], 3, "relative target returns physical source row")
    eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), lines, "relative dispatch keeps source bytes")
  end)
  if preview._toggle_sessions[source] and vim.api.nvim_get_current_buf() ~= source then preview.toggle() end
  vim.api.nvim_buf_delete(source, { force = true })
  vim.fn.delete(dir, "rf")
  assert(ok, err)
end)

test("public reference reflow uses measured window width and preserves UTF-8 ownership", function()
  local preview = require "md-render.preview"
  local lines = {
    "before",
    "",
    "前 [[*長標籤 alpha beta gamma delta*]] 後",
    "",
    "[*長標籤 alpha beta gamma delta*]: <two  spaces.md>",
  }
  local original_win, split_win = vim.api.nvim_get_current_win(), nil
  local source = vim.api.nvim_create_buf(false, true)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(source)
  local tick = vim.api.nvim_buf_get_changedtick(source)
  local ok, err = pcall(function()
    vim.cmd "vsplit"
    split_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_width(split_win, 50)
    preview.toggle { text_scale = false }
    local session = assert(preview._toggle_sessions[source])
    eq(vim.api.nvim_win_get_width(session.win), 50, "actual wide window geometry")
    eq(session.opts.max_width, 50, "actual wide session geometry")
    local wide = vim.deepcopy(session.content.lines)
    eq(
      visible(session.content),
      { "  before", "  前 [長標籤 alpha beta gamma delta] 後" },
      "wide reference stays one row"
    )
    vim.api.nvim_win_set_width(split_win, 24)
    session:resize(session.win)
    session:rebuild()
    eq(vim.api.nvim_win_get_width(session.win), 24, "actual narrow window geometry")
    eq(session.opts.max_width, 24, "actual narrow session geometry")
    eq(
      visible(session.content),
      { "  before", "  前 [長標籤 alpha beta", "  gamma delta] 後" },
      "narrow reference visibly reflows"
    )
    eq(vim.api.nvim_buf_get_lines(session.buf, 0, -1, false), session.content.lines, "narrow public buffer rows")
    local fragments, italic = {}, {}
    for _, link in ipairs(session.content.link_metadata) do
      local row = session.content.lines[link.line + 1]
      eq(link.url, "two  spaces.md", "narrow fragment keeps full target")
      eq(session.content.source_line_map[link.line + 1], 3, "narrow fragment physical source row")
      eq(Links.at(session.buf, session.ns, link.line, link.col_start), link.url, "narrow fragment first byte")
      eq(Links.at(session.buf, session.ns, link.line, link.col_end - 1), link.url, "narrow fragment last byte")
      fragments[#fragments + 1] = row:sub(link.col_start + 1, link.col_end)
      assert(not fragments[#fragments]:find "[%[%]]", "narrow outer brackets are literal")
      vim.api.nvim_win_set_cursor(session.win, { link.line + 1, link.col_start })
    end
    assert(#fragments > 1, "actual narrow layout has multiple linked fragments")
    for _, row in ipairs(session.content.highlights) do
      for _, hl in ipairs(row.groups) do
        if hl.hl == "Italic" then
          italic[#italic + 1] = session.content.lines[row.line + 1]:sub(hl.col + 1, hl.end_col)
        end
      end
    end
    eq(table.concat(fragments):gsub(" ", ""), "長標籤alphabetagammadelta", "narrow fragments retain all label bytes")
    eq(table.concat(italic):gsub(" ", ""), "長標籤alphabetagammadelta", "narrow italics retain all label bytes")
    eq(vim.api.nvim_win_get_cursor(session.win)[1], 4, "cursor is on the final wrapped fragment")
    eq(session:rendered_to_source_f(4), 3.5, "float scrolling retains interpolation between source owners")
    eq(session:rendered_to_source(4), 3, "integer cursor recovery uses the physical owner")
    eq(session:rendered_to_source(6), 5, "outside the map retains the existing sentinel fallback")
    preview.toggle()
    eq(vim.api.nvim_win_get_cursor(0)[1], 3, "narrow source toggle returns physical reference row")
    vim.api.nvim_win_set_width(split_win, 50)
    preview.toggle { text_scale = false }
    eq(session.content.lines, wide, "widening restores the original rows")
    eq(vim.api.nvim_buf_get_changedtick(source), tick, "reflow leaves source changedtick unchanged")
    preview.toggle()
  end)
  if preview._toggle_sessions[source] and vim.api.nvim_get_current_buf() ~= source then preview.toggle() end
  if split_win and vim.api.nvim_win_is_valid(split_win) then vim.api.nvim_win_close(split_win, true) end
  if vim.api.nvim_win_is_valid(original_win) then vim.api.nvim_set_current_win(original_win) end
  eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), lines, "reflow preserves original source bytes")
  vim.api.nvim_buf_delete(source, { force = true })
  assert(ok, err)
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
