-- CommonMark 0.31.2 examples 596/604 and GFM 0.29 examples 622-635.
-- https://spec.commonmark.org/0.31.2/#autolinks
-- https://github.github.com/gfm/#autolinks-extension-
-- Run: nvim --headless -u NONE --noplugin -l tests/autolinks_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local markdown = require "md-render.markdown"
local Builder = require("md-render.content_builder").ContentBuilder
local display = require "md-render.display_utils"
local Links = require "md-render.links"
local preview = require "md-render.preview"
local image = require "md-render.image"
local pass_count, fail_count = 0, 0

local function eq(actual, expected, message)
  assert(
    vim.deep_equal(actual, expected),
    message .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual)
  )
  pass_count = pass_count + 1
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("FAIL " .. name .. ": " .. tostring(err))
  end
end

local function check(text, highlights, links, expected, targets)
  eq(text, expected, "visible text")
  local wanted, wanted_hls, offset = {}, {}, 1
  for _, target in ipairs(targets) do
    local first, last = assert(text:find(target[1], offset, true))
    wanted[#wanted + 1] = { col_start = first - 1, col_end = last, url = target[2] }
    wanted_hls[#wanted_hls + 1] = { col = first - 1, end_col = last, hl = "MdRenderLink" }
    offset = last + 1
  end
  table.sort(links, function(a, b)
    return a.col_start < b.col_start
  end)
  eq(links, wanted, "complete destinations and exact UTF-8 byte ranges")
  local link_hls = vim.tbl_filter(function(hl)
    return hl.hl == "MdRenderLink"
  end, highlights)
  table.sort(link_hls, function(a, b)
    return a.col < b.col
  end)
  eq(link_hls, wanted_hls, "one highlight per linked label")
end

local balanced = "www.google.com/search?q=Markup+(business)"
local encrypted = "https://encrypted.google.com/search?q=Markup+(business)"
local shortened = encrypted:sub(1, 49) .. "…"
local cases = {
  { "GFM 629 HTTP", "http://commonmark.org", nil, { { "http://commonmark.org", "http://commonmark.org" } } },
  { "existing HTTP single-label host", "https://localhost", nil, { { "https://localhost", "https://localhost" } } },
  {
    "HTTP balances restored rejected destination parentheses",
    "https://example.com/[x](foo<!-- -->bar)",
    "https://example.com/[x](foobar)",
    { { "https://example.com/[x](foobar)", "https://example.com/[x](foobar)" } },
  },
  {
    "existing HTTP adjacent Unicode",
    "前https://example.com",
    nil,
    { { "https://example.com", "https://example.com" } },
  },
  { "GFM 629 balanced", "(Visit " .. encrypted .. ")", "(Visit " .. shortened .. ")", { { shortened, encrypted } } },
  {
    "CM 596",
    "<irc://foo.bar:2233/baz>",
    "irc://foo.bar:2233/baz",
    { { "irc://foo.bar:2233/baz", "irc://foo.bar:2233/baz" } },
  },
  {
    "CM 604",
    "<foo@bar.example.com>",
    "foo@bar.example.com",
    { { "foo@bar.example.com", "mailto:foo@bar.example.com" } },
  },
  { "GFM 622", "www.commonmark.org", nil, { { "www.commonmark.org", "http://www.commonmark.org" } } },
  {
    "www within ordinary brackets",
    "[ hello www.example.com ]",
    nil,
    { { "www.example.com", "http://www.example.com" } },
  },
  {
    "www within an invalid explicit label",
    "[ hello www.example.com ](bad dest)",
    nil,
    { { "www.example.com", "http://www.example.com" } },
  },
  {
    "www within an unresolved reference label",
    "[ hello www.example.com ][missing]",
    nil,
    { { "www.example.com", "http://www.example.com" } },
  },
  {
    "www after a rejected destination opener",
    "[x](www.example.com bad)",
    nil,
    { { "www.example.com", "http://www.example.com" } },
  },
  {
    "GFM 623",
    "Visit www.commonmark.org/help for more information.",
    nil,
    { { "www.commonmark.org/help", "http://www.commonmark.org/help" } },
  },
  {
    "GFM 624 domain punctuation",
    "Visit www.commonmark.org.",
    nil,
    { { "www.commonmark.org", "http://www.commonmark.org" } },
  },
  {
    "GFM 624 path punctuation",
    "Visit www.commonmark.org/a.b.",
    nil,
    { { "www.commonmark.org/a.b", "http://www.commonmark.org/a.b" } },
  },
  { "GFM 625 balanced", balanced, nil, { { balanced, "http://" .. balanced } } },
  { "GFM 625 excess closing", balanced .. "))", nil, { { balanced, "http://" .. balanced } } },
  { "GFM 625 enclosing", "(" .. balanced .. ")", nil, { { balanced, "http://" .. balanced } } },
  { "GFM 625 unmatched opening", "(" .. balanced, nil, { { balanced, "http://" .. balanced } } },
  {
    "GFM 626 interior closing",
    "www.google.com/search?q=(business))+ok",
    nil,
    { { "www.google.com/search?q=(business))+ok", "http://www.google.com/search?q=(business))+ok" } },
  },
  {
    "GFM 627 query",
    "www.google.com/search?q=commonmark&hl=en",
    nil,
    { { "www.google.com/search?q=commonmark&hl=en", "http://www.google.com/search?q=commonmark&hl=en" } },
  },
  {
    "GFM 627 entity-like ending",
    "www.google.com/search?q=commonmark&hl;",
    nil,
    { { "www.google.com/search?q=commonmark", "http://www.google.com/search?q=commonmark" } },
  },
  {
    "GFM 628 less-than",
    "www.commonmark.org/he<lp",
    nil,
    { { "www.commonmark.org/he", "http://www.commonmark.org/he" } },
  },
  { "GFM 630", "foo@bar.baz", nil, { { "foo@bar.baz", "mailto:foo@bar.baz" } } },
  {
    "GFM 631",
    "hello@mail+xyz.example isn't valid, but hello+xyz@mail.example is.",
    nil,
    { { "hello+xyz@mail.example", "mailto:hello+xyz@mail.example" } },
  },
  { "GFM 632 plain", "a.b-c_d@a.b", nil, { { "a.b-c_d@a.b", "mailto:a.b-c_d@a.b" } } },
  { "GFM 632 punctuation", "a.b-c_d@a.b.", nil, { { "a.b-c_d@a.b", "mailto:a.b-c_d@a.b" } } },
  { "GFM 632 invalid hyphen", "a.b-c_d@a.b-", nil, {} },
  { "GFM 632 invalid underscore", "a.b-c_d@a.b_", nil, {} },
  { "GFM 633 mailto", "mailto:foo@bar.baz", nil, { { "mailto:foo@bar.baz", "mailto:foo@bar.baz" } } },
  { "GFM 633 mailto punctuation", "mailto:a.b-c_d@a.b", nil, { { "mailto:a.b-c_d@a.b", "mailto:a.b-c_d@a.b" } } },
  { "GFM 633 mailto final dot", "mailto:a.b-c_d@a.b.", nil, { { "mailto:a.b-c_d@a.b", "mailto:a.b-c_d@a.b" } } },
  { "GFM 633 mailto slash", "mailto:a.b-c_d@a.b/", nil, { { "mailto:a.b-c_d@a.b", "mailto:a.b-c_d@a.b" } } },
  { "GFM 633 invalid hyphen", "mailto:a.b-c_d@a.b-", nil, {} },
  { "GFM 633 invalid underscore", "mailto:a.b-c_d@a.b_", nil, {} },
  { "GFM 633 xmpp", "xmpp:foo@bar.baz", nil, { { "xmpp:foo@bar.baz", "xmpp:foo@bar.baz" } } },
  { "GFM 633 xmpp dot", "xmpp:foo@bar.baz.", nil, { { "xmpp:foo@bar.baz", "xmpp:foo@bar.baz" } } },
  { "GFM 634 resource", "xmpp:foo@bar.baz/txt", nil, { { "xmpp:foo@bar.baz/txt", "xmpp:foo@bar.baz/txt" } } },
  {
    "GFM 634 resource at",
    "xmpp:foo@bar.baz/txt@bin",
    nil,
    { { "xmpp:foo@bar.baz/txt@bin", "xmpp:foo@bar.baz/txt@bin" } },
  },
  {
    "GFM 634 resource domain",
    "xmpp:foo@bar.baz/txt@bin.com",
    nil,
    { { "xmpp:foo@bar.baz/txt@bin.com", "xmpp:foo@bar.baz/txt@bin.com" } },
  },
  {
    "GFM 635 resource boundary",
    "xmpp:foo@bar.baz/txt/bin",
    nil,
    { { "xmpp:foo@bar.baz/txt", "xmpp:foo@bar.baz/txt" } },
  },
  {
    "URL punctuation",
    "https://example.com/a_(b)).,!?",
    nil,
    { { "https://example.com/a_(b)", "https://example.com/a_(b)" } },
  },
  {
    "angle URI scheme case",
    "<MAILTO:FOO@BAR.BAZ>",
    "MAILTO:FOO@BAR.BAZ",
    { { "MAILTO:FOO@BAR.BAZ", "MAILTO:FOO@BAR.BAZ" } },
  },
  {
    "angle literal syntax",
    "<irc://x/**b**/[a](b)/&amp;>",
    "irc://x/**b**/[a](b)/&amp;",
    { { "irc://x/**b**/[a](b)/&amp;", "irc://x/**b**/[a](b)/&amp;" } },
  },
  {
    "angle email punctuation",
    "<x`y+z@example.com>",
    "x`y+z@example.com",
    { { "x`y+z@example.com", "mailto:x`y+z@example.com" } },
  },
  {
    "angle URI adjacent Unicode",
    "前<irc://foo.bar:2233/baz>後",
    "前irc://foo.bar:2233/baz後",
    { { "irc://foo.bar:2233/baz", "irc://foo.bar:2233/baz" } },
  },
  { "email adjacent Unicode", "前foo@bar.baz後", nil, { { "foo@bar.baz", "mailto:foo@bar.baz" } } },
  {
    "URL literal interior markers",
    "www.example.com/a*b*c",
    nil,
    { { "www.example.com/a*b*c", "http://www.example.com/a*b*c" } },
  },
  { "URL semicolon", "www.example.com/a;", nil, { { "www.example.com/a;", "http://www.example.com/a;" } } },
  { "www invalid last label", "www.example.c_m", nil, {} },
  { "www invalid second-last label", "www.ex_ample.com", nil, {} },
  {
    "www valid earlier underscore",
    "www.a_b.example.com",
    nil,
    { { "www.a_b.example.com", "http://www.a_b.example.com" } },
  },
  { "www invalid empty domain segment", "www.example..com", nil, {} },
  { "www invalid boundary", "awww.example.com", nil, {} },
  { "email missing domain period", "foo@example", nil, {} },
  { "email empty domain segment", "foo@example..com", nil, {} },
  { "email empty domain", "foo@.", nil, {} },
  { "email empty initial domain segment", "foo@.example.com", nil, {} },
  { "invalid short angle scheme", "<x:y>", nil, {} },
  { "raw HTML attributes", "A <span title='foo@bar.baz'> B", nil, {} },
  { "angle URI DEL", "<irc://foo.bar/\127>", nil, {} },
  {
    "angle URI owns comments",
    "<irc://a/%%literal%%>",
    "irc://a/%%literal%%",
    { { "irc://a/%%literal%%", "irc://a/%%literal%%" } },
  },
  {
    "angle HTTP owns comments",
    "<https://a/%%literal%%>",
    "https://a/%%literal%%",
    { { "https://a/%%literal%%", "https://a/%%literal%%" } },
  },
  {
    "angle URI comment bytes beside explicit link",
    "A <irc://a/%%literal%%> [B](/url)",
    "A irc://a/%%literal%% B",
    { { "irc://a/%%literal%%", "irc://a/%%literal%%" }, { "B", "/url" } },
  },
  {
    "angle URI owns comment and link syntax",
    "<irc://a/%%[r](u)%%>",
    "irc://a/%%[r](u)%%",
    { { "irc://a/%%[r](u)%%", "irc://a/%%[r](u)%%" } },
  },
  {
    "explicit angle destination keeps comments",
    "[x](<https://a/%%literal%%>)",
    "x",
    { { "x", "https://a/%%literal%%" } },
  },
  { "Obsidian comment owns angle text", "A %% <irc://a> %% B", "A B", {} },
  { "Obsidian comment closes before inner angle", "A %% <irc://a/%%literal%%> %% B", "A literal B", {} },
  { "HTML comment owns angle text", "A <!-- <irc://a/--> B", "A B", {} },
  { "escaped opener cannot create angle link", "\\<irc://a>", "<irc://a>", {} },
  {
    "www trailing named entity",
    "www.example.com/a&amp;",
    "www.example.com/a&",
    { { "www.example.com/a", "http://www.example.com/a" } },
  },
  {
    "www interior named entity",
    "www.example.com/a&amp;tail",
    nil,
    { { "www.example.com/a&amp;tail", "http://www.example.com/a&amp;tail" } },
  },
  {
    "www trailing numeric entity",
    "www.example.com/a&#38;",
    nil,
    { { "www.example.com/a&#38;", "http://www.example.com/a&#38;" } },
  },
  {
    "www escaped opening delimiter",
    "\\(www.example.com)",
    "(www.example.com)",
    { { "www.example.com", "http://www.example.com" } },
  },
  { "www entity does not create opening delimiter", "&lpar;www.example.com)", "(www.example.com)", {} },
  {
    "www owns following backticks",
    "www.example.com`foo@bar.baz`",
    nil,
    { { "www.example.com`foo@bar.baz`", "http://www.example.com`foo@bar.baz`" } },
  },
  {
    "www owns comments",
    "www.example.com/a%%b%%c",
    nil,
    { { "www.example.com/a%%b%%c", "http://www.example.com/a%%b%%c" } },
  },
  {
    "www owns entity whitespace",
    "www.example.com/a&#32;b",
    nil,
    { { "www.example.com/a&#32;b", "http://www.example.com/a&#32;b" } },
  },
  {
    "www owns backslash escapes",
    "www.example.com/a\\*b",
    nil,
    { { "www.example.com/a\\*b", "http://www.example.com/a\\*b" } },
  },
  {
    "www trailing escaped punctuation",
    "www.example.com/a\\*",
    nil,
    { { "www.example.com/a\\", "http://www.example.com/a\\" } },
  },
  {
    "existing HTTP owns www path",
    "https://example.com/(www.example.com)",
    nil,
    { { "https://example.com/(www.example.com)", "https://example.com/(www.example.com)" } },
  },
  -- CommonMark link text cannot contain another link: the inner angle link wins.
  {
    "angle URI outranks an enclosing explicit link",
    "[<irc://foo.bar>](/outer)",
    "[irc://foo.bar](/outer)",
    { { "irc://foo.bar", "irc://foo.bar" } },
  },
  {
    "angle HTTP has only the inner destination",
    "[<https://foo.bar>](/outer)",
    "[https://foo.bar](/outer)",
    { { "https://foo.bar", "https://foo.bar" } },
  },
  {
    "angle email outranks an enclosing explicit link",
    "[<a@foo.bar>](/outer)",
    "[a@foo.bar](/outer)",
    { { "a@foo.bar", "mailto:a@foo.bar" } },
  },
  {
    "angle link prevents a full reference from owning its text",
    "[<irc:label>][r]",
    "[irc:label]r",
    { { "irc:label", "irc:label" }, { "r", "/outer" } },
    refs = { r = "/outer" },
  },
  {
    "angle link outranks a shortcut reference",
    "[<irc:label>]",
    "[irc:label]",
    { { "irc:label", "irc:label" } },
    refs = { ["<irc:label>"] = "/outer" },
  },
  {
    "angle link outranks a collapsed reference",
    "[<irc:label>][]",
    "[irc:label][]",
    { { "irc:label", "irc:label" } },
    refs = { ["<irc:label>"] = "/outer" },
  },
  {
    "code inside a link label owns angle syntax",
    "[`<irc:label>`](/outer)",
    "<irc:label>",
    { { "<irc:label>", "/outer" } },
  },
  {
    "escaped angle syntax remains a link label",
    "[\\<irc:label>](/outer)",
    "<irc:label>",
    { { "<irc:label>", "/outer" } },
  },
  {
    "an image may contain angle text inside an outer link",
    "A [![<irc:label>](image.png)](/outer)",
    "A irc:label",
    { { "irc:label", "/outer" } },
  },
  {
    "invalid image syntax cannot consume the inner angle link",
    "A [![<irc:label>](bad dest)](/outer)",
    "A [![irc:label](bad dest)](/outer)",
    { { "irc:label", "irc:label" } },
  },
  {
    "inline image descriptions may contain angle text",
    "A ![<irc:label>](image.png)",
    "A irc:label",
    { { "irc:label", "image.png" } },
  },
  {
    "an escaped image marker leaves an ordinary link label",
    "\\![<irc:label>](image.png)",
    "![irc:label](image.png)",
    { { "irc:label", "irc:label" } },
  },
  {
    "an escaped backslash does not escape the image marker",
    "\\\\![<irc:label>](image.png)",
    "\\irc:label",
    { { "irc:label", "image.png" } },
  },
  {
    "an unclosed bracket leaves the inner angle link active",
    "[before <irc:label>",
    "[before irc:label",
    { { "irc:label", "irc:label" } },
  },
}

local supports_kitty = image.supports_kitty
image.supports_kitty = function()
  return false
end

for _, case in ipairs(cases) do
  test(case[1], function()
    local expected = case[3] or case[2]
    local text, highlights, links = markdown.render(case[2], nil, nil, case.refs)
    check(text, highlights, links, expected, case[4])
    local source_lines = {}
    for label, url in pairs(case.refs or {}) do
      source_lines[#source_lines + 1] = "[" .. label .. "]: " .. url
    end
    source_lines[#source_lines + 1] = case[2]
    local source = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(source, 0, -1, false, source_lines)
    local builder = Builder.new()
    builder:render_document(
      vim.api.nvim_buf_get_lines(source, 0, -1, false),
      { max_width = 1000, indent = "", text_scale = false }
    )
    local content = builder:result()
    eq(content.lines, { expected }, "ContentBuilder text")
    local inline_links = vim.deepcopy(content.link_metadata)
    for _, link in ipairs(inline_links) do
      eq(link.line, 0, "single-row link")
      link.line = nil
    end
    check(
      content.lines[1],
      content.highlights[1] and content.highlights[1].groups or {},
      inline_links,
      expected,
      case[4]
    )
    local buf = vim.api.nvim_create_buf(false, true)
    local ns = vim.api.nvim_create_namespace "autolinks_test"
    display.apply_content_to_buffer(buf, ns, content)
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), content.lines, "real rendered buffer")
    for _, link in ipairs(content.link_metadata) do
      eq(Links.at(buf, ns, link.line, link.col_start), link.url, "click first byte")
      eq(Links.at(buf, ns, link.line, link.col_end - 1), link.url, "click last byte")
      eq(Links.at(buf, ns, link.line, link.col_end), nil, "exclusive click range")
    end
    eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), source_lines, "source unchanged")
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.api.nvim_buf_delete(source, { force = true })
  end)
