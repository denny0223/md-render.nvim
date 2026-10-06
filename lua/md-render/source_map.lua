---@class MdRender.SourceMap
---@field length integer number of bytes represented by this map
---@field runs { col: integer, source_line: integer }[] source changes at 0-based byte offsets
local SourceMap = {}
SourceMap.__index = SourceMap

local function new_map(length, runs)
  return setmetatable({ length = length, runs = runs }, SourceMap)
end

-- A later slice or insertion at the same column replaces the boundary owner.
local function append(runs, col, source_line)
  local last = runs[#runs]
  if last and last.col == col then
    if #runs > 1 and runs[#runs - 1].source_line == source_line then
      runs[#runs] = nil
    else
      last.source_line = source_line
    end
  elseif not last or last.source_line ~= source_line then
    runs[#runs + 1] = { col = col, source_line = source_line }
  end
end

---@param text string original source, before inline transformations
---@return MdRender.SourceMap
function SourceMap.new(text)
  local runs, source_line = { { col = 0, source_line = 1 } }, 1
  for pos in text:gmatch "()\n" do
    source_line = source_line + 1
    runs[#runs + 1] = { col = pos, source_line = source_line }
  end
  return new_map(#text, runs)
end

---@param length integer
---@param source_line integer
---@return MdRender.SourceMap
function SourceMap.constant(length, source_line)
  return new_map(length, { { col = 0, source_line = source_line } })
end

-- Return the run containing offset, including a possible EOF transition.
local function run_at(map, offset)
  local first, last = 1, #map.runs
  while first <= last do
    local mid = math.floor((first + last) / 2)
    if map.runs[mid].col <= offset then
      first = mid + 1
    else
      last = mid - 1
    end
  end
  return last
end

---@param offset integer 0-based byte offset
---@return integer
function SourceMap:at(offset)
  offset = math.max(0, math.min(offset, self.length))
  local run = self.runs[run_at(self, offset)]
  return run and run.source_line or 1
end

---@param first integer inclusive byte offset
---@param last integer exclusive byte offset
---@return MdRender.SourceMap independent map, including the end boundary owner
function SourceMap:slice(first, last)
  assert(first >= 0 and first <= last and last <= self.length, "source slice outside mapped bytes")
  local index = run_at(self, first)
  local run = self.runs[index]
  local runs = { { col = 0, source_line = run and run.source_line or 1 } }
  for i = index + 1, #self.runs do
    run = self.runs[i]
    if run.col > last then break end
    append(runs, run.col - first, run.source_line)
  end
  return new_map(last - first, runs)
end

---@param edits { first: integer, last: integer, value?: MdRender.SourceMap }[] ordered, nonoverlapping edits in original coordinates
---@return MdRender.SourceMap self
function SourceMap:replace(edits)
  if #edits == 0 then return self end
  local runs, length, cursor, owner, position = {}, 0, 1, 1, 0
  local function copy(first, last)
    while self.runs[cursor] and self.runs[cursor].col <= first do
      owner = self.runs[cursor].source_line
      cursor = cursor + 1
    end
    append(runs, length, owner)
    while self.runs[cursor] and self.runs[cursor].col <= last do
      local run = self.runs[cursor]
      append(runs, length + run.col - first, run.source_line)
      owner = run.source_line
      cursor = cursor + 1
    end
    length = length + last - first
  end
  for _, edit in ipairs(edits) do
    assert(
      edit.first >= position and edit.first <= edit.last and edit.last <= self.length,
      "source edits must be ordered and inside mapped bytes"
    )
    copy(position, edit.first)
    if edit.value then
      for _, run in ipairs(edit.value.runs) do
        append(runs, length + run.col, run.source_line)
      end
      length = length + edit.value.length
    end
    position = edit.last
  end
  copy(position, self.length)
  self.length, self.runs = length, runs
  return self
end

---@param removals { start: integer, count: integer }[] existing rendered byte deltas
---@return MdRender.SourceMap self
function SourceMap:removals(removals)
  local edits = {}
  for index, removal in ipairs(removals) do
    if removal.count ~= 0 then
      local first = removal.count > 0 and removal.start or removal.start + removal.count
      edits[#edits + 1] = {
        first = first,
        last = removal.count > 0 and first + removal.count or first,
        -- Expansion of ordinary text continues the preceding byte's owner.
        -- Token/label replacements supply their actual content map instead.
        value = removal.count < 0 and SourceMap.constant(-removal.count, self:at(math.max(0, first - 1))) or nil,
        order = index,
      }
    end
  end
  table.sort(edits, function(a, b)
    if a.first ~= b.first then return a.first < b.first end
    if a.last ~= b.last then return a.last < b.last end
    return a.order < b.order
  end)
  return self:replace(edits)
end

---@param edits table ordered edit batch owned by the caller
---@param span table source-restorable token span
---@param first integer inclusive byte offset
---@param last integer exclusive byte offset
---@param content_map? MdRender.SourceMap origins after token-specific normalization
function SourceMap:protect(edits, span, first, last, content_map)
  span.raw_sources = self:slice(first, last)
  span.sources = content_map or self:slice(first, last)
  edits[#edits + 1] = {
    first = first,
    last = last,
    value = SourceMap.constant(#span.placeholder, self:at(first)),
  }
end

return SourceMap
