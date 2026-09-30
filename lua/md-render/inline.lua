local M = {}

local ESCAPABLE = [[!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~]]

local function escaped(text, pos)
  return text:sub(pos, pos) == "\\" and pos < #text and ESCAPABLE:find(text:sub(pos + 1, pos + 1), 1, true)
end

local function skip_space(text, pos)
  pos = text:match("^[ \t]*()", pos)
  if text:sub(pos, pos) == "\r" then
    pos = pos + 1
    if text:sub(pos, pos) == "\n" then pos = pos + 1 end
  elseif text:sub(pos, pos) == "\n" then
    pos = pos + 1
  end
  return text:match("^[ \t]*()", pos)
end

--- End of a valid angle autolink, including its closing >.
function M.autolink_end(text, start)
  if text:sub(start, start) ~= "<" then return end
  local finish = text:find(">", start + 1, true)
  if not finish then return end
  local value = text:sub(start + 1, finish - 1)
  if value:find "[<>%z\1-\32\127]" then return end
  local scheme = value:match "^([A-Za-z][A-Za-z0-9.+-]*):"
  if scheme and #scheme >= 2 and #scheme <= 32 then return finish end
  local domain = value:match "^[A-Za-z0-9.!#$%%&'*+/=?^_`{|}~%-]+@(.+)$"
  if not domain or domain:find("..", 1, true) or domain:sub(-1) == "." then return end
  for label in domain:gmatch "[^.]+" do
    if #label > 63 or not label:match "^[A-Za-z0-9][A-Za-z0-9%-]*$" or not label:match "[A-Za-z0-9]$" then return end
  end
  if domain:sub(1, 1) ~= "." then return finish end
end

