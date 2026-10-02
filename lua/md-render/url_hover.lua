--- Show the full URL in a small floating window at the bottom-right of the
--- editor while the mouse hovers over a link in a md-render preview.

local M = {}
local Links = require "md-render.links"

local DEBOUNCE_MS = 100
local WINBLEND = 15
local AUGROUP = "md_render_url_hover"
local KEY_NS = vim.api.nvim_create_namespace "md_render_url_hover_keys"
local close_autocmds = {}

---@type table<integer, { buf: integer, ns: integer }>
local registered = {}

local state = {
  ---@type integer?
  hover_win = nil,
  ---@type integer?
  hover_buf = nil,
  ---@type string?
  current_url = nil,
  ---@type integer?
  current_win = nil,
  ---@type string?
  pending_url = nil,
  pending_win = nil,
  ---@type table?
  pending_token = nil,
}

local augroup_initialized = false
local saved_mousemoveevent
local mouse_scheduled = false

local function ensure_hover_buf()
  if state.hover_buf and vim.api.nvim_buf_is_valid(state.hover_buf) then return state.hover_buf end
  state.hover_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.hover_buf].bufhidden = "hide"
  return state.hover_buf
end

---@param url string
---@param max_width integer
---@return string
local function truncate_url(url, max_width)
  if max_width <= 0 then return "" end
  if vim.api.nvim_strwidth(url) <= max_width then return url end
  if max_width == 1 then return "…" end

  local result_width = 0
  local pieces = {}
  local len = vim.fn.strchars(url)
  for i = 0, len - 1 do
    local ch = vim.fn.strcharpart(url, i, 1)
    local w = vim.api.nvim_strwidth(ch)
    if result_width + w + 1 > max_width then break end
    pieces[#pieces + 1] = ch
    result_width = result_width + w
  end
  return table.concat(pieces) .. "…"
end

local function cancel_pending()
  state.pending_token = nil
  state.pending_url = nil
  state.pending_win = nil
end

local function close_hover()
  if state.hover_win and vim.api.nvim_win_is_valid(state.hover_win) then
    pcall(vim.api.nvim_win_close, state.hover_win, true)
  end
  state.hover_win = nil
  state.current_url = nil
  state.current_win = nil
end

--- How many rows at the bottom of the editor are occupied by cmdline +
--- statusline. The hover is placed just above this band so it doesn't
--- overlap either.
---@return integer
local function bottom_reserved_rows()
  local rows = vim.o.cmdheight
  local ls = vim.o.laststatus
  if ls == 2 or ls == 3 then
    rows = rows + 1
  elseif ls == 1 and #vim.api.nvim_tabpage_list_wins(0) > 1 then
    rows = rows + 1
  end
  return rows
end

---@param url string
---@param source_win integer
local function show_hover(url, source_win)
  if
    state.hover_win
    and (
      not vim.api.nvim_win_is_valid(state.hover_win)
      or vim.api.nvim_win_get_tabpage(state.hover_win) ~= vim.api.nvim_get_current_tabpage()
    )
  then
    close_hover()
  end
  if state.current_url == url and state.current_win == source_win then return end

  local max_width = math.max(1, math.floor(vim.o.columns / 2))
  local display = truncate_url(url, max_width)
  local width = math.max(1, vim.api.nvim_strwidth(display))
  local row = math.max(0, vim.o.lines - bottom_reserved_rows() - 1)
  local col = math.max(0, vim.o.columns - width)

  if state.hover_win and vim.api.nvim_win_is_valid(state.hover_win) then
    local buf = vim.api.nvim_win_get_buf(state.hover_win)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { display })
    vim.api.nvim_win_set_config(state.hover_win, {
      relative = "editor",
      width = width,
      height = 1,
      row = row,
      col = col,
    })
  else
    local buf = ensure_hover_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { display })
    state.hover_win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = width,
      height = 1,
      row = row,
      col = col,
      style = "minimal",
      border = "none",
      focusable = false,
      zindex = 250,
      noautocmd = true,
    })
    vim.wo[state.hover_win].winblend = WINBLEND
    vim.wo[state.hover_win].winhighlight = "Normal:Comment,NormalFloat:Comment"
  end

  state.current_url = url
  state.current_win = source_win
end

---@param mouse { winid: integer, line: integer, column: integer }
---@param buf integer
---@param ns integer
---@return string?
local function url_at_mouse(mouse, buf, ns)
  return Links.at(buf, ns, mouse.line - 1, mouse.column - 1)
