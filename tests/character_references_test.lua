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
print(string.format("character_references_test: %d checks, %d failed groups", checks, failures))
if failures > 0 then os.exit(1) end