end

test("explicit, code, HTML, reference and custom links do not overlap autolinks", function()
  local input =
    "[www.example.com](/explicit) `www.code.com foo@code.com` <a href='/html'>foo@html.com</a> [https://ref.com][ref] TASK-42 www.example.com/TASK-42#123"
  local custom = { { key_prefix = "TASK-", url_template = "https://tracker.example/<num>" } }
  local text, highlights, links = markdown.render(input, "https://repo.example", custom, { ref = "/reference" })
  check(
    text,
    highlights,
    links,
    "www.example.com www.code.com foo@code.com foo@html.com https://ref.com TASK-42 www.example.com/TASK-42#123",
    {
      { "www.example.com", "/explicit" },
      { "foo@html.com", "/html" },
      { "https://ref.com", "/reference" },
      { "TASK-42", "https://tracker.example/42" },
      { "www.example.com/TASK-42#123", "http://www.example.com/TASK-42#123" },
    }
  )
  text, highlights, links = markdown.render("[TASK-42](https://explicit.com)", nil, custom)
  check(text, highlights, links, "TASK-42", { { "TASK-42", "https://explicit.com" } })
end)

test("angle tokens preserve reference identifiers and coexist with bare URLs", function()
  local text, highlights, links =
    markdown.render("[x][<irc:label>]", nil, nil, { ["<irc:label>"] = "https://reference.example" })
  check(text, highlights, links, "x", { { "x", "https://reference.example" } })
  text, highlights, links = markdown.render "前 <ab:x> www.example.com foo@bar.baz `END`"
  check(text, highlights, links, "前 ab:x www.example.com foo@bar.baz END", {
    { "ab:x", "ab:x" },
    { "www.example.com", "http://www.example.com" },
    { "foo@bar.baz", "mailto:foo@bar.baz" },
  })
end)

