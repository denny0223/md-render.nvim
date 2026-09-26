local M = {}

--- Find the link containing a byte position; extmark query bounds are inclusive.
function M.at(buf, ns, row, col)
  if not vim.api.nvim_buf_is_valid(buf) or row < 0 or col < 0 or row >= vim.api.nvim_buf_line_count(buf) then
    return nil
  end
  local pos = { row, col }
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, pos, pos, { details = true, overlap = true })
  for _, mark in ipairs(marks) do
    local _, start_row, start_col, details = unpack(mark)
    local end_row, end_col = details.end_row or start_row, details.end_col or start_col + 1
    if details.url and (row > start_row or col >= start_col) and (row < end_row or col < end_col) then
      return details.url
    end
  end
end

return M
