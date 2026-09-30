-- Accepted list markers stay consistent through source ownership and rendering.
-- CommonMark 0.31.2 examples 266, 281, 304; issue #32.
-- Run: NVIM_LOG_FILE=/tmp/compat-lists-nvim.log nvim --headless -u NONE --noplugin -l tests/list_items_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local Builder = require("md-render.content_builder").ContentBuilder
local markdown = require "md-render.markdown"
local display = require "md-render.display_utils"
local Links = require "md-render.links"
require("md-render.image").supports_kitty = function()
  return false
end
vim.env.TMUX, vim.env.TMUX_PANE = nil, nil
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
local function build(source)
  local original = vim.deepcopy(source)
  local b = Builder.new()
  b:render_document(source, { max_width = 120, indent = "", text_scale = false })
  eq(source, original, "source bytes unchanged")
  local c = b:result()
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "list_items_test"
  display.apply_content_to_buffer(buf, ns, c)
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), c.lines, "actual buffer text")
  local markers = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    if mark[4].hl_group == "Special" then
      markers[#markers + 1] = {
        c.source_line_map[mark[2] + 1],
        mark[3],
        mark[4].end_col,
        c.lines[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col),
      }
    end
  end
  for _, link in ipairs(c.link_metadata) do
    eq(Links.at(buf, ns, link.line, link.col_start), link.url, "first label byte activates full target")
    eq(Links.at(buf, ns, link.line, link.col_end - 1), link.url, "last label byte activates full target")
    eq(Links.at(buf, ns, link.line, link.col_end), nil, "byte after label has no target")
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  return c, markers
end

test("empty items retain markers and physical source rows", function()
  local c, markers = build { "- foo", "-", "- \t", "- bar" }
  eq(c.lines, { "• foo", "• ", "• ", "• bar" }, "empty bullets")
  eq(c.source_line_map, { 1, 2, 3, 4 }, "empty item ownership")
  eq(
    markers,
    { { 1, 0, 4, "• " }, { 2, 0, 4, "• " }, { 3, 0, 4, "• " }, { 4, 0, 4, "• " } },
    "empty marker spans"
  )
  c, markers = build { "0)", "7) \t", "1) [next](/exact)" }
  eq(c.lines, { "0) ", "1) ", "2) next" }, "empty ordered items still number")
  eq(c.source_line_map, { 1, 2, 3 }, "ordered item rows")
  eq(markers, { { 1, 0, 3, "0) " }, { 2, 0, 3, "1) " }, { 3, 0, 3, "2) " } }, "ordered marker spans")
  c, markers = build { "999999999.", "1." }
  eq(c.lines, { "999999999. ", "1000000000. " }, "empty display numbering can also grow")
  eq(markers, { { 1, 0, 11, "999999999. " }, { 2, 0, 12, "1000000000. " } }, "grown empty marker spans")
  for _, case in ipairs {
    { { "-", "outside" }, { "• ", "outside" }, { 1, 2 } },
    { { "-       ", "  inside" }, { "• ", "  inside" }, { 1, 2 } },
    { { "-", "", "  outside" }, { "• ", "", "  outside" }, { 1, 2, 3 } },
    { { "> -", ">", ">   outside" }, { "│ • ", "│ ", "│   outside" }, { 1, 2, 3 } },
  } do
    c = build(case[1])
    eq(c.lines, case[2], "empty item content needs its own accepted container")
    eq(c.source_line_map, case[3], "empty and following paragraphs keep physical rows")
  end
end)

test("invalid and non-interrupting markers remain paragraph content", function()
  for _, delimiter in ipairs { ".", ")" } do
    local c, markers = build { "1234567890" .. delimiter .. " not ok" }
    eq(c.lines, { "1234567890" .. delimiter .. " not ok" }, "ten digit text")
    eq(markers, {}, "ten digit text has no list style")
    c, markers = build { "The number of windows in my house is", "14" .. delimiter .. "  The number of doors is 6." }
    eq(
      c.lines,
      { "The number of windows in my house is 14" .. delimiter .. " The number of doors is 6." },
      "one paragraph"
    )
    eq(c.source_line_map, { 1 }, "paragraph source ownership")
    eq(markers, {}, "non-interrupting number has no list style")
  end
  for _, empty in ipairs { "+", "1)", "1) \t", "2." } do
    local c, markers = build { "paragraph", empty }
    eq(c.lines, { "paragraph " .. vim.trim(empty) }, "empty marker cannot interrupt")
    eq(markers, {}, "empty paragraph text has no marker style")
  end
  eq(markdown.is_block_start("1) item", true), true, "ordered one interrupts")
  eq(markdown.is_block_start("0) item", true), false, "ordered zero cannot interrupt")
  for _, case in ipairs {
    { { "- outer", "  7) child", "  7) again" }, { "• outer 7) child 7) again" } },
    { { "> paragraph", "> 14. text" }, { "│ paragraph 14. text" } },
    { { "> paragraph", "> +", "> 14. text" }, { "│ paragraph + 14. text" } },
  } do
    local c, markers = build(case[1])
    eq(c.lines, case[2], "container paragraphs use the same interruption rule")
    eq(markers, case[1][1]:match "^-" and { { 1, 0, 4, "• " } } or {}, "rejected nested/quoted marker spans")
  end
end)