test("www text stays inside explicit, reference and wiki link labels", function()
  for _, input in ipairs { "[www.example.com][ref]", "[www.example.com][]", "[www.example.com]" } do
    local text, highlights, links = markdown.render(
      input,
      nil,
      nil,
      { ref = "https://reference.example", ["www.example.com"] = "https://reference.example" }
    )
    check(text, highlights, links, "www.example.com", { { "www.example.com", "https://reference.example" } })
  end
  local text, _, links = markdown.render "[[www.example.com]]"
  eq(text, "www.example.com", "wiki label")
  eq(
    links,
    { { col_start = 0, col_end = 15, url = "obsidian://advanced-uri?filepath=www.example.com" } },
    "wiki owns its www label"
  )
end)

test("www ownership uses reference labels before code protection", function()
  for _, input in ipairs { "[`x` www.example.com]", "[`x` www.example.com][]" } do
    local text, highlights, links = markdown.render(input, nil, nil, { ["`x` www.example.com"] = "/reference" })
    check(text, highlights, links, "x www.example.com", { { "x www.example.com", "/reference" } })
  end
  local text, _, links = markdown.render "[x](www.example.com/\127)"
  eq(text:sub(1, 4), "[x](", "an autolink token cannot make an invalid explicit destination valid")
  for _, link in ipairs(links) do
    eq(text:sub(link.col_start + 1, link.col_end) ~= "x", true, "invalid explicit label is not linked")
  end
end)

