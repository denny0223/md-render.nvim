---@class MdRender.Autolink
---@field key_prefix string   -- e.g., "HOGE-"
---@field url_template string -- e.g., "https://jira.example.com/browse/HOGE-<num>"
---@field is_alphanumeric? boolean

---@class MdRender.Markdown.Highlight
---@field col integer 0-indexed start column
---@field end_col integer 0-indexed end column
---@field hl string highlight group name

---@class MdRender.Markdown.Link
---@field col_start integer 0-indexed start column
---@field col_end integer 0-indexed end column
---@field url string

---@class MdRender.Markdown.Break
---@field col integer 0-indexed separator byte in rendered text (one ASCII space)
---@field source_line integer 1-indexed source row starting the next paragraph segment

---@class MdRender.Markdown.Removal
---@field start integer 0-indexed position in the input text
---@field count integer number of bytes removed

---@class MdRender.Markdown
local Markdown = {}

local wrap_mod = require "md-render.wrap"
local fence_mod = require "md-render.fence"
local inline = require "md-render.inline"
local character_references = require "md-render.character_references"
local SourceMap = require "md-render.source_map"

local MAX_URL_DISPLAY_WIDTH = 50
local delimiter_char

--- Parse ATX syntax before interpreting its inline content or container layout.
---@param line string source line after any container prefix has been removed
---@return integer? level 1-6, or nil when this is not an ATX heading
---@return string? content raw inline source; empty string is a valid heading
function Markdown.parse_atx_heading(line)
  local markers, content = line:match "^ ? ? ?(#+)(.*)$"
  if not markers or #markers > 6 or (content ~= "" and not content:match "^[ \t]") then return nil end
  -- A closing run is unescaped only when whitespace immediately precedes it.
  content = content:gsub("[ \t]+#+[ \t]*$", "")
  return #markers, (content:gsub("^[ \t]+", ""):gsub("[ \t]+$", ""))
end

--- Parse a container-relative Setext underline; leading tabs are expanded by its owner.
---@param line string
---@return integer? level 1 or 2, nil when the underline is ineligible
function Markdown.parse_setext_underline(line)
  if line:match "^ ? ? ?=+[ \t]*$" then return 1 end
  if line:match "^ ? ? ?%-+[ \t]*$" then return 2 end
end

