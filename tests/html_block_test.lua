-- CommonMark 0.31.2 HTML-block boundaries; GFM 0.29-gfm uses this current core.
-- Run: NVIM_LOG_FILE=/tmp/compat-html-nvim.log nvim --headless -u NONE --noplugin -l tests/html_block_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local html = require "md-render.html_block"
local markdown = require "md-render.markdown"
local markdown_table = require "md-render.markdown_table"
local checks = 0
local function eq(actual, expected, label)
  assert(
    vim.deep_equal(actual, expected),
    label .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)
  )
  checks = checks + 1
end

for _, case in ipairs {
  { "<PRE", 1, "</style>*tail*" },
  { "<pre>", 1, "</pre>" },
  { "<script>", 1, "x</TEXTAREA>" },
  { "<style type='text/css'>", 1, "</pre>" },
  { "<textarea>", 1, "</script>" },
  { "<!--", 2, "-->*tail*" },
  { "<?php", 3, "?>*tail*" },
  { "<!doctype", 4, ">*tail*" },
  { "<![CDATA[", 5, "]]>*tail*" },
  { "<table><tr><td>", 6, "" },
  { "</DIV>", 6, "\t " },
  { "<search>", 6, "" },
  { "<source>", 7, "" },
  { '<a href="foo">', 7, "" },
  { "<custom-tag key='value'>", 7, "" },
  { "<pre-custom>", 7, "" },
  { "<script2>", 7, "" },
  { "<style-custom>", 7, "" },
  { "<textarea2>", 7, "" },
  { "</pre>", 7, "" },
} do
  local text, kind, closing = unpack(case)
  local interrupting = kind ~= 7 and kind or nil
  for _, indent in ipairs { "", " ", "   " } do
    eq(html.start(indent .. text), kind, "opening " .. indent .. text)
    eq(html.start(indent .. text, true), interrupting, "paragraph interruption " .. text)
  end
  eq(html.ends(kind, closing), true, "closing " .. text)
  eq(html.ends(kind, "*still raw*"), false, "continuation " .. text)
end

for _, text in ipairs {
  "    <div>",
  "\t<div>",
  "<pre/>",
  "<style=foo>",
  "<textarea/>",
  "<divx attr='x'>tail",
  "<div/foo>",
  "<span>tail",
  '<a href="unclosed>',
  "<a href=x@y>tail",
  "<!1>",
  "<![cdata[",
  "<https://example.com>",
  "<foo@bar.com>",
  "text <div>",
} do
  eq(html.start(text), nil, "invalid block opening " .. text)
end
eq(html.start "<scripture>", 7, "complete non-raw tag is type 7")
eq(html.start(" \t<div>", false, 1), 6, "tab uses the physical starting column")
eq(html.ends(1, "</pre >"), false, "raw closer requires the exact end tag")
eq(html.ends(6, "</table>"), false, "tag balance does not end a type-6 block")
eq(html.ends(7, "</a>"), false, "tag balance does not end a type-7 block")
eq(html.start "<?x?>", 3, "same-line processing instruction opening")
eq(html.ends(3, "<?x?>"), true, "same-line processing instruction close")

for _, text in ipairs { '<a href="foo">', "<span>", "<https://example.com>" } do
  eq(markdown.is_block_start(text, true), false, "inline token cannot interrupt a paragraph " .. text)
  eq(markdown_table.is_body_row(text, true), true, "inline token stays in an established paragraph " .. text)
end
for _, text in ipairs { "<textarea>", "<!doctype>", "<search>" } do
  eq(markdown.is_block_start(text, true), true, "current core interruption " .. text)
  eq(markdown_table.is_body_row(text, true), false, "current core table termination " .. text)
end
eq(markdown.is_block_start("<source>", true), false, "GFM's old source type-6 tag follows current type-7 grammar")

print("html_block_test: " .. checks .. " passed")
