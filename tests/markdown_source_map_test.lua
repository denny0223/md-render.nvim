-- Source tracking follows the actual inline parser without changing its display.
-- Run: nvim --headless -u NONE --noplugin -l tests/markdown_source_map_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local Markdown = require "md-render.markdown"
local pass_count = 0
local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message .. ": " .. vim.inspect(actual))
  pass_count = pass_count + 1
end

local url_prefix = "https://example.com/" .. string.rep("x", 24)
local cases = {
  {
    name = "raw HTML closing-tag newline is not displayed",
    source = "甲<b>乙丙</b\n>丁",
    context = { raw_html = true },
    text = "甲乙丙丁",
    boundary = 9,
  },
  {
    name = "raw anchor closing-tag newline is not displayed",
    source = '甲<a href="/target">乙丙</a\n>丁',
    context = { raw_html = true },
    text = "甲乙丙丁",
    boundary = 9,
    url = "/target",
  },
  {
    name = "removing a multiline comment joins URL fragments from two source rows",
    source = "https://example.com/%%\nhidden%%乙",
    text = "https://example.com/乙",
    boundary = 20,
    url = "https://example.com/乙",
  },
  {
    name = "HTML comment removal retains the row after a short token in a link label",
    source = "[甲<!-- hidden\n-->乙<!-->丙](/target) tail",
    text = "甲乙丙 tail",
    boundary = 3,
    url = "/target",
  },
  {
    name = "HTML comment removal retains the row after a short token in emphasis",
    source = "**甲<!-- hidden\n-->乙<!--->丙** tail",
    text = "甲乙丙 tail",
    boundary = 3,
  },
  {
    name = "URL truncation keeps a visible suffix from the second source row",
    source = url_prefix .. "%%\nhidden%%乙丙丁戊 尾",
    text = url_prefix .. "乙丙… 尾",
    boundary = 44,
    url = url_prefix .. "乙丙丁戊",
  },
  {
    name = "URL truncation measures escaped and entity tokens before restoring them",
    source = url_prefix .. "%%\nhidden%%&#x4E59;\\_&#x4E19;丁戊 尾",
    text = url_prefix .. "乙_丙… 尾",
    boundary = 44,
    url = url_prefix .. "乙_丙丁戊",
  },
  {
    name = "nested HTML emphasis and code keep the code's interior source row",
    source = "甲<b>**乙`丙\n丁`戊**</b>己",
    text = "甲乙丙 丁戊己",
    boundary = 10,
  },
  {
    name = "code CRLF folding and single-space trimming retain physical source owners",
    source = "甲` 乙\r\n丙 `丁",
    text = "甲乙 丙丁",
    boundary = 7,
  },
  {
    name = "escapes and entities do not move the physical CJK join",
    source = "甲\\*乙\n丙&#x4E01;戊",
    text = "甲*乙丙丁戊",
    boundary = 7,
  },
  {
    name = "an entity LF is display whitespace rather than another source row",
    source = "甲&#10;乙\n丙",
    text = "甲 乙丙",
    boundary = 7,
  },
}

for _, case in ipairs(cases) do
  local control = { Markdown.render(case.source, nil, nil, nil, nil, nil, case.context) }
  local tracked = { Markdown.render(case.source, nil, nil, nil, nil, nil, case.context, true) }
  local normal_values, tracked_values = {}, {}
  for i = 1, 9 do
    normal_values[i], tracked_values[i] = control[i], tracked[i]
  end
  eq(tracked_values, normal_values, case.name .. ": the original nine return values")
  eq(control[10], nil, case.name .. ": ordinary rendering does not track source rows")
  eq(tracked[1], case.text, case.name .. ": exact display text")
  eq(tracked[10], {
    { col = 0, source_line = 1 },
    { col = case.boundary, source_line = 2 },
  }, case.name .. ": exact rendered byte owners")
  eq(tracked[2]._source_map, nil, case.name .. ": private tracking state does not escape")
  if case.url then eq(tracked[3][1].url, case.url, case.name .. ": untruncated navigation target") end
end

print(string.format("markdown_source_map_test: %d passed", pass_count))