end

local function handle_mouse_move()
  local mouse = require("md-render.display_utils").getmousepos()
  local entry = registered[mouse.winid]

  if not entry or not vim.api.nvim_win_is_valid(mouse.winid) or vim.api.nvim_win_get_buf(mouse.winid) ~= entry.buf then
    if entry then M.detach(mouse.winid) end
    cancel_pending()
    close_hover()
    return
  end

  local url = url_at_mouse(mouse, entry.buf, entry.ns)

  if not url then
    cancel_pending()
    close_hover()
    return
  end

  if state.current_url == url and state.current_win == mouse.winid then
    cancel_pending()
    return
  end

  if state.pending_url == url and state.pending_win == mouse.winid then return end

  local token = {}
  state.pending_token = token
  state.pending_url = url
  state.pending_win = mouse.winid
  local source_win = mouse.winid

  vim.defer_fn(function()
    if state.pending_token ~= token then return end
    cancel_pending()
    local current = registered[source_win]
    if
      not current
      or current ~= entry
      or not vim.api.nvim_win_is_valid(source_win)
      or vim.api.nvim_win_get_buf(source_win) ~= current.buf
      or vim.api.nvim_win_get_tabpage(source_win) ~= vim.api.nvim_get_current_tabpage()
    then
      return
    end
    show_hover(url, source_win)
  end, DEBOUNCE_MS)
end

local function ensure_initialized()
  if augroup_initialized then return end
  augroup_initialized = true
  saved_mousemoveevent = vim.o.mousemoveevent
  vim.o.mousemoveevent = true
  -- Observe the native event without replacing user mappings, including when
  -- the mouse is over a preview that does not have keyboard focus.
  vim.on_key(function(key, typed)
    if key ~= vim.keycode "<MouseMove>" and typed ~= vim.keycode "<MouseMove>" then return end
    if mouse_scheduled then return end
    mouse_scheduled = true
    vim.schedule(function()
      mouse_scheduled = false
      if next(registered) then handle_mouse_move() end
    end)
  end, KEY_NS)
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "BufWinLeave", "TabLeave" }, {
    group = vim.api.nvim_create_augroup(AUGROUP, { clear = true }),
    callback = function(ev)
      if ev.event == "TabLeave" then
        cancel_pending()
        close_hover()
        return
      end
      local function prune()
        for win, entry in pairs(registered) do
          if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= entry.buf then M.detach(win) end
        end
      end
      if ev.event == "BufWinLeave" then
        vim.schedule(prune)
      else
        prune()
      end
    end,
  })
end

function M.detach(win)
  registered[win] = nil
  if close_autocmds[win] then pcall(vim.api.nvim_del_autocmd, close_autocmds[win]) end
  close_autocmds[win] = nil
  if state.pending_win == win then cancel_pending() end
  if state.current_win == win then close_hover() end
  if not next(registered) and augroup_initialized then
    vim.on_key(nil, KEY_NS)
    vim.api.nvim_clear_autocmds { group = AUGROUP }
    if vim.o.mousemoveevent then vim.o.mousemoveevent = saved_mousemoveevent end
    saved_mousemoveevent = nil
    augroup_initialized = false
  end
end

--- Start showing URL hovers for the given preview window.
---@param buf integer
---@param ns integer
---@param win integer
function M.attach(buf, ns, win)
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then return end
  ensure_initialized()
  local already_registered = registered[win] ~= nil
  if already_registered and registered[win].buf == buf and registered[win].ns == ns then return end
  if state.pending_win == win then cancel_pending() end
  if state.current_win == win then close_hover() end
  registered[win] = { buf = buf, ns = ns }
  if already_registered then return end
  close_autocmds[win] = vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup(AUGROUP, { clear = false }),
    pattern = tostring(win),
    once = true,
    callback = function()
      M.detach(win)
    end,
  })
end

--- Exposed for tests.
function M._internal()
  return {
    state = state,
    registered = registered,
    truncate_url = truncate_url,
    url_at_mouse = url_at_mouse,
    handle_mouse_move = handle_mouse_move,
    show_hover = show_hover,
    close_hover = close_hover,
    bottom_reserved_rows = bottom_reserved_rows,
    DEBOUNCE_MS = DEBOUNCE_MS,
  }
end

return M
