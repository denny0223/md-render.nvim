--- Shared text feedback for both heading renderers.
local M = {}
local selection_modes = { v = true, V = true, ["\022"] = true, s = true, S = true, ["\019"] = true }

--- Leave Neovim in charge of selected rows and external feedback such as yank
--- highlights. Query only the viewport, and ignore our own Markdown styling.
local function interaction_rows(state, selecting)
  local rows = {}
  local first = vim.fn.line("w0", state.win) - 1
  local last = vim.fn.line("w$", state.win) - 1
  local function include(a, b)
    for row = math.max(first, a), math.min(last, b) do
      rows[row] = true
    end
  end
  if selecting then
    local anchor, cursor = vim.fn.line "v" - 1, vim.fn.line "." - 1
    include(math.min(anchor, cursor), math.max(anchor, cursor))
  end
  local scopes = {}
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(state.buf, -1, { first, 0 }, { last, -1 }, {
      details = true,
      overlap = true,
      type = "highlight",
    }))
  do
    local details = mark[4]
    if details.ns_id ~= state.content.highlight_ns and not details.invalid then
      local wins = scopes[details.ns_id]
      if not wins then
        wins = vim.api.nvim__ns_get(details.ns_id).wins or {}
        scopes[details.ns_id] = wins
      end
      if #wins == 0 or vim.list_contains(wins, state.win) then
        local finish = details.end_row or mark[2]
        if details.end_col == 0 then finish = finish - 1 end
        include(mark[2], finish)
      end
    end
  end
  return rows
end

--- Search in the real buffer so Vim's regex options and multiline matches
--- agree with the highlights. Never change the search state.
local function search_rows(state, placements)
  local pattern = vim.v.hlsearch == 1 and vim.fn.getreg "/" or ""
  local view = vim.api.nvim_win_call(state.win, vim.fn.winsaveview)
  local key = vim.inspect {
    pattern,
    vim.o.ignorecase,
    vim.o.smartcase,
    vim.o.magic,
    view.topline,
    vim.api.nvim_win_get_height(state.win),
  }
  if state.search_key == key then return state.search_rows end
  state.search_key, state.search_rows = key, {}
  if pattern == "" then return state.search_rows end
  vim.api.nvim_win_call(state.win, function()
    for _, placement in ipairs(placements) do
      local row = placement.line + 1
      if vim.fn.screenpos(state.win, row, 1).row > 0 then
        local started = vim.uv.hrtime()
        local ok, matched = pcall(function()
          vim.api.nvim_win_set_cursor(state.win, { row, 0 })
          if vim.fn.searchpos(pattern, "cnW", row, 5)[1] == row then return true end
          -- A multiline match may start above this heading. Look for the
          -- preceding match and test its end in the same buffer context.
          if pattern:find("\\n", 1, true) or pattern:find("\\_", 1, true) then
            local first = vim.fn.searchpos(pattern, "bcW", 1, 5)
            if first[1] > 0 then return vim.fn.searchpos(pattern, "cenW", 0, 5)[1] >= row end
          end
          return false
        end)
        -- A timed-out/invalid pattern must not be covered by an image.
        state.search_rows[row] = not ok or matched or (vim.uv.hrtime() - started > 5e6)
      end
    end
    vim.fn.winrestview(view)
  end)
  return state.search_rows
end

--- Return whether all headings, or individual buffer rows, need native feedback.
function M.protected(state, placements)
  local mode = vim.api.nvim_get_mode().mode
  local active = vim.api.nvim_get_current_win() == state.win
  local selecting = active and selection_modes[mode:sub(1, 1)]
  local all = (active and mode ~= "n" and not selecting and mode:sub(1, 2) ~= "no")
    or vim.fn.pumvisible() == 1
    or #vim.fn.getmatches(state.win) > 0
  local rows = interaction_rows(state, selecting)
  for row, matched in pairs(search_rows(state, placements)) do
    if matched then rows[row - 1] = true end
  end
  return all, rows
end

return M
