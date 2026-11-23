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
local pointer_active = false
local pressed

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

local function preview_at(win)
  local entry = registered[win]
  local buf = win ~= 0 and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
  if entry and entry.buf ~= buf then
    M.detach(win)
    entry = nil
  end
  if entry or not buf or not vim.b[buf].md_render then return entry end
  -- A split can display the same preview before its first focus event binds it.
  local session = require("md-render.preview")._sessions[buf]
  return session and registered[session.win]
end

-- Keyboard selection deliberately owns a whole caption or table cell. A click
-- must land on displayed image pixels, including in an unfocused split.
local function image_at_mouse(mouse, entry, already_pressed)
  if not entry or mouse.line <= 0 or mouse.column <= 0 or vim.api.nvim_get_mode().mode ~= "n" then return end
  if not (vim.o.mouse:find("a", 1, true) or vim.o.mouse:find("n", 1, true)) then return end
  local session = require("md-render.preview")._sessions[entry.buf]
  if not session then return end
  local p, idx
  if session.image_state and session.image_state.snacks then
    p, idx = require("md-render.snacks_image").placement_at_mouse(session.image_state, mouse)
  else
    -- Native Kitty places images in a single window; Snacks paints buffer extmarks.
    if session.win ~= mouse.winid then return end
    local row = mouse.line - 1
    local col = vim.fn.virtcol({ mouse.line, mouse.column }, true, mouse.winid)[1] - 1 + (mouse.coladd or 0)
    p, idx = session:image_at(row, col)
    if not p or row < p.line or col < p.col or col >= p.col + p.cols then return end
    -- Neovim maps the empty area below EOF to the buffer's last line.
    if vim.fn.screenpos(mouse.winid, mouse.line, mouse.column).row ~= mouse.screenrow then return end
  end
  if not p then return end
  -- Neovim maps the press in the focused buffer, then the release in the clicked buffer.
  if not already_pressed and vim.fn.maparg("<LeftMouse>", "n") ~= "" then return end
  local mapping = vim.api.nvim_win_call(mouse.winid, function()
    return vim.fn.maparg("<LeftRelease>", "n", false, true).callback
  end)
  if not session._keymap_opts or mapping ~= session._keymap_opts.image_click then return end
  local _, source = session:image_view_hint(p, idx)
  if source then return p, session, idx, source end
end

local function press_image(mouse)
  local entry = preview_at(mouse.winid)
  local p, session, index, source = image_at_mouse(mouse, entry)
  if not p or url_at_mouse(mouse, entry.buf, entry.ns) then return end
  local press = { mouse = mouse, placement = p }
  -- Focusing a split can reflow the buffer and replace its Snacks extmarks.
  -- Keep the occurrence the reader actually pressed through that repaint.
  if mouse.winid ~= session.win then
    local tick = session.source_tick
    press.open_after_focus = function()
      if
        vim.api.nvim_get_current_buf() == session.buf
        and vim.api.nvim_buf_is_valid(session.source_bufnr)
        and vim.api.nvim_buf_get_changedtick(session.source_bufnr) == tick
      then
        return session:open_image(p, index, source)
      end
    end
  end
  return press
end

function M.finish_image_click(mouse)
  local start = pressed
  pressed = nil
  if
    not start
    or mouse.winid ~= start.mouse.winid
    or mouse.screenrow ~= start.mouse.screenrow
    or mouse.screencol ~= start.mouse.screencol
  then
    return
  end
  if start.open_after_focus then
    start.open_after_focus()
  else
    local p, session, idx = image_at_mouse(mouse, preview_at(mouse.winid), true)
    if p and p == start.placement then session:open_image(p, idx) end
  end
  return true
end

local function handle_mouse_move()
  local mouse = require("md-render.display_utils").getmousepos()
  local entry = preview_at(mouse.winid)
  local hints = require "md-render.image_hint"

  if not entry then
    hints.hide()
    cancel_pending()
    close_hover()
    return
  end

  local url = url_at_mouse(mouse, entry.buf, entry.ns)
  local p = not url and image_at_mouse(mouse, entry)
  if p then
    hints.show(mouse.winid, p, "Click to open")
  else
    hints.hide()
  end

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
    if
      preview_at(source_win) ~= entry
      or vim.api.nvim_win_get_tabpage(source_win) ~= vim.api.nvim_get_current_tabpage()
    then
      return
    end
    show_hover(url, source_win)
  end, DEBOUNCE_MS)
end

--- Recheck the pointer after a preview rebuild or image delivery at rest.
function M.refresh()
  if pointer_active then
    handle_mouse_move()
    return true
  end
end

local function ensure_initialized()
  if augroup_initialized then return end
  augroup_initialized = true
  saved_mousemoveevent = vim.o.mousemoveevent
  vim.o.mousemoveevent = true
  -- Observe input without replacing mappings or focusing the hovered window.
  local function schedule_hover()
    if mouse_scheduled then return end
    mouse_scheduled = true
    vim.schedule(function()
      mouse_scheduled = false
      if pointer_active and next(registered) then handle_mouse_move() end
    end)
  end
  local motion = {}
  for _, name in ipairs {
    "<MouseMove>",
    "<ScrollWheelUp>",
    "<ScrollWheelDown>",
    "<ScrollWheelLeft>",
    "<ScrollWheelRight>",
  } do
    motion[vim.keycode(name)] = true
  end
  local press, drag, release = vim.keycode "<LeftMouse>", vim.keycode "<LeftDrag>", vim.keycode "<LeftRelease>"
  vim.on_key(function(key, typed)
    if motion[key] or motion[typed] then
      pressed = nil
      pointer_active = true
      schedule_hover()
    elseif key == press and typed == press then
      pressed = press_image(require("md-render.display_utils").getmousepos())
    elseif key == drag or typed == drag then
      pressed = nil
    elseif #typed > 0 and typed ~= release and key ~= release then
      pressed = nil
      if pointer_active then
        pointer_active = false
        cancel_pending()
        -- Closing a float changes editor state, which is deferred out of on_key.
        vim.schedule(function()
          if not pointer_active then
            close_hover()
            require("md-render.image_hint").refresh()
          end
        end)
      end
    end
  end, KEY_NS)
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "BufWinLeave", "WinLeave", "TabLeave" }, {
    group = vim.api.nvim_create_augroup(AUGROUP, { clear = true }),
    callback = function(ev)
      if ev.event == "WinLeave" or ev.event == "TabLeave" then
        pointer_active = false
        if ev.event == "TabLeave" then pressed = nil end
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
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = AUGROUP,
    callback = function()
      if pointer_active then schedule_hover() end
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
    pointer_active, pressed = false, nil
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
