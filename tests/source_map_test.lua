-- Sparse byte provenance survives inline removal and token protection.
-- Run: nvim --headless -u NONE --noplugin -l tests/source_map_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local SourceMap = require "md-render.source_map"
local pass_count = 0
local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message .. ": " .. vim.inspect(actual))
  pass_count = pass_count + 1
end

local source = SourceMap.new "甲\n乙\n丙"
eq(source.runs, {
  { col = 0, source_line = 1 },
  { col = 4, source_line = 2 },
  { col = 8, source_line = 3 },
}, "UTF-8 ownership uses byte offsets")
eq({ source:at(3), source:at(4), source:at(8) }, { 1, 2, 3 }, "newline belongs to its preceding source row")
local middle = source:slice(4, 7)
middle:replace { { first = 0, last = 3, value = SourceMap.constant(3, 9) } }
eq(source:at(4), 2, "editing a slice cannot change its parent")

local clipped = SourceMap.new "ab\ncd\nef"
clipped:replace { { first = 1, last = 4 }, { first = 5, last = 7 } }
eq(clipped.length, 3, "one batch uses original source coordinates")
eq(clipped.runs, {
  { col = 0, source_line = 1 },
  { col = 1, source_line = 2 },
  { col = 2, source_line = 3 },
}, "deleted rows retain surviving character owners")

local expanded = SourceMap.new "ab\nc"
expanded:removals { { start = 5, count = -2 }, { start = 1, count = 1 } }
eq(expanded.length, 5, "removal deltas support expansion in original coordinates")
eq(expanded.runs, { { col = 0, source_line = 1 }, { col = 4, source_line = 2 } }, "inserted text keeps preceding owner")

local token_source = SourceMap.new "x`aa\nbb`y\nz"
local span = { placeholder = "TOKEN", content = "aa bb" }
local edits = {}
token_source:protect(edits, span, 1, 8, token_source:slice(2, 7))
token_source:replace(edits)
eq(token_source.length, 9, "protection contracts only token-owned source bytes")
token_source:replace { { first = 1, last = 6, value = span.sources } }
eq(
  { token_source:at(1), token_source:at(4), token_source:at(8) },
  { 1, 2, 3 },
  "restoration retains interior source rows"
)

local default_span = { placeholder = "P" }
local raw = SourceMap.new "a\nb"
raw:protect({}, default_span, 0, 3)
default_span.sources:replace { { first = 0, last = 3, value = SourceMap.constant(3, 7) } }
eq(default_span.raw_sources:at(2), 2, "raw and display token maps are independent")
eq(SourceMap.new("a\n"):slice(2, 2):at(0), 2, "an empty EOF slice keeps its boundary owner")

print(string.format("source_map_test: %d passed", pass_count))