test("consumed definitions keep the source paragraph interruption decision", function()
  for _, prefix in ipairs { "", "> " } do
    for _, definition in ipairs { { "[r]: /safe" }, { "[r]:", "  /safe" }, { "[r]: /safe", '  "title', '  across"' } } do
      local source = vim.tbl_map(function(line)
        return prefix .. line
      end, definition)
      source[#source + 1] = prefix .. "9. [link][r]"
      source[#source + 1] = prefix .. "9. next"
      local c, markers = build(source)
      local display_prefix = prefix ~= "" and "│ " or ""
      eq(c.lines, { display_prefix .. "9. link 9. next" }, "non-one markers continue the source paragraph")
      eq(c.source_line_map, { #definition + 1 }, "definition consumption keeps paragraph source owner")
      eq(markers, {}, "consumption cannot turn rejected marker text into items")
      eq(c.link_metadata[1].url, "/safe", "definition destination preserved")
    end
  end
end)

test("valid markers, marker changes, tabs and tasks retain ownership", function()
  local c, markers = build { "0. zero", "1. one", "1) changed", "1)", "+ plus", "* star", "- dash" }
  eq(
    c.lines,
    { "0. zero", "1. one", "1) changed", "2) ", "• plus", "• star", "• dash" },
    "marker changes restart lists"
  )
  eq(c.source_line_map, { 1, 2, 3, 4, 5, 6, 7 }, "changed marker rows")
  eq(#markers, 7, "every accepted marker owns its row")
  c, markers = build { "999999999. first", "1. [next](/right)", "", "-\titem", "\t- nested", "- [ ] task" }
  eq(
    c.lines,
    { "999999999. first", "1000000000. next", "", "• item", "    ▪ nested", "󰄱  task" },
    "valid digits, tabs and tasks"
  )
  eq(markers[2], { 2, 0, 12, "1000000000. " }, "display number growth keeps full marker span")
  eq(c.source_line_map, { 1, 2, 3, 4, 5, 6 }, "tabbed rows remain physical")
  c, markers = build { "```", "-", "14. literal", "1234567890. literal", "```", "- item" }
  eq(c.lines, { "-", "14. literal", "1234567890. literal", "• item" }, "code owns marker text")
  eq(markers, { { 6, 0, 4, "• " } }, "only outside marker is styled")
  c, markers = build { "- - -" }
  eq(markers, {}, "thematic break takes precedence")
  eq(c.heading_lines, {}, "thematic break is not a heading")
end)

test("public preview rebuild preserves accepted markers and source", function()
  local preview = require "md-render.preview"
  local source = { "- foo", "-", "- [next](/exact)", "", "paragraph", "14. text", "", "1234567890. literal" }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
  vim.api.nvim_set_current_buf(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local ok, err = pcall(function()
    preview.toggle { text_scale = false, max_width = 120 }
    local session = assert(preview._toggle_sessions[buf])
    for step = 1, 2 do
      eq(
        session.content.lines,
        { "  • foo", "  • ", "  • next", "  ", "  paragraph 14. text", "  ", "  1234567890. literal" },
        "public text"
      )
      eq(session.content.source_line_map, { 1, 2, 3, 4, 5, 7, 8 }, "public source rows")
      eq(vim.api.nvim_buf_get_lines(session.buf, 0, -1, false), session.content.lines, "public actual buffer")
      local link = session.content.link_metadata[1]
      eq(Links.at(session.buf, session.ns, link.line, link.col_start), "/exact", "public full target")
      if step == 1 then session:rebuild() end
    end
  end)
  if preview._toggle_sessions[buf] then preview.toggle() end
  eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), source, "preview recovers exact source")
  eq(vim.api.nvim_buf_get_changedtick(buf), tick, "preview leaves source changedtick")
  vim.api.nvim_buf_delete(buf, { force = true })
  assert(ok, err)
end)
print(string.format("list_items_test: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
