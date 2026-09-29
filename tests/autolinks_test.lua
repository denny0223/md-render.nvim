-- Bare HTTP(S) boundaries from GFM 0.29 examples 625-629.
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
    "URL punctuation",
    "https://example.com/a_(b)).,!?",
    nil,
    { { "https://example.com/a_(b)", "https://example.com/a_(b)" } },
  },
  {
    "existing HTTP owns www path",
    "https://example.com/(www.example.com)",
    nil,
    { { "https://example.com/(www.example.com)", "https://example.com/(www.example.com)" } },
  },
  -- CommonMark link text cannot contain another link: the inner angle link wins.
}

local supports_kitty = image.supports_kitty
image.supports_kitty = function()
  return false
end

for _, case in ipairs(cases) do
  test(case[1], function()
    local expected = case[3] or case[2]
    local text, highlights, links = markdown.render(case[2])
    check(text, highlights, links, expected, case[4])
    local source = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(source, 0, -1, false, { case[2] })
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
    eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), { case[2] }, "source unchanged")
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.api.nvim_buf_delete(source, { force = true })
  end)
end

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
