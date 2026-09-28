-- Run: nvim --headless -u NONE --noplugin -l tests/character_references_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local markdown = require "md-render.markdown"
local references = require "md-render.character_references"
local checks, failures = 0, 0

local function eq(actual, expected, message)
  checks = checks + 1
  assert(
    vim.deep_equal(actual, expected),
    message .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)
  )
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    failures = failures + 1
    print("FAIL: " .. name .. ": " .. tostring(err))
  end
end

test("named data loads only when a name lookup needs it", function()
  eq(package.loaded["md-render.html_entities"], nil, "loading the renderer does not load named data")
  eq(references.decode "plain &#65; &#x1F600; \\&amp; &amp", "plain A 😀 &amp; &amp", "non-name decoding")
  eq(package.loaded["md-render.html_entities"], nil, "text, numeric, escaped and incomplete references need no table")
  eq(references.decode "&amp;", "&", "first named lookup")
  local loaded = package.loaded["md-render.html_entities"]
  eq(type(loaded), "table", "first named lookup loads the table")
  eq(references.decode "&AElig;", "Æ", "subsequent named lookup")
  eq(package.loaded["md-render.html_entities"] == loaded, true, "subsequent lookups reuse Lua's module cache")
end)

local entities = require "md-render.html_entities"

test("the complete table matches the independent official codepoint digest", function()
  local names, canonical = vim.tbl_keys(entities), {}
  table.sort(names)
  eq(#names, 2125, "semicolon-terminated names")
  for _, name in ipairs(names) do
    canonical[#canonical + 1] = name .. "\t" .. #entities[name] .. ":" .. entities[name] .. "\n"
  end
  -- Computed from the official JSON's codepoints, independently of the generated
  -- table's characters field. Pins every name/value, including all 93 two-codepoint values.
  eq(
    vim.fn.sha256(table.concat(canonical)),
    "7852dd68da6df5465c35772780f428c430d88f2ff387f5cdd4744672a1a4a240",
    "WHATWG table"
  )
end)

test("the shared matcher consumes complete references at the requested byte", function()
  for name, value in pairs(entities) do
    local reference = "&" .. name .. ";"
    eq({ references.match("中 " .. reference .. " tail", 5) }, { reference, value }, reference)
  end
  for _, text in ipairs {
    "&amp",
    "&Amp;",
    "&MadeUpEntity;",
    "&#;",
    "&#x;",
    "&#12345678;",
    "&#x1234567;",
    "&#-1;",
    "&am**p;**",
  } do
    eq({ references.match(text, 1) }, {}, text .. " is not a complete reference")
  end
  eq({ references.match("prefix &amp;", 1) }, {}, "the matcher does not scan ahead")
end)

test("metadata decoding handles escapes without reparsing output", function()
  for _, case in ipairs {
    { "\\&amp;", "&amp;" },
    { "\\\\&amp;", "\\&" },
    { "&amp\\;", "&amp;" },
    { "&\\#65;", "&#65;" },
    { "&#92;&#42;", "\\*" },
    { "&amp;#65;", "&#65;" },
    { "\\_&nGt;", "_≫\u{20D2}" },
    { "&#0;&#xD800;&#x110000;", "���" },
    { "&#xD7FF;&#xE000;&#x10FFFF;", "\u{D7FF}\u{E000}\u{10FFFF}" },
    -- CommonMark 2.5 and cmark preserve valid scalars, including C1 controls.
    { "&#128;&#x9F;", "\u{80}\u{9F}" },
    { "\\a\\ \\\n", "\\a\\ \\\n" },
  } do
    eq(references.decode(case[1]), case[2], case[1])
  end
end)

test("every official name decodes once with exact style and URL ranges", function()
  for name, value in pairs(entities) do
    local reference = "&" .. name .. ";"
    local label = "A" .. value:gsub("[\r\n]", " ") .. "Z"
    local text, highlights, links =
      markdown.render("P &amp; [**A" .. reference .. "Z**](https://example.invalid/" .. reference .. ") \\* Q")
    eq(text, "P & " .. label .. " * Q", reference .. " text")
    eq(#highlights, 2, reference .. " highlight count")
    local groups = {}
    for _, hl in ipairs(highlights) do
      groups[hl.hl] = true
      eq(hl.col, 4, reference .. " highlight start")
      eq(hl.end_col, 4 + #label, reference .. " highlight end")
      eq(text:sub(hl.col + 1, hl.end_col), label, reference .. " highlighted text")
    end
    eq(groups, { Bold = true, MdRenderLink = true }, reference .. " styles")
    eq(
      links,
      { { col_start = 4, col_end = 4 + #label, url = "https://example.invalid/" .. value } },
      reference .. " link"
    )
  end
end)

-- Adapted from CommonMark 0.31.2 examples 25-30, 32, 35 and 37; expected Unicode is explicit.
-- https://spec.commonmark.org/0.31.2/#entity-and-numeric-character-references
test("official samples and exact name recognition", function()
  for _, case in ipairs {
    {
      "&nbsp; &amp; &copy; &AElig; &Dcaron; &frac34; &HilbertSpace; &DifferentialD; &ClockwiseContourIntegral; &ngE;",
      "\u{A0} & © Æ Ď ¾ ℋ ⅆ ∲ ≧\u{338}",
    },
    { "&#35; &#1234; &#992; &#0;", "# Ӓ Ϡ �" },
    { "&#X22; &#XD06; &#xcab;", '" ആ ಫ' },
    { "&AMP;&amp;&Aacute;&aacute;&GT;&gt;", "&&Áá>>" },
    { "&NotEqualTilde;&fjlig;&varsubsetneq;", "≂\u{338}fj⊊\u{FE00}" },
    { "&nbsp &x; &#; &#x; &#87654321; &#abcdef0; &ThisIsNotDefined; &hi?;", nil },
    { "&copy &MadeUpEntity; &Amp; &FRAC14; &notit; &;", nil },
    { "`f&ouml;&ouml;`", "f&ouml;&ouml;" },
    { "&#42;foo&#42;", "*foo*" },
    { "&amp;ouml; &amp;#65;", "&ouml; &#65;" },
  } do
    local text, highlights, links = markdown.render(case[1])
    eq(text, case[2] or case[1], case[1])
    if case[1] == "&#42;foo&#42;" then eq(highlights, {}, "decoded markers remain text") end
    eq(links, {}, "ordinary references do not become links")
  end
  local _, _, links = markdown.render '[foo](/f&ouml;&ouml; "f&ouml;&ouml;")'
  eq(links[1].url, "/föö", "entities in inline destinations")
end)

test("numeric syntax limits and Unicode boundaries", function()
  for _, case in ipairs {
    { "&#0;", "�" },
    { "&#xD800;", "�" },
    { "&#xDFFF;", "�" },
    { "&#1114112;", "�" },
    { "&#x110000;", "�" },
    { "&#9999999;", "�" },
    { "&#xD7FF;", "\u{D7FF}" },
    { "&#xE000;", "\u{E000}" },
    { "&#1114111;", "\u{10FFFF}" },
    { "&#x10FFFF;", "\u{10FFFF}" },
    { "&#0000065;", "A" },
    { "&#X000041;", "A" },
    { "&#00000065;", nil },
    { "&#x0000041;", nil },
    { "&#-1;", nil },
    { "&#x-1;", nil },
    { "&#+65;", nil },
    { "&#65", nil },
  } do
    local expected = case[2] or case[1]
    local text, highlights, links =
      markdown.render("P **" .. case[1] .. "** &amp; [X](https://example.invalid/" .. case[1] .. ")")
    eq(text, "P " .. expected .. " & X", case[1])
    local bold
    for _, hl in ipairs(highlights) do
      if hl.hl == "Bold" then bold = text:sub(hl.col + 1, hl.end_col) end
    end
    eq(bold, expected, case[1] .. " bold")
    eq(links[1].url, "https://example.invalid/" .. expected, case[1] .. " URL")
  end
end)

test("escaped references and decoded PUA remain literal in text and URLs", function()
  for _, case in ipairs {
    { "\\&ouml;", "&ouml;" },
    { "&amp\\;", "&amp;" },
    { "&\\#65;", "&#65;" },
    { "&#xF00A;", "\u{F00A}" },
    { "&#xF02A;", "\u{F02A}" },
    { "&#xF1000;1&#xF1001;", "\u{F1000}1\u{F1001}" },
    { "&#92;&#42;", "\\*" },
    { "&bsol;&ast;", "\\*" },
    { "&amp;#xF00A;", "&#xF00A;" },
  } do
    local text, highlights, links =
      markdown.render("\\* [A" .. case[1] .. "Z](https://example.invalid/" .. case[1] .. ") `SAFE`")
    eq(text, "* A" .. case[2] .. "Z SAFE", case[1] .. " text")
    eq(
      links,
      { { col_start = 2, col_end = 4 + #case[2], url = "https://example.invalid/" .. case[2] } },
      case[1] .. " URL"
    )
    local code
    for _, hl in ipairs(highlights) do
      if hl.hl == "MdRenderInlineCode" then code = text:sub(hl.col + 1, hl.end_col) end
    end
    eq(code, "SAFE", case[1] .. " following code")
  end
end)

test("removing inline syntax cannot create a new character reference", function()
  for _, case in ipairs {
    { "&am**p;**", "&amp;", "Bold", "p;", 3 },
    { "&#x4**1;**", "&#x41;", "Bold", "1;", 4 },
    { "&am[p;](https://example.invalid)", "&amp;", "MdRenderLink", "p;", 3 },
  } do
    local text, highlights, links = markdown.render(case[1])
    eq(text, case[2], case[1] .. " text")
    eq(#highlights, 1, case[1] .. " one style")
    eq(highlights[1].hl, case[3], case[1] .. " style")
    eq(highlights[1].col, case[5], case[1] .. " style start")
    eq(text:sub(highlights[1].col + 1, highlights[1].end_col), case[4], case[1] .. " styled text")
    if case[3] == "MdRenderLink" then
      eq(links, { { col_start = 3, col_end = 5, url = "https://example.invalid" } }, "joined reference link")
    else
      eq(links, {}, "joined reference has no links")
    end
  end
end)

test("comment boundaries precede escapes and cannot create references", function()
  for _, case in ipairs {
    { "A<!-- \\-->B &amp;", "AB &" },
    { "A%% \\%%B &amp;", "AB &" },
    { "&am<!-- \\-->p;", "&amp;" },
  } do
    local text, highlights, links = markdown.render(case[1])
    eq(text, case[2], case[1])
    eq(highlights, {}, "comment produces no styles")
    eq(links, {}, "comment produces no links")
  end
end)

test("angle destinations decode their original source exactly once", function()
  for _, case in ipairs {
    { "&amp;", "&" },
    { "\\&amp;", "&amp;" },
    { "&amp;#65;", "&#65;" },
    { "&#92;&#42;", "\\*" },
    { "\u{F1000}\u{F1002}\u{F1004}&#xF1004;", "\u{F1000}\u{F1002}\u{F1004}\u{F1004}" },
  } do
    local text, highlights, links = markdown.render("[X](<https://example.invalid/" .. case[1] .. ">)")
    eq(text, "X", "angle destination label")
    eq(highlights, { { col = 0, end_col = 1, hl = "MdRenderLink" } }, "angle destination style")
    eq(
      links,
      { { col_start = 0, col_end = 1, url = "https://example.invalid/" .. case[2] } },
      case[1] .. " angle destination"
    )
  end
end)

test("comment-looking destination text cannot synthesize a character reference", function()
  for _, fragment in ipairs { "&am<!---->p;", "&am%%c%%p;" } do
    local url = "https://example.invalid/" .. fragment
    local text, highlights, links = markdown.render("[X](" .. url .. ")")
    eq(text, "X", "comment-looking destination label")
    eq(highlights, { { col = 0, end_col = 1, hl = "MdRenderLink" } }, "comment-looking destination style")
    eq(links, { { col_start = 0, col_end = 1, url = url } }, "the original destination remains intact")
  end
  local text, highlights, links = markdown.render "A<!-- [X](https://example.invalid/&amp;) -->B"
  eq(text, "AB", "a real comment may contain link-looking text")
  eq(highlights, {}, "comment content has no style")
  eq(links, {}, "comment content has no destination")
end)

test("HTML media filenames decoded from references remain literal", function()
  for _, case in ipairs {
    { '<img src="https://example.invalid/&#42;x&#42;.png">', "*x*.png" },
    { '<video src="https://example.invalid/&#42;x&#42;.mp4"></video>', "*x*.mp4" },
  } do
    local text, highlights, links = markdown.render(case[1])
    eq(text:sub(-#case[2]), case[2], "literal media filename")
    for _, hl in ipairs(highlights) do
      eq(hl.hl == "Italic", false, "decoded asterisks cannot open emphasis")
      eq(hl.col >= 0 and hl.end_col <= #text, true, "media highlight range")
    end
    eq(links, { { col_start = 0, col_end = #text, url = "https://example.invalid/" .. case[2] } }, "media URL")
  end
end)

test("bare URLs end before adjacent literal code", function()
  local url = "https://example.invalid/&"
  local text, highlights, links = markdown.render "https://example.invalid/&amp;`CODE`"
  eq(text, url .. "CODE", "bare URL followed by code")
  eq(highlights, {
    { col = 0, end_col = #url, hl = "MdRenderLink" },
    { col = #url, end_col = #url + 4, hl = "MdRenderInlineCode" },
  }, "separate URL and code ranges")
  eq(links, { { col_start = 0, col_end = #url, url = url } }, "code is excluded from destination")
end)

test("replacement text cannot impersonate a later restoration token", function()
  local lookalike = "\u{F1004}3\u{F1005}"
  local text, highlights = markdown.render "&#xF1004;3&#xF1005; **&amp;**"
  eq(text, lookalike .. " &", "decoded token-looking text remains literal")
  eq(
    highlights,
    { { col = #lookalike + 1, end_col = #lookalike + 2, hl = "Bold" } },
    "only the final ampersand is bold"
  )
  local _, _, links = markdown.render "[X](https://example.invalid/&#xF1004;3&#xF1005;&amp;)"
  eq(
    links,
    { { col_start = 0, col_end = 1, url = "https://example.invalid/" .. lookalike .. "&" } },
    "URL token-looking text"
  )
end)

test("removing markup cannot turn original PUA text into restoration tokens", function()
  for _, case in ipairs {
    { "\u{F1004}", "\u{F1005}", "&amp;", "&" },
    { "\u{F1002}", "\u{F1003}", "\\*", "*" },
  } do
    local literal = case[1] .. case[1] .. "1" .. case[2]
    for _, comment in ipairs { "<!-- -->", "%% %%" } do
      local text = markdown.render(case[1] .. comment .. case[1] .. "1" .. case[2] .. " " .. case[3])
      eq(text, literal .. " " .. case[4], "comment-joined PUA text")
    end
    local text, highlights = markdown.render(case[1] .. "**" .. case[1] .. "1" .. case[2] .. "** " .. case[3])
    eq(text, literal .. " " .. case[4], "style-joined PUA text")
    eq(highlights, { { col = #case[1], end_col = #literal, hl = "Bold" } }, "literal PUA style range")
    local _, _, links = markdown.render(
      "[X](https://example.invalid/" .. case[1] .. "<!-- -->" .. case[1] .. "1" .. case[2] .. case[3] .. ")"
    )
    eq(
      links,
      { { col_start = 0, col_end = 1, url = "https://example.invalid/" .. literal .. case[4] } },
      "comment-joined PUA destination"
    )
  end
end)

test("entity protection preserves source punctuation next to underscore emphasis", function()
  -- CommonMark 0.31.2 uses the original reference's punctuation for flanking,
  -- even when its replacement is a letter rather than punctuation.
  for _, case in ipairs {
    { "&amp;_hi_", "&hi", 1 },
    { "_hi_&amp;", "hi&", 0 },
    { "&amp;_hi_&amp;", "&hi&", 1 },
    { "&#35;_hi_", "#hi", 1 },
    { "&auml;_hi_", "ähi", 2 },
    { "_hi_&auml;", "hiä", 0 },
    { "&#65;_hi_", "Ahi", 1 },
  } do
    local text, highlights = markdown.render(case[1])
    eq(text, case[2], case[1] .. " text")
    eq(highlights, { { col = case[3], end_col = case[3] + 2, hl = "Italic" } }, case[1] .. " emphasis")
  end
  local literal = "a_hi_b \u{F1004}_hi_"
  local text, highlights = markdown.render(literal)
  eq(text, literal, "ordinary word and PUA boundaries remain literal")
  eq(highlights, {}, "a raw PUA character is not an entity token")
end)

test("footnote lookup retains the original entity spelling", function()
  for _, label in ipairs { "&amp;", "&#65;" } do
    local text, highlights, links = markdown.render("[^" .. label .. "]", nil, nil, nil, { [label] = 1 })
    eq(text, "¹", label .. " footnote number")
    eq(highlights, { { col = 0, end_col = 2, hl = "Special" } }, label .. " footnote style")
    eq(links, { { col_start = 0, col_end = 2, url = "#footnote-def-" .. label } }, label .. " original footnote anchor")
  end
end)

test("reference destinations decode without a second restoration pass", function()
  local builder = require("md-render.content_builder").ContentBuilder.new()
  builder:render_document(
    { "[foo][id]", "", "[id]: https://example.invalid/&#xF00A;\\*?q=\\&amp;" },
    { max_width = 80, text_scale = false }
  )
  local content = builder:result()
  eq(#content.link_metadata, 1, "one reference link")
  eq(content.link_metadata[1].url, "https://example.invalid/\u{F00A}*?q=&amp;", "reference destination")
end)

test("fence info decodes while fenced content stays literal", function()
  local builder = require("md-render.content_builder").ContentBuilder.new()
  builder:render_document({ "``` f&ouml;&ouml;", "&ouml; &#65;", "```" }, { max_width = 80, text_scale = false })
  local content = builder:result()
  eq(#content.code_blocks, 1, "one fenced code block")
  eq(content.code_blocks[1].language, "föö", "CommonMark example 34 info string")
  eq(content.code_blocks[1].source_lines, { "&ouml; &#65;" }, "code block references stay literal")
  for _, lines in ipairs {
    { "> ``` f&ouml;&ouml;", "> &ouml;", "> ```" },
    { "> [!NOTE]", "> ~~~ f&ouml;&ouml;", "> &ouml;", "> ~~~" },
    { "- item", "", "  ``` f&ouml;&ouml;", "  &ouml;", "  ```" },
  } do
    local nested = require("md-render.content_builder").ContentBuilder.new()
    nested:render_document(lines, { max_width = 80, text_scale = false })
    local block = nested:result().code_blocks[1]
    eq(block.language, "föö", "nested fence info")
    eq(block.source_lines, { "&ouml;" }, "nested code remains literal")
  end
end)

test("fence syntax is determined before info decoding", function()
  local fence = require "md-render.fence"
  for _, case in ipairs {
    { "``` &Tab;lua&#9;extra", "lua\textra", "lua" },
    { "``` lang&#96;", "lang`", "lang`" },
    { "~~~ lang`", "lang`", "lang`" },
    { "``` \\&amp;", "&amp;", "&amp;" },
    { "``` &#92;&#42;", "\\*", "\\*" },
    { "``` &#0;", "�", "�" },
  } do
    local opening = assert(fence.opening(case[1]))
    eq(opening.info, case[2], case[1] .. " info")
    eq(opening.lang, case[3], case[1] .. " language")
  end
  eq(fence.opening "``` lang\\`", nil, "raw backticks still invalidate a backtick fence")
end)

test("numeric references are not repository issue references", function()
  local text, _, links = markdown.render("&#35; &#65; &#x1F600; &AElig;", "https://github.com/example/project")
  eq(text, "# A 😀 Æ", "entity text with repository context")
  eq(links, {}, "entities must not create issue links")
end)

print(string.format("character_references_test: %d checks, %d failed groups", checks, failures))
if failures > 0 then os.exit(1) end