--- GFM URL punctuation is excluded only at the end; interior parentheses stay.
function M.trim_autolink(url)
  local previous
  repeat
    previous = url
    url = url:gsub("[?!.,:*_~]+$", ""):gsub("&[A-Za-z0-9]+;$", "")
    if url:sub(-1) == ")" then
      local _, opening = url:gsub("%(", "")
      local _, closing = url:gsub("%)", "")
      local excess = math.min(closing - opening, #(url:match "%)%)*$"))
      if excess > 0 then url = url:sub(1, #url - excess) end
    end
  until previous == url
  return url
end

local function www_end(text, start, source_label)
  local before = text:sub(1, start - 1)
  if source_label then before = source_label(before) end
  if before ~= "" and not before:sub(-1):find "[%s*_~(]" then return end
  -- A www segment inside an existing HTTP URL belongs to that URL.
  if before:match 'https?://[^%s<>"`]*$' then return end
  local url = M.trim_autolink(text:match("^[^%s<]+", start))
  local domain = url:match "^[A-Za-z0-9_.%-]+"
  if not domain or domain:find("..", 1, true) then return end
  local penultimate, last = domain:match "([^.]+)%.([^.]+)$"
  if not last or last:find("_", 1, true) or penultimate:find("_", 1, true) then return end
  return start + #url - 1
end

--- HTML and code have equal precedence: the first complete construct wins.
function M.html_end(text, start)
  local rest = text:sub(start)
  if rest:sub(1, 5) == "<!-->" then return start + 4 end
  if rest:sub(1, 6) == "<!--->" then return start + 5 end
  for _, pair in ipairs { { "<!--", "-->" }, { "<?", "?>" }, { "<![CDATA[", "]]>" } } do
    if rest:sub(1, #pair[1]) == pair[1] then
      local _, finish = text:find(pair[2], start + #pair[1], true)
      return finish
    end
  end
  local simple = rest:match "^<![A-Za-z]+[^>]*>"
  if simple then return start + #simple - 1 end
  local closing = text:match("^</[A-Za-z][A-Za-z0-9%-]*()", start)
  if closing then
    closing = skip_space(text, closing)
    if text:sub(closing, closing) == ">" then return closing end
    return
  end
  local pos = text:match("^<[A-Za-z][A-Za-z0-9%-]*()", start)
  if not pos then return end
  while pos <= #text do
    local next_pos = skip_space(text, pos)
    if text:sub(next_pos, next_pos) == ">" then return next_pos end
    if text:sub(next_pos, next_pos + 1) == "/>" then return next_pos + 1 end
    if next_pos == pos then return end
    local name_end = text:match("^[A-Za-z_:][A-Za-z0-9:._%-]*()", next_pos)
    if not name_end then return end
    pos = skip_space(text, name_end)
    if text:sub(pos, pos) == "=" then
      pos = skip_space(text, pos + 1)
      local quote = text:sub(pos, pos)
      if quote == '"' or quote == "'" then
        local finish = text:find(quote, pos + 1, true)
        if not finish then return end
        pos = finish + 1
      else
        local first = pos
        -- ponytail: retain NUL rejection until insecure source characters are normalized.
        while pos <= #text and not text:sub(pos, pos):find "[%z \t\r\n\"'=<>`]" do
          pos = pos + 1
        end
        if pos == first then return end
      end
    else
      pos = name_end
    end
  end
end

--- First byte after a valid destination (angle delimiters included).
function M.destination_end(text, start)
  local pos = start
  if text:sub(pos, pos) == "<" then
    pos = pos + 1
    while pos <= #text and text:sub(pos, pos) ~= ">" do
      local c = text:sub(pos, pos)
      if c == "<" or c == "\n" or c == "\r" or c == "\0" then return end
      pos = pos + (escaped(text, pos) and 2 or 1)
    end
    if pos > #text then return end
    pos = pos + 1
  else
    local depth = 0
    while pos <= #text do
      local c = text:sub(pos, pos)
      if escaped(text, pos) then
        pos = pos + 2
      elseif c == "(" then
        depth = depth + 1
        pos = pos + 1
      elseif c == ")" then
        if depth == 0 then break end
        depth = depth - 1
        pos = pos + 1
      elseif text:byte(pos) == 127 then
        return
      elseif text:byte(pos) <= 32 then
        break
      else
        pos = pos + 1
      end
    end
    if depth ~= 0 then return end
  end
  return pos
end

--- First byte after a complete title, including its closing delimiter.
function M.title_end(text, start)
  local pos = start
  local delimiter = text:sub(pos, pos)
  if not (delimiter == '"' or delimiter == "'" or delimiter == "(") then return end
  local closing = delimiter == "(" and ")" or delimiter
  pos = pos + 1
  local title_start = pos
  while pos <= #text and text:sub(pos, pos) ~= closing do
    if delimiter == "(" and text:sub(pos, pos) == "(" then return end
    pos = pos + (escaped(text, pos) and 2 or 1)
  end
  if pos > #text then return end
  local title = text:sub(title_start, pos - 1):gsub("\r\n", "\n"):gsub("\r", "\n")
  if title:find "\n[ \t]*\n" then return end
  return pos + 1
end

--- Closing parenthesis of a valid inline link destination and optional title.
function M.link_end(text, start)
  if text:sub(start, start) ~= "(" then return end
  local dest_end = M.destination_end(text, skip_space(text, start + 1))
  if not dest_end then return end
  local pos = skip_space(text, dest_end)
  if text:sub(pos, pos) == ")" then return pos end
  if pos == dest_end then return end
  pos = M.title_end(text, pos)
  if not pos then return end
  pos = skip_space(text, pos)
  if text:sub(pos, pos) == ")" then return pos end
end

local function index_runs(text, start)
  local runs, pos = {}, start
  while pos <= #text do
    local first, last = text:find("`+", pos)
    if not first then break end
    local ticks = last - first + 1
    runs[ticks] = runs[ticks] or { cursor = 1 }
    local matches = runs[ticks]
    matches[#matches + 1] = { start = first, finish = last }
    pos = last + 1
  end
  return runs
end

local function code_end(text, start, runs)
  local _, run_end = text:find("`+", start)
  local ticks = run_end - start + 1
  local matches = runs[ticks]
  if matches then
    -- Scan positions only move forward, so each candidate is visited once.
    while matches[matches.cursor] and matches[matches.cursor].start <= run_end do
      matches.cursor = matches.cursor + 1
    end
    local closing = matches[matches.cursor]
    if closing then return closing.finish, ticks, run_end end
  end
  return nil, ticks, run_end
end

function M.reference_end(text, start, source_label)
  if text:sub(start, start) ~= "[" then return end
  local pos = start + 1
  -- UTF-8 uses at most four bytes per character; include the closing bracket.
  -- Protected labels need restoration before the source character count below.
  while pos <= #text and (source_label or pos - start <= 4 * 999 + 1) do
    local c = text:sub(pos, pos)
    if escaped(text, pos) then
      pos = pos + 2
    elseif c == "]" then
      local label = text:sub(start + 1, pos - 1)
      if source_label then label = source_label(label) end
      if vim.fn.strchars(label) <= 999 then return pos end
      return
    elseif c == "[" then
      return
    else
      pos = pos + 1
    end
  end
end

--- Labels retain source escapes/entities; only case and label whitespace fold.
function M.normalize_reference_label(label)
  label = label:gsub("[ \t\r\n]+", " "):gsub("^ ", ""):gsub(" $", "")
  if not label:find "[\128-\255]" then return label:lower() end
  local exceptions = require "md-render.casefold"
  return (
    label:gsub("[%z\1-\127\194-\253][\128-\191]*", function(char)
      return exceptions[char] or vim.fn.tolower(char)
    end)
  )
end

--- Parse a complete definition at a line start; return its final newline byte.
--- The caller supplies one container at a time and owns block/code boundaries.
function M.reference_definition(text, start)
  local pos = text:match("^ ? ? ?()", start)
  local label_end = M.reference_end(text, pos)
  if not label_end or text:sub(label_end + 1, label_end + 1) ~= ":" then return end
  local label = text:sub(pos + 1, label_end - 1)
  if label:sub(1, 1) == "^" or label:find "\n[ \t]*\n" then return end
  label = M.normalize_reference_label(label)
  if label == "" then return end
  local dest_start = skip_space(text, label_end + 2)
  local dest_end = M.destination_end(text, dest_start)
  if not dest_end or dest_end == dest_start then return end
  local line_end = text:match("^[ \t]*()", dest_end)
  local destination_only = line_end > #text or text:sub(line_end, line_end) == "\n"
  pos = skip_space(text, dest_end)
  local title_end = pos > dest_end and M.title_end(text, pos)
  if title_end then
    title_end = text:match("^[ \t]*()", title_end)
    if title_end > #text or text:sub(title_end, title_end) == "\n" then
      return label, text:sub(dest_start, dest_end - 1), title_end
    end
  end
  if destination_only then return label, text:sub(dest_start, dest_end - 1), line_end end
end

--- Scan one already-parsed paragraph; block boundaries are the caller's job.
local function scan(text, refs, wanted_link, source_label, bare_url)
  local spans, brackets, autolinks, invalid_destinations, hard_breaks = {}, {}, {}, {}, {}
  local runs
  local autolink_finish = 0
  local has_angle_link = false
  local function note_angle_link()
    if #brackets > 0 then
      brackets[#brackets].angle_link = true
    else
      has_angle_link = true
    end
  end
  local pos = wanted_link or 1
  while pos <= #text do
    local c = text:sub(pos, pos)
    if escaped(text, pos) then
      pos = pos + 2
    elseif c == "`" then
      runs = runs or index_runs(text, pos)
      local finish, ticks, run_end = code_end(text, pos, runs)
      if finish then spans[#spans + 1] = { start = pos, finish = finish, ticks = ticks } end
      pos = (finish or run_end) + 1
    elseif c == "<" then
      local finish = M.autolink_end(text, pos)
      if finish then
        autolinks[#autolinks + 1] = { start = pos, finish = finish, angle = true }
        note_angle_link()
      end
      finish = finish or M.html_end(text, pos)
      pos = (finish or pos) + 1
    elseif not wanted_link and (text:sub(pos, pos + 3) == "www." or (bare_url and text:match("^https?://", pos))) then
      -- Hard-break ownership reuses Markdown's established HTTP matcher.
      local url = bare_url and text:match("^https?://", pos) and bare_url(pos)
      local finish = url and pos + #url - 1 or www_end(text, pos, source_label)
      -- Autolinks apply to text nodes, never a resolved link/image label.
      -- Reuse the same bracket scanner; lookahead disables www recognition.
      if finish then
        for _, bracket in ipairs(brackets) do
          if bracket.link == nil then
            local lookahead = scan(text, refs, bracket.start, source_label)
            bracket.link = lookahead.suffix_start ~= nil
              or (
                text:sub(bracket.start, bracket.start + 1) == "[[" and text:find("]]", bracket.start + 2, true) ~= nil
              )
          end
          if bracket.link then
            finish = nil
            break
          end
        end
      end
      if finish then
        autolink_finish = finish
        if not url then autolinks[#autolinks + 1] = { start = pos, finish = finish } end
      end
      pos = (finish or pos) + 1
    elseif text:sub(pos, pos + 1) == "%%" then
      -- Obsidian comments, like HTML comments, cannot open code spans.
      local finish = text:find("%%", pos + 2, true)
      pos = finish and finish + 2 or pos + 2
    elseif c == "\n" then
      local first = pos
      while text:sub(first - 1, first - 1) == " " and first > 1 do
        first = first - 1
      end
      if pos - first < 2 then
        local slash = pos
        while text:sub(slash - 1, slash - 1) == "\\" and slash > 1 do
          slash = slash - 1
        end
        first = (pos - slash) % 2 == 1 and pos - 1 or pos
      end
      if first > autolink_finish and first < pos and pos < #text then
        hard_breaks[#hard_breaks + 1] = { start = first, finish = pos }
      end
      pos = pos + 1
    elseif c == "[" or text:sub(pos, pos + 1) == "![" then
      for _, bracket in ipairs(brackets) do
        bracket.nested = true
      end
      local image_marker = c == "!"
      -- link_bounds() starts at [, so recover a preceding unescaped image marker.
      local preceding_escape = wanted_link == pos and text:sub(1, pos - 1):match "(\\*)!$" or nil
      local image = image_marker or (preceding_escape ~= nil and #preceding_escape % 2 == 0)
      brackets[#brackets + 1] = { start = pos + (image_marker and 1 or 0), image = image, active = true }
      pos = pos + (image_marker and 2 or 1)
    elseif c == "]" and #brackets > 0 then
      local bracket = table.remove(brackets)
      if source_label then
        local label = text:sub(bracket.start + 1, pos - 1)
        local original = source_label(label)
        -- Protected text must retain the same ownership as its source label.
        if original ~= label and scan(original, refs).has_angle_link then bracket.angle_link = true end
      end
      if bracket.angle_link and not bracket.image then bracket.active = false end
      local finish = bracket.active and M.link_end(text, pos + 1) or nil
      if not finish and text:sub(pos + 1, pos + 1) == "(" then
        invalid_destinations[#invalid_destinations + 1] = pos + 1
      end
      local matched = finish ~= nil
      local url
      if bracket.active and not matched and refs then
        local ref_end = M.reference_end(text, pos + 1, source_label)
        local label = ref_end and text:sub(pos + 2, ref_end - 1)
        if not label or label == "" then label = not bracket.nested and text:sub(bracket.start + 1, pos - 1) or nil end
        if label then
          label = source_label and source_label(label) or label
          if vim.fn.strchars(label) <= 999 then url = refs[M.normalize_reference_label(label)] end
        end
        matched = url ~= nil
        if matched then finish = ref_end or pos end
      end
      -- Images may contain links in their description; a valid image consumes
      -- that ownership, while literal brackets leave the inner autolink active.
      if bracket.angle_link and not (bracket.image and matched) then note_angle_link() end
      if wanted_link == bracket.start then
        return { code_spans = spans, suffix_start = matched and pos + 1 or nil, link_end = finish, reference_url = url }
      end
      if matched and not bracket.image then
        for _, previous in ipairs(brackets) do
          if not previous.image then previous.active = false end
        end
      end
      pos = (finish or pos) + 1
    else
      pos = pos + 1
    end
  end
  for _, bracket in ipairs(brackets) do
    if bracket.angle_link then has_angle_link = true end
  end
  return {
    code_spans = spans,
    autolinks = autolinks,
    invalid_destinations = invalid_destinations,
    hard_breaks = hard_breaks,
    has_angle_link = has_angle_link,
  }
end

--- Hard breaks belong to text nodes, never code, HTML or valid link suffixes.
function M.hard_breaks(text, ref_links, source_label, bare_url)
  if not text:find("\n", 1, true) then return {} end
  return scan(text, ref_links, nil, source_label, bare_url).hard_breaks
end

--- Source-literal autolinks follow the shared escape, code, comment and link precedence.
function M.autolinks(text, ref_links, source_label)
  if not text:find("<", 1, true) and not text:find("www.", 1, true) then return {} end
  return scan(text, ref_links, nil, source_label).autolinks
end

--- Raw, matched code ranges: 1-based inclusive byte offsets and delimiter length.
function M.code_spans(text, ref_links)
  if not text:find("`", 1, true) then return {} end
  return scan(text, ref_links).code_spans
end

--- The same label/code boundaries used by whitespace and link rendering.
---@return integer? suffix_start 1-based byte after the closing label bracket
---@return integer? finish 1-based inclusive end of the whole link
---@return string? reference_url decoded destination for a resolved reference
function M.link_bounds(text, start, ref_links, source_label)
  local result = scan(text, ref_links, start, source_label)
  return result.suffix_start, result.link_end, result.reference_url
end

--- Pick a marker absent from the source, even after source fragments are joined.
--- The common case requires only one search; collisions use a character set.
function M.token_prefix(text, codepoint)
  local marker = vim.fn.nr2char(codepoint)
  if not text:find(marker, 1, true) then return marker end
  local used = {}
  for char in text:gmatch "[\240-\244][\128-\191]+" do
    used[char] = true
  end
  for cp = codepoint + 1, 0x10FFFD do
    if cp <= 0xFFFFD or cp >= 0x100000 then
      marker = vim.fn.nr2char(cp)
      if not used[marker] then return marker end
    end
  end
  -- A source containing every remaining PUA character can still be protected:
  -- it cannot contain or synthesize more copies than its total source count.
  marker = vim.fn.nr2char(codepoint)
  local _, count = text:gsub(marker, "")
  return marker:rep(count + 1)
end

--- A rejected source destination cannot become valid after comments disappear.
--- Protect only its opening parenthesis, preserving bracket/reference ownership.
function M.protect_invalid_destinations(text, ref_links, source_label)
  if not text:find("](", 1, true) then return text, {} end
  local positions = scan(text, ref_links, nil, source_label).invalid_destinations
  if #positions == 0 then return text, {} end
  local invalid, spans = {}, {}
  for _, pos in ipairs(positions) do
    invalid[pos] = true
  end
  local prefix = M.token_prefix(text .. (source_label and source_label(text) or ""), 0xF1006)
  local protected = text:gsub("()%(", function(pos)
    if not invalid[pos] then return "(" end
    local placeholder = prefix .. (#spans + 1) .. "\u{F1007}"
    spans[#spans + 1] = { placeholder = placeholder, content = "(", raw = "(" }
    return placeholder
  end)
  return protected, spans
end

--- Protect code before display whitespace, comments, escapes, or entities change.
function M.protect_code(text, ref_links)
  if not text:find("`", 1, true) then return text, {} end
  local spans, parts, pos = {}, {}, 1
  local prefix = M.token_prefix(text, 0xF1000)
  for _, range in ipairs(M.code_spans(text, ref_links)) do
    local content = text:sub(range.start + range.ticks, range.finish - range.ticks)
    content = content:gsub("\r\n", "\n"):gsub("[\r\n]", " ")
    if content:sub(1, 1) == " " and content:sub(-1) == " " and content:find "[^ ]" then content = content:sub(2, -2) end
    local placeholder = prefix .. (#spans + 1) .. "\u{F1001}"
    spans[#spans + 1] = { placeholder = placeholder, content = content, raw = text:sub(range.start, range.finish) }
    parts[#parts + 1] = text:sub(pos, range.start - 1)
    parts[#parts + 1] = placeholder
    pos = range.finish + 1
  end
  parts[#parts + 1] = text:sub(pos)
  return table.concat(parts), spans
end

return M
