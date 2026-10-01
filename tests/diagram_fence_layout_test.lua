-- Diagram construction uses the same container budget at a closer, dedent and EOF (#33).
-- Cache/capability stubs cover layout and pending-worker payloads, not raster/terminal rendering.
-- Run: NVIM_LOG_FILE=/tmp/compat-lists-nvim.log nvim --headless -u NONE --noplugin -l tests/diagram_fence_layout_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local Builder = require("md-render.content_builder").ContentBuilder
local display = require "md-render.display_utils"
local image = require "md-render.image"
local links = require "md-render.links"
local cached, enabled = false, true
local cache_sources = {}
image.supports_kitty = function()
  return enabled
end
image.has_mmdc = function()
  return true
end
image.has_plantuml = function()
  return true
end
image.get_mermaid_cached = function(source)
  cache_sources[#cache_sources + 1] = source
  return cached and "/tmp/diagram-fence.png" or nil
end
image.get_plantuml_cached = image.get_mermaid_cached
image.image_dimensions = function()
  return 1000, 100
end
image.get_cell_size = function()
  return { cell_w = 8, cell_h = 16 }
end
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
local function render(source, opts, check)
  local original = vim.deepcopy(source)
  local previous_buf = vim.api.nvim_get_current_buf()
  local source_buf = vim.api.nvim_create_buf(false, true)
  local buf = vim.api.nvim_create_buf(false, true)
  local ok, c = pcall(function()
    vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, source)
    vim.api.nvim_set_current_buf(source_buf)
    local tick = vim.api.nvim_buf_get_changedtick(source_buf)
    local b = Builder.new()
    b:render_document(source, vim.tbl_extend("force", { max_width = 48, indent = "", text_scale = false }, opts or {}))
    local content = b:result()
    eq(#content.source_line_map, #content.lines, "one source owner per rendered row")
    local ns = vim.api.nvim_create_namespace "diagram_fence_layout_test"
    display.apply_content_to_buffer(buf, ns, content)
    eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false), content.lines, "actual buffer rows")
    if check then check(content, buf, ns) end
    eq(source, original, "source array bytes stay unchanged")
    eq(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), original, "source buffer bytes stay unchanged")
    eq(vim.api.nvim_buf_get_changedtick(source_buf), tick, "source buffer changedtick stays unchanged")
    return content
  end)
  if vim.api.nvim_buf_is_valid(previous_buf) then vim.api.nvim_set_current_buf(previous_buf) end
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.api.nvim_buf_delete(source_buf, { force = true })
  assert(ok, c)
  return c
