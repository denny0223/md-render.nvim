--- Fenced code block delimiters, as CommonMark / GFM define them.
---
--- A fence is a run of at least three backticks or three tildes.  The info
--- string after it may be separated by spaces (``` bash), and its first word
--- is the language.  A block is closed only by a run of the *same* character
--- that is at least as long as the opening one and followed by nothing but
--- whitespace, so ```` can wrap a sample that itself contains ```, and a
--- ~~~ block can hold ``` lines.
---
--- Every pass that has to skip code (tab expansion, container indent,
--- paragraph joining, footnote collection, the renderer itself) tracks fences
--- through this module, so they all agree on where a block starts and ends.

local references = require "md-render.character_references"
local M = {}

--- Count indentation at its original column; tabs stop every four columns.
function M.indent_columns(indent, column)
  local start = column or 0
  column = start
  for c in indent:gmatch "." do
    column = c == "\t" and (column + 4 - column % 4) or (column + 1)
  end
  return column - start
end

---@class MdRender.Fence
---@field char string "`" or "~"
---@field len integer length of the fence run
---@field indent string whitespace in front of the fence
---@field container integer known container indentation still present in the line
---@field info string decoded info string, trimmed
---@field lang string? first word of the info string

--- Parse an opening fence.
---@param line string
---@param column? integer original column before the container-relative line
---@param container? integer known container indentation still present in the line
---@return MdRender.Fence?
function M.opening(line, column, container)
  local indent, run = line:match "^([ \t]*)(```+)"
  if not run then
    indent, run = line:match "^([ \t]*)(~~~+)"
  end
  if not run then return nil end
  container = container or 0
  local width = M.indent_columns(indent, column)
  if width < container or width - container > 3 then return nil end
  local info = line:sub(#indent + #run + 1)
  -- A backtick fence's info string may not contain a backtick; ``` x ```
  -- is an inline code span, not a fence.
  if run:sub(1, 1) == "`" and info:find("`", 1, true) then return nil end
  info = vim.trim(references.decode(info))
  return {
    char = run:sub(1, 1),
    len = #run,
    indent = string.rep(" ", width),
    container = container,
    info = info,
    lang = info:match "^%S+",
  }
end

--- Whether `line` closes the block opened by `fence`.
---@param line string
---@param fence MdRender.Fence
---@param column? integer original column before the container-relative line
---@return boolean
function M.closes(line, fence, column)
  local indent, run = line:match "^([ \t]*)(```+)%s*$"
  if not run then
    indent, run = line:match "^([ \t]*)(~~~+)%s*$"
  end
  if not run or run:sub(1, 1) ~= fence.char or #run < fence.len then return false end
  local width = M.indent_columns(indent, column) - fence.container
  return width >= 0 and width <= 3
end

--- Advance a fence tracker by one line.
---
--- `open` is the fence of the block the previous line was in (nil outside
--- code).  Returns the fence the next line is in, and whether this line was
--- itself a fence (opening or closing).
---@param open MdRender.Fence?
---@param line string container-relative input
---@param column? integer original column, before any container prefix was removed
---@param container? integer known container indentation still present in the line
---@return MdRender.Fence? open, boolean is_fence, string line
function M.step(open, line, column, container)
  local is_fence
  if open then
    is_fence = M.closes(line, open, column)
    if is_fence then open = nil end
  else
    open = M.opening(line, column, container)
    is_fence = open ~= nil
  end
  if is_fence then
    -- Only delimiters are normalized. Tabs in literal code stay untouched.
    local indent = line:match "^[ \t]*"
    line = string.rep(" ", M.indent_columns(indent, column)) .. line:sub(#indent + 1)
  end
  return open, is_fence, line
end

return M