--- Slugs use semantic heading text, before terminal-specific presentation.
---@param text string raw heading text (after # markers)
---@param ref_links? table<string, string>
---@param footnote_map? table<string, integer>
---@param block_context? table
---@return string slug
function Markdown.heading_slug(text, ref_links, footnote_map, block_context)
  local context = { semantic = true, raw_html = block_context and block_context.raw_html }
  local rendered = Markdown.render(text, nil, nil, ref_links, footnote_map, true, context)
  rendered = vim.fn.tolower(vim.trim(rendered))
  return (
    rendered:gsub("[%z\1-\127\194-\253][\128-\191]*", function(char)
      if char == " " then return "-" end
      if char == "-" or char == "_" then return char end
      local space, punctuation = delimiter_char(char)
      return (space or punctuation or char:find "%c") and "" or char
    end)
  )
end

--- ASCII punctuation characters that can be backslash-escaped (CommonMark spec)
local ESCAPABLE_CHARS = [[!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~]]

--- Adjust highlight and link positions after byte removals
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@param removals MdRender.Markdown.Removal[]
---@param hl_count integer number of highlights to adjust (from the beginning)
---@param link_count integer number of links to adjust (from the beginning)
local function adjust_positions(highlights, links, removals, hl_count, link_count)
  local sources = highlights._source_map
  if sources then
    if removals.source_edits then
      sources:replace(removals.source_edits)
    else
      sources:removals(removals)
    end
  end
  if #removals == 0 or hl_count + link_count == 0 then return end
  -- Each removal contributes a ramp over its source bytes. Token expansion
  -- contributes a negative jump instead. Prefix sums make each endpoint lookup
  -- logarithmic even when thousands of tags create thousands of highlights.
  local changes = {}
  for _, removal in ipairs(removals) do
    local first, last = removal.start, removal.start + removal.count
    if removal.count > 0 then
      changes[#changes + 1] = { first, 1, -first }
      changes[#changes + 1] = { last, -1, last }
    elseif removal.count < 0 then
      changes[#changes + 1] = { last, 0, removal.count }
    end
  end
  table.sort(changes, function(a, b)
    return a[1] < b[1]
  end)
  local slope, offset = 0, 0
  for _, change in ipairs(changes) do
    slope, offset = slope + change[2], offset + change[3]
    change[2], change[3] = slope, offset
  end
  local function adjust(pos)
    local first, last = 1, #changes
    while first <= last do
      local mid = math.floor((first + last) / 2)
      if changes[mid][1] <= pos then
        first = mid + 1
      else
        last = mid - 1
      end
    end
    local change = changes[last]
    return change and pos - change[2] * pos - change[3] or pos
  end
  for i = 1, hl_count do
    highlights[i].col = adjust(highlights[i].col)
    highlights[i].end_col = adjust(highlights[i].end_col)
  end
  for i = 1, link_count do
    links[i].col_start = adjust(links[i].col_start)
    links[i].col_end = adjust(links[i].col_end)
  end
end

--- Restore only tokens created by this render, keeping all ranges in byte coordinates.
---@param text string
---@param spans {placeholder: string, content: string}[]
---@param hl_group string?
---@param highlights? MdRender.Markdown.Highlight[]
---@param links? MdRender.Markdown.Link[]
---@return string
local function restore_spans(text, spans, hl_group, highlights, links)
  if #spans == 0 then return text end
  highlights, links = highlights or {}, links or {}
  local hl_count, link_count = #highlights, #links
  local by_token, removals, shift = {}, {}, 0
  local sources = highlights._source_map
  if sources then removals.source_edits = {} end
  for _, span in ipairs(spans) do
    by_token[span.placeholder] = span
  end
  -- Every token in a batch shares a PUA prefix/suffix and a decimal index.
  -- gsub scans only the input: decoded Unicode can never become another token.
  local pattern = spans[1].placeholder:gsub("%d+", "%%d+")
  local rendered = text:gsub("()(" .. pattern .. ")", function(first, token)
    local span = by_token[token]
    if not span then return token end
    local col = first - 1 + shift
    span.col = col
    local count = #token - #span.content
    removals[#removals + 1] = { start = first - 1 + #span.content, count = count }
    if sources then
      removals.source_edits[#removals.source_edits + 1] = {
        first = first - 1,
        last = first - 1 + #token,
        value = span.sources,
      }
    end
    if hl_group then highlights[#highlights + 1] = { col = col, end_col = col + #span.content, hl = hl_group } end
    shift = shift - count
    return span.content
  end)
  adjust_positions(highlights, links, removals, hl_count, link_count)
  return rendered
end

--- Reference identifiers use their source spelling, not decoded display text.
local function restore_source(text, spans, sources)
  if #spans == 0 then return text end
  local originals = {}
  for _, span in ipairs(spans) do
    originals[span.placeholder] = span.raw
  end
  local pattern = spans[1].placeholder:gsub("%d+", "%%d+")
  if not sources then return (text:gsub(pattern, originals)) end
  local edits, by_token = {}, {}
  for _, span in ipairs(spans) do
    by_token[span.placeholder] = span
  end
  text = text:gsub("()(" .. pattern .. ")", function(first, token)
    local span = by_token[token]
    if not span then return token end
    edits[#edits + 1] = { first = first - 1, last = first - 1 + #token, value = span.raw_sources }
    return span.raw
  end)
  sources:replace(edits)
  return text
end

--- Hide owned source bytes while extensions inspect the remaining text.
local function protect_ranges(text, source, ranges, highlights, links)
  if #ranges == 0 then return text, {} end
  local prefix = inline.token_prefix(source .. text, 0xF100C)
  local spans, parts, removals, pos = {}, {}, {}, 1
  local sources = highlights._source_map
  if sources then removals.source_edits = {} end
  for _, range in ipairs(ranges) do
    local raw = text:sub(range.start, range.finish)
    local placeholder = prefix .. (#spans + 1) .. "\u{F100D}"
    local span = { placeholder = placeholder, raw = raw, content = raw, link = range.link }
    spans[#spans + 1] = span
    if sources then sources:protect(removals.source_edits, span, range.start - 1, range.finish) end
    parts[#parts + 1] = text:sub(pos, range.start - 1) .. placeholder
    removals[#removals + 1] = { start = range.start - 1 + #placeholder, count = #raw - #placeholder }
    pos = range.finish + 1
  end
  parts[#parts + 1] = text:sub(pos)
  adjust_positions(highlights, links, removals, #highlights, #links)
  return table.concat(parts), spans
end

local function contains_token(text, spans)
  return #spans > 0 and text:find(spans[1].placeholder:gsub("%d+", "%%d+")) ~= nil
end

--- Code/HTML may style an alias, but cannot become an extension destination.
--- A resolved link/autolink anywhere in the label retains its own target.
local function extension_owned(inner, standard_spans, code_spans, autolink_spans)
  local target = inner:match "^[^|]*"
  if contains_token(target, code_spans) or contains_token(inner, autolink_spans) then return true end
  for _, span in ipairs(standard_spans) do
    if (span.link and inner:find(span.placeholder, 1, true)) or target:find(span.placeholder, 1, true) then
      return true
    end
  end
  return false
end

--- Hide escaped punctuation until syntax recognition is finished.
local function escape_backslashes(text, source, literal_autolinks, sources)
  local escapes, result = {}, {}
  local edits = sources and {}
  local prefix = inline.token_prefix((source or "") .. text, 0xF1002)
  local i = 1
  while i <= #text do
    local next_ch = text:sub(i + 1, i + 1)
    local autolink_end = literal_autolinks and text:sub(i, i) == "<" and inline.autolink_end(text, i)
    if autolink_end then
      result[#result + 1] = text:sub(i, autolink_end)
      i = autolink_end + 1
    elseif text:sub(i, i) == "\\" and next_ch ~= "" and ESCAPABLE_CHARS:find(next_ch, 1, true) then
      local placeholder = prefix .. (#escapes + 1) .. "\u{F1003}"
      local span = { placeholder = placeholder, content = next_ch, raw = "\\" .. next_ch }
      escapes[#escapes + 1] = span
      if sources then sources:protect(edits, span, i - 1, i + 1, sources:slice(i, i + 1)) end
      result[#result + 1] = placeholder
      i = i + 2
    else
      result[#result + 1] = text:sub(i, i)
      i = i + 1
    end
  end
  if sources then sources:replace(edits) end
  return table.concat(result), escapes
end

--- Recognize references in the source, before removing any Markdown syntax.
--- Keeping their values hidden also prevents decoded punctuation from becoming syntax.
local function protect_entities(text, source, literal, sources)
  local spans, result = {}, {}
  local edits = sources and {}
  local prefix = inline.token_prefix((source or "") .. text, 0xF1004)
  local i = 1
  while i <= #text do
    local autolink_end = text:sub(i, i) == "<" and inline.autolink_end(text, i)
    local reference, replacement = character_references.match(text, i)
    local next_char = text:sub(i + 1, i + 1)
    if not literal and text:sub(i, i) == "\\" and next_char ~= "" and ESCAPABLE_CHARS:find(next_char, 1, true) then
      result[#result + 1] = text:sub(i, i + 1)
      i = i + 2
    elseif autolink_end then
      result[#result + 1] = text:sub(i, autolink_end)
      i = autolink_end + 1
    elseif replacement then
      local placeholder = prefix .. (#spans + 1) .. "\u{F1005}"
      local span = { placeholder = placeholder, content = replacement, raw = reference }
      spans[#spans + 1] = span
      if sources then
        sources:protect(edits, span, i - 1, i - 1 + #reference, SourceMap.constant(#replacement, sources:at(i - 1)))
      end
      result[#result + 1] = placeholder
      i = i + #reference
    else
      result[#result + 1] = text:sub(i, i)
      i = i + 1
    end
  end
  if sources then sources:replace(edits) end
  return table.concat(result), spans
end

--- Preserve source breaks through inline parsing without changing whitespace
--- boundaries. Tabs protect the token from display-space collapse; source
--- restoration retains reference-label spelling and source-row accounting.
local function protect_hard_breaks(text, source, ref_links, source_label, bare_url, sources)
  local ranges = inline.hard_breaks(text, ref_links, source_label, bare_url)
  if #ranges == 0 then return text, {} end
  local prefix = inline.token_prefix(source .. character_references.decode(source) .. text, 0xF100A)
  local spans, parts, pos, source_line = {}, {}, 1, 1
  local edits = sources and {}
  for _, range in ipairs(ranges) do
    local _, rows = source_label(text:sub(pos, range.finish)):gsub("\n", "")
    source_line = source_line + rows
    local placeholder = "\t" .. prefix .. (#spans + 1) .. "\u{F100B}\t"
    spans[#spans + 1] = {
      placeholder = placeholder,
      raw = text:sub(range.start, range.finish),
      content = " ",
      source_line = source_line,
    }
    if sources then
      sources:protect(
        edits,
        spans[#spans],
        range.start - 1,
        range.finish,
        SourceMap.constant(1, sources:at(range.start - 1))
      )
    end
    parts[#parts + 1] = text:sub(pos, range.start - 1) .. placeholder
    pos = range.finish + 1
  end
  parts[#parts + 1] = text:sub(pos)
  if sources then sources:replace(edits) end
  return table.concat(parts), spans
end

--- Pad a Nerd Font icon glyph so it always occupies 2 display cells.
--- When setcellwidths makes the glyph width 1, an extra space is appended.
---@param icon string single icon character
---@return string
local function pad_icon(icon)
  if vim.api.nvim_strwidth(icon) == 1 then return icon .. " " end
  return icon
end

--- Heading level icons (nf-md-format_header_1 .. _6)
local HEADING_ICONS = { "󰉫", "󰉬", "󰉭", "󰉮", "󰉯", "󰉰" }

--- The bare level icon glyph, e.g. `"󰉬"` for `##`.
---@param level integer 1-6
---@return string
function Markdown.heading_icon(level)
  return HEADING_ICONS[level]
end

--- Scaled layouts omit icons; ContentBuilder adds rank markers for plain text.
---@param _level integer 1-6
---@return string
function Markdown.heading_icon_prefix(_level)
  return ""
end

--- GitHub Flavored Markdown + Obsidian alert/callout types
local ALERT_TYPES = {
  -- GitHub Alerts
  NOTE = { icon = "󰋽", label = "Note" },
  TIP = { icon = "󰌶", label = "Tip" },
  IMPORTANT = { icon = "󰅾", label = "Important" },
  WARNING = { icon = "󰀪", label = "Warning" },
  CAUTION = { icon = "󰳦", label = "Caution" },
  -- Obsidian additional types
  ABSTRACT = { icon = "󱉫", label = "Abstract" },
  SUMMARY = { icon = "󱉫", label = "Summary", style = "ABSTRACT" },
  TLDR = { icon = "󱉫", label = "TL;DR", style = "ABSTRACT" },
  INFO = { icon = "󰋽", label = "Info", style = "NOTE" },
  TODO = { icon = "󰄬", label = "Todo" },
  SUCCESS = { icon = "󰄬", label = "Success" },
  CHECK = { icon = "󰄬", label = "Check", style = "SUCCESS" },
  DONE = { icon = "󰄬", label = "Done", style = "SUCCESS" },
  QUESTION = { icon = "󱈅", label = "Question" },
  HELP = { icon = "󱈅", label = "Help", style = "QUESTION" },
  FAQ = { icon = "󱈅", label = "FAQ", style = "QUESTION" },
  FAILURE = { icon = "󰅙", label = "Failure" },
  FAIL = { icon = "󰅙", label = "Fail", style = "FAILURE" },
  MISSING = { icon = "󰅙", label = "Missing", style = "FAILURE" },
  DANGER = { icon = "󱐌", label = "Danger" },
  ERROR = { icon = "󱐌", label = "Error", style = "DANGER" },
  BUG = { icon = "󱈰", label = "Bug" },
  EXAMPLE = { icon = "󰆹", label = "Example" },
  QUOTE = { icon = "󱗝", label = "Quote" },
  CITE = { icon = "󱗝", label = "Cite", style = "QUOTE" },
}

--- Process Obsidian highlight markers by removing markers and adding highlights
---@param text string The input text
---@param pattern string The Lua pattern to match (e.g., "%*%*([^*]+)%*%*")
---@param hl_group string The highlight group to apply
---@param marker_len integer The length of each marker (e.g., 2 for ** or ~~)
---@param highlights MdRender.Markdown.Highlight[] Existing highlights to adjust
---@param links MdRender.Markdown.Link[] Existing links to adjust
---@return string processed The text with markers removed
local function process_paired_markers(text, pattern, hl_group, marker_len, highlights, links)
  local pre_hl_count = #highlights
  local pre_link_count = #links
  local removals = {}
  local processed = ""
  local i = 1
  while i <= #text do
    local s, e = text:find(pattern, i)
    if not s then
      processed = processed .. text:sub(i)
      break
    end
    processed = processed .. text:sub(i, s - 1)
    local content = text:match(pattern, s)
    table.insert(removals, { start = s - 1, count = marker_len })
    table.insert(removals, { start = s - 1 + marker_len + #content, count = marker_len })
    local start_col = #processed
    processed = processed .. content
    table.insert(highlights, { col = start_col, end_col = start_col + #content, hl = hl_group })
    i = e + 1
  end
  adjust_positions(highlights, links, removals, pre_hl_count, pre_link_count)
  return processed
end

--- The UTF-8 character whose last byte sits at `pos` (1-indexed).
---@param text string
---@param pos integer
---@return string char empty when `pos` is before the start of `text`
local function char_ending_at(text, pos)
  if pos < 1 then return "" end
  local first = pos
  while first > 1 do
    local b = text:byte(first)
    if b < 0x80 or b > 0xBF then break end
    first = first - 1
  end
  return text:sub(first, pos)
end

--- The UTF-8 character whose first byte sits at `pos` (1-indexed).
---@param text string
---@param pos integer
---@return string char empty when `pos` is past the end of `text`
local function char_starting_at(text, pos)
  local last = pos
  while last < #text do
    local b = text:byte(last + 1)
    if b < 0x80 or b > 0xBF then break end
    last = last + 1
  end
  return text:sub(pos, last)
end

-- URI encoding preserves reserved delimiters; query values must escape them.
local function query_value(value)
  return (value:gsub("[^A-Za-z0-9%-%._~]", function(char)
    return string.format("%%%02X", char:byte())
  end))
end

--- Process [[wikilinks]]: display as link text with highlight
---@param text string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_wikilinks(
  text,
  highlights,
  links,
  emphasis_spans,
  hard_break_spans,
  standard_spans,
  code_spans,
  autolink_spans,
  decode_url
)
  if not text:find("[[", 1, true) or not text:find("]]", 1, true) then return text end
  local pre_hl_count, pre_link_count, removals = #highlights, #links, {}
  local sources = highlights._source_map
  if sources then removals.source_edits = {} end
  local processed = ""
  local i = 1

  while i <= #text do
    if text:sub(i, i + 1) == "[[" then
      local close = text:find("]]", i + 2, true)
      if close and extension_owned(text:sub(i + 2, close - 1), standard_spans, code_spans, autolink_spans) then
        close = nil
      end
      if close then
        local inner = text:sub(i + 2, close - 1)
        local display, target

        local pipe_pos = inner:find("|", 1, true)
        local display_sources
        if pipe_pos then
          target = inner:sub(1, pipe_pos - 1)
          display = inner:sub(pipe_pos + 1)
          if sources then display_sources = sources:slice(i + 1 + pipe_pos, close - 1) end
        else
          target = inner
          local heading = inner:match "^#(.+)$"
          if heading then
            display = heading
            if sources then display_sources = sources:slice(i + 2, close - 1) end
          else
            local page, h = inner:match "^([^#]+)#(.+)$"
            if page and h then
              display = page .. " > " .. h
              if sources then
                display_sources = sources:slice(i + 1, close - 1)
                display_sources:replace {
                  { first = #page, last = #page + 1, value = SourceMap.constant(3, display_sources:at(#page)) },
                }
              end
            else
              display = inner
              if sources then display_sources = sources:slice(i + 1, close - 1) end
            end
          end
        end

        -- Targets keep their original spelling while labels render inline styles.
        target = decode_url(restore_source(restore_source(target, hard_break_spans), emphasis_spans))
        -- Determine URL and highlight based on link type
        local url, hl
        local anchor_heading = target:match "^#(.+)$"
        if anchor_heading then
          -- Same-document heading anchor: [[#heading]]
          url = "#" .. Markdown.heading_slug(anchor_heading)
          hl = "MdRenderLinkAnchor"
        else
          -- Obsidian cross-file link via Advanced URI plugin
          local page, heading = target:match "^([^#]+)#(.+)$"
          if page and heading then
            url = "obsidian://advanced-uri?filepath=" .. query_value(page) .. "&heading=" .. query_value(heading)
          else
            url = "obsidian://advanced-uri?filepath=" .. query_value(target)
          end
          hl = "MdRenderLinkObsidian"
        end

        local start_col = #processed
        processed = processed .. display
        table.insert(highlights, { col = start_col, end_col = start_col + #display, hl = hl })
        table.insert(links, {
          col_start = start_col,
          col_end = start_col + #display,
          url = url,
          _decoded = true,
        })
        removals[#removals + 1] = { start = i - 1 + #display, count = close + 2 - i - #display }
        if sources then
          removals.source_edits[#removals.source_edits + 1] =
            { first = i - 1, last = close + 1, value = display_sources }
        end
        i = close + 2
      else
        processed = processed .. text:sub(i, i)
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end

  adjust_positions(highlights, links, removals, pre_hl_count, pre_link_count)
  return processed
end

local IMAGE_EXTENSIONS = { png = true, jpg = true, jpeg = true, gif = true, svg = true, webp = true, bmp = true }

--- Process ![[embeds]]: display as icon + filename with highlight
---@param text string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_embeds(
  text,
  highlights,
  links,
  emphasis_spans,
  hard_break_spans,
  standard_spans,
  code_spans,
  autolink_spans,
  decode_url,
  semantic
)
  if not text:find("![[", 1, true) or not text:find("]]", 1, true) then return text end
  local pre_hl_count, pre_link_count, removals = #highlights, #links, {}
  local sources = highlights._source_map
  if sources then removals.source_edits = {} end
  local processed = ""
  local i = 1

  while i <= #text do
    if text:sub(i, i + 2) == "![[" then
      local close = text:find("]]", i + 3, true)
      if close and extension_owned(text:sub(i + 3, close - 1), standard_spans, code_spans, autolink_spans) then
        close = nil
      end
      if close then
        local inner = text:sub(i + 3, close - 1)
        local target = inner:match "^([^|#]+)" or inner
        local source_target = decode_url(restore_source(restore_source(target, hard_break_spans), emphasis_spans))
        local ext = source_target:match "%.(%w+)$"
        local icons_mod = require "md-render.icons"
        local raw_icon, embed_icon_hl
        if ext and IMAGE_EXTENSIONS[ext:lower()] then
          raw_icon, embed_icon_hl = icons_mod.get_image_icon(source_target)
        else
          raw_icon = "📎"
        end
        local icon = semantic and "" or icons_mod.pad_icon(raw_icon) .. " "
        local display = icon .. target
        if sources then
          local value = sources:slice(i + 2, i + 2 + #target)
          value:replace { { first = 0, last = 0, value = SourceMap.constant(#icon, sources:at(i - 1)) } }
          removals.source_edits[#removals.source_edits + 1] = { first = i - 1, last = close + 1, value = value }
        end

        local start_col = #processed
        processed = processed .. display
        if embed_icon_hl and not semantic then
          table.insert(highlights, { col = start_col, end_col = start_col + #icon - 1, hl = embed_icon_hl })
        end
        table.insert(
          highlights,
          { col = start_col + #icon, end_col = start_col + #display, hl = "MdRenderLinkObsidian" }
        )
        table.insert(links, {
          col_start = start_col,
          col_end = start_col + #display,
          url = "obsidian://advanced-uri?filepath=" .. query_value(source_target),
          _decoded = true,
        })
        removals[#removals + 1] = { start = i - 1 + #display, count = close + 2 - i - #display }
        i = close + 2
      else
        processed = processed .. text:sub(i, i)
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end

  adjust_positions(highlights, links, removals, pre_hl_count, pre_link_count)
  return processed
end

--- Inline and reference links share the same destination/title syntax.
local function link_destination(text)
  local escaped, escapes = escape_backslashes(text)
  local destination = escaped:match "^%s*<([^>]*)>" or escaped:match "^%s*(%S+)" or ""
  return character_references.decode(restore_source(destination, escapes))
end

local link_bounds = inline.link_bounds

--- Apply display transformations without changing a valid destination/title or HTML attribute.
local function map_display_text(text, transform, keep_literals)
  if not text:find("](", 1, true) and not (keep_literals and text:find "[<\\]") then return transform(text, 0) end
  local parts, start, i = {}, 1, 1
  local failed_html, last_comment = {}, text:match "^.*()%-%->" or 0
  local indexed_links = inline.scan(text).links
  while i <= #text do
    local c = text:sub(i, i)
    local _, comment_end
    if i + 4 <= last_comment and text:sub(i, i + 3) == "<!--" then
      _, comment_end = text:find("-->", i + 4, true)
    end
    if not comment_end then
      _, comment_end = text:find("^%%%%.-%%%%", i)
    end
    if c == "\\" then
      if keep_literals and i < #text and ESCAPABLE_CHARS:find(text:sub(i + 1, i + 1), 1, true) then
        parts[#parts + 1] = transform(text:sub(start, i - 1), start - 1)
        parts[#parts + 1] = text:sub(i, i + 1)
        start = i + 2
      end
      i = i + 1
    elseif comment_end then
      -- A link-looking sequence inside a comment is not a link boundary.
      i = comment_end
    elseif c == "<" and inline.autolink_end(text, i) then
      i = inline.autolink_end(text, i)
    elseif keep_literals and c == "<" and inline.html_end(text, i, failed_html) then
      local last = inline.html_end(text, i, failed_html)
      parts[#parts + 1] = transform(text:sub(start, i - 1), start - 1)
      parts[#parts + 1] = text:sub(i, last)
      start, i = last + 1, last
    elseif c == "[" then
      local first, last = link_bounds(text, i, nil, nil, indexed_links)
      if last then
        parts[#parts + 1] = transform(text:sub(start, first), start - 1)
        parts[#parts + 1] = text:sub(first + 1, last)
        start, i = last + 1, last
      end
    end
    i = i + 1
  end
  parts[#parts + 1] = transform(text:sub(start), start - 1)
  return table.concat(parts)
end

--- Comments can consume several source rows; surviving text keeps its own origin.
local function protect_comments(text, source, sources)
  local spans = {}
  if not text:find("<!--", 1, true) and not text:find("%%", 1, true) then return text, spans end
  local prefix = inline.token_prefix(source .. text, 0xF100E)
  local edits = sources and {}
  local rendered = map_display_text(text, function(part, start)
    local original_length = #part
    local part_sources = sources and sources:slice(start, start + #part)
    local replacements = part_sources and {}
    local function stash(pos, raw)
      local token = prefix .. (#spans + 1) .. "\u{F100F}"
      local span = { placeholder = token, raw = raw, content = "" }
      spans[#spans + 1] = span
      if part_sources then
        part_sources:protect(
          replacements,
          span,
          pos - 1,
          pos - 1 + #raw,
          SourceMap.constant(0, part_sources:at(pos - 1))
        )
      end
      return token
    end
    part = part:gsub("()(%%%%.-%%%%)", stash)
    if part_sources then
      part_sources:replace(replacements)
      replacements = {}
    end
    -- Restrict matching to the closed prefix; unmatched suffixes stay literal.
    local last = part:match "^.*()%-%->"
    if last then part = part:sub(1, last + 2):gsub("()(<!%-%-.-%-%->)", stash) .. part:sub(last + 3) end
    if part_sources then
      part_sources:replace(replacements)
      edits[#edits + 1] = { first = start, last = start + original_length, value = part_sources }
    end
    return part
  end, true)
  if sources then sources:replace(edits) end
  return rendered, spans
end

--- Collapse display spaces while retaining indentation and literal destinations.
local function collapse_spaces(text, highlights, links, prefix)
  if not text:find("  ", 1, true) then return text end
  prefix = prefix or 0
  local leading = text:sub(1, prefix) .. text:sub(prefix + 1):match "^(%s*)"
  local removals = {}
  local collapsed = leading
    .. map_display_text(text:sub(#leading + 1), function(part, start)
      return (
        part:gsub("()(  +)", function(pos, spaces)
          removals[#removals + 1] = { start = #leading + start + pos, count = #spaces - 1 }
          return " "
        end)
      )
    end)
  adjust_positions(highlights, links, removals, #highlights, #links)
  return collapsed
end

--- Angle and www autolinks own their source bytes before other inline syntax.
local function protect_autolinks(text, source, ref_links, source_label, sources)
  local spans, pieces, pos = {}, {}, 1
  local edits = sources and {}
  local prefix = inline.token_prefix(source .. text, 0xF1006)
  for _, range in ipairs(inline.autolinks(text, ref_links, source_label)) do
    local token = prefix .. (#spans + 1) .. "\u{F1007}"
    local raw = text:sub(range.start, range.finish)
    local label = range.angle and raw:sub(2, -2) or raw
    local url = range.angle and (label:match "^[A-Za-z][A-Za-z0-9.+-]*:" and label or "mailto:" .. label)
      or "http://" .. label
    spans[#spans + 1] = { placeholder = token, content = raw, raw = raw, label = label, url = url }
    if sources then sources:protect(edits, spans[#spans], range.start - 1, range.finish) end
    pieces[#pieces + 1] = text:sub(pos, range.start - 1) .. token
    pos = range.finish + 1
  end
  pieces[#pieces + 1] = text:sub(pos)
  if sources then sources:replace(edits) end
  return table.concat(pieces), spans
end

local function overlaps_link(links, first, last)
  for _, link in ipairs(links) do
    if first < link.col_end and last > link.col_start then return true end
  end
  return false
end

--- Keep destination colors in the inline stack, before nested emphasis/code.
local function add_link_highlight(highlights, first, last, url)
  local hl = require("md-render.links").highlight(url)
  if hl ~= "MdRenderLink" then table.insert(highlights, { col = first, end_col = last, hl = "Underlined" }) end
  table.insert(highlights, { col = first, end_col = last, hl = hl })
end

--- Process inline and reference links through the same bracket/code scanner
--- Supports balanced brackets for image-in-link patterns like [![alt](img)](url)
---@param text string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_links(text, highlights, links, source_label, ref_links)
  if not text:find("[", 1, true) then return text end
  local indexed_links = inline.scan(text, ref_links, source_label).links
  if not next(indexed_links) then return text end
  local pre_hl_count = #highlights
  local pre_link_count = #links
  local removals = {}
  local processed = ""
  local failed_html = {}
  local i = 1
  while i <= #text do
    local literal_end = text:sub(i, i) == "<"
      and (inline.autolink_end(text, i) or inline.html_end(text, i, failed_html))
    if literal_end then
      processed = processed .. text:sub(i, literal_end)
      i = literal_end + 1
    elseif text:sub(i, i) == "[" then
      local suffix_start, finish, reference_url = link_bounds(text, i, ref_links, source_label, indexed_links)
      if finish then
        local link_text_raw = text:sub(i + 1, suffix_start - 2)
        local url = reference_url or link_destination(source_label(text:sub(suffix_start + 1, finish - 1)))

        -- The same scanner recognizes inline, full, collapsed and shortcut images.
        local image = text:sub(i + 1, i + 1) == "!" and indexed_links[i + 2]
        local alt = image
          and image.image
          and image.finish == suffix_start - 2
          and text:sub(image.start + 1, image.suffix_start - 2)
        local display_text = alt or link_text_raw

        local start_col = #processed
        processed = processed .. display_text
        add_link_highlight(highlights, start_col, start_col + #display_text, url)
        table.insert(links, { col_start = start_col, col_end = start_col + #display_text, url = url, _decoded = true })
        local label_start = alt and image.start or i
        local label_end = alt and image.suffix_start or suffix_start
        table.insert(removals, { start = i - 1, count = label_start - i + 1 })
        table.insert(removals, { start = label_end - 2, count = finish - label_end + 2 })
        i = finish + 1
      else
        processed = processed .. text:sub(i, i)
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  adjust_positions(highlights, links, removals, pre_hl_count, pre_link_count)
  return processed
end

--- Measure rendered URL text while keeping each protected token indivisible.
local function truncate_url(url, max_width, literals)
  local tokens = {}
  for _, spans in ipairs(literals) do
    if #spans > 0 then
      local by_token = {}
      for _, span in ipairs(spans) do
        by_token[span.placeholder] = span
      end
      url:gsub("()(" .. spans[1].placeholder:gsub("%d+", "%%d+") .. ")", function(pos, token)
        tokens[pos] = by_token[token]
      end)
    end
  end
  local pos, width, cut = 1, 0, 0
  local target = max_width - vim.api.nvim_strwidth "…"
  while pos <= #url do
    local span = tokens[pos]
    local char = span and span.content or url:match("^[%z\1-\127\194-\253][\128-\191]*", pos) or url:sub(pos, pos)
    local size = span and #span.placeholder or #char
    width = width + vim.api.nvim_strwidth(char)
    if width <= target then cut = pos + size - 1 end
    if width > max_width then return url:sub(1, cut) .. "…", cut end
    pos = pos + size
  end
  return url
end

--- Keep the established HTTP boundary for decoded tokens and Unicode symbols.
local function trim_autolink(url, literals)
  local previous
  repeat
    previous = url
    url = inline.trim_autolink(url)
    -- Preserve the existing display boundary for trailing Unicode symbols.
    local protected = false
    for _, spans in ipairs(literals) do
      if #spans > 0 and url:match(spans[1].placeholder:gsub("%d+", "%%d+") .. "$") then protected = true end
    end
    if not protected then
      local last = vim.fn.strcharpart(url, vim.fn.strchars(url) - 1, 1)
      if #last > 1 and vim.fn.charclass(last) <= 1 then url = url:sub(1, #url - #last) end
    end
  until previous == url
  return url
end

local function bare_autolink(text, start, literals, code_spans, angle_spans, emphasis_spans)
  local previous = text:sub(start - 1, start - 1)
  -- Retain existing HTTP(S) support for single-label hosts and adjacent prose.
  local scheme = text:match("^(https?://)", start)
  if scheme then
    local url = text:match('^[^%s<>"`]+', start)
    for _, spans in ipairs { code_spans, angle_spans, emphasis_spans or {} } do
      if #spans > 0 then
        local first = url:find(spans[1].placeholder:gsub("%d+", "%%d+"))
        if first then url = url:sub(1, first - 1) end
      end
    end
    url = trim_autolink(url, literals)
    return url, url
  end

  -- Email addresses are recognized within text, with their own ASCII alphabet.
  if previous:find "[A-Za-z0-9._+%-]" then return end
  local protocol = text:match("^(mailto:)", start) or text:match("^(xmpp:)", start) or ""
  local address = text:match("^[A-Za-z0-9._+%-]+@[A-Za-z0-9_.%-]+", start + #protocol)
  if not address then return end
  address = address:gsub("%.+$", "")
  local domain = address:match "@(.+)$"
  if
    not domain
    or domain:sub(1, 1) == "."
    or not domain:find(".", 1, true)
    or domain:find("..", 1, true)
    or not domain:match "[A-Za-z0-9]$"
  then
    return
  end
  local label = protocol .. address
  if protocol == "xmpp:" then label = label .. (text:match("^/[A-Za-z0-9@.]+", start + #label) or "") end
  return label, protocol == "" and "mailto:" .. address or label
end

--- CommonMark flanking uses source characters, not decoded/display text.
delimiter_char = function(char)
  local cp = char ~= "" and wrap_mod.utf8_codepoint(char) or nil
  local space = char == ""
    or char:find "^[ \t\n\r\f]$" ~= nil
    or cp == 0xA0
    or cp == 0x1680
    or (cp and cp >= 0x2000 and cp <= 0x200A)
    or cp == 0x202F
    or cp == 0x205F
    or cp == 0x3000
  if not cp or cp < 128 then return space, char:find "^%p$" ~= nil end
  -- Neovim's word-motion classes differ from Unicode P/S (e.g. × and 々).
  local ranges = require "md-render.unicode_punctuation"
  local first, last = 1, #ranges
  while first <= last do
    local mid = math.floor((first + last) / 2)
    local range = ranges[mid]
    if cp < range[1] then
      last = mid - 1
    elseif cp > range[2] then
      first = mid + 1
    else
      return space, true
    end
  end
  return space, false
end

--- Resolve runs before presentation removes link brackets, comments or URLs.
--- Keep matched markers as source-restorable tokens until link ownership is set.
local function protect_emphasis(text, source, refs, footnotes, code_spans, autolink_spans, source_label, sources)
  if not text:find "[*_~]" then return text, {}, {} end
  local pairs = {}
  local failed_html = {}
  local parsed = inline.scan(text, refs, source_label)
  local standard_ranges = inline.standard_ranges(text, refs, source_label, parsed)
  local function resolve(first, last, in_label, depth)
    if depth > inline.MAX_NESTING then return end
    local openers, lower = {}, {}
    local pos = first
    while pos <= last do
      local char = text:sub(pos, pos)
      local suffix, link_end
      if char == "[" then
        suffix, link_end = inline.link_bounds(text, pos, refs, source_label, parsed.links)
      end
      local wiki_start = text:sub(pos, pos + 1) == "[[" and pos or text:sub(pos, pos + 2) == "![[" and pos + 1
      local wiki_end = wiki_start and text:find("]]", wiki_start + 2, true)
      if wiki_end then
        local inner = text:sub(wiki_start + 2, wiki_end - 1)
        local pipe = inner:find("|", 1, true)
        local target_end = pipe and wiki_start + 1 + pipe or wiki_end + 1
        if extension_owned(inner, {}, code_spans, autolink_spans) then wiki_end = nil end
        if wiki_end and inline.extension_owned(standard_ranges, pos, wiki_end + 1, target_end) then wiki_end = nil end
      end
      local note, note_end = text:match("^%[%^([^%]]+)%]()", pos)
      local literal_end = char == "<" and inline.html_end(text, pos, failed_html)
      local comment_end = text:sub(pos, pos + 1) == "%%" and text:find("%%", pos + 2, true)
      local url = not in_label and bare_autolink(text, pos, {}, code_spans, autolink_spans)
      if char == "\\" and ESCAPABLE_CHARS:find(text:sub(pos + 1, pos + 1), 1, true) then
        pos = pos + 2
      elseif literal_end or comment_end then
        pos = literal_end and literal_end + 1 or comment_end + 2
      elseif note and footnotes and footnotes[source_label(note)] then
        pos = note_end
      elseif wiki_end then
        local label_first, label_last = wiki_start + 2, wiki_end - 1
        if char == "!" then
          local separator = text:find("[|#]", label_first)
          if separator and separator > label_first and separator < wiki_end then label_last = separator - 1 end
        else
          local pipe = text:find("|", label_first, true)
          if pipe and pipe < wiki_end then label_first = pipe + 1 end
        end
        resolve(label_first, label_last, true, depth + 1)
        pos = wiki_end + 2
      elseif link_end then
        resolve(pos + 1, suffix - 2, true, depth + 1)
        pos = link_end + 1
      elseif url then
        pos = pos + #url
      elseif char == "*" or char == "_" or char == "~" then
        local finish = pos
        while finish < last and text:sub(finish + 1, finish + 1) == char do
          finish = finish + 1
        end
        local before_pos, after_pos = pos - 1, finish + 1
        -- GFM's core emphasis scanner skips adjacent extension markers (~).
        -- Its strikethrough scanner still uses the ordinary source flanking.
        if char ~= "~" then
          while text:sub(before_pos, before_pos) == "~" and before_pos > 0 do
            before_pos = before_pos - 1
          end
          while text:sub(after_pos, after_pos) == "~" do
            after_pos = after_pos + 1
          end
        end
        local before, after = char_ending_at(text, before_pos), char_starting_at(text, after_pos)
        if #before > 1 then
          local original = source_label(text:sub(1, before_pos))
          before = char_ending_at(original, #original)
        end
        if #after > 1 then after = char_starting_at(source_label(text:sub(after_pos)), 1) end
        local before_space, before_punct = delimiter_char(before)
        local after_space, after_punct = delimiter_char(after)
        local left = not after_space and (not after_punct or before_space or before_punct)
        local right = not before_space and (not before_punct or after_space or after_punct)
        local run = {
          char = char,
          start = pos,
          length = finish - pos + 1,
          remaining = finish - pos + 1,
          can_open = left and (char ~= "_" or not right or before_punct),
          can_close = right and (char ~= "_" or not left or after_punct),
        }
        -- GFM accepts matching single/double tildes, never a slice of a longer run.
        if char ~= "~" or run.length <= 2 then
          local key = char .. (run.can_open and "open" or "close") .. run.length % 3
          while run.can_close and run.remaining > 0 do
            local index = #openers
            while index > 0 do
              local opener = openers[index]
              if opener.start < (lower[key] or first) then break end
              local compatible = char == "~" and opener.length == run.length
                or (
                  char ~= "~"
                  and (
                    not (opener.can_close or run.can_open)
                    or (opener.length + run.length) % 3 ~= 0
                    or (opener.length % 3 == 0 and run.length % 3 == 0)
                  )
                )
              if opener.char == char and compatible then break end
              index = index - 1
            end
            local opener = openers[index]
            if not opener or opener.start < (lower[key] or first) then
              lower[key] = run.start
              break
            end
            local count = char == "~" and run.length or math.min(2, opener.remaining, run.remaining)
            pairs[#pairs + 1] = {
              first = opener.start + opener.remaining - count,
              last = run.start + run.length - run.remaining,
              count = count,
              hl = char == "~" and "DiagnosticDeprecated" or count == 2 and "Bold" or "Italic",
            }
            opener.remaining, run.remaining = opener.remaining - count, run.remaining - count
            -- Paired spans nest; unmatched interior openers cannot cross a closer.
            for i = #openers, index + (opener.remaining > 0 and 1 or 0), -1 do
              openers[i] = nil
            end
          end
          if run.can_open and run.remaining > 0 then
            run.start = finish - run.remaining + 1
            openers[#openers + 1] = run
          end
        end
        pos = finish + 1
      else
        pos = pos + 1
      end
    end
  end
  resolve(1, #text, false, 0)
  local spans, boundaries, parts, pos = {}, {}, {}, 1
  local prefix = inline.token_prefix(source .. text, 0xF1008)
  for _, pair in ipairs(pairs) do
    for _, field in ipairs { "first", "last" } do
      local start = pair[field]
      local token = prefix .. (#spans + 1) .. "\u{F1009}"
      local span = { placeholder = token, raw = text:sub(start, start + pair.count - 1), content = "" }
      spans[#spans + 1] = span
      boundaries[#boundaries + 1] = { start = start, count = pair.count, token = token, span = span }
      pair[field] = span
    end
  end
  table.sort(boundaries, function(a, b)
    return a.start < b.start
  end)
  local edits = sources and {}
  for _, boundary in ipairs(boundaries) do
    if sources then
      sources:protect(
        edits,
        boundary.span,
        boundary.start - 1,
        boundary.start - 1 + boundary.count,
        SourceMap.constant(0, sources:at(boundary.start - 1))
      )
    end
    parts[#parts + 1] = text:sub(pos, boundary.start - 1) .. boundary.token
    pos = boundary.start + boundary.count
  end
  parts[#parts + 1] = text:sub(pos)
  if sources then sources:replace(edits) end
  return table.concat(parts), spans, pairs
end

local function restore_emphasis(text, spans, pairs, highlights, links)
  text = restore_spans(text, spans, nil, highlights, links)
  for _, pair in ipairs(pairs) do
    local first, last = pair.first.col, pair.last.col
    if first and last then highlights[#highlights + 1] = { col = first, end_col = last, hl = pair.hl } end
  end
  return text
end

--- Recognize autolinks once, preserving their labels through later formatting.
---@param text string
---@param max_url_width integer
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_bare_urls(
  text,
  max_url_width,
  highlights,
  links,
  literals,
  code_spans,
  spans,
  emphasis_spans,
  source
)
  if #spans == 0 and not text:find "https?://" and not text:find("@", 1, true) then return text end
  local pre_hl_count = #highlights
  local pre_link_count = #links
  local existing_links = vim.list_slice(links)
  -- Remaining raw HTML is displayed dimly, but its attributes are not text nodes.
  for _, hl in ipairs(highlights) do
    if hl.hl == "Comment" then existing_links[#existing_links + 1] = { col_start = hl.col, col_end = hl.end_col } end
  end
  table.sort(existing_links, function(a, b)
    return a.col_start < b.col_start
  end)
  local prefix = spans[1] and spans[1].placeholder:match "^(.-)%d+" or inline.token_prefix(source .. text, 0xF1006)
  local protected = {}
  for _, span in ipairs(spans) do
    protected[span.placeholder] = span
  end
  local pattern = spans[1] and spans[1].placeholder:gsub("%d+", "%%d+")
  local parts, output_bytes = {}, 0
  local i, owner_index = 1, 1
  local removals = {}
  local sources = highlights._source_map
  if sources then removals.source_edits = {} end

  while i <= #text do
    -- Owned labels must be excluded before URL trimming scans their suffixes.
    while existing_links[owner_index] and existing_links[owner_index].col_end <= i - 1 do
      owner_index = owner_index + 1
    end
    local owner = existing_links[owner_index]
    if owner and owner.col_start <= i - 1 then
      local part = text:sub(i, owner.col_end)
      parts[#parts + 1] = part
      output_bytes = output_bytes + #part
      i = owner.col_end + 1
      goto next_url
    end
    local token = pattern and text:match("^" .. pattern, i)
    local literal = token and protected[token]
    local label, url
    if literal then
      label, url = literal.label, literal.url
    else
      label, url = bare_autolink(text, i, literals, code_spans, spans, emphasis_spans)
    end
    local length = token and #token or label and #label
    if label and not overlaps_link(existing_links, i - 1, i - 1 + length) then
      local display_url, cut = truncate_url(label, max_url_width, literal and {} or literals)
      local display_sources
      if sources then
        if literal then
          local first = literal.raw:sub(1, 1) == "<" and 1 or 0
          display_sources = literal.raw_sources:slice(first, first + #label)
        else
          display_sources = sources:slice(i - 1, i - 1 + length)
        end
        if cut then
          display_sources = display_sources:slice(0, cut)
          display_sources:replace {
            { first = cut, last = cut, value = SourceMap.constant(#"…", display_sources:at(math.max(0, cut - 1))) },
          }
        end
      end
      if literal then
        literal.content = display_url
        if sources then literal.sources = display_sources end
      else
        token = prefix .. (#spans + 1) .. "\u{F1007}"
        spans[#spans + 1] = { placeholder = token, content = display_url }
        if sources then
          sources:protect(removals.source_edits, spans[#spans], i - 1, i - 1 + length, display_sources)
        end
        removals[#removals + 1] = { start = i - 1 + #token, count = length - #token }
      end
      local first = output_bytes
      parts[#parts + 1] = token
      output_bytes = output_bytes + #token
      add_link_highlight(highlights, first, output_bytes, url)
      links[#links + 1] = { col_start = first, col_end = output_bytes, url = url, _decoded = literal ~= nil }
      i = i + length
    else
      parts[#parts + 1] = text:sub(i, i)
      output_bytes = output_bytes + 1
      i = i + 1
    end
    ::next_url::
  end
  adjust_positions(highlights, links, removals, pre_hl_count, pre_link_count)
  return table.concat(parts)
end

--- Process #123 issue/PR references: make them clickable
---@param text string
---@param repo_base_url string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_issue_refs(text, repo_base_url, highlights, links)
  local processed = ""
  local i = 1
  while i <= #text do
    local s, e = text:find("#%d+", i)
    if s == i and not overlaps_link(links, s - 1, e) then
      local issue_num = text:match("#(%d+)", i)
      local issue_text = "#" .. issue_num
      local url = repo_base_url .. "/issues/" .. issue_num
      local start_col = #processed
      processed = processed .. issue_text
      add_link_highlight(highlights, start_col, start_col + #issue_text, url)
      table.insert(links, { col_start = start_col, col_end = start_col + #issue_text, url = url })
      i = e + 1
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  return processed
end

--- Process autolink references: make key_prefix matches clickable
---@param text string
---@param autolinks MdRender.Autolink[]
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_autolink_refs(text, autolinks, highlights, links)
  local processed = ""
  local i = 1
  while i <= #text do
    local matched = false
    for _, autolink in ipairs(autolinks) do
      local prefix = autolink.key_prefix
      if text:sub(i, i + #prefix - 1) == prefix then
        -- Try to match the value after the prefix
        local rest = text:sub(i + #prefix)
        local value
        if autolink.is_alphanumeric then
          value = rest:match "^([%w]+)"
        else
          value = rest:match "^(%d+)"
        end
        if value and #value > 0 then
          local ref_text = prefix .. value
          if overlaps_link(links, i - 1, i - 1 + #ref_text) then break end
          local url = autolink.url_template:gsub("<num>", value)
          local start_col = #processed
          processed = processed .. ref_text
          add_link_highlight(highlights, start_col, start_col + #ref_text, url)
          table.insert(links, { col_start = start_col, col_end = start_col + #ref_text, url = url })
          i = i + #ref_text
          matched = true
          break
        end
      end
    end
    if not matched then
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  return processed
end

--- Prepend blockquote visual prefix and shift all highlight/link positions
---@param text string
---@param quote_prefix string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string
local function apply_blockquote_prefix(text, quote_prefix, highlights, links)
  local offset = #quote_prefix
  local sources = highlights._source_map
  if sources then sources:replace { { first = 0, last = 0, value = SourceMap.constant(offset, sources:at(0)) } } end
  text = quote_prefix .. text
  table.insert(highlights, 1, { col = 0, end_col = offset, hl = "FloatBorder" })
  for idx = 2, #highlights do
    highlights[idx].col = highlights[idx].col + offset
    highlights[idx].end_col = highlights[idx].end_col + offset
  end
  for _, link in ipairs(links) do
    link.col_start = link.col_start + offset
    link.col_end = link.col_end + offset
  end
  return text
end

--- HTML inline tag definitions: tag names -> highlight group (false = strip tags only)
local HTML_TAG_HIGHLIGHTS = {
  b = "Bold",
  strong = "Bold",
  i = "Italic",
  em = "Italic",
  code = "MdRenderInlineCode",
  s = "DiagnosticDeprecated",
  del = "DiagnosticDeprecated",
  strike = "DiagnosticDeprecated",
  u = "Underlined",
  mark = "MdRenderHighlight",
  kbd = "Special",
  sub = false,
  sup = false,
  figure = false,
  figcaption = "Comment",
}

--- Source-byte ownership shared by inline presentation and document display readers.
function Markdown.html_literal_ranges(text, raw_html, ref_links)
  if not text:find("<", 1, true) then return {} end
  local tokens = inline.html_tags(text)
  if not raw_html then
    local ranges, index = inline.scan(text, ref_links).standard_ranges, 0
    tokens = function()
      repeat
        index = index + 1
      until not ranges[index] or ranges[index].html
      local range = ranges[index]
      if range then return range.start, range.finish, text:sub(range.start, range.finish) end
    end
  end
  local depth, open_tags, ranges = 0, {}, {}
  local owner, excessive
  for first, last, token in tokens do
    local name, closing = inline.html_name(token)
    if HTML_TAG_HIGHLIGHTS[name] ~= nil or name == "a" or name == "video" then
      if closing and (open_tags[name] or 0) > 0 then
        open_tags[name], depth = open_tags[name] - 1, depth - 1
        if depth == 0 then
          if excessive then ranges[#ranges + 1] = { start = owner, finish = last } end
          owner, excessive = nil, nil
        end
      elseif not closing and not token:match "/>$" then
        if depth == 0 then owner = first end
        open_tags[name], depth = (open_tags[name] or 0) + 1, depth + 1
        excessive = excessive or depth > inline.MAX_NESTING
      end
    end
  end
  if excessive then ranges[#ranges + 1] = { start = owner, finish = #text } end
  return ranges
end

--- Preserve excessive owners as literal spans; following ordinary HTML still renders.
local function protect_html_nesting(text, highlights, links, raw_html, ref_links, literal_ranges)
  local ranges = Markdown.html_literal_ranges(text, raw_html, ref_links)
  if literal_ranges and #literal_ranges > 0 then
    vim.list_extend(ranges, literal_ranges)
    table.sort(ranges, function(a, b)
      return a.start < b.start
    end)
    local owners = {}
    for _, range in ipairs(ranges) do
      local previous = owners[#owners]
      if previous and range.start <= previous.finish + 1 then
        previous.finish = math.max(previous.finish, range.finish)
      else
        owners[#owners + 1] = { start = range.start, finish = range.finish }
      end
    end
    ranges = owners
  end
  return protect_ranges(text, text, ranges, highlights, links)
end

--- Process HTML tags: <a href> links, <img> images, and paired inline tags
--- Matched code spans are already protected by the caller.
---@param text string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_html_tags(text, highlights, links, decode_url, keep_rows, semantic)
  if not text:find("<", 1, true) then return text end
  local html_closing = inline.html_closing_index(text)
  local pre_hl_count = #highlights
  local pre_link_count = #links
  local removals = {}
  local sources = highlights._source_map
  if sources then removals.source_edits = {} end
  local function remove_tag(start, tag, replacement_bytes, replacement_sources, closing)
    local rows = keep_rows and tag:gsub("[^\n]", "") or ""
    if sources then
      local value = replacement_sources or SourceMap.constant(replacement_bytes or 0, sources:at(start))
      -- Closing-tag rows are discarded by the display caller, rather than copied.
      if #rows > 0 and not closing then
        local row_sources, edits = sources:slice(start, start + #tag), {}
        for first, last in tag:gmatch "()[^\n]+()" do
          edits[#edits + 1] = { first = first - 1, last = last - 1 }
        end
        row_sources:replace(edits)
        value:replace { { first = value.length, last = value.length, value = row_sources } }
      end
      removals.source_edits[#removals.source_edits + 1] = { first = start, last = start + #tag, value = value }
    end
    replacement_bytes = (replacement_bytes or 0) + #rows
    table.insert(removals, { start = start + replacement_bytes, count = #tag - replacement_bytes })
    return rows
  end
  local function media_sources(start, label, first, icon)
    if not sources then return nil end
    local value = first and sources:slice(start + first - 1, start + first - 1 + #label)
      or SourceMap.constant(0, sources:at(start))
    value:replace { { first = 0, last = 0, value = SourceMap.constant(#icon, sources:at(start)) } }
    return value
  end
  local processed = ""
  local failed_html = {}
  local i = 1
  while i <= #text do
    if text:sub(i, i) == "<" then
      local tag_end = inline.html_end(text, i, failed_html)
      local opening_tag = tag_end and text:sub(i, tag_end)
      local matched = false

      -- Try <a href="...">text</a>
      local tag_name, closing = inline.html_name(opening_tag or "")
      local a_tag = tag_name == "a" and not closing and opening_tag
      if a_tag then
        local href = inline.html_target(a_tag)
        local close_start, close_end = html_closing("a", i + #a_tag)
        if href and close_start then
          href = decode_url(href)
          local content = text:sub(i + #a_tag, close_start - 1)
          processed = processed .. remove_tag(i - 1, a_tag)
          remove_tag(close_start - 1, text:sub(close_start, close_end), nil, nil, true)
          local start_col = #processed
          processed = processed .. content
          add_link_highlight(highlights, start_col, start_col + #content, href)
          table.insert(links, { col_start = start_col, col_end = start_col + #content, url = href, _decoded = true })
          i = close_end + 1
          matched = true
        end
      end

      -- Try <img src="..." alt="...">
      if not matched then
        local img_tag = tag_name == "img" and not closing and opening_tag
        if img_tag then
          local src, src_first = inline.html_target(img_tag)
          if src then
            local display_name = src:match "([^/]+)$" or src
            local basename_first = src_first + #src - #display_name
            src = decode_url(src)
            local alt, quoted, alt_first = inline.html_attribute(img_tag, "alt")
            if not quoted then alt = nil end
            local icons_mod = require "md-render.icons"
            local raw_img_icon, img_icon_hl = icons_mod.get_image_icon(src)
            local img_icon = semantic and "" or icons_mod.pad_icon(raw_img_icon) .. " "
            local display = semantic and (alt or "") or img_icon .. ((alt and alt ~= "") and alt or display_name)
            if keep_rows then display = display:gsub("[\r\n]", " ") end
            local label = semantic and (alt or "") or ((alt and alt ~= "") and alt or display_name)
            local first = alt and (semantic or alt ~= "") and alt_first or basename_first
            local tag_rows = remove_tag(i - 1, img_tag, #display, media_sources(i - 1, label, first, img_icon))
            local start_col = #processed
            processed = processed .. display
            if img_icon_hl and not semantic then
              table.insert(highlights, { col = start_col, end_col = start_col + #img_icon - 1, hl = img_icon_hl })
            end
            add_link_highlight(highlights, start_col + #img_icon, start_col + #display, src)
            table.insert(links, { col_start = start_col, col_end = start_col + #display, url = src, _decoded = true })
            processed = processed .. tag_rows
            i = i + #img_tag
            matched = true
          end
        end
      end

      -- Try <video src="...">...</video> or <video><source src="...">...</video>
      if not matched then
        local video_end = opening_tag
          and tag_name == "video"
          and not closing
          and select(2, html_closing("video", i + #opening_tag))
        local video_tag = video_end and text:sub(i, video_end)
        if video_tag then
          local src, src_first = inline.html_target(video_tag)
          if src then
            local display_name = src:match "([^/]+)$" or src
            local basename_first = src_first + #src - #display_name
            src = decode_url(src)
            local icons_mod = require "md-render.icons"
            local raw_icon, icon_hl = icons_mod.get_image_icon(src)
            local img_icon = semantic and "" or icons_mod.pad_icon(raw_icon) .. " "
            local display = semantic and "" or img_icon .. display_name
            if keep_rows then display = display:gsub("[\r\n]", " ") end
            local label = semantic and "" or display_name
            local tag_rows =
              remove_tag(i - 1, video_tag, #display, media_sources(i - 1, label, basename_first, img_icon))
            local start_col = #processed
            processed = processed .. display
            if icon_hl and not semantic then
              table.insert(highlights, { col = start_col, end_col = start_col + #img_icon - 1, hl = icon_hl })
            end
            add_link_highlight(highlights, start_col + #img_icon, start_col + #display, src)
            table.insert(links, { col_start = start_col, col_end = start_col + #display, url = src, _decoded = true })
            processed = processed .. tag_rows
            i = i + #video_tag
            matched = true
          end
        end
      end

      -- Try paired HTML tags (<b>, <strong>, <em>, etc.)
      if not matched then
        local paired_name = text:match("^<(%a+)[%s>]", i)
        if paired_name then
          local lower_tag = paired_name:lower()
          local hl = HTML_TAG_HIGHLIGHTS[lower_tag]
          if hl ~= nil then
            local open_tag = opening_tag
            if open_tag then
              local close_start, close_end = html_closing(paired_name, i + #open_tag)
              if close_start then
                local content = text:sub(i + #open_tag, close_start - 1)
                processed = processed .. remove_tag(i - 1, open_tag)
                remove_tag(close_start - 1, text:sub(close_start, close_end), nil, nil, true)
                local start_col = #processed
                processed = processed .. content
                if hl then table.insert(highlights, { col = start_col, end_col = start_col + #content, hl = hl }) end
                i = close_end + 1
                matched = true
              end
            end
          end
        end
      end

      if not matched then
        local literal = opening_tag or text:sub(i, i)
        processed = processed .. literal
        i = i + #literal
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  adjust_positions(highlights, links, removals, pre_hl_count, pre_link_count)
  return processed
end

--- Process Obsidian-style #tags: highlight tag text.
--- Tags must contain at least one non-digit character to avoid confusion with issue refs.
---@param text string
---@param highlights MdRender.Markdown.Highlight[]
---@return string processed
local function process_tags(text, highlights)
  if not text:find("#", 1, true) then return text end
  local processed = ""
  local i = 1
  while i <= #text do
    if text:sub(i, i) == "#" then
      local prev_char = i > 1 and text:sub(i - 1, i - 1) or ""
      local at_boundary = prev_char == "" or prev_char:match "%s"
      if at_boundary then
        local tag = text:match("^#([%w_/-][%w_/%-]*)", i)
        if tag and tag:match "%a" then
          local full = "#" .. tag
          local start_col = #processed
          processed = processed .. full
          table.insert(highlights, { col = start_col, end_col = start_col + #full, hl = "MdRenderTag" })
          i = i + #full
        else
          processed = processed .. "#"
          i = i + 1
        end
      else
        processed = processed .. "#"
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  return processed
end

--- Unicode superscript digit characters
local SUPERSCRIPT_DIGITS = { "⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹" }

--- Convert a number to superscript Unicode string
---@param n integer
---@return string
local function to_superscript(n)
  local s = tostring(n)
  local result = {}
  for i = 1, #s do
    local d = tonumber(s:sub(i, i))
    table.insert(result, SUPERSCRIPT_DIGITS[d + 1])
  end
  return table.concat(result)
end

--- Process footnote references [^id] → superscript number with highlight and link
---@param text string
---@param footnote_map table<string, integer> footnote label → number mapping
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_footnote_refs(text, footnote_map, highlights, links, source_label)
  if not footnote_map or not next(footnote_map) then return text end
  local pre_hl_count, pre_link_count, removals = #highlights, #links, {}
  local sources = highlights._source_map
  if sources then removals.source_edits = {} end
  local processed = ""
  local i = 1
  while i <= #text do
    if text:sub(i, i + 1) == "[^" then
      local close = text:find("]", i + 2, true)
      if close then
        local label = source_label(text:sub(i + 2, close - 1))
        local num = footnote_map[label]
        if num then
          local display = to_superscript(num)
          local start_col = #processed
          processed = processed .. display
          table.insert(highlights, { col = start_col, end_col = start_col + #display, hl = "Special" })
          table.insert(
            links,
            { col_start = start_col, col_end = start_col + #display, url = "#footnote-def-" .. label, _decoded = true }
          )
          removals[#removals + 1] = { start = i - 1 + #display, count = close + 1 - i - #display }
          if sources then
            removals.source_edits[#removals.source_edits + 1] = {
              first = i - 1,
              last = close,
              value = SourceMap.constant(#display, sources:at(i - 1)),
            }
          end
          i = close + 1
        else
          processed = processed .. text:sub(i, i)
          i = i + 1
        end
      else
        processed = processed .. text:sub(i, i)
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  adjust_positions(highlights, links, removals, pre_hl_count, pre_link_count)
  return processed
end

--- Process inline math $...$ by removing dollar signs and adding highlights.
--- Skips $$ (display math) and content inside backticks.
---@param text string
---@param hl_group string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_inline_math(text, hl_group, highlights, links)
  local pre_hl_count = #highlights
  local pre_link_count = #links
  local removals = {}
  local processed = ""
  local i = 1
  while i <= #text do
    if text:sub(i, i) == "$" and text:sub(i, i + 1) ~= "$$" then
      local e = text:find("%$", i + 1)
      if e and e > i + 1 then
        local content = text:sub(i + 1, e - 1)
        if not content:match "^%s" and not content:match "%s$" then
          table.insert(removals, { start = i - 1, count = 1 })
          table.insert(removals, { start = e - 1, count = 1 })
          local start_col = #processed
          processed = processed .. content
          table.insert(highlights, { col = start_col, end_col = start_col + #content, hl = hl_group })
          i = e + 1
        else
          processed = processed .. "$"
          i = i + 1
        end
      else
        processed = processed .. "$"
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  adjust_positions(highlights, links, removals, pre_hl_count, pre_link_count)
  return processed
end

--- Keep remaining HTML tags with a dim highlight (tags not handled by process_html_tags)
--- Matched code spans are already protected by the caller.
---@param text string
---@param highlights MdRender.Markdown.Highlight[]
---@return string processed
local function strip_html_tags(text, highlights, semantic)
  if not text:find("<", 1, true) then return text end
  local processed = ""
  local removals = {}
  local failed_html = {}
  local i = 1
  while i <= #text do
    if text:sub(i, i) == "<" then
      local tag_end = inline.html_end(text, i, failed_html)
      local tag = tag_end and text:sub(i, tag_end)
      if tag and tag:match "^</?%a" and not inline.autolink_end(text, i) then
        local start_col = #processed
        if not semantic then
          processed = processed .. tag
          table.insert(highlights, { col = start_col, end_col = start_col + #tag, hl = "Comment" })
        else
          removals[#removals + 1] = { start = i - 1, count = #tag }
        end
        i = i + #tag
      else
        processed = processed .. text:sub(i, i)
        i = i + 1
      end
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  if highlights._source_map then highlights._source_map:removals(removals) end
  return processed
end

local function normalize_line_endings(text, sources)
  if sources and text:find("\r\n", 1, true) then
    local removals = {}
    for pos in text:gmatch "()\r\n" do
      removals[#removals + 1] = { start = pos - 1, count = 1 }
    end
    sources:removals(removals)
  end
  return (text:gsub("\r\n", "\n"):gsub("\r", "\n"))
end

--- Apply supported HTML display semantics without activating Markdown syntax.
--- Physical source breaks survive tag removal, including multiline attributes.
function Markdown.render_html(text, semantic, literal_ranges, sources)
  text = normalize_line_endings(text, sources)
  local source = text
  local highlights, links = {}, {}
  highlights._source_map = sources
  local nested_html
  text, nested_html = protect_html_nesting(text, highlights, links, true, nil, literal_ranges)
  local entities
  -- Hidden literal bytes must also be excluded from the entity token namespace.
  text, entities = protect_entities(text, source, true, sources)
  text = inline.hide_html_comments(text, sources)
  for _ = 1, inline.MAX_NESTING do
    local previous = text
    text = process_html_tags(text, highlights, links, function(url)
      return restore_spans(url, entities)
    end, true, semantic)
    if text == previous then break end
  end
  text = strip_html_tags(text, highlights, semantic)
  text = restore_spans(text, nested_html, "Comment", highlights, links)
  for _, span in ipairs(entities) do
    span.content = span.content:gsub("[\r\n]", " ")
  end
  text = restore_spans(text, entities, nil, highlights, links)
  for _, link in ipairs(links) do
    link._decoded = nil
  end
  highlights._source_map = nil
  return text, highlights, links
end

local function span_boundaries(highlights, links)
  local starts, ends = {}, {}
  for _, hl in ipairs(highlights) do
    starts[hl.col], ends[hl.end_col] = true, true
  end
  for _, link in ipairs(links) do
    starts[link.col_start], ends[link.col_end] = true, true
  end
  return starts, ends
end

--- Fold source soft breaks only after syntax recognition; CJK gaps disappear.
local function display_soft_breaks(text, highlights, links)
  if not text:find("\n", 1, true) then return text end
  local starts, ends = span_boundaries(highlights, links)
  local removals = {}
  local rendered = text:gsub("()([ \t]*\n+)", function(pos, breaks)
    local replacement = " "
    if
      not (ends[pos - 1] and starts[pos + #breaks - 1])
      and wrap_mod.is_east_asian_wide(char_ending_at(text, pos - 1))
      and wrap_mod.is_east_asian_wide(char_starting_at(text, pos + #breaks))
    then
      replacement = ""
    end
    local removed = #breaks - #replacement
    if removed > 0 then removals[#removals + 1] = { start = pos - 1 + #replacement, count = removed } end
    return replacement
  end)
  adjust_positions(highlights, links, removals, #highlights, #links)
  return rendered
end

--- Drop the spaces a Japanese author puts around an inline marker only so that
--- a lenient parser recognises it.
---
--- `これは **強調** です。` is written that way because some parsers miss a
--- `**` that is not surrounded by whitespace.  CommonMark needs no such help
--- (`これは**強調**です。` emphasises just fine), so once the markers are gone
--- those spaces are pure markup and read as unwanted gaps.  They are dropped
--- when the characters on both sides are East Asian wide — the same rule
--- `display_soft_breaks()` applies to the space CommonMark inserts at a soft
--- line break, and the same rule Japanese typography uses for the space
--- between a wide and a narrow character.  `これは **API** です。` therefore
--- keeps its spaces, because `API` is narrow and the gap belongs there.
---
--- A space is only dropped when exactly one of its sides is a span boundary.
--- The space in `**あ** **い**`, or between two adjacent links, is the only
--- thing holding the two spans apart on screen, so it stays.
---@param text string fully processed line, inline markers already removed
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function drop_marker_spaces(text, highlights, links)
  if not text:find(" ", 1, true) then return text end

  -- Span boundaries are the record of where the removed markers used to be.
  local span_starts, span_ends = span_boundaries(highlights, links)

  local removals = {}
  local pos = text:find(" ", 1, true)
  while pos do
    -- `pos` is 1-indexed; span boundaries are 0-indexed columns.
    local ends_before = span_ends[pos - 1] or false
    local starts_after = span_starts[pos] or false
    if ends_before ~= starts_after then
      local before = char_ending_at(text, pos - 1)
      local after = char_starting_at(text, pos + 1)
      if wrap_mod.is_east_asian_wide(before) and wrap_mod.is_east_asian_wide(after) then
        table.insert(removals, { start = pos - 1, count = 1 })
      end
    end
    pos = text:find(" ", pos + 1, true)
  end
  if #removals == 0 then return text end

  local parts = {}
  local prev = 1
  for _, r in ipairs(removals) do
    table.insert(parts, text:sub(prev, r.start))
    prev = r.start + 2
  end
  table.insert(parts, text:sub(prev))
  adjust_positions(highlights, links, removals, #highlights, #links)
  return table.concat(parts)
end

--- Render markdown text to plain text with highlight and link metadata
---@param text string The markdown text to render
---@param repo_base_url? string Optional repository base URL for issue/PR references
---@param autolinks? MdRender.Autolink[] Optional autolink definitions
---@param ref_links? table<string, string> Optional reference link definitions (normalized label -> URL)
---@param footnote_map? table<string, integer>
---@param inline_only? boolean Leave block markers literal in cells, captions and other inline contexts
---@param block_context? {heading_level?: integer, list_marker?: boolean, raw_html?: boolean, quote_prefix?: string} accepted document block syntax
---@param track_sources? boolean retain physical source row origins for joined paragraphs
---@return string rendered_text The rendered plain text
---@return MdRender.Markdown.Highlight[] highlights
---@return MdRender.Markdown.Link[] links
---@return string? special_type Special type like "heading" if applicable
---@return string? list_marker List marker if applicable
---@return string? alert_type Alert type (NOTE, TIP, etc.) if applicable
---@return string? fold_mod Callout fold modifier if applicable
---@return string? heading_content Original heading content if applicable
---@return MdRender.Markdown.Break[] hard_breaks Mandatory row boundaries in the newline-free text
---@return {col: integer, source_line: integer}[]? source_runs physical source owners of rendered bytes
Markdown.render = function(
  text,
  repo_base_url,
  autolinks,
  ref_links,
  footnote_map,
  inline_only,
  block_context,
  track_sources
)
  local raw_html = block_context and block_context.raw_html
  local semantic = block_context and block_context.semantic
  inline_only = inline_only == true or (raw_html and not block_context.heading_level)
  local rendered_text = text
  local highlights = {}
  local links = {}
  local hard_break_spans = {}
  local sources

  local function finish(special_type, list_marker, alert_type, fold_mod, heading_content)
    rendered_text = restore_spans(rendered_text:gsub("[\r\n]", " "), hard_break_spans, nil, highlights, links)
    local breaks = {}
    for _, span in ipairs(hard_break_spans) do
      if span.col then breaks[#breaks + 1] = { col = span.col, source_line = span.source_line } end
    end
    highlights._source_map = nil
    return rendered_text,
      highlights,
      links,
      special_type,
      list_marker,
      alert_type,
      fold_mod,
      heading_content,
      breaks,
      sources and sources.runs
  end

  -- Blockquote (> ) - extract prefix
  local quote_prefix = ""
  local is_blockquote = false
  local quote_depth = 0
  while not inline_only and quote_depth < inline.MAX_NESTING and rendered_text:match "^>[ \t]?" do
    rendered_text = rendered_text:gsub("^>[ \t]?", "", 1)
    quote_prefix = quote_prefix .. "│ "
    is_blockquote = true
    quote_depth = quote_depth + 1
  end

  if is_blockquote and block_context and block_context.quote_prefix then quote_prefix = block_context.quote_prefix end
  if quote_depth == inline.MAX_NESTING and rendered_text:match "^>" then
    rendered_text = apply_blockquote_prefix(rendered_text, quote_prefix, highlights, links)
    return finish "blockquote"
  end

  -- ATX syntax belongs to the content, after its quote containers.
  local heading_level, heading_content
  if not inline_only then
    if block_context and block_context.heading_level then
      heading_level = block_context.heading_level
      heading_content = raw_html and rendered_text or rendered_text:gsub("^[ \t]+", ""):gsub("[ \t]+$", "")
    else
      heading_level, heading_content = Markdown.parse_atx_heading(rendered_text)
    end
  end
  if heading_level then rendered_text = heading_content end

  -- Detect alert/callout syntax [!TYPE], [!TYPE]+, [!TYPE]- with optional title
  if is_blockquote and not heading_level then
    local alert_key, fold_mod, custom_title
    -- Try: [!TYPE]+/- Title
    alert_key, fold_mod, custom_title = rendered_text:match "^%[!(%a+)%]([+-])%s+(.+)$"
    if not alert_key then
      -- Try: [!TYPE] Title (no fold modifier)
      alert_key, custom_title = rendered_text:match "^%[!(%a+)%]%s+(.+)$"
    end
    if not alert_key then
      -- Try: [!TYPE]+/- (no title)
      alert_key, fold_mod = rendered_text:match "^%[!(%a+)%]([+-])$"
    end
    if not alert_key then
      -- Try: [!TYPE] (no fold modifier, no title)
      alert_key = rendered_text:match "^%[!(%a+)%]$"
    end
    if alert_key then
      alert_key = alert_key:upper()
      local alert = ALERT_TYPES[alert_key]
      local style_key, icon, label
      if alert then
        style_key = alert.style or alert_key
        icon = alert.icon
        label = alert.label
      else
        -- Unknown callout type: use a generic style
        style_key = "NOTE"
        icon = "❝"
        -- Capitalize: first letter upper, rest lower
        label = alert_key:sub(1, 1) .. alert_key:sub(2):lower()
      end
      local padded_icon = pad_icon(icon)
      if custom_title then
        rendered_text = padded_icon .. " " .. custom_title
      else
        rendered_text = padded_icon .. " " .. label
      end
      rendered_text = apply_blockquote_prefix(rendered_text, quote_prefix, highlights, links)
      return finish("blockquote", nil, style_key, fold_mod)
    end
  end

  -- Track before list/task presentation, which can consume a physical newline.
  if track_sources then
    sources = SourceMap.new(rendered_text)
    highlights._source_map = sources
  end

  -- List items (- * + 1. 1)) - detect marker
  local list_marker
  local list_content
  if not inline_only and not heading_level and (not block_context or block_context.list_marker ~= false) then
    local _, _, prefix = Markdown.list_marker_type(rendered_text)
    -- Display numbering can exceed the source marker's nine-digit limit.
    if not prefix and block_context and block_context.list_marker then
      prefix = rendered_text:match "^([ \t]*%d+[.)][ \t]+)" or rendered_text:match "^([ \t]*%d+[.)])$"
    end
    if prefix then
      list_content = rendered_text:sub(#prefix + 1)
      list_marker = prefix:gsub("[ \t]*$", " ", 1)
      if sources then
        sources:replace { { first = 0, last = #prefix, value = SourceMap.constant(#list_marker, sources:at(0)) } }
      end
      rendered_text = list_marker .. list_content
    end
  end

  -- Checkbox (- [ ] / - [x] / - [X] / - [-]) - replace marker + checkbox with icon
  local checkbox_hl = nil
  if list_marker then
    local after_marker = rendered_text:sub(#list_marker + 1)
    -- Preserve empty tasks; following text needs separating whitespace.
    local cb_match, cb_char = after_marker:match "^(%[([xX %-])%]%f[%s%z]%s?)"
    if cb_match then
      local icon
      if cb_char == " " then
        icon = pad_icon "󰄱" .. " "
        checkbox_hl = "Comment"
      elseif cb_char == "-" then
        icon = pad_icon "󰡖" .. " "
        checkbox_hl = "DiagnosticWarn"
      else
        icon = pad_icon "󰄲" .. " "
        checkbox_hl = "DiagnosticOk"
      end
      local indent_part = list_marker:match "^(%s*)" or ""
      if sources then
        sources:replace {
          {
            first = 0,
            last = #list_marker + #cb_match,
            value = SourceMap.constant(#indent_part + #icon, sources:at(0)),
          },
        }
      end
      list_marker = indent_part .. icon
      rendered_text = list_marker .. after_marker:sub(#cb_match + 1)
    end
  end

  -- Replace bullet markers with symbols based on nesting level
  if list_marker and not checkbox_hl then
    local indent_part = list_marker:match "^(%s*)" or ""
    if list_marker:match "[-*+]" then
      local bullet_icons = { "•", "◦", "▪" }
      local nesting_level = math.floor(#indent_part / 2)
      local icon = bullet_icons[(nesting_level % #bullet_icons) + 1] .. " "
      if sources then
        sources:replace {
          { first = 0, last = #list_marker, value = SourceMap.constant(#indent_part + #icon, sources:at(0)) },
        }
      end
      list_marker = indent_part .. icon
      rendered_text = list_marker .. list_content
    end
  end

  -- Establish code boundaries before whitespace or comment transformations.
  local code_spans, invalid_destinations
  if raw_html then
    code_spans, invalid_destinations = {}, {}
  else
    rendered_text, code_spans = inline.protect_code(rendered_text, ref_links, sources)
    rendered_text, invalid_destinations = inline.protect_invalid_destinations(rendered_text, ref_links, function(label)
      return restore_source(label, code_spans)
    end, sources)
  end
  rendered_text = normalize_line_endings(rendered_text, sources)
  if checkbox_hl then
    local spaces = rendered_text:sub(#list_marker + 1):match "^ +" or ""
    if sources then sources:replace { { first = #list_marker, last = #list_marker + #spaces } } end
    rendered_text = list_marker .. rendered_text:sub(#list_marker + #spaces + 1)
  end

  -- Fast path: skip all inline processing for plain text lines that contain
  -- no markdown-significant characters.  This dramatically speeds up rendering
  -- of large documents (e.g. classical Chinese texts) where most lines are
  -- pure prose with no formatting.
  local needs_inline = rendered_text:find "[%*_~`%[<>=!$\\&#%%@]"
    or rendered_text:find "https?://"
    or rendered_text:find("www.", 1, true)
    or (autolinks and #autolinks > 0)
    or (footnote_map and next(footnote_map) and rendered_text:find "%[%^")
  -- Declare locals before the fast-path goto so they are in scope at ::finalize::
  local backslash_escapes, entity_spans, autolink_spans, emphasis_spans, emphasis_pairs, comment_spans
  local standard_spans, html_ranges, html_spans, html_pos, nested_html, failed_html
  local decode_url, source_label

  if raw_html then
    rendered_text, highlights, links =
      Markdown.render_html(rendered_text, semantic, block_context.literal_html_ranges, sources)
    highlights._source_map = sources
    rendered_text = rendered_text:gsub("\n", " ")
    goto finalize
  end

  if not needs_inline and #code_spans == 0 and not rendered_text:find "  +\n" then
    if not semantic then
      rendered_text = display_soft_breaks(rendered_text, highlights, links)
      rendered_text = collapse_spaces(rendered_text, highlights, links, checkbox_hl and #list_marker or 0)
    end
    goto finalize
  end

  rendered_text, nested_html = protect_html_nesting(rendered_text, highlights, links, false, ref_links)
  for _, span in ipairs(nested_html) do
    span.content =
      restore_source(restore_source(span.content, code_spans, span.sources), invalid_destinations, span.sources)
  end
  rendered_text, autolink_spans = protect_autolinks(rendered_text, text, ref_links, function(label)
    return restore_source(restore_source(label, code_spans), invalid_destinations)
  end, sources)
  rendered_text, emphasis_spans, emphasis_pairs = protect_emphasis(
    rendered_text,
    text,
    ref_links,
    footnote_map,
    code_spans,
    autolink_spans,
    function(label)
      return restore_source(restore_source(restore_source(label, code_spans), invalid_destinations), autolink_spans)
    end,
    sources
  )
  rendered_text, hard_break_spans = protect_hard_breaks(rendered_text, text, ref_links, function(label)
    return restore_source(
      restore_source(restore_source(restore_source(label, emphasis_spans), autolink_spans), code_spans),
      invalid_destinations
    )
  end, function(pos)
    return bare_autolink(rendered_text, pos, {}, code_spans, autolink_spans, emphasis_spans)
  end, sources)
  rendered_text, entity_spans = protect_entities(rendered_text, text, nil, sources)
  rendered_text, comment_spans = protect_comments(rendered_text, text, sources)
  rendered_text, backslash_escapes = escape_backslashes(rendered_text, text, true, sources)

  decode_url = function(url)
    return restore_spans(restore_spans(restore_spans(url, comment_spans), backslash_escapes), entity_spans)
  end
  source_label = function(label)
    label = restore_source(label, comment_spans)
    label = restore_source(label, hard_break_spans)
    label = restore_source(restore_source(label, emphasis_spans), autolink_spans)
    return restore_source(
      restore_source(restore_source(restore_source(label, entity_spans), backslash_escapes), code_spans),
      invalid_destinations
    )
  end

  -- Standard labels, destinations and HTML attributes are opaque to extensions.
  rendered_text, standard_spans = protect_ranges(
    rendered_text,
    text,
    inline.standard_ranges(rendered_text, ref_links, source_label),
    highlights,
    links
  )
  rendered_text = process_embeds(
    rendered_text,
    highlights,
    links,
    emphasis_spans,
    hard_break_spans,
    standard_spans,
    code_spans,
    autolink_spans,
    decode_url,
    semantic
  )
  rendered_text = process_wikilinks(
    rendered_text,
    highlights,
    links,
    emphasis_spans,
    hard_break_spans,
    standard_spans,
    code_spans,
    autolink_spans,
    decode_url
  )
  rendered_text = process_footnote_refs(rendered_text, footnote_map, highlights, links, source_label)
  rendered_text = restore_spans(rendered_text, standard_spans, nil, highlights, links)
  rendered_text = process_links(rendered_text, highlights, links, source_label, ref_links)
  -- Link/reference ownership is settled before comments leave the display.
  rendered_text = restore_spans(rendered_text, comment_spans, nil, highlights, links)
  -- Explicit/reference validity is settled; later autolinks need real parentheses.
  rendered_text = restore_spans(rendered_text, invalid_destinations, nil, highlights, links)
  for _ = 1, inline.MAX_NESTING do
    local prev = rendered_text
    rendered_text = process_html_tags(rendered_text, highlights, links, decode_url, nil, semantic)
    if rendered_text == prev then break end
  end
  rendered_text = strip_html_tags(rendered_text, highlights, semantic)
  html_ranges, html_pos, failed_html = {}, 1, {}
  while html_pos <= #rendered_text do
    local html_end = rendered_text:sub(html_pos, html_pos) == "<"
      and inline.html_end(rendered_text, html_pos, failed_html)
    if html_end then html_ranges[#html_ranges + 1] = { start = html_pos, finish = html_end } end
    html_pos = (html_end or html_pos) + 1
  end
  rendered_text, html_spans = protect_ranges(rendered_text, text, html_ranges, highlights, links)
  rendered_text = process_bare_urls(
    rendered_text,
    semantic and math.huge or MAX_URL_DISPLAY_WIDTH,
    highlights,
    links,
    { backslash_escapes, entity_spans },
    code_spans,
    autolink_spans,
    emphasis_spans,
    text
  )
  if repo_base_url then rendered_text = process_issue_refs(rendered_text, repo_base_url, highlights, links) end
  if autolinks and #autolinks > 0 then
    rendered_text = process_autolink_refs(rendered_text, autolinks, highlights, links)
  end
  rendered_text = process_tags(rendered_text, highlights)
  rendered_text = restore_emphasis(rendered_text, emphasis_spans, emphasis_pairs, highlights, links)
  rendered_text = process_paired_markers(rendered_text, "==([^=]+)==", "MdRenderHighlight", 2, highlights, links)
  rendered_text = process_inline_math(rendered_text, "MdRenderMath", highlights, links)
  rendered_text = restore_spans(rendered_text, html_spans, nil, highlights, links)

  -- Restore each source token once. Decoded destinations from reference
  -- definitions already crossed this boundary and must not be interpreted again.
  for _, link in ipairs(links) do
    if not link._decoded then link.url = decode_url(link.url) end
    link._decoded = nil
  end
  if not semantic then rendered_text = display_soft_breaks(rendered_text, highlights, links) end
  -- Validate labels in their original spelling before display-space collapse.
  -- Code and entities remain protected, and generated checkbox padding stays.
  if not semantic then
    rendered_text = collapse_spaces(rendered_text, highlights, links, checkbox_hl and #list_marker or 0)
  end
  rendered_text = restore_spans(rendered_text, nested_html, "Comment", highlights, links)
  rendered_text = restore_spans(rendered_text, autolink_spans, nil, highlights, links)
  rendered_text = restore_spans(rendered_text, backslash_escapes, nil, highlights, links)
  rendered_text = restore_spans(rendered_text, code_spans, "MdRenderInlineCode", highlights, links)
  rendered_text = restore_spans(rendered_text, entity_spans, nil, highlights, links)
  -- Entity line endings are inline whitespace, never additional buffer rows.
  rendered_text = rendered_text:gsub("[\r\n]", " ")

  -- Close up the CJK gaps left behind by the removed markers.  Runs last so
  -- that every span boundary is final, and before the heading/list/blockquote
  -- highlights below, which are not inline spans.
  if not semantic then rendered_text = drop_marker_spaces(rendered_text, highlights, links) end

  ::finalize::

  -- Add heading icon and highlight
  if heading_level then
    local icon = Markdown.heading_icon_prefix(heading_level)
    local icon_len = #icon
    -- Shift all existing highlights and links by the icon length
    for _, hl in ipairs(highlights) do
      hl.col = hl.col + icon_len
      hl.end_col = hl.end_col + icon_len
    end
    for _, link in ipairs(links) do
      link.col_start = link.col_start + icon_len
      link.col_end = link.col_end + icon_len
    end
    rendered_text = icon .. rendered_text
    local hl_group = "MdRenderH" .. heading_level
    table.insert(highlights, 1, { col = 0, end_col = #rendered_text, hl = hl_group })
    if is_blockquote then rendered_text = apply_blockquote_prefix(rendered_text, quote_prefix, highlights, links) end
    return finish(is_blockquote and "blockquote" or "heading", nil, nil, nil, heading_content)
  end

  -- Add list marker and checkbox highlight
  if list_marker then
    if checkbox_hl then
      local indent_len = #(list_marker:match "^(%s*)" or "")
      table.insert(highlights, 1, { col = indent_len, end_col = #list_marker, hl = checkbox_hl })
    else
      table.insert(highlights, 1, { col = 0, end_col = #list_marker, hl = "Special" })
    end
  end

  -- Prepend blockquote prefix
  if is_blockquote then
    rendered_text = apply_blockquote_prefix(rendered_text, quote_prefix, highlights, links)
    return finish("blockquote", list_marker)
  end

  return finish(nil, list_marker)
end

--- Parse footnote definitions from document lines.
--- Returns ordered list of {label, text} and a label→number mapping.
---@param lines string[]
---@param opts? {continuation_only?: table<integer, boolean>}
---@return {label: string, text: string}[] definitions
---@return table<string, integer> label_to_number
---@return table<integer, boolean> consumed physical input rows
Markdown.parse_footnotes = function(lines, opts)
  local defs = {}
  local label_to_num = {}
  local current_label = nil
  local current_parts = {}
  local current_rows, consumed = {}, {}
  local open_fence = nil

  local function flush()
    if current_label then
      if not label_to_num[current_label] then
        local definition = { label = current_label, text = wrap_mod.join_source_lines(current_parts) }
        if opts then
          definition.source_line, definition.source_lines = current_rows[1], current_rows
        end
        table.insert(defs, definition)
        label_to_num[current_label] = #defs
      end
      current_label = nil
      current_parts = {}
      current_rows = {}
    end
  end

  for index, line in ipairs(lines) do
    local is_fence
    open_fence, is_fence = fence_mod.step(open_fence, line)
    if is_fence then flush() end
    if open_fence or is_fence then goto continue end

    local label, text
    if not (opts and opts.continuation_only and opts.continuation_only[index]) then
      label, text = line:match "^%[%^([^%]]+)%]:%s+(.+)$"
    end
    if label then
      flush()
      current_label = label
      current_parts = { text }
      current_rows = { index }
      consumed[index] = true
    elseif current_label and line:match "^%s%s+" then
      -- Continuation line (indented)
      table.insert(current_parts, line:match "^%s+(.+)$" or "")
      current_rows[#current_rows + 1] = index
      consumed[index] = true
    else
      flush()
    end
    ::continue::
  end
  flush()

  return defs, label_to_num, consumed
end

--- Check if a line is a footnote definition
---@param line string
---@return boolean
Markdown.is_footnote_def = function(line)
  return line:match "^%[%^[^%]]+%]:%s+" ~= nil
end

--- Check if a line starts a block-level construct (not a paragraph continuation)
---@param line string
---@param in_paragraph boolean whether a paragraph is currently open
---@return boolean
function Markdown.is_block_start(line, in_paragraph)
  if line:match "^%s*$" then return true end
  -- Four-column indentation cannot introduce a new block inside a paragraph.
  if in_paragraph and line:match "^    " then return false end
  if Markdown.parse_atx_heading(line) then return true end
  if Markdown.list_marker_type(line, in_paragraph) then return true end
  if line:match "^>" then return true end
  local stripped = line:gsub("%s", "")
  local marker = stripped:sub(1, 1)
  if #stripped >= 3 and marker:match "[-_*]" and stripped == string.rep(marker, #stripped) then return true end
  if in_paragraph and Markdown.parse_setext_underline(line) then return true end
  if line:match "^%[%^.+%]:" then return true end
  if line:match "^%[!%a+%]" then return true end -- callout header (marker already stripped)
  if require("md-render.html_block").start(line, in_paragraph) then return true end
  if line:match "^%s*!%[" then return true end
  if line:match "^%$%$$" then return true end
  if line:match "^%%%%" then return true end
  if line:match "^:::" then return true end
  -- Indented code block (4+ spaces). Per CommonMark it cannot interrupt a
  -- paragraph, so while one is open the line is a continuation instead --
  -- this is what keeps deeply indented list continuations joined.
  if not in_paragraph and line:match "^    %s*%S" then return true end
  return false
end

--- Strip only explicit containers; lazy quote continuation belongs to block parsing.
local function reference_content(line)
  local depth, column = 0, 0
  while depth < inline.MAX_NESTING do
    local prefix, gap, content = line:match "^( ? ? ?>)([ \t]?)(.*)$"
    if not content then break end
    column = column + #prefix
    local width = fence_mod.indent_columns(gap, column)
    line, depth = string.rep(" ", math.max(0, width - 1)) .. content, depth + 1
    column = column + math.min(width, 1)
  end
  local prefix, gap, content = line:match "^( ? ? ?[-*+])([ \t]+)(.*)$"
  if not content and Markdown.list_marker_type(line) then
    prefix, gap, content = line:match "^( ? ? ?%d+[.)])([ \t]+)(.*)$"
  end
  if content then
    local width = fence_mod.indent_columns(gap, column + #prefix)
    line = string.rep(" ", width <= 4 and 0 or width - 1) .. content
  end
  return line, depth, content ~= nil
end

--- Parse definitions at paragraph starts, retaining input indices for consumption.
--- Masked code/comment rows must remain blank input rows, never disappear.
---@param lines string[]
---@param origins? table original physical columns and accepted container continuations
---@param src_indices? integer[] original row for each input line
---@return table<string, string> refs normalized source label to decoded URL
---@return table<integer, boolean> consumed 1-based input rows owned by valid definitions
---@return table<integer, integer> definition_ends definition's first input row to its last
Markdown.parse_reference_links = function(lines, origins, src_indices)
  local refs, consumed, definition_ends = {}, {}, {}
  local first = 1
  while first <= #lines do
    local parts, starts = {}, {}
    local _, depth = reference_content(lines[first])
    local last, offset = first, 1
    while last <= #lines do
      local content, current_depth, item = reference_content(lines[last])
      if current_depth ~= depth or (last > first and item) then break end
      parts[#parts + 1], starts[#starts + 1] = content, offset
      offset = offset + #content + 1
      last = last + 1
    end
    local text = table.concat(parts, "\n")
    local row, paragraph = 1, false
    while row <= #parts do
      local line = parts[row]
      local label, destination, finish
      if not paragraph then
        label, destination, finish = inline.reference_definition(text, starts[row])
      end
      if finish then
        if refs[label] == nil then refs[label] = link_destination(destination) end
        local start = first + row - 1
        repeat
          consumed[first + row - 1] = true
          row = row + 1
        until row > #parts or starts[row] > finish
        definition_ends[start] = first + row - 2
      else
        local origin = origins and origins[src_indices and src_indices[first + row - 1] or first + row - 1]
        paragraph = (origin and origin.continuation_depth == depth) or not Markdown.is_block_start(line, paragraph)
        row = row + 1
      end
    end
    first = last
  end
  return refs, consumed, definition_ends
end

--- Check whether one complete line is a valid reference definition.
---@param line string
---@return boolean
Markdown.is_reference_link_def = function(line)
  local _, consumed = Markdown.parse_reference_links { line }
  return consumed[1] == true
end

--- Get the list marker type of a line.
--- Returns the specific marker character/delimiter to distinguish list types per CommonMark:
--- "-", "*", "+" for bullet lists, "." or ")" for ordered list delimiters, or nil for non-list lines.
---@param line string
---@param in_paragraph? boolean only markers allowed to interrupt a paragraph
---@return string? marker_type
---@return string? number source digits for an ordered marker
---@return string? prefix source marker and its following whitespace
---@return string? content marker-free source content
Markdown.list_marker_type = function(line, in_paragraph)
  local prefix, content = line:match "^([ \t]*[-*+][ \t]+)(.*)$"
  if not prefix then
    prefix, content = line:match "^([ \t]*[-*+])$", ""
  end
  local number, delim
  if not prefix then
    prefix, content = line:match "^([ \t]*%d+[.)][ \t]+)(.*)$"
    if not prefix then
      prefix, content = line:match "^([ \t]*%d+[.)])$", ""
    end
    if prefix then
      number, delim = prefix:match "(%d+)([.)])"
    end
  end
  if not prefix or (number and #number > 9) then return nil end
  if in_paragraph and (content:match "^[ \t]*$" or (number and tonumber(number) ~= 1)) then return nil end
  return delim or prefix:match "[-*+]", number, prefix, content
end

--- Renumber ordered list items following CommonMark rules.
--- The first item's number determines the start; subsequent items are
--- numbered sequentially regardless of their source numbers.
---@param lines string[]
---@param excluded_lines? table<integer, any> literal source rows
---@param src_indices? integer[] original source row for each input line
---@param container_indents? table<integer, string> removed source container indentation
---@param list_bases? table<integer, integer> source parent content columns of eligible list markers
---@param source_origins? table quote identity with source indentation and physical columns
---@return string[]
Markdown.renumber_ordered_lists = function(
  lines,
  excluded_lines,
  src_indices,
  container_indents,
  list_bases,
  source_origins
)
  local result = {}
  local stack = {}

  local function renumber(line, src, origin, accepted_prefix)
    -- Source container parsing owns marker eligibility; indentation alone
    -- cannot distinguish nested lists from literal code.
    local excluded = not accepted_prefix
      and ((excluded_lines and excluded_lines[src]) or (list_bases and list_bases[src] == nil))
    local prefix = line:match "^([ \t>]*)"
    local marker_line = line:sub(#prefix + 1)
    local delimiter, num = Markdown.list_marker_type(marker_line)
    if not marker_line:match "^%d" then num = nil end
    local rest = num and marker_line:sub(#num + 2)
    local source_prefix = (not accepted_prefix and container_indents and container_indents[src] or "") .. prefix
    local ancestor_prefix = not accepted_prefix and origin and origin.ancestor_prefix
    -- Optional spacing after > does not change the quote's identity.
    local container = source_prefix:gsub("> ?", "> ")
    local source_container = ancestor_prefix and (container_indents and container_indents[src] or "") .. ancestor_prefix
      or container
    local quote_prefix = source_container:match "^(.*>)" or ""
    local base = accepted_prefix and origin.base or list_bases and list_bases[src]
    local blank = line:match "^[ \t>]*$"
    local sibling
    while #stack > 0 do
      local item = stack[#stack]
      sibling = num
        and not excluded
        and quote_prefix == item.quote_prefix
        and (base ~= nil and base == item.base or base == nil and container == item.prefix)
      local nested = vim.startswith(source_container, item.content_prefix)
      -- Unmarked blank rows end quotes, but keep ordinary loose lists open.
      if sibling or nested or (blank and vim.startswith(container, item.quote_prefix)) then break end
      table.remove(stack)
    end
    if num and not excluded then
      local item = stack[#stack]
      if sibling and item.delimiter == delimiter then
        item.counter = item.counter + 1
      else
        if sibling then table.remove(stack) end
        item = { prefix = container, base = base, delimiter = delimiter, counter = tonumber(num) }
        table.insert(stack, item)
      end
      -- Container widths belong to the source marker, even when 9 becomes 10.
      local column = origin and origin.quote_columns[#origin.quote_columns]
      if column then
        -- The display prefix includes one generated space after the last >.
        local indent = (prefix:match "[ \t]*$"):sub(2)
        column = column + fence_mod.indent_columns(indent, column)
      end
      local gap = fence_mod.indent_columns(rest:match "^[ \t]*", (column or #source_prefix) + #num + 1)
      if rest:match "^[ \t]*$" then gap = 1 end
      item.content_prefix = source_container .. string.rep(" ", #num + 1 + (gap <= 4 and gap or 1))
      item.quote_prefix = quote_prefix
      return prefix .. tostring(item.counter) .. delimiter .. rest
    else
      return line
    end
  end

  for i, line in ipairs(lines) do
    local src = src_indices and src_indices[i] or i
    local origin = source_origins and source_origins[src]
    for _, prefix in ipairs(origin and origin.list_prefixes or {}) do
      prefix.text = renumber(prefix.text, src, prefix, true)
    end
    result[#result + 1] = renumber(line, src, origin)
  end
  return result
end

return Markdown
