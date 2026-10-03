-- Bound interpreter work instead of imposing machine-dependent timing limits.
-- Run: NVIM_LOG_FILE=/tmp/md-render-scaling.log timeout 10s nvim --headless -u NONE --noplugin -i NONE -l tests/parser_scaling_test.lua
-- Growth benchmark: prefix the command with MD_RENDER_PARSER_BENCHMARK=1 (use timeout 30s).
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local markdown = require "md-render.markdown"
local inline = require "md-render.inline"
jit.off()

local function measured(render, budget)
  local instructions = 0
  debug.sethook(function()
    instructions = instructions + 1000
    assert(instructions < (budget or 30000000), "paragraph exceeded its bounded parser work budget")
  end, "", 1000)
  local result = { pcall(render) }
  debug.sethook()
  assert(result[1], result[2])
  return instructions, unpack(result, 2)
end

local function bounded(source, expected, expected_link, budget)
  local instructions, text, _, links = measured(function()
    return markdown.render(source)
  end, budget)
  assert(text == expected, "large paragraph changed visible text")
  if expected_link then
    assert(#links == 1 and links[1].url == expected_link, "unmatched brackets changed URL ownership")
    assert(text:sub(links[1].col_start + 1, links[1].col_end) == "www.example.com", "URL byte positions changed")
  end
  return instructions
end

local brackets = string.rep("[", 4000)
bounded(brackets, brackets)
bounded(brackets .. " www.example.com", brackets .. " www.example.com", "http://www.example.com")
for _, body in ipairs {
  { "`x`", "x" },
  { "&amp;", "&" },
  { "*x*", "x" },
  { "<https://example.com>", "https://example.com" },
} do
  local opening, closing = string.rep("[ ", 4000), string.rep(" ]", 4000)
  bounded(opening .. body[1] .. closing, opening .. body[2] .. closing)
end
bounded(string.rep("**x** ", 4000), string.rep("x ", 4000))

-- Recursion limits are a presentation ceiling; rejected nesting stays readable.
-- Large flat valid inputs remain supported, and later normal content still works.
local depth_limit = 32
local function html(n, closed)
  return string.rep("<b>", n) .. "中" .. (closed and string.rep("</b>", n) or "")
end
for _, depth in ipairs { depth_limit - 1, depth_limit, depth_limit + 1, 3200 } do
  local source = html(depth, true)
  local expected = depth <= depth_limit and "中" or source
  bounded(source, expected)
  local _, rendered = measured(function()
    return markdown.render_html(source)
  end)
  assert(rendered == expected, "raw HTML and inline HTML have the same nesting fallback")
end
for _, tag in ipairs { "<b>", '<a href="u">', "<video>" } do
  local source = string.rep(tag, 4000) .. "中"
  bounded(source, source)
end
for _, body in ipairs { "中", '<source src="clip.mp4">' } do
  local source = string.rep("<video>", 4000) .. body .. string.rep("</video>", 4000)
  bounded(source, source)
  local _, parsed = measured(function()
    return inline.scan(source)
  end)
  assert(parsed.standard_ranges[1].link == (body ~= "中" and true or nil), "nested video source ownership")
end
local video = '<video><source src="outer.mp4"><video></video></video><source src="later.mp4">'
local video_ranges = inline.scan(video).standard_ranges
assert(video_ranges[1].link and not video_ranges[3].link, "video sources before an opener cannot belong to it")
video_ranges = inline.scan('<video></video><source src="later.mp4">').standard_ranges
assert(not video_ranges[1].link, "video source lookup cannot pass its closing tag")
bounded(string.rep("<b>中</b>", 4000), string.rep("中", 4000))
bounded(string.rep("<b><i>中</i></b>", 2000), string.rep("中", 2000))
bounded(string.rep("[中](<b>) ", 2000), string.rep("中 ", 2000))
bounded(string.rep("\\<b>", 2000), string.rep("<b>", 2000))

for _, pathological in ipairs {
  html(3200, true),
  string.rep('<a href="u">', 2000) .. string.rep("</a>", 2000),
  string.rep("<video>", 2000) .. '<source src="clip.mp4">' .. string.rep("</video>", 2000),
  string.rep("![", 4000) .. "*中*" .. string.rep("](u)", 4000),
} do
  local _, text, _, links = measured(function()
    return markdown.render(
      "前 [先](before.md) " .. pathological .. " 尾 [正常](after.md) `中 & long literal content`"
    )
  end)
  local found = {}
  for _, link in ipairs(links) do
    if link.url == "before.md" or link.url == "after.md" then
      found[link.url] = text:sub(link.col_start + 1, link.col_end)
    end
  end
  assert(
    found["before.md"] == "先" and found["after.md"] == "正常",
    "same-paragraph links retain UTF-8 byte positions"
  )
  assert(text:find("中 & long literal content", 1, true), "literal token expansion remains intact after fallback")
end

for _, render in ipairs { markdown.render, markdown.render_html } do
  local source = '<a href="before.md">先</a> ' .. html(3200, true) .. ' <a href="after.md">正常</a>'
  local _, text, _, links = measured(function()
    return render(source)
  end)
  assert(#links == 2, "excessive HTML owner does not suppress surrounding HTML links")
  assert(
    links[1].url == "before.md" and text:sub(links[1].col_start + 1, links[1].col_end) == "先",
    "preceding HTML link"
  )
  assert(
    links[2].url == "after.md" and text:sub(links[2].col_start + 1, links[2].col_end) == "正常",
    "following HTML link"
  )
end

for _, depth in ipairs { depth_limit - 1, depth_limit, depth_limit + 1, 4000 } do
  local source = string.rep("![", depth) .. "*中*" .. string.rep("](u)", depth)
  local _, rendered = measured(function()
    return markdown.render(source)
  end)
  local body = depth <= depth_limit and "中" or "*中*"
  local expected = "!" .. string.rep("![", depth - 2) .. body .. string.rep("](u)", depth - 2)
  assert(rendered == expected, "deep image labels retain their literal tail")
end

local ContentBuilder = require("md-render.content_builder").ContentBuilder
local display = require "md-render.display_utils"
local link_mod = require "md-render.links"
require("md-render.image").supports_kitty = function()
  return false
end
require("md-render").setup_highlights()
local function document(source)
  local original = vim.deepcopy(source)
  local _, content = measured(function()
    local builder = ContentBuilder.new()
    builder:render_document(source, { max_width = 40000, indent = "", text_scale = false })
    return builder:result()
  end)
  assert(vim.deep_equal(source, original), "bounded parsing must not mutate source")
  for row, src in ipairs(content.source_line_map) do
    assert(content.lines[row] and src >= 1 and src <= #source, "bounded parsing keeps original source rows")
  end
  local buf, ns = vim.api.nvim_create_buf(false, true), vim.api.nvim_create_namespace "parser_scaling"
  display.apply_content_to_buffer(buf, ns, content)
  for _, link in ipairs(content.link_metadata) do
    assert(link.col_start >= 0 and link.col_end <= #content.lines[link.line + 1], "link byte bounds after fallback")
    assert(link_mod.at(buf, ns, link.line, link.col_start) == link.url, "fallback keeps actual link extmarks")
  end
  vim.api.nvim_buf_delete(buf, { force = true })
  return content
end
local function following_content(source)
  local normal_src = #source + 2
  vim.list_extend(source, { "", "尾 [正常](after.md)", "", "# 結尾" })
  local content = document(source)
  local found
  for _, link in ipairs(content.link_metadata) do
    if link.url == "after.md" then
      assert(content.source_line_map[link.line + 1] == normal_src, "normal link keeps its physical source row")
      assert(
        content.lines[link.line + 1]:sub(link.col_start + 1, link.col_end) == "正常",
        "normal UTF-8 label after fallback"
      )
      found = true
    end
  end
  assert(found, "normal content after bounded input must still render")
  local heading = assert(content.heading_anchors["結尾"], "normal heading after fallback keeps its anchor")
  assert(content.source_line_map[heading + 1] == #source, "heading navigation keeps its physical source row")
  return content
end
for _, depth in ipairs { depth_limit - 1, depth_limit, depth_limit + 1, 2000 } do
  local prefix = string.rep("> ", depth)
  local content = following_content { prefix .. "中" }
  local expected = string.rep("│ ", math.min(depth, depth_limit))
    .. string.rep("> ", math.max(0, depth - depth_limit))
    .. "中"
  assert(content.lines[1] == expected, "over-limit quote markers remain literal")
  assert(content.source_line_map[1] == 1, "quote fallback keeps source row")
  bounded(prefix .. "中", expected)
end
for _, depth in ipairs { depth_limit, depth_limit + 1 } do
  local prefix = string.rep("> ", depth)
  local content = following_content { prefix .. "- item", prefix .. "  child", "lazy" }
  assert(table.concat(content.lines, "\n"):find("child", 1, true), "deep quoted list retains its child")
  assert(table.concat(content.lines, "\n"):find("lazy", 1, true), "deep quote retains lazy continuation text")
  content = following_content { prefix .. "```lua", prefix .. "CODE", prefix .. "```" }
  assert(table.concat(content.lines, "\n"):find("CODE", 1, true), "deep quoted fence retains source content")
  local source = { prefix .. "[nested]: /quoted", "", "[use][nested]" }
  content = following_content(source)
  local refs, consumed = markdown.parse_reference_links { prefix .. "[nested]: /quoted" }
  if depth <= depth_limit then
    assert(refs.nested == "/quoted" and consumed[1], "accepted quote depth may define a reference")
  else
    assert(not refs.nested and not consumed[1], "over-limit quote tail cannot define a reference")
    assert(content.lines[1]:find("[nested]: /quoted", 1, true), "over-limit reference remains visible")
    for _, link in ipairs(content.link_metadata) do
      assert(link.url ~= "/quoted", "over-limit reference cannot become an active target")
    end
  end
end
following_content { string.rep("> - ", 2000) .. "中" }
following_content { html(3200, true) }
following_content { string.rep("![", 4000) .. "*中*" .. string.rep("](u)", 4000) }
local html_rows = following_content {
  "<div>",
  string.rep("<b>", depth_limit + 1),
  "中",
  string.rep("</b>", depth_limit + 1),
  '<a href="after-html.md">後</a>',
  "</div>",
}
local html_link
for _, link in ipairs(html_rows.link_metadata) do
  if link.url == "after-html.md" then html_link = link end
end
assert(
  html_link and html_rows.source_line_map[html_link.line + 1] == 5,
  "multiline HTML fallback retains following link source row"
)
local literal_quote =
  following_content { string.rep("> ", depth_limit + 1) .. "**中** [literal](must-stay-literal.md)" }
assert(
  literal_quote.lines[1]:find("> **中** [literal](must-stay-literal.md)", 1, true),
  "over-limit quote leaf stays literal"
)
for _, link in ipairs(literal_quote.link_metadata) do
  assert(link.url ~= "must-stay-literal.md", "over-limit literal quote cannot create an active target")
end
print "parser_scaling_test: pathological nesting, HTML and flat controls stay within the work budget and retain source navigation"

if vim.env.MD_RENDER_PARSER_BENCHMARK == "1" then
  print "scenario,n,median_ms,instructions (three runs; elapsed time is informational)"
  for _, case in ipairs {
    { "brackets", "[", "[" },
    { "brackets_www", "[", "[", " www.example.com" },
    { "formatted", "**x** ", "x " },
    { "formatted_www", "**x** ", "x ", "www.example.com" },
  } do
    for _, n in ipairs { 1000, 2000, 4000, 8000 } do
      local source, expected = string.rep(case[2], n) .. (case[4] or ""), string.rep(case[3], n) .. (case[4] or "")
      local samples, instructions = {}, nil
      for run = 1, 3 do
        collectgarbage "collect"
        local start = vim.uv.hrtime()
        instructions = bounded(source, expected, case[4] and "http://www.example.com", 30000000 * math.max(1, n / 4000))
        samples[run] = (vim.uv.hrtime() - start) / 1e6
      end
      table.sort(samples)
      print(string.format("%s,%d,%.3f,%d", case[1], n, samples[2], instructions))
    end
  end
end
