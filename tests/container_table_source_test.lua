-- Source ownership for GFM tables inside lists and blockquotes.
-- Run: nvim --headless -u NONE --noplugin -l tests/container_table_source_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local Builder = require("md-render.content_builder").ContentBuilder
require("md-render.image").supports_kitty = function()
  return false
end

local function build(lines)
  local builder = Builder.new()
  builder:render_document(lines, { indent = "", max_width = 80, text_scale = false })
  return builder:result()
end

local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end

local function rows_at(content, src)
  local rows = {}
  for i, source in ipairs(content.source_line_map) do
    if source == src then rows[#rows + 1] = content.lines[i] end
  end
  return rows
end

local function contains(content, src, text)
  for _, row in ipairs(rows_at(content, src)) do
    if row:find(text, 1, true) then return end
  end
  error(("missing %q at source %d: %s"):format(text, src, vim.inspect(content.lines)))
end

-- An image starts an ordinary table row. The following reference-looking row
-- is cell text, even though the same source spelling defines a link elsewhere.
local refs = build {
  "> H|B",
  "> -|-",
  "> ![map](image.png)|圖",
  "> [r]: /fake",
  "> [good]|LAST",
  "",
  "[r] [good]",
  "",
  "[good]: /real",
}
contains(refs, 4, "[r]: /fake")
contains(refs, 5, "LAST")
contains(refs, 7, "[r] good")
eq(
  vim.tbl_map(function(link)
    return { refs.source_line_map[link.line + 1], link.url }
  end, refs.link_metadata),
  { { 3, "image.png" }, { 5, "/real" }, { 7, "/real" } },
  "links belong to their source rows"
)

-- A marker shares its source with a confirmed header. A short delimiter
-- cannot split a task or steal the next item.
local task = build { "> - [x] HEAD | tail", ">   -|-", ">   cell|right", "> - [x] TODO" }
eq(#rows_at(task, 1), 2, "marker and header share the source")
contains(task, 1, "[x] HEAD")
contains(task, 3, "right")
assert(not rows_at(task, 4)[1]:find("[x]", 1, true), "ordinary task uses its checkbox")
local short = build { "> - [x] TODO | TAIL", ">  -|-", "> NEXT" }
eq(#short.lines, 1, "underindented delimiter leaves the task together")
contains(short, 1, "TAIL -|- NEXT")

local numbered = build { "> 8) A|B", ">    -|-", ">    a|b", "> 1) C|D|E", ">    -|-|-", ">    c|d|last", "> 1) end" }
contains(numbered, 1, "8)")
contains(numbered, 4, "9)")
contains(numbered, 6, "last")
contains(numbered, 7, "10) end")

local nested = build {
  "> - A|B",
  ">   -|-",
  ">   a|b",
  ">   - I|J|K",
  ">     -|-|-",
  ">     i|j|inner",
  ">   R|S",
  ">   -|-",
  ">   r|parent",
}
contains(nested, 6, "inner")
contains(nested, 9, "parent")
local mixed = build { "- > FIRST|B", "  > -|-", "  > v|w", "> - > SECOND|C", ">   > -|-", ">   > x|y" }
for _, idx in ipairs { 1, 4 } do
  eq(#rows_at(mixed, idx), 2, "mixed container marker and header share their source")
end

-- Only the header can borrow a paragraph's missing container marker.
local lazy = build { "> intro", "H|B", "> -|-", "> LOW|TAIL", "EXIT|OUT", "> LAST" }
contains(lazy, 2, "H")
contains(lazy, 4, "TAIL")
eq(rows_at(lazy, 5), { "EXIT|OUT" }, "an unmarked body row leaves the quote")
local missing = build { "> A|B", "-|-", "> LAST" }
eq(missing.lines, { "│ A|B -|- LAST" }, "an unmarked delimiter stays in its quote paragraph")
local list = build { "- intro", "H|B", "  -|-", "  LOW|TAIL", "EXIT|OUT" }
contains(list, 4, "TAIL")
contains(list, 5, "EXIT|OUT")
for _, prefix in ipairs { "", "> " } do
  local function source(lines)
    return vim.tbl_map(function(line)
      return prefix .. line
    end, lines)
  end
  local item = build(source { "- intro", "H|B", "  -|-", "  cell|tail" })
  contains(item, 2, "H")
  contains(item, 4, "tail")
  eq(#build(source { "- intro", "H|B", "-|-", "cell|tail" }).lines, 1, "missing list indentation keeps the paragraph")

  local ordered = build(source { "history", "2. A|B", "   -|-", "   data|tail" })
  contains(ordered, 2, "2. A")
  contains(ordered, 4, "tail")
  eq(#build(source { "2. A|B", "-|-", "cell|tail" }).lines, 1, "an opening ordered item owns its paragraph")
  local first = build(source { "history", "1. A|B", "-|-", "cell|tail" })
  contains(first, 2, "1. A|B -|- cell|tail")
end
local depth = build { "> > A|B", ">   > -|-", ">> X|Y" }
contains(depth, 3, "Y")

-- Quoted math keeps its literal source rows until the fence or container ends.
for _, inner in ipairs { "", "  " } do
  local math = { "> " .. inner .. "$$", "> " .. inner .. "A|B", "> " .. inner .. "-|-", "> " .. inner .. "x|y" }
  if inner ~= "" then
    table.insert(math, 1, ">")
    table.insert(math, 1, "> - intro")
  end
  local first = #math - 3
  for _, close in ipairs { true, false } do
    local source = vim.deepcopy(math)
    if close then source[#source + 1] = "> " .. inner .. "$$" end
    local prefix = (close or inner ~= "") and "> " or ""
    local after = #source + 1
    vim.list_extend(source, { prefix .. "after|header", prefix .. "-|-", prefix .. "end|value" })
    local content = build(source)
    for offset, literal in ipairs { "$$", "A|B", "-|-", "x|y" } do
      eq(rows_at(content, first + offset - 1), { "│ " .. inner .. literal }, "literal math row and physical source")
    end
    contains(content, after, "after")
    contains(content, after + 2, "value")
  end
end

print "Container table source ownership passed"