test("literal token-shaped input cannot become an autolink token", function()
  local raw = "\u{F1006}1\u{F1007}"
  local text, highlights, links = markdown.render(raw .. " <ab:x> www.example.com")
  check(text, highlights, links, raw .. " ab:x www.example.com", {
    { "ab:x", "ab:x" },
    { "www.example.com", "http://www.example.com" },
  })
end)

test("Unicode, truncation and following highlights survive public rebuilds", function()
  local input = "前 <" .. encrypted .. "> 後 **粗體** [右](https://right.example)"
  local source = vim.api.nvim_create_buf(false, true)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { input })
  vim.api.nvim_set_current_buf(source)
  local ok, err = pcall(function()
    preview.toggle { text_scale = false, max_width = 1000 }
    local session = assert(preview._toggle_sessions[source])
    for step = 1, 2 do
      local content = session.content
      eq(content.lines, { "  前 " .. shortened .. " 後粗體 右" }, "public preview shortened text")
      local full
      for _, link in ipairs(content.link_metadata) do
        eq(Links.at(session.buf, session.ns, link.line, link.col_start), link.url, "public link target")
        if link.url == encrypted then full = link end
      end
      assert(full, "public preview retains the complete unshortened destination")
      eq(
        content.lines[full.line + 1]:sub(full.col_start + 1, full.col_end),
        shortened,
        "full destination covers only shortened label"
      )
      local bold = vim.tbl_filter(function(hl)
        return hl.hl == "Bold"
      end, content.highlights[1].groups)
      eq(#bold, 1, "following bold survives")
      eq(content.lines[1]:sub(bold[1].col + 1, bold[1].end_col), "粗體", "following Unicode highlight range")
      if step == 1 then session:rebuild() end
    end
  end)
  if preview._toggle_sessions[source] then preview.toggle() end
  eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), { input }, "public preview source unchanged")
  vim.api.nvim_buf_delete(source, { force = true })
  assert(ok, err)
end)

image.supports_kitty = supports_kitty
print(string.format("autolinks_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
