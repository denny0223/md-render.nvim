local M = {}
local fence = require "md-render.fence"
local inline = require "md-render.inline"

-- CommonMark 0.31.2 is the core grammar; GFM extensions do not replace its
-- textarea, lowercase declaration, search or source-tag boundary rules.
local BLOCK_TAGS =
  " address article aside base basefont blockquote body caption center col colgroup dd details dialog dir div dl dt fieldset figcaption figure footer form frame frameset h1 h2 h3 h4 h5 h6 head header hr html iframe legend li link main menu menuitem nav noframes ol optgroup option p param search section summary table tbody td tfoot th thead title tr track ul "
local RAW_TAGS = { pre = true, script = true, style = true, textarea = true }

--- The seven HTML-block openings, after at most three columns of indentation.
--- A complete type-7 tag cannot interrupt a paragraph.
---@return integer? kind
function M.start(line, in_paragraph, column)
  local indent, text = line:match "^([ \t]*)(.*)$"
  if fence.indent_columns(indent, column) > 3 or text:sub(1, 1) ~= "<" then return end
  local lower = text:lower()
  local raw_tag, tail = lower:match "^<([a-z][a-z0-9%-]*)(.*)$"
  if RAW_TAGS[raw_tag] and (tail == "" or tail:match "^[ \t>]") then return 1 end
  if text:sub(1, 4) == "<!--" then return 2 end
  if text:sub(1, 2) == "<?" then return 3 end
  if text:match "^<![A-Za-z]" then return 4 end
  if text:sub(1, 9) == "<![CDATA[" then return 5 end
  local tag, rest = lower:match "^</?([a-z][a-z0-9]*)(.*)$"
  if
    tag
    and BLOCK_TAGS:find(" " .. tag .. " ", 1, true)
    and (rest == "" or rest:match "^[ \t>]" or rest:sub(1, 2) == "/>")
  then
    return 6
  end
  if not in_paragraph and text:match "^</?[A-Za-z]" and (text:sub(1, 2) == "</" or not RAW_TAGS[raw_tag]) then
    local finish = inline.html_end(text, 1)
    if finish and text:sub(finish + 1):match "^[ \t]*$" then return 7 end
  end
end

--- Types 1–5 include their closing line; types 6–7 exclude the blank terminator.
function M.ends(kind, line)
  if kind == 1 then
    local lower = line:lower()
    for tag in pairs(RAW_TAGS) do
      if lower:find("</" .. tag .. ">", 1, true) then return true end
    end
    return false
  end
  local endings = { [2] = "-->", [3] = "?>", [4] = ">", [5] = "]]>" }
  if endings[kind] then return line:find(endings[kind], 1, true) ~= nil end
  return line:match "^[ \t]*$" ~= nil
end

return M
