--- Paint shaped headings while Neovim retains text, selections and link actions.
local M = {}
local image = require "md-render.image"
---@type table<integer, MdRender.HeadingImageState>
local states = {}

local function overlaps(a, b)
  return a.top <= b.bottom and a.bottom >= b.top and a.left <= b.right and a.right >= b.left
end

local function erase(state, free, keep_masks)
  if not keep_masks then
    if state.masked and vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_clear_namespace(state.buf, state.mask_ns, 0, -1)
    end
    state.masked = false
  end
  for _, entry in ipairs(state.entries) do
    if not keep_masks then entry.mask_id = nil end
    if entry.id and (free or entry.visible) then
      if free then
        image.delete_image(entry.id)
      else
        image.clear_placements(entry.id)
      end
      entry.visible = false
    end
  end
  state.drawn = 0
  state.last_layout = nil
end

local function paint(state)
  if state.closed or not vim.api.nvim_win_is_valid(state.win) then return end
  if
    vim.api.nvim_win_get_buf(state.win) ~= state.buf
    or vim.api.nvim_win_get_tabpage(state.win) ~= vim.api.nvim_get_current_tabpage()
  then
    erase(state)
    return
  end
  -- :highlight has no change event. Compare the groups used when shaping,
  -- withdraw stale pixels now, and let the existing cache rebuild once.
  if not state.force_text then
    for name, style in pairs(state.content.heading_highlights or {}) do
      if not vim.deep_equal(style, vim.api.nvim_get_hl(0, { name = name, link = false })) then
        state.force_text = true
        vim.schedule(function()
          local preview = package.loaded["md-render.preview"]
          if not state.closed and preview then preview.rebuild_visible() end
        end)
        break
      end
    end
  end
  local active = vim.api.nvim_get_current_win() == state.win
  local feedback, interacting = require("md-render.heading_feedback").protected(state, state.content.text_placements)
  local native = state.failed
    or state.force_text
    or not vim.o.termguicolors
    or require("md-render.heading_feedback").custom_highlights(state.win)
    or vim.wo[state.win].winblend > 0
    or feedback
  local overlays = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local cfg = vim.api.nvim_win_get_config(win)
    if win ~= state.win and cfg.relative ~= "" then
      local pos = vim.api.nvim_win_get_position(win)
      -- Include a possible border so images never cover floating UI.
      local border = cfg.border and cfg.border ~= "none" and 2 or 0
      table.insert(overlays, {
        top = pos[1] + 1,
        left = pos[2] + 1,
        bottom = pos[1] + vim.api.nvim_win_get_height(win) + border,
        right = pos[2] + vim.api.nvim_win_get_width(win) + border,
      })
    end
  end
  local cursor = vim.api.nvim_win_get_cursor(state.win)[1] - 1
  local cursor_col = active and vim.fn.virtcol "." - 1 or -1
  local left, right, top, bottom = require("md-render.text_size").text_area(state.win)
  if not left then return end
  local visible, layout, masks = {}, {}, {}
  for _, entry in ipairs(state.entries) do
    local p = entry.placement
    local current = vim.api.nvim_buf_get_lines(state.buf, p.line, p.line + 1, false)[1] or ""
    local pos = vim.fn.screenpos(state.win, p.line + 1, p.col + 1)
    local rect = { top = pos.row, left = pos.col, bottom = pos.row + p.scale - 1, right = pos.col + entry.cols - 1 }
    local covered = false
    for row = p.line, p.line + p.scale - 1 do
      if interacting[row] then covered = true end
    end
    for _, overlay in ipairs(overlays) do
      if overlaps(rect, overlay) then
        covered = true
        break
      end
    end
    if
      not native
      and not covered
      and entry.id
      and entry.ready
      and rect.left >= left
      and rect.right <= right
      and rect.top >= top
      and rect.bottom <= bottom
      and current:sub(p.col + 1, p.col + #p.text) == p.text
      and not (
        active
        and cursor >= p.line
        and cursor < p.line + p.scale
        and cursor_col >= entry.col
        and cursor_col < entry.col + math.max(entry.cols, vim.fn.strdisplaywidth(p.text))
      )
    then
      table.insert(visible, entry)
      table.insert(layout, table.concat({ entry.id, pos.row, pos.col }, ":"))
      if entry.transparent then masks[entry] = true end
    end
  end
  local key = table.concat(layout, "/")
  if state.last_layout == key then return end
  image.begin_sync_update()
  erase(state, false, true)
  image.begin_batch()
  -- Preserve masks across graphics repaints: recreating extmarks would start
  -- another Neovim redraw, which in turn requests another graphics repaint.
  for _, entry in ipairs(state.entries) do
    local p = entry.placement
    if masks[entry] and not entry.mask_id then
      -- Blank only the displayed glyphs: transparent PNGs must not expose a
      -- second copy of the text. Overlay text leaves buffer coordinates intact.
      entry.mask_id = vim.api.nvim_buf_set_extmark(state.buf, state.mask_ns, p.line, p.col, {
        virt_text = { { string.rep(" ", vim.fn.strdisplaywidth(p.text)), p.normal or "Normal" } },
        virt_text_pos = "overlay",
        priority = vim.hl.priorities.user + 1,
      })
    elseif not masks[entry] and entry.mask_id then
      vim.api.nvim_buf_del_extmark(state.buf, state.mask_ns, entry.mask_id)
      entry.mask_id = nil
    end
  end
  state.masked = next(masks) ~= nil
  for _, entry in ipairs(visible) do
    local p = entry.placement
    image.put_image(entry.id, state.win, p.line, entry.col, entry.cols, p.scale, nil, entry.width, entry.height)
    entry.visible = true
  end
  image.end_sync_update()
  image.flush_batch()
  state.drawn, state.last_layout = #visible, key
end

local function repaint(state)
  if state.closed then return end
  if state.pending then return end
  state.pending = true
  vim.schedule(function()
    state.pending = false
    paint(state)
  end)
end

---@param state MdRender.HeadingImageState?
function M.detach(state)
  if not state or state.closed then return end
  state.closed = true
  if states[state.win] == state then states[state.win] = nil end
  erase(state, true)
  vim.on_key(nil, state.key_ns)
  vim.api.nvim_del_augroup_by_id(state.group)
end

---@param win integer
---@param content MdRender.Content
---@return MdRender.HeadingImageState?
function M.attach(win, content)
  if win == 0 then win = vim.api.nvim_get_current_win() end
  local cell = image.get_cell_size()
  if not cell or not image.supports_kitty() then return nil end
  ---@class MdRender.HeadingImageState
  ---@field image_headings true
  ---@field win integer
  ---@field buf integer
  ---@field content MdRender.Content
  ---@field entries table[] window-owned image placements and interaction targets
  ---@field drawn integer number of visible images
  ---@field closed? boolean
  ---@field last_layout? string
  local state = {
    image_headings = true,
    win = win,
    buf = vim.api.nvim_win_get_buf(win),
    content = content,
    entries = {},
    drawn = 0,
    group = vim.api.nvim_create_augroup("md_render_heading_image_" .. win, { clear = true }),
    key_ns = vim.api.nvim_create_namespace("md_render_heading_image_keys_" .. win),
    mask_ns = vim.api.nvim_create_namespace("md_render_heading_image_mask_" .. win),
  }
  -- A render buffer may also be visible in a window which has no images.
  vim.api.nvim__ns_set(state.mask_ns, { wins = { win } })
  states[win] = state
  for _, p in ipairs(content.text_placements or {}) do
    local raster = p.raster
    if raster and raster.data then
      local entry = vim.tbl_extend("force", {}, raster, {
        placement = p,
        col = vim.fn.strdisplaywidth(content.lines[p.line + 1]:sub(1, p.col)),
      })
      state.entries[#state.entries + 1] = entry
      entry.id = image.transmit_png(raster.data, function(err)
        if state.closed then return end
        if err then
          state.failed = true
          erase(state)
          image.fail_png(err)
        else
          entry.ready = true
          repaint(state)
        end
      end)
      if not entry.id then
        state.failed = true
        image.fail_png "terminal PNG transmission is unavailable"
      end
    end
  end
  repaint(state)
  vim.api.nvim_create_autocmd({
    "CursorMoved",
    "ModeChanged",
    "CmdlineEnter",
    "CmdlineChanged",
    "CmdlineLeave",
    "TextYankPost",
    "WinScrolled",
    "WinResized",
    "SafeState",
    "WinEnter",
    "WinLeave",
    "TabEnter",
    "TabLeave",
  }, {
    group = state.group,
    callback = function(event)
      -- Scheduling from SafeState would keep waking the idle loop itself.
      if event.event == "SafeState" then
        paint(state)
      else
        repaint(state)
      end
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = state.group,
    callback = function()
      -- Never cover a new theme with cached colors from the previous theme.
      state.force_text = true
      repaint(state)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = state.group,
    pattern = require("md-render.display_utils").REPAINT_EVENT,
    callback = function()
      state.last_layout = nil
      repaint(state)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.group,
    pattern = tostring(win),
    callback = function()
      M.detach(state)
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = state.group,
    callback = function()
      M.detach(state)
    end,
  })
  vim.on_key(function(key, typed)
    local event = typed ~= "" and typed or key
    if event == vim.keycode "<C-l>" then state.last_layout = nil end
    if event ~= vim.keycode "<MouseMove>" and typed and typed ~= "" then repaint(state) end
  end, state.key_ns)
  return state
end

return M
