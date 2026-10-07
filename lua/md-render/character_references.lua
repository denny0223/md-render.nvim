local M = {}

--- CommonMark replaces raw NUL on a rendering copy, before parsing any syntax.
---@param text string
---@param sources? MdRender.SourceMap
---@return string
---@return MdRender.Markdown.Removal[]? removals byte deltas in original coordinates
function M.normalize_nul(text, sources)
  if not text:find("\0", 1, true) then return text end
  local SourceMap = sources and require "md-render.source_map"
  local edits, removals = {}, {}
  for pos in text:gmatch "()%z" do
    removals[#removals + 1] = { start = pos + 2, count = -2 }
    if sources then
      edits[#edits + 1] = { first = pos - 1, last = pos, value = SourceMap.constant(#"�", sources:at(pos - 1)) }
    end
  end
  if sources then sources:replace(edits) end
  return (text:gsub("%z", "�")), removals
end

--- Match one complete CommonMark character reference at a 1-indexed byte offset.
--- Unknown names and invalid numeric syntax are ordinary source text.
---@param text string
---@param i integer
---@return string? reference
---@return string? replacement
function M.match(text, i)
  if text:sub(i, i) ~= "&" then return nil, nil end
  local reference, digits = text:match("^(&#(%d+);)", i)
  local base, max_digits = 10, 7
  if not reference then
    reference, digits = text:match("^(&#[xX](%x+);)", i)
    base, max_digits = 16, 6
  end
  if reference then
    if #digits > max_digits then return nil, nil end
    local cp = tonumber(digits, base)
    if cp == 0 or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF) then return reference, "�" end
    return reference, vim.fn.nr2char(cp)
  end
  local name
  reference, name = text:match("^(&(%a%w*);)", i)
  local value = name and require("md-render.html_entities")[name]
  if value then return reference, value end
  return nil, nil
end

--- Decode a raw metadata string, including backslash-escaped ASCII punctuation.
--- This does not parse Markdown constructs or revisit emitted characters, so
--- \&amp; stays &amp; and &#92;&#42; becomes a literal backslash followed by *.
---@param text string
---@return string
function M.decode(text)
  local out, i = {}, 1
  while i <= #text do
    local char = text:sub(i, i)
    local next_char = text:sub(i + 1, i + 1)
    if char == "\\" and next_char:match "[!-~]" and not next_char:match "%w" then
      out[#out + 1] = next_char
      i = i + 2
    else
      local reference, replacement = M.match(text, i)
      out[#out + 1] = replacement or char
      i = i + (reference and #reference or 1)
    end
  end
  return table.concat(out)
end

return M
