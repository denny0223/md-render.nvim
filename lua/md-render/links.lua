local M = {}

--- Escape terminal control bytes without changing the hyperlink destination.
function M.osc8_url(url)
  return (url:gsub("%c", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

--- Shared by Markdown style spans and native link extmarks.
function M.highlight(url)
  return url:match "^#" and "MdRenderLinkAnchor"
    or url:match "^obsidian://" and "MdRenderLinkObsidian"
    or "MdRenderLink"
end

--- Move within a rendered document, retaining native jump history.
function M.jump(win, row, col)
  win, col = win or vim.api.nvim_get_current_win(), col or 0
  local cursor = vim.api.nvim_win_get_cursor(win)
  if cursor[1] == row + 1 and cursor[2] == col then return end
  vim.api.nvim_win_call(win, function()
    vim.cmd "normal! m'"
    vim.api.nvim_win_set_cursor(win, { row + 1, col })
  end)
end

--- Resolve a heading or footnote fragment to its rendered row.
function M.anchor_row(url, content)
  local anchor = url and url:match "^#(.*)$"
  if anchor == nil then return nil end
  anchor = vim.uri_decode(anchor)
  return anchor == "" and 0 or (content.footnote_anchors or {})[anchor] or (content.heading_anchors or {})[anchor]
end

--- Consume internal links even when their destination is absent.
function M.follow_anchor(url, content, win)
  if not url or not url:match "^#" then return false end
  local row = M.anchor_row(url, content)
  if row then M.jump(win, row) end
  return true
end

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

--- Resolve an explicit local destination, without filename-search heuristics.
function M.file_path(url, directory)
  if url:match "^#" or url:match "^//" then return nil end
  local path = url:match "^[^?#]*"
  if path:match "^file:///" then
    path = vim.uri_to_fname(path)
  elseif path:match "^%a[%w+.-]*:" then
    return nil
  else
    path = vim.uri_decode(path)
  end
  if path == "" or path:find("\0", 1, true) then return nil end
  if path:sub(1, 1) ~= "/" then path = vim.fs.joinpath(directory, path) end
  -- Let the filesystem resolve .. after symlinks; lexical normalization can
  -- select a different file and would also strip a significant trailing slash.
  return path
end

return M
