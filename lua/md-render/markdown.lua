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

local MAX_URL_DISPLAY_WIDTH = 50

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

--- Convert heading text to a URL-safe slug (GitHub-compatible).
--- Strips inline markdown markers, lowercases, replaces spaces with hyphens.
---@param text string raw heading text (after # markers)
---@return string slug
function Markdown.heading_slug(text)
  local s = text
  -- Strip common inline markdown markers
  s = s:gsub("%*%*(.-)%*%*", "%1") -- bold
  s = s:gsub("%*(.-)%*", "%1") -- italic
  s = s:gsub("~~(.-)~~", "%1") -- strikethrough
  s = s:gsub("==(.-)==", "%1") -- highlight
  s = s:gsub("`(.-)`", "%1") -- code
  s = s:gsub("%[(.-)%]%(.-%)", "%1") -- [text](url) → text
  s = s:gsub("%[%[(.-)%]%]", function(inner)
    local pipe = inner:find("|", 1, true)
    if pipe then return inner:sub(pipe + 1) end
    return inner
  end)
  s = s:lower()
  s = s:gsub("[%p]", "") -- remove ASCII punctuation, preserve multibyte chars
  s = s:gsub("%s+", "-") -- spaces to hyphens
  s = s:gsub("%-+", "-") -- collapse hyphens
  s = s:gsub("^%-+", ""):gsub("%-+$", "") -- trim hyphens
  return s
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
  if #removals == 0 then return end
  local function adjust(pos)
    local shift = 0
    for _, r in ipairs(removals) do
      if pos >= r.start + r.count then
        shift = shift + r.count
      elseif pos > r.start then
        shift = shift + (pos - r.start)
      end
    end
    return pos - shift
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
    if hl_group then highlights[#highlights + 1] = { col = col, end_col = col + #span.content, hl = hl_group } end
    shift = shift - count
    return span.content
  end)
  adjust_positions(highlights, links, removals, hl_count, link_count)
  return rendered
end

--- Reference identifiers use their source spelling, not decoded display text.
local function restore_source(text, spans)
  if #spans == 0 then return text end
  local originals = {}
  for _, span in ipairs(spans) do
    originals[span.placeholder] = span.raw
  end
  return (text:gsub(spans[1].placeholder:gsub("%d+", "%%d+"), originals))
end

--- Hide escaped punctuation until syntax recognition is finished.
local function escape_backslashes(text, source, literal_autolinks)
  local escapes, result = {}, {}
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
      escapes[#escapes + 1] = { placeholder = placeholder, content = next_ch, raw = "\\" .. next_ch }
      result[#result + 1] = placeholder
      i = i + 2
    else
      result[#result + 1] = text:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(result), escapes
end

--- Recognize references in the source, before removing any Markdown syntax.
--- Keeping their values hidden also prevents decoded punctuation from becoming syntax.
local function protect_entities(text, source)
  local spans, result = {}, {}
  local prefix = inline.token_prefix((source or "") .. text, 0xF1004)
  local i = 1
  while i <= #text do
    local autolink_end = text:sub(i, i) == "<" and inline.autolink_end(text, i)
    local reference, replacement = character_references.match(text, i)
    local next_char = text:sub(i + 1, i + 1)
    if text:sub(i, i) == "\\" and next_char ~= "" and ESCAPABLE_CHARS:find(next_char, 1, true) then
      result[#result + 1] = text:sub(i, i + 1)
      i = i + 2
    elseif autolink_end then
      result[#result + 1] = text:sub(i, autolink_end)
      i = autolink_end + 1
    elseif replacement then
      local placeholder = prefix .. (#spans + 1) .. "\u{F1005}"
      spans[#spans + 1] = { placeholder = placeholder, content = replacement, raw = reference }
      result[#result + 1] = placeholder
      i = i + #reference
    else
      result[#result + 1] = text:sub(i, i)
      i = i + 1
    end
  end
  return table.concat(result), spans
end

--- Preserve source breaks through inline parsing without changing whitespace
--- boundaries. Tabs protect the token from display-space collapse; source
--- restoration retains reference-label spelling and source-row accounting.
local function protect_hard_breaks(text, source, ref_links, source_label, bare_url)
  local ranges = inline.hard_breaks(text, ref_links, source_label, bare_url)
  if #ranges == 0 then return text, {} end
  local prefix = inline.token_prefix(source .. character_references.decode(source) .. text, 0xF100A)
  local spans, parts, pos, source_line = {}, {}, 1, 1
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
    parts[#parts + 1] = text:sub(pos, range.start - 1) .. placeholder
    pos = range.finish + 1
  end
  parts[#parts + 1] = text:sub(pos)
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

--- Process [[wikilinks]]: display as link text with highlight
---@param text string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_wikilinks(text, highlights, links, emphasis_spans, hard_break_spans)
  if not text:find("[[", 1, true) then return text end
  local processed = ""
  local i = 1

  while i <= #text do
    if text:sub(i, i + 1) == "[[" then
      local close = text:find("]]", i + 2, true)
      if close then
        local inner = text:sub(i + 2, close - 1)
        local display, target

        local pipe_pos = inner:find("|", 1, true)
        if pipe_pos then
          target = inner:sub(1, pipe_pos - 1)
          display = inner:sub(pipe_pos + 1)
        else
          target = inner
          local heading = inner:match "^#(.+)$"
          if heading then
            display = heading
          else
            local page, h = inner:match "^(.+)#(.+)$"
            if page and h then
              display = page .. " > " .. h
            else
              display = inner
            end
          end
        end

        -- Targets keep their original spelling while labels render inline styles.
        target = restore_source(restore_source(target, hard_break_spans), emphasis_spans)
        -- Determine URL and highlight based on link type
        local url, hl
        local anchor_heading = target:match "^#(.+)$"
        if anchor_heading then
          -- Same-document heading anchor: [[#heading]]
          url = "#" .. Markdown.heading_slug(anchor_heading)
          hl = "MdRenderLinkAnchor"
        else
          -- Obsidian cross-file link via Advanced URI plugin
          local page, heading = target:match "^(.+)#(.+)$"
          if page and heading then
            url = "obsidian://advanced-uri?filepath=" .. page .. "&heading=" .. heading
          else
            url = "obsidian://advanced-uri?filepath=" .. target
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
        })
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

  return processed
end

local IMAGE_EXTENSIONS = { png = true, jpg = true, jpeg = true, gif = true, svg = true, webp = true, bmp = true }

--- Process ![[embeds]]: display as icon + filename with highlight
---@param text string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_embeds(text, highlights, links, emphasis_spans, hard_break_spans)
  if not text:find("![[", 1, true) then return text end
  local processed = ""
  local i = 1

  while i <= #text do
    if text:sub(i, i + 2) == "![[" then
      local close = text:find("]]", i + 3, true)
      if close then
        local inner = text:sub(i + 3, close - 1)
        local target = inner:match "^([^|#]+)" or inner
        local source_target = restore_source(restore_source(target, hard_break_spans), emphasis_spans)
        local ext = source_target:match "%.(%w+)$"
        local icons_mod = require "md-render.icons"
        local raw_icon, embed_icon_hl
        if ext and IMAGE_EXTENSIONS[ext:lower()] then
          raw_icon, embed_icon_hl = icons_mod.get_image_icon(source_target)
        else
          raw_icon = "📎"
        end
        local icon = icons_mod.pad_icon(raw_icon) .. " "
        local display = icon .. target

        local start_col = #processed
        processed = processed .. display
        if embed_icon_hl then
          table.insert(highlights, { col = start_col, end_col = start_col + #icon - 1, hl = embed_icon_hl })
        end
        table.insert(
          highlights,
          { col = start_col + #icon, end_col = start_col + #display, hl = "MdRenderLinkObsidian" }
        )
        table.insert(links, {
          col_start = start_col,
          col_end = start_col + #display,
          url = "obsidian://advanced-uri?filepath=" .. source_target,
        })
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

  return processed
end

--- Inline and reference links share the same destination/title syntax.
local function link_destination(text)
  local escaped, escapes = escape_backslashes(text)
  local destination = escaped:match "^%s*<([^>]*)>" or escaped:match "^%s*(%S+)" or ""
  return character_references.decode(restore_source(destination, escapes))
end

local link_bounds = inline.link_bounds

--- Apply display transformations without changing a valid link destination/title.
local function map_display_text(text, transform)
  if not text:find("](", 1, true) then return transform(text, 0) end
  local parts, start, i = {}, 1, 1
  while i <= #text do
    local c = text:sub(i, i)
    local _, comment_end = text:find("^<!%-%-.-%-*%-%->", i)
    if not comment_end then
      _, comment_end = text:find("^%%%%.-%%%%", i)
    end
    if c == "\\" then
      i = i + 1
    elseif comment_end then
      -- A link-looking sequence inside a comment is not a link boundary.
      i = comment_end
    elseif c == "<" and inline.autolink_end(text, i) then
      i = inline.autolink_end(text, i)
    elseif c == "[" then
      local first, last = link_bounds(text, i)
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
local function protect_autolinks(text, source, ref_links, source_label)
  local spans, pieces, pos = {}, {}, 1
  local prefix = inline.token_prefix(source .. text, 0xF1006)
  for _, range in ipairs(inline.autolinks(text, ref_links, source_label)) do
    local token = prefix .. (#spans + 1) .. "\u{F1007}"
    local raw = text:sub(range.start, range.finish)
    local label = range.angle and raw:sub(2, -2) or raw
    local url = range.angle and (label:match "^[A-Za-z][A-Za-z0-9.+-]*:" and label or "mailto:" .. label)
      or "http://" .. label
    spans[#spans + 1] = { placeholder = token, content = raw, raw = raw, label = label, url = url }
    pieces[#pieces + 1] = text:sub(pos, range.start - 1) .. token
    pos = range.finish + 1
  end
  pieces[#pieces + 1] = text:sub(pos)
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
  local pre_hl_count = #highlights
  local pre_link_count = #links
  local removals = {}
  local processed = ""
  local i = 1
  while i <= #text do
    local literal_end = text:sub(i, i) == "<" and (inline.autolink_end(text, i) or inline.html_end(text, i))
    if literal_end then
      processed = processed .. text:sub(i, literal_end)
      i = literal_end + 1
    elseif text:sub(i, i) == "[" then
      local suffix_start, finish, reference_url = link_bounds(text, i, ref_links, source_label)
      if finish then
        local link_text_raw = text:sub(i + 1, suffix_start - 2)
        local url = reference_url or link_destination(source_label(text:sub(suffix_start + 1, finish - 1)))

        -- If link text is an image ![alt](img-url), use alt as display
        local alt = link_text_raw:match "^!%[(.-)%]%((.-)%)$"
        local display_text = alt or link_text_raw

        local start_col = #processed
        processed = processed .. display_text
        add_link_highlight(highlights, start_col, start_col + #display_text, url)
        table.insert(links, { col_start = start_col, col_end = start_col + #display_text, url = url, _decoded = true })
        table.insert(removals, { start = i - 1, count = 1 }) -- opening [
        table.insert(removals, { start = suffix_start - 2, count = finish - suffix_start + 2 }) -- ] plus link suffix
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
    if width > max_width then return url:sub(1, cut) .. "…" end
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
local function delimiter_char(char)
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
local function protect_emphasis(text, source, refs, footnotes, code_spans, autolink_spans, source_label)
  if not text:find "[*_~]" then return text, {}, {} end
  local pairs = {}
  local function resolve(first, last, in_label)
    local openers, lower = {}, {}
    local pos = first
    while pos <= last do
      local char = text:sub(pos, pos)
      local suffix, link_end
      if char == "[" then
        suffix, link_end = inline.link_bounds(text, pos, refs, source_label)
      end
      local wiki_start = text:sub(pos, pos + 1) == "[[" and pos or text:sub(pos, pos + 2) == "![[" and pos + 1
      local wiki_end = wiki_start and text:find("]]", wiki_start + 2, true)
      local note, note_end = text:match("^%[%^([^%]]+)%]()", pos)
      local literal_end = char == "<" and inline.html_end(text, pos)
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
        resolve(label_first, label_last, true)
        pos = wiki_end + 2
      elseif link_end then
        resolve(pos + 1, suffix - 2, true)
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
  resolve(1, #text, false)
  local spans, boundaries, parts, pos = {}, {}, {}, 1
  local prefix = inline.token_prefix(source .. text, 0xF1008)
  for _, pair in ipairs(pairs) do
    for _, field in ipairs { "first", "last" } do
      local start = pair[field]
      local token = prefix .. (#spans + 1) .. "\u{F1009}"
      local span = { placeholder = token, raw = text:sub(start, start + pair.count - 1), content = "" }
      spans[#spans + 1] = span
      boundaries[#boundaries + 1] = { start = start, count = pair.count, token = token }
      pair[field] = span
    end
  end
  table.sort(boundaries, function(a, b)
    return a.start < b.start
  end)
  for _, boundary in ipairs(boundaries) do
    parts[#parts + 1] = text:sub(pos, boundary.start - 1) .. boundary.token
    pos = boundary.start + boundary.count
  end
  parts[#parts + 1] = text:sub(pos)
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
  local pre_hl_count = #highlights
  local pre_link_count = #links
  local existing_links = vim.list_slice(links)
  -- Remaining raw HTML is displayed dimly, but its attributes are not text nodes.
  for _, hl in ipairs(highlights) do
    if hl.hl == "Comment" then existing_links[#existing_links + 1] = { col_start = hl.col, col_end = hl.end_col } end
  end
  local prefix = spans[1] and spans[1].placeholder:match "^(.-)%d+" or inline.token_prefix(source .. text, 0xF1006)
  local protected = {}
  for _, span in ipairs(spans) do
    protected[span.placeholder] = span
  end
  local pattern = spans[1] and spans[1].placeholder:gsub("%d+", "%%d+")
  local processed = ""
  local i = 1
  local removals = {}

  while i <= #text do
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
      local display_url = truncate_url(label, max_url_width, literal and {} or literals)
      if literal then
        literal.content = display_url
      else
        token = prefix .. (#spans + 1) .. "\u{F1007}"
        spans[#spans + 1] = { placeholder = token, content = display_url }
        removals[#removals + 1] = { start = i - 1 + #token, count = length - #token }
      end
      local first = #processed
      processed = processed .. token
      add_link_highlight(highlights, first, #processed, url)
      links[#links + 1] = { col_start = first, col_end = #processed, url = url, _decoded = literal ~= nil }
      i = i + length
    else
      processed = processed .. text:sub(i, i)
      i = i + 1
    end
  end
  adjust_positions(highlights, links, removals, pre_hl_count, pre_link_count)
  return processed
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

--- Process HTML tags: <a href> links, <img> images, and paired inline tags
--- Matched code spans are already protected by the caller.
---@param text string
---@param highlights MdRender.Markdown.Highlight[]
---@param links MdRender.Markdown.Link[]
---@return string processed
local function process_html_tags(text, highlights, links, decode_url)
  if not text:find("<", 1, true) then return text end
  local pre_hl_count = #highlights
  local pre_link_count = #links
  local removals = {}
  local processed = ""
  local i = 1
  while i <= #text do
    if text:sub(i, i) == "<" then
      local rest = text:sub(i)
      local matched = false

      -- Try <a href="...">text</a>
      local a_tag = rest:match "^(<a%s[^>]*>)"
      if a_tag then
        local href = a_tag:match 'href="([^"]*)"' or a_tag:match "href='([^']*)'"
        local close_start, close_end = text:find("</a>", i + #a_tag, true)
        if href and close_start then
          href = decode_url(href)
          local content = text:sub(i + #a_tag, close_start - 1)
          table.insert(removals, { start = i - 1, count = #a_tag })
          table.insert(removals, { start = close_start - 1, count = 4 })
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
        local img_tag = rest:match "^(<img%s[^>]*>)"
        if img_tag then
          local src = img_tag:match 'src="([^"]*)"' or img_tag:match "src='([^']*)'"
          if src then
            local display_name = src:match "([^/]+)$" or src
            src = decode_url(src)
            local alt = img_tag:match 'alt="([^"]*)"' or img_tag:match "alt='([^']*)'"
            local icons_mod = require "md-render.icons"
            local raw_img_icon, img_icon_hl = icons_mod.get_image_icon(src)
            local img_icon = icons_mod.pad_icon(raw_img_icon) .. " "
            local display = img_icon .. ((alt and alt ~= "") and alt or display_name)
            table.insert(removals, { start = i - 1, count = #img_tag })
            local start_col = #processed
            processed = processed .. display
            if img_icon_hl then
              table.insert(highlights, { col = start_col, end_col = start_col + #img_icon - 1, hl = img_icon_hl })
            end
            add_link_highlight(highlights, start_col + #img_icon, start_col + #display, src)
            table.insert(links, { col_start = start_col, col_end = start_col + #display, url = src, _decoded = true })
            i = i + #img_tag
            matched = true
          end
        end
      end

      -- Try <video src="...">...</video> or <video><source src="...">...</video>
      if not matched then
        local video_tag = rest:match "^(<video[%s>].-</video>)"
        if video_tag then
          local src = video_tag:match 'src="([^"]*)"' or video_tag:match "src='([^']*)'"
          if not src then
            src = video_tag:match '<source[^>]*src="([^"]*)"' or video_tag:match "<source[^>]*src='([^']*)'>"
          end
          if src then
            local display_name = src:match "([^/]+)$" or src
            src = decode_url(src)
            local icons_mod = require "md-render.icons"
            local raw_icon, icon_hl = icons_mod.get_image_icon(src)
            local img_icon = icons_mod.pad_icon(raw_icon) .. " "
            local display = img_icon .. display_name
            table.insert(removals, { start = i - 1, count = #video_tag })
            local start_col = #processed
            processed = processed .. display
            if icon_hl then
              table.insert(highlights, { col = start_col, end_col = start_col + #img_icon - 1, hl = icon_hl })
            end
            add_link_highlight(highlights, start_col + #img_icon, start_col + #display, src)
            table.insert(links, { col_start = start_col, col_end = start_col + #display, url = src, _decoded = true })
            i = i + #video_tag
            matched = true
          end
        end
      end

      -- Try paired HTML tags (<b>, <strong>, <em>, etc.)
      if not matched then
        local tag_name = rest:match "^<(%a+)[%s>]"
        if tag_name then
          local lower_tag = tag_name:lower()
          local hl = HTML_TAG_HIGHLIGHTS[lower_tag]
          if hl ~= nil then
            local open_tag = rest:match("^(<" .. tag_name .. "[^>]*>)")
            if open_tag then
              local close_tag = "</" .. tag_name .. ">"
              local close_start = text:find(close_tag, i + #open_tag, true)
              if not close_start and tag_name ~= lower_tag then
                close_tag = "</" .. lower_tag .. ">"
                close_start = text:find(close_tag, i + #open_tag, true)
              end
              if close_start then
                local content = text:sub(i + #open_tag, close_start - 1)
                table.insert(removals, { start = i - 1, count = #open_tag })
                table.insert(removals, { start = close_start - 1, count = #close_tag })
                local start_col = #processed
                processed = processed .. content
                if hl then table.insert(highlights, { col = start_col, end_col = start_col + #content, hl = hl }) end
                i = close_start + #close_tag
                matched = true
              end
            end
          end
        end
      end

      if not matched then
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
local function strip_html_tags(text, highlights)
  if not text:find("<", 1, true) then return text end
  local processed = ""
  local i = 1
  while i <= #text do
    if text:sub(i, i) == "<" then
      local tag = text:sub(i):match "^(</?%a[^>]*>)"
      if tag and not inline.autolink_end(text, i) then
        local start_col = #processed
        processed = processed .. tag
        table.insert(highlights, { col = start_col, end_col = start_col + #tag, hl = "Comment" })
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
  return processed
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
  local rendered = text:gsub("()(\n+)", function(pos, breaks)
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
---@return string rendered_text The rendered plain text
---@return MdRender.Markdown.Highlight[] highlights
---@return MdRender.Markdown.Link[] links
---@return string? special_type Special type like "heading" if applicable
---@return string? list_marker List marker if applicable
---@return string? alert_type Alert type (NOTE, TIP, etc.) if applicable
---@return string? fold_mod Callout fold modifier if applicable
---@return string? heading_content Original heading content if applicable
---@return MdRender.Markdown.Break[] hard_breaks Mandatory row boundaries in the newline-free text
Markdown.render = function(text, repo_base_url, autolinks, ref_links, footnote_map, inline_only)
  inline_only = inline_only == true
  local rendered_text = text
  local highlights = {}
  local links = {}
  local hard_break_spans = {}

  local function finish(special_type, list_marker, alert_type, fold_mod, heading_content)
    rendered_text = restore_spans(rendered_text:gsub("[\r\n]", " "), hard_break_spans, nil, highlights, links)
    local breaks = {}
    for _, span in ipairs(hard_break_spans) do
      if span.col then breaks[#breaks + 1] = { col = span.col, source_line = span.source_line } end
    end
    return rendered_text, highlights, links, special_type, list_marker, alert_type, fold_mod, heading_content, breaks
  end

  -- Heading (# ## ### etc.) - detect level and strip markers, process inline elements below
  local heading_level, heading_content
  if not inline_only then
    heading_level, heading_content = Markdown.parse_atx_heading(rendered_text)
  end
  if heading_level then rendered_text = heading_content end

  -- Blockquote (> ) - extract prefix
  local quote_prefix = ""
  local is_blockquote = false
  while not inline_only and not heading_level and rendered_text:match "^>%s?" do
    rendered_text = rendered_text:gsub("^>%s?", "", 1)
    quote_prefix = quote_prefix .. "│ "
    is_blockquote = true
  end

  -- Detect alert/callout syntax [!TYPE], [!TYPE]+, [!TYPE]- with optional title
  if is_blockquote then
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

  -- List items (- * + 1. 1)) - detect marker
  local list_marker
  if not inline_only and not heading_level then
    list_marker = rendered_text:match "^(%s*[-*+]%s)" or rendered_text:match "^(%s*%d+[.)]%s)"
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
      list_marker = indent_part .. icon
      rendered_text = list_marker .. rendered_text:sub(#(rendered_text:match "^%s*[-*+]%s" or "") + 1)
    end
  end

  -- Establish code boundaries before whitespace or comment transformations.
  local code_spans, invalid_destinations
  rendered_text, code_spans = inline.protect_code(rendered_text, ref_links)
  rendered_text, invalid_destinations = inline.protect_invalid_destinations(rendered_text, ref_links, function(label)
    return restore_source(label, code_spans)
  end)
  rendered_text = rendered_text:gsub("\r\n", "\n"):gsub("\r", "\n")
  if checkbox_hl then rendered_text = list_marker .. rendered_text:sub(#list_marker + 1):gsub("^ +", "") end

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
  local backslash_escapes, entity_spans, autolink_spans, emphasis_spans, emphasis_pairs
  local decode_url, source_label

  if not needs_inline and #code_spans == 0 and not rendered_text:find "  +\n" then
    rendered_text = display_soft_breaks(rendered_text, highlights, links)
    rendered_text = collapse_spaces(rendered_text, highlights, links, checkbox_hl and #list_marker or 0)
    goto finalize
  end

  rendered_text, autolink_spans = protect_autolinks(rendered_text, text, ref_links, function(label)
    return restore_source(restore_source(label, code_spans), invalid_destinations)
  end)
  rendered_text, emphasis_spans, emphasis_pairs = protect_emphasis(
    rendered_text,
    text,
    ref_links,
    footnote_map,
    code_spans,
    autolink_spans,
    function(label)
      return restore_source(restore_source(restore_source(label, code_spans), invalid_destinations), autolink_spans)
    end
  )
  rendered_text, hard_break_spans = protect_hard_breaks(rendered_text, text, ref_links, function(label)
    return restore_source(
      restore_source(restore_source(restore_source(label, emphasis_spans), autolink_spans), code_spans),
      invalid_destinations
    )
  end, function(pos)
    return bare_autolink(rendered_text, pos, {}, code_spans, autolink_spans, emphasis_spans)
  end)
  rendered_text, entity_spans = protect_entities(rendered_text, text)
  if rendered_text:find("<!--", 1, true) or rendered_text:find("%%", 1, true) then
    rendered_text = map_display_text(rendered_text, function(part)
      return (part:gsub("%%%%(.-)%%%%", ""):gsub("<!%-%-.-%-*%-%->", ""))
    end)
  end
  rendered_text, backslash_escapes = escape_backslashes(rendered_text, text, true)

  decode_url = function(url)
    return restore_spans(restore_spans(url, backslash_escapes), entity_spans)
  end
  source_label = function(label)
    label = restore_source(label, hard_break_spans)
    label = restore_source(restore_source(label, emphasis_spans), autolink_spans)
    return restore_source(
      restore_source(restore_source(restore_source(label, entity_spans), backslash_escapes), code_spans),
      invalid_destinations
    )
  end

  -- Process inline elements (embeds and wikilinks before standard links)
  rendered_text = process_embeds(rendered_text, highlights, links, emphasis_spans, hard_break_spans)
  rendered_text = process_wikilinks(rendered_text, highlights, links, emphasis_spans, hard_break_spans)
  rendered_text = process_footnote_refs(rendered_text, footnote_map, highlights, links, source_label)
  rendered_text = process_links(rendered_text, highlights, links, source_label, ref_links)
  -- Explicit/reference validity is settled; later autolinks need real parentheses.
  rendered_text = restore_spans(rendered_text, invalid_destinations, nil, highlights, links)
  repeat
    local prev = rendered_text
    rendered_text = process_html_tags(rendered_text, highlights, links, decode_url)
  until rendered_text == prev
  rendered_text = strip_html_tags(rendered_text, highlights)
  rendered_text = process_bare_urls(
    rendered_text,
    MAX_URL_DISPLAY_WIDTH,
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

  -- Restore each source token once. Decoded destinations from reference
  -- definitions already crossed this boundary and must not be interpreted again.
  for _, link in ipairs(links) do
    if not link._decoded then link.url = decode_url(link.url) end
    link._decoded = nil
  end
  rendered_text = display_soft_breaks(rendered_text, highlights, links)
  -- Validate labels in their original spelling before display-space collapse.
  -- Code and entities remain protected, and generated checkbox padding stays.
  rendered_text = collapse_spaces(rendered_text, highlights, links, checkbox_hl and #list_marker or 0)
  rendered_text = restore_spans(rendered_text, autolink_spans, nil, highlights, links)
  rendered_text = restore_spans(rendered_text, backslash_escapes, nil, highlights, links)
  rendered_text = restore_spans(rendered_text, code_spans, "MdRenderInlineCode", highlights, links)
  rendered_text = restore_spans(rendered_text, entity_spans, nil, highlights, links)
  -- Entity line endings are inline whitespace, never additional buffer rows.
  rendered_text = rendered_text:gsub("[\r\n]", " ")

  -- Close up the CJK gaps left behind by the removed markers.  Runs last so
  -- that every span boundary is final, and before the heading/list/blockquote
  -- highlights below, which are not inline spans.
  rendered_text = drop_marker_spaces(rendered_text, highlights, links)

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
    return finish("heading", nil, nil, nil, heading_content)
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
---@return {label: string, text: string}[] definitions
---@return table<string, integer> label_to_number
Markdown.parse_footnotes = function(lines)
  local defs = {}
  local label_to_num = {}
  local current_label = nil
  local current_parts = {}
  local open_fence = nil

  local function flush()
    if current_label then
      if not label_to_num[current_label] then
        table.insert(defs, { label = current_label, text = wrap_mod.join_source_lines(current_parts) })
        label_to_num[current_label] = #defs
      end
      current_label = nil
      current_parts = {}
    end
  end

  for _, line in ipairs(lines) do
    local is_fence
    open_fence, is_fence = fence_mod.step(open_fence, line)
    if is_fence then flush() end
    if open_fence or is_fence then goto continue end

    local label, text = line:match "^%[%^([^%]]+)%]:%s+(.+)$"
    if label then
      flush()
      current_label = label
      current_parts = { text }
    elseif current_label and line:match "^%s%s+" then
      -- Continuation line (indented)
      table.insert(current_parts, line:match "^%s+(.+)$" or "")
    else
      flush()
    end
    ::continue::
  end
  flush()

  return defs, label_to_num
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
  if Markdown.parse_atx_heading(line) then return true end
  if Markdown.list_marker_type(line) then return true end
  if line:match "^>" then return true end
  if line:match "^%s*[-_*]%s*[-_*]%s*[-_*]" then return true end
  if line:match "^[=-]+%s*$" then return true end
  if line:match "^%[%^.+%]:" then return true end
  if line:match "^%[!%a+%]" then return true end -- callout header (marker already stripped)
  if line:match "^%s*<" then return true end
  if line:match "^%s*!%[" then return true end
  if line:match "^%$%$$" then return true end
  if line:match "^%%%%" then return true end
  if line:match "^:::" then return true end
  -- Indented code block (4+ spaces). Per CommonMark it cannot interrupt a
  -- paragraph, so while one is open the line is a continuation instead --
  -- this is what keeps deeply indented list continuations joined.
  if not in_paragraph and line:match "^    %S" then return true end
  return false
end

--- Strip only explicit containers; lazy quote continuation belongs to block parsing.
local function reference_content(line)
  local depth, column = 0, 0
  while true do
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
---@return table<string, string> refs normalized source label to decoded URL
---@return table<integer, boolean> consumed 1-based input rows owned by valid definitions
---@return table<integer, integer> definition_ends definition's first input row to its last
Markdown.parse_reference_links = function(lines)
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
        paragraph = not Markdown.is_block_start(line, paragraph)
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
---@return string? marker_type
---@return string? number source digits for an ordered marker
Markdown.list_marker_type = function(line)
  local bullet = line:match "^%s*([-*+])%s"
  if bullet then return bullet end
  local number, delim = line:match "^%s*(%d+)([.)])%s"
  if number and #number <= 9 then return delim, number end
  return nil
end

--- Renumber ordered list items following CommonMark rules.
--- The first item's number determines the start; subsequent items are
--- numbered sequentially regardless of their source numbers.
---@param lines string[]
---@param excluded_lines? table<integer, any> literal source rows
---@param src_indices? integer[] original source row for each input line
---@param container_indents? table<integer, string> removed source container indentation
---@param list_bases? table<integer, integer> source parent content columns of eligible list markers
---@return string[]
Markdown.renumber_ordered_lists = function(lines, excluded_lines, src_indices, container_indents, list_bases)
  local result = {}
  local stack = {}

  for i, line in ipairs(lines) do
    local src = src_indices and src_indices[i] or i
    -- Source container parsing owns marker eligibility; indentation alone
    -- cannot distinguish nested lists from literal code.
    local excluded = (excluded_lines and excluded_lines[src]) or (list_bases and list_bases[src] == nil)
    local prefix = line:match "^([ \t>]*)"
    local marker_line = line:sub(#prefix + 1)
    local delimiter, num = Markdown.list_marker_type(marker_line)
    if not marker_line:match "^%d" then num = nil end
    local rest = num and marker_line:sub(#num + 2)
    local source_prefix = (container_indents and container_indents[src] or "") .. prefix
    -- Optional spacing after > does not change the quote's identity.
    local container = source_prefix:gsub("> ?", "> ")
    local quote_prefix = container:match "^(.*>)" or ""
    local base = list_bases and list_bases[src]
    local blank = line:match "^[ \t>]*$"
    local sibling
    while #stack > 0 do
      local item = stack[#stack]
      sibling = num
        and not excluded
        and quote_prefix == item.quote_prefix
        and (base ~= nil and base == item.base or base == nil and container == item.prefix)
      local nested = vim.startswith(container, item.content_prefix)
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
      local gap = fence_mod.indent_columns(rest:match "^[ \t]*", #source_prefix + #num + 1)
      item.content_prefix = container .. string.rep(" ", #num + 1 + (gap <= 4 and gap or 1))
      item.quote_prefix = quote_prefix
      table.insert(result, prefix .. tostring(item.counter) .. delimiter .. rest)
    else
      table.insert(result, line)
    end
  end
  return result
end

return Markdown
