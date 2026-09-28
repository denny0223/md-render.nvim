--- Paint shaped headings while Neovim retains text, selections and link actions.
local M = {}
local image = require "md-render.image"
---@type table<integer, MdRender.HeadingImageState>
local states = {}

--- Only visible images have projected targets; hovering never changes layout.
---@return table mouse
---@return boolean? projected
---@return table? entry
function M.mouse_position(mouse)
  local state = states[mouse.winid]
  if
    not state
    or state.closed
    or not vim.api.nvim_win_is_valid(state.win)
    or vim.api.nvim_win_get_buf(state.win) ~= state.buf
  then
    return mouse
  end
  for _, entry in ipairs(state.entries) do
    if entry.visible and entry.columns then
      local p = entry.placement
      local pos = vim.fn.screenpos(state.win, p.line + 1, p.col + 1)
      local column = mouse.screencol - pos.col + 1
      if
        mouse.screenrow >= pos.row
        and mouse.screenrow < pos.row + p.scale
        and column >= 1
        and column <= math.max(entry.cols, vim.fn.strdisplaywidth(p.text))
      then
        local byte = entry.columns[column]
        return vim.tbl_extend("force", mouse, {
          line = byte and p.line + 1 or 0,
          column = byte and p.col + byte + 1 or 0,
          coladd = 0,
        }),
          true,
          entry
      end
    end
  end
  return mouse
end

local function overlaps(a, b)
  return a.top <= b.bottom and a.bottom >= b.top and a.left <= b.right and a.right >= b.left
end

local function clear_links(state)
  if not state.linked then return end
  -- These URLs belong to terminal cells, outside Neovim's shadow grid.
  -- A physical repaint restores native text and removes stale hit targets.
  state.linked = nil
  vim.cmd "mode"
  require("md-render.display_utils").announce_repaint "heading_image"
  return true
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
  if not keep_masks then clear_links(state) end
end

local function paint_links(state, visible)
  local out = {}
  for _, entry in ipairs(visible) do
    if entry.links then
      local p = entry.placement
      local pos = vim.fn.screenpos(state.win, p.line + 1, p.col + 1)
      local normal = vim.api.nvim_get_hl(0, { name = p.normal or "Normal", link = false })
      local bg = normal.bg or vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
      local sgr = "\x1b[0m"
      if bg then
        sgr = sgr
          .. string.format(
            "\x1b[48;2;%d;%d;%dm",
            bit.rshift(bg, 16),
            bit.band(bit.rshift(bg, 8), 255),
            bit.band(bg, 255)
          )
      end
      for row = pos.row, pos.row + p.scale - 1 do
        out[#out + 1] = string.format("\x1b[%d;%dH", row, pos.col) .. sgr .. entry.links
      end
    end
  end
  if #out > 0 then
    -- OSC 8 on virtual text cannot cover cells beyond the native buffer text.
    -- Use the same measured cells as mouse_position, leaving opening to Kitty.
    vim.api.nvim_ui_send("\x1b7" .. table.concat(out) .. "\x1b[0m\x1b8")
    state.linked = true
  end
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
  local custom_highlights = require("md-render.heading_feedback").custom_highlights(state.win)
  if not state.force_text and not custom_highlights then
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
    or custom_highlights
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
        and state.gesture ~= entry
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
  if state.last_layout == key then
    paint_links(state, visible)
    return
  end
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
  -- Apply mask changes before the physical repaint; recompute visibility
  -- afterwards. :mode performs its own synchronized update.
  if clear_links(state) then return paint(state) end
  -- Finish raw cell writes before opening the synchronized graphics batch.
  paint_links(state, visible)
  image.begin_sync_update()
  erase(state, false, true)
  image.begin_batch()
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

function M.release_mouse(win)
  local state = states[win]
  if not state then return false end
  local dragged = state.dragged
  state.gesture, state.press, state.dragged = nil, nil, nil
  repaint(state)
  return dragged
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
      local urls, linked = {}, false
      for column, byte in ipairs(entry.columns or {}) do
        urls[column] = ""
        for _, link in ipairs(content.link_metadata or {}) do
          if byte and link.line == p.line and p.col + byte >= link.col_start and p.col + byte < link.col_end then
            -- URLs enter a terminal control sequence here, not just an API.
            urls[column] = link.url:gsub("[%c]", function(c)
              return string.format("%%%02X", c:byte())
            end)
            linked = true
            break
          end
        end
      end
      if linked then
        local runs, previous = {}, nil
        for _, url in ipairs(urls) do
          if url ~= previous then
            runs[#runs + 1] = "\x1b]8;;" .. url .. "\x1b\\"
            previous = url
          end
          runs[#runs + 1] = " "
        end
        entry.links = table.concat(runs) .. "\x1b]8;;\x1b\\"
      end
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
    callback = function(event)
      local source = type(event.data) == "table" and event.data.source
      if source == "text_size" or source == "heading_image" then state.linked = nil end
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
    if event == vim.keycode "<LeftMouse>" and vim.o.mouse ~= "" then
      state.gesture, state.press, state.dragged = nil, nil, nil
      local raw = vim.fn.getmousepos()
      local mouse, projected, entry = M.mouse_position(raw)
      if projected and mouse.winid == state.win then
        state.gesture = entry
        if mouse.line > 0 then state.press = mouse end
        local gesture = state.gesture
        -- Let Neovim focus the window and process the press before correcting
        -- the drag origin. Replaying mouse input here corrupts TUI redraws.
        vim.schedule(function()
          if
            not state.closed
            and mouse.line > 0
            and state.gesture == gesture
            and vim.api.nvim_get_current_win() == state.win
            and vim.api.nvim_win_get_buf(state.win) == state.buf
            and vim.api.nvim_get_mode().mode == "n"
          then
            vim.api.nvim_win_set_cursor(state.win, { mouse.line, mouse.column - 1 })
          end
          repaint(state)
        end)
      end
    elseif event == vim.keycode "<LeftRelease>" then
      -- The release mapping clears the gesture after resolving the visible
      -- target. Scheduling here can run before a mapped release is dispatched.
      return
    elseif event == vim.keycode "<LeftDrag>" then
      if state.gesture then state.dragged = true end
      -- Press and drag can arrive in the same input batch, before scheduled
      -- cursor correction. The native press has completed by this point.
      if
        state.gesture
        and state.press
        and vim.api.nvim_get_current_win() == state.win
        and vim.api.nvim_win_get_buf(state.win) == state.buf
        and vim.api.nvim_get_mode().mode == "n"
      then
        vim.api.nvim_win_set_cursor(state.win, { state.press.line, state.press.column - 1 })
      end
      state.gesture, state.press = nil, nil
      erase(state)
    elseif event ~= vim.keycode "<MouseMove>" and typed and typed ~= "" then
      state.gesture, state.press, state.dragged = nil, nil, nil
      repaint(state)
    end
  end, state.key_ns)
  return state
end

return M
