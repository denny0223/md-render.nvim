--- Native heading runs share Markdown byte ranges with wrapping and hit targets.
local M = {}

--- Split only at style/link boundaries, then reuse the normal OSC 66 packing.
function M.runs(text, offset, highlights, links, spec, budget)
  local finish = offset + #text
  local boundaries = { [offset] = true, [finish] = true }
  for _, span in ipairs(highlights) do
    boundaries[math.max(offset, math.min(finish, span.col))] = true
    boundaries[math.max(offset, math.min(finish, span.end_col))] = true
  end
  for _, link in ipairs(links) do
    boundaries[math.max(offset, math.min(finish, link.col_start))] = true
    boundaries[math.max(offset, math.min(finish, link.col_end))] = true
  end
  local points = vim.tbl_keys(boundaries)
  table.sort(points)
  local runs, width = {}, 0
  for i = 1, #points - 1 do
    local first, last = points[i], points[i + 1]
    local groups, url = {}, nil
    for _, span in ipairs(highlights) do
      if span.col <= first and span.end_col > first then groups[#groups + 1] = span.hl end
    end
    for _, link in ipairs(links) do
      if link.col_start <= first and link.col_end > first then url = link.url end
    end
    local parts, cells =
      require("md-render.text_size").split_run(text:sub(first - offset + 1, last - offset), spec, budget)
    local byte = first - offset
    for _, run in ipairs(parts) do
      run.hl, run.url, run.byte = groups, url, byte
      run.width = spec.s * (run.w > 0 and run.w or vim.api.nvim_strwidth(run.text))
      runs[#runs + 1] = run
      byte = byte + #run.text
    end
    width = width + cells
  end
  return runs, width
end

--- Map visible cells to source bytes; rounded run padding has no text target.
function M.columns(placement)
  local columns, column = {}, 0
  local ratio = placement.scale * (placement.num and placement.num / placement.den or 1)
  for _, run in ipairs(placement.runs) do
    local chars, width, byte = {}, 0, run.byte
    for _, char in ipairs(vim.fn.split(run.text, "\\zs")) do
      width = width + vim.api.nvim_strwidth(char)
      chars[#chars + 1] = { last = width * ratio, byte = byte }
      byte = byte + #char
    end
    local index = 1
    for cell = 1, run.width do
      while chars[index] and cell - 0.5 >= chars[index].last do
        index = index + 1
      end
      columns[column + cell] = chars[index] and chars[index].byte or false
    end
    column = column + run.width
  end
  return columns
end

return M