end
local function build(lang, list, details, ending, payload, opts)
  local source = details and { "<details open>", "<summary>Diagram</summary>", "" } or {}
  local opener = #source + 1
  local margin = list and "  " or ""
  source[#source + 1] = (list and "- " or "") .. "```" .. lang
  source[#source + 1] = margin .. payload
  if ending == "closed" then source[#source + 1] = margin .. "```" end
  if ending == "dedented" then source[#source + 1] = "root text" end
  return render(source, opts), opener
end

for _, lang in ipairs { "mermaid", "plantuml" } do
  for _, list in ipairs { false, true } do
    for _, details in ipairs { false, true } do
      local endings = list and { "closed", "eof", "dedented" } or { "closed", "eof" }
      for _, cache_hit in ipairs { false, true } do
        test(string.format("%s list=%s details=%s cached=%s", lang, list, details, cache_hit), function()
          cached, enabled = cache_hit, true
          local baseline
          for _, ending in ipairs(endings) do
            local payload = "Alice -> Bob: 甲"
            local c = build(lang, list, details, ending, payload)
            local p = assert(c.image_placements[1])
            local cols = cached and (list and 44 or 46) or (list and 35 or 36)
            local col = (cached and 1 or (list and 5 or 6)) + (details and 2 or 0)
            local expected = {
              line = (details and 2 or 0) + (list and 1 or 0) + 1,
              col = col,
              cols = cols,
              rows = cached and 2 or 15,
              path = cached and "/tmp/diagram-fence.png" or nil,
              img_w = cached and 1000 or nil,
              img_h = cached and 100 or nil,
            }
            if not cached then expected[lang .. "_source"] = payload end
            eq(c.image_placements, { expected }, ending .. " exact diagram geometry/payload")
            eq(cache_sources[#cache_sources], payload, ending .. " cache receives dedented literal bytes")
            local prefix = (details and "│ " or "") .. (list and "  " or "")
            local title = lang == "mermaid" and "Mermaid" or "PlantUML"
            eq(c.lines[p.line], (list and "  " or "") .. title, ending .. " existing diagram header")
            local body = vim.list_slice(c.lines, p.line + 1, p.line + p.rows)
            local expected_body = {}
            for row = 1, p.rows do
              local text = prefix
              if not cached and row == 8 then
                local message = "Rendering " .. (lang == "mermaid" and "mermaid" or "PlantUML") .. " diagram..."
                local pad = math.max(0, math.floor((cols - vim.api.nvim_strwidth(message)) / 2))
                text = text .. string.rep(" ", col - (details and 2 or 0) + pad) .. message
              end
              expected_body[row] = text
            end
            eq(body, expected_body, ending .. " exact container-prefixed image/placeholder rows")
            if baseline then eq(body, baseline, ending .. " matches explicit closer") end
            baseline = body
            eq(c.code_blocks, {}, ending .. " handled image has no literal-code metadata")
            eq(c.expandable_regions, {}, ending .. " image keeps existing expansion policy")
            if ending == "dedented" then
              eq(c.lines[#c.lines], (details and "│ " or "") .. "root text", "dedent starts the following paragraph")
            end
          end
        end)

        test(string.format("%s metadata list=%s details=%s cached=%s", lang, list, details, cache_hit), function()
          cached, enabled = cache_hit, true
          for _, ending in ipairs(endings) do
            local source = details and { "<details open>", "<summary>Diagram</summary>", "" } or {}
            local marker, margin = list and "- " or "", list and "  " or ""
            local before_url, tail_url = "https://before.test", "./tail.md"
            source[#source + 1] = marker .. "**BEFORE** [BEFORE](" .. before_url .. ")"
            source[#source + 1] = marker .. "```" .. lang
            source[#source + 1] = margin .. "https://literal.test/a"
            if ending == "closed" then source[#source + 1] = margin .. "```" end
            if ending ~= "eof" then source[#source + 1] = marker .. "[TAIL](" .. tail_url .. ")" end
            render(source, nil, function(c, buf, ns)
              local expected_urls, actual_urls = { before_url }, {}
              if ending ~= "eof" then expected_urls[#expected_urls + 1] = tail_url end
              for _, link in ipairs(c.link_metadata) do
                actual_urls[#actual_urls + 1] = link.url
                local label = link.url == before_url and "BEFORE" or "TAIL"
                eq(c.lines[link.line + 1]:sub(link.col_start + 1, link.col_end), label, ending .. " link bytes")
                eq(links.at(buf, ns, link.line, link.col_start), link.url, ending .. " actual link start")
                eq(links.at(buf, ns, link.line, link.col_end), nil, ending .. " actual link end")
              end
              eq(actual_urls, expected_urls, ending .. " only visible links survive diagram replacement")
              local bold = {}
              for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
                if mark[4].hl_group == "Bold" then
                  bold[#bold + 1] = c.lines[mark[2] + 1]:sub(mark[3] + 1, mark[4].end_col)
                end
              end
              eq(bold, { "BEFORE" }, ending .. " preceding style survives sparse highlight cleanup")
              local header_row = c.image_placements[1].line - 1
              for col = 0, #c.lines[header_row + 1] - 1 do
                eq(links.at(buf, ns, header_row, col), nil, ending .. " diagram header has no removed URL target")
              end
              if ending ~= "eof" then
                local tail = c.link_metadata[#c.link_metadata]
                eq(c.source_line_map[tail.line + 1], #source, ending .. " trailing sibling physical source row")
              end
            end)
          end
        end)
      end

      test(string.format("%s literal list=%s details=%s", lang, list, details), function()
        enabled = false
        local payload = "<!-- [r]: /literal --> " .. string.rep("甲", 24)
        for _, ending in ipairs(endings) do
          for _, expanded in ipairs { false, true } do
            local opener = details and 4 or 1
            local c = build(lang, list, details, ending, payload, { expand_state = { [opener] = expanded } })
            local cb = assert(c.code_blocks[1])
            eq(cb.language, lang, ending .. " fallback language")
            eq(cb.source_lines, { payload }, ending .. " fallback retains full literal bytes")
            eq(cb.prefix_len, (list and 2 or 0) + (details and #"│ " or 0), ending .. " fallback prefix bytes")
            eq(c.source_line_map[cb.start_line + 1], opener + 1, ending .. " literal physical source row")
            eq(c.image_placements, {}, ending .. " disabled capability keeps text fallback")
            local region = assert(c.expandable_regions[1])
            eq({ region.block_id, region.expanded }, { opener, expanded }, ending .. " existing expansion owner/state")
            local visible = c.lines[cb.start_line + 1]:sub(cb.prefix_len + 1)
            if expanded then
              eq(visible, payload, ending .. " expanded fallback display")
            else
              eq(visible:sub(-#"…"), "…", ending .. " fallback truncation display")
            end
          end
        end
      end)
    end
  end
end
print(string.format("diagram_fence_layout_test: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
