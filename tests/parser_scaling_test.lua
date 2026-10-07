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

-- Lua instruction hooks cannot see C string searches or suffix copies. Count their byte ranges,
-- including failed comment candidates and redundant quantifier backtracking.
local function native_measured(render, source_bytes)
  local find, match, gsub, sub = string.find, string.match, string.gsub, string.sub
  local bytes = 0
  local delimiters = { [">"] = true, ["-->"] = true, ["?>"] = true, ["]]>"] = true, ['"'] = true, ["'"] = true }
  local comment = "<!%-%-.-%-%->"
  local old_comment = "<!%-%-.-%-*%-%->"
  local function charge(count)
    bytes = bytes + math.max(0, count)
    assert(bytes <= 64 * source_bytes, "paragraph exceeded its native string-work byte budget")
  end
  local function comment_work(text, first, redundant)
    local _, finish = find(text, "-->", first + 4, true)
    charge((finish or #text) - first - 3)
    if redundant and finish then
      for run, tail in text:sub(first + 4, finish - 3):gmatch "(%-+)([^%-])" do
        if tail ~= ">" then charge(#run * (#run + 1) / 2) end
      end
    end
    return finish
  end
  string.find = function(text, pattern, first, plain)
    first = first or 1
    if pattern == "^" .. old_comment and match(text, "^<!%-%-", first) then comment_work(text, first, true) end
    local a, b = find(text, pattern, first, plain)
    if plain and delimiters[pattern] or pattern == "[<>%z\1-\32\127]" then charge((b or #text) - first + 1) end
    return a, b
  end
  string.match = function(text, pattern, first)
    first = first or 1
    if pattern == "^.*()%-%->" then
      charge(#text - first + 1)
    elseif pattern == "^<![A-Za-z]+[^>]*>()" then
      local name_end = match(text, "^<![A-Za-z]+()", first)
      if name_end then
        local finish = find(text, ">", first + 3, true)
        charge((finish or #text) - first + 1)
        if not finish then charge((name_end - first - 2) ^ 2 / 2) end
      end
    end
    return match(text, pattern, first)
  end
  string.gsub = function(text, pattern, replace, limit)
    if pattern == comment or pattern == old_comment then
      local pos = 1
      while pos <= #text do
        local first = find(text, "<!--", pos, true)
        if not first then break end
        local finish = comment_work(text, first, pattern == old_comment)
        pos = finish and finish + 1 or first + 1
      end
    end
    return gsub(text, pattern, replace, limit)
  end
  string.sub = function(text, first, last)
    local result = sub(text, first, last)
    if not last and first > 1 then charge(#result) end
    return result
  end
  local result = { pcall(render) }
  string.find, string.match, string.gsub, string.sub = find, match, gsub, sub
  assert(result[1], result[2])
  return bytes, unpack(result, 2)
end

for _, source in ipairs {
  string.rep("<!--", 8000),
  string.rep("<?", 8000),
  string.rep("<![CDATA[", 3000),
  string.rep("<!D", 8000),
  "<!" .. string.rep("D", 8000),
} do
  for _, render in ipairs { markdown.render, markdown.render_html, inline.hide_html_comments } do
    local _, text = native_measured(function()
      return render(source)
    end, #source)
    assert(text == source, "unmatched HTML remains readable under the native work budget")
  end
  native_measured(function()
    return inline.scan(source)
  end, #source)
end

for _, render in ipairs { markdown.render, markdown.render_html } do
  local flat = string.rep("<b>中</b>", 4000)
  local _, rendered = native_measured(function()
    return render(flat)
  end, #flat)
  assert(rendered == string.rep("中", 4000), "large flat HTML avoids repeated suffix copies")
  local source = "前<!--" .. string.rep("-", 8000) .. "x-->後"
  local _, text = native_measured(function()
    return render(source)
  end, #source)
  assert(text == "前後", "long paired comment retains its original closing semantics")
  local unmatched = string.rep("<!--", 8000)
  source = unmatched .. ' <b>後</b> <a href="after.md">正常</a>'
  local _, following, _, links = native_measured(function()
    return render(source)
  end, #source)
  assert(following == unmatched .. " 後 正常", "native search fallback cannot suppress later HTML")
  assert(
    #links == 1 and links[1].url == "after.md" and following:sub(links[1].col_start + 1, links[1].col_end) == "正常",
    "native search fallback preserves later UTF-8 links"
  )
end
for _, case in ipairs {
  { "前<!-->尾", "前尾" },
  { "前<!--->尾", "前尾" },
  { "前<!-->隱藏--><!--正常-->尾", "前隱藏-->尾" },
  { "前<!--->隱藏--><!--正常-->尾", "前隱藏-->尾" },
} do
  assert(markdown.render(case[1]) == case[2], "normal comments retain complete short-token boundaries")
  assert(markdown.render_html(case[1]) == case[2], "raw comments retain complete short-token boundaries")
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
for _, depth in ipairs { depth_limit, depth_limit + 1 } do
  local source = string.rep("<b>", depth) .. "&amp;<!--secret-->" .. string.rep("</b>", depth)
  local expected = depth <= depth_limit and "&" or source
  for _, render in ipairs { markdown.render, markdown.render_html } do
    local _, rendered = measured(function()
      return render(source)
    end)
    assert(rendered == expected, "literal HTML fallback must retain entity spelling and comments")
  end
end
local literal_html = string.rep("<b>", depth_limit + 1)
  .. "&amp;<!--secret-->\u{F1004}1\u{F1005}"
  .. string.rep("</b>", depth_limit + 1)
local token_entities = "&#" .. 0xF100C .. ";1&#" .. 0xF100D .. ";"
for _, render in ipairs { markdown.render, markdown.render_html } do
  local _, rendered, _, links = measured(function()
    return render(
      '<a href="before&amp;.md">前&amp;</a> '
        .. literal_html
        .. " &amp; "
        .. token_entities
        .. ' <a href="after&amp;.md">後&amp;</a>'
    )
  end)
  assert(
    rendered == "前& " .. literal_html .. " & \u{F100C}1\u{F100D} 後&",
    "literal fallback and decoded entities cannot impersonate one another's tokens"
  )
  assert(
    #links == 2
      and links[1].url == "before&.md"
      and rendered:sub(links[1].col_start + 1, links[1].col_end) == "前&"
      and links[2].url == "after&.md"
      and rendered:sub(links[2].col_start + 1, links[2].col_end) == "後&",
    "entity restoration around literal HTML must retain decoded targets and UTF-8 link positions"
  )
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
-- Interpreter hooks cannot measure the native string scans inside URL trimming.
-- Explicit image/link ownership must exclude their labels before that work starts.
for _, scheme in ipairs { "http", "https" } do
  local destination = scheme .. "://x"
  local nested = string.rep("![", 4000) .. "中" .. string.rep("](" .. destination .. ")", 4000)
  local expected = "!" .. string.rep("![", 3998) .. "中" .. string.rep("](" .. destination .. ")", 3998)
  local trim = inline.trim_autolink
  inline.trim_autolink = function(url)
    assert(url:sub(1, #destination) ~= destination, "owned HTTP URL reached the bare URL trimmer")
    return trim(url)
  end
  local _, rendered, _, links = measured(function()
    return markdown.render("前: [先](before.md) " .. nested .. " 尾: [正常](after.md) https://later.example")
  end)
  inline.trim_autolink = trim
  assert(rendered == "前: 先 " .. expected .. " 尾: 正常 https://later.example", "owned HTTP label changed")
  local found = {}
  for _, link in ipairs(links) do
    found[link.url] = rendered:sub(link.col_start + 1, link.col_end)
  end
  assert(
    #links == 4
      and found[destination] == expected:sub(2)
      and found["before.md"] == "先"
      and found["after.md"] == "正常"
      and found["https://later.example"] == "https://later.example",
    "skipping owned HTTP labels must preserve surrounding UTF-8 links and bare URLs"
  )
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
  "中 &amp;<!--secret-->",
  string.rep("</b>", depth_limit + 1),
  '<a href="after-html.md">後</a>',
  "</div>",
}
local html_link
local literal_row
for row, text in ipairs(html_rows.lines) do
  if text:find("中 &amp;<!--secret-->", 1, true) then literal_row = row end
end
assert(literal_row and html_rows.source_line_map[literal_row] == 3, "literal HTML body retains its physical source row")
for _, link in ipairs(html_rows.link_metadata) do
  if link.url == "after-html.md" then html_link = link end
end
assert(
  html_link and html_rows.source_line_map[html_link.line + 1] == 5,
  "multiline HTML fallback retains following link source row"
)

-- Document display readers share the raw HTML owner's literal boundary.
-- A heading, fold, table or media row cannot reactivate its hidden children.
local opening_html, closing_html = string.rep("<b>", depth_limit + 1), string.rep("</b>", depth_limit + 1)
do
  -- Skipping literal-owned summary closers must retain failed delimiter state.
  local literal = string.rep(opening_html .. "<!--x</summary>" .. closing_html, 200)
  local source = {
    "<details open><summary>" .. literal .. '</summary><a href="body.md">體</a></details><a href="after.md">後</a>',
    "",
    "[next](next.md)",
  }
  local _, content = native_measured(function()
    local builder = ContentBuilder.new()
    builder:render_document(source, { max_width = 400000, indent = "", text_scale = false })
    return builder:result()
  end, #source[1])
  assert(content.lines[1] == "▼ " .. literal, "summary lookup preserves every malformed literal owner")
  assert(#content.link_metadata == 3, "literal summary cannot consume its normal body and following links")
  local labels = { ["body.md"] = "體", ["after.md"] = "後", ["next.md"] = "next" }
  for _, link in ipairs(content.link_metadata) do
    assert(
      content.lines[link.line + 1]:sub(link.col_start + 1, link.col_end) == labels[link.url],
      "bounded summary lookup retains normal UTF-8 link bytes"
    )
    assert(
      content.source_line_map[link.line + 1] == (link.url == "next.md" and 3 or 1),
      "bounded summary lookup retains physical source rows"
    )
  end
end
for _, middle in ipairs {
  '<h1><a href="hidden.md">中</a></h1>',
  '<details><summary><a href="hidden.md">中</a></summary>body</details>',
  '<table><tr><th><a href="hidden.md">中</a></th></tr></table>',
  '<img src="hidden.png" alt="中">',
  '<video src="hidden.mp4"></video>',
  '<div><a href="hidden.md">中</a></div>',
  '<span><a href="hidden.md">中</a></span>',
  '<p><a href="hidden.md">中</a></p>',
  '<figure><figcaption><a href="hidden.md">中</a></figcaption></figure>',
  '<dl><dt><a href="hidden.md">中</a></dt><dd>body</dd></dl>',
  "<!--literal &amp; comment-->",
} do
  local content = following_content { "<div>", opening_html, middle, closing_html, "</div>" }
  local found
  for row, line in ipairs(content.lines) do
    if line == middle then
      assert(content.source_line_map[row] == 3, "literal display row keeps its physical source")
      found = true
    end
  end
  assert(found, "document HTML display must preserve each literal-owned element")
  assert(#content.callout_folds == 0 and #content.image_placements == 0, "literal owners cannot open folds or media")
  for _, link in ipairs(content.link_metadata) do
    assert(
      link.url ~= "hidden.md" and link.url ~= "hidden.png" and link.url ~= "hidden.mp4",
      "literal target activated"
    )
  end
end
local inner_image = '<img src="hidden.png" alt="中">'
local literal_image = opening_html .. inner_image .. closing_html
local outer_heading = document { "<h1>前 " .. literal_image .. " 後</h1>" }
assert(
  outer_heading.lines[1] == "# 前 " .. literal_image .. " 後",
  "normal outer heading retains its literal image child"
)
assert(
  #outer_heading.image_placements == 0 and #outer_heading.link_metadata == 0,
  "heading cannot extract literal media"
)
assert(next(outer_heading.heading_anchors) ~= nil, "normal outer heading keeps navigation")

local sibling_html = '<a href="before.md">前</a> '
  .. opening_html
  .. '<a href="hidden.md">中</a>'
  .. closing_html
  .. ' <a href="after.md">後</a>'
local siblings = document { "<div>", sibling_html, "</div>" }
assert(#siblings.link_metadata == 2, "same-row normal HTML siblings remain active")
for _, link in ipairs(siblings.link_metadata) do
  local label = siblings.lines[link.line + 1]:sub(link.col_start + 1, link.col_end)
  assert(label == (link.url == "before.md" and "前" or "後"), "same-row sibling UTF-8 position")
  assert(siblings.source_line_map[link.line + 1] == 2, "same-row sibling source mapping")
end
local details_tail = "&amp;<!--literal-->" .. closing_html
local details = document {
  "<details open><summary>normal</summary>",
  opening_html,
  details_tail .. '</details><a href="after.md">後</a>',
  '<a href="outside.md">尾</a>',
  "",
}
local literal_tail, outside
for row, line in ipairs(details.lines) do
  if line:find(details_tail, 1, true) then
    literal_tail = true
    assert(details.source_line_map[row] == 3, "split details literal fragment keeps its source")
  end
  if line == "尾" then outside = true end
end
assert(literal_tail and outside, "literal details tail preserves spelling and closes its normal outer fold")
assert(#details.link_metadata == 2, "normal details suffix and following row remain active")

local unmatched_headings = { "<div>" }
for _ = 1, 1000 do
  unmatched_headings[#unmatched_headings + 1] = "<h1>"
end
unmatched_headings[#unmatched_headings + 1] = "</div>"
following_content(unmatched_headings)

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
