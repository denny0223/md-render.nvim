--- Paint shaped headings while Neovim retains text, selections and link actions.
local M = {}
local image = require "md-render.image"
---@type table<integer, MdRender.HeadingImageState>
local states = {}
local PLACEHOLDER = vim.fn.nr2char(0x10EEEE)

local function placeholder_origin(row)
  return PLACEHOLDER .. vim.fn.nr2char(row == 1 and 0x0305 or 0x030D) .. vim.fn.nr2char(0x0305)
end

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

local function clear_links(state)
  if not state.linked then return end
  -- These URLs belong to terminal cells, outside Neovim's shadow grid.
  -- A physical repaint restores native text and removes stale hit targets.
  state.linked = nil
  vim.cmd "mode"
  require("md-render.display_utils").announce_repaint "heading_image"
  return true
end

local function clear_mask(state, entry)
  for _, id in ipairs(entry.mask_ids or {}) do
    vim.api.nvim_buf_del_extmark(state.buf, state.mask_ns, id)
  end
  entry.mask_ids = nil
end

local function erase(state, free, keep_masks)
  if not keep_masks then
    if state.masked and vim.api.nvim_buf_is_valid(state.buf) then
      vim.api.nvim_buf_clear_namespace(state.buf, state.mask_ns, 0, -1)
    end
    state.masked = false
  end
  for _, entry in ipairs(state.entries) do
    if not keep_masks then entry.mask_ids = nil end
    if entry.id and (free or entry.visible) then
      if free then
        image.delete_image(entry.id)
      elseif not state.tmux then
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
      if state.tmux then
        sgr = sgr
          .. string.format(
            "\x1b[38;2;%d;%d;%dm",
            bit.rshift(entry.id, 16),
            bit.band(bit.rshift(entry.id, 8), 255),
            bit.band(entry.id, 255)
          )
      end
      for row = 1, p.scale do
        out[#out + 1] = string.format("\x1b[%d;%dH", pos.row + row - 1, pos.col) .. sgr .. entry.links[row]
      end
    end
  end
  if #out > 0 then
    -- OSC 8 on virtual text cannot cover cells beyond the native buffer text.
    -- Use the same measured cells as mouse_position, leaving opening to Kitty.
    -- In tmux these are pane-relative placeholder cells, not passthrough writes.
    local data = "\x1b7" .. table.concat(out) .. "\x1b[0m\x1b8"
    -- Tmux must redraw complete cells: incremental combining-character writes
    -- can lose placeholder row marks in offset panes (including linked rows).
    if state.tmux then data = "\x1b[?2026h" .. data .. "\x1b[?2026l" end
    local ok, err = pcall(vim.api.nvim_ui_send, data)
    if not ok then
      state.failed = true
      erase(state)
      image.fail_png(tostring(err))
      return false
    end
    state.linked = true
  end
  return true
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
    or (state.tmux and require("md-render.heading_tmux").status().key ~= state.connection)
  local display = require "md-render.display_utils"
  local overlays = display.floating_rects(state.win)
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
    local covered = display.covered_by_float(rect, overlays)
    for row = p.line, p.line + p.scale - 1 do
      if interacting[row] then covered = true end
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
      if entry.transparent or state.tmux then masks[entry] = true end
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
    local mask_col = state.tmux and entry.col - (vim.fn.getwininfo(state.win)[1].leftcol or 0)
    if entry.mask_ids and state.tmux and entry.mask_col ~= mask_col then clear_mask(state, entry) end
    if masks[entry] and not entry.mask_ids then
      -- Blank only the displayed glyphs: transparent PNGs must not expose a
      -- second copy of the text. Overlay text leaves buffer coordinates intact.
      entry.mask_ids = {}
      entry.mask_col = mask_col
      if state.tmux then
        local normal = vim.api.nvim_get_hl(0, { name = p.normal or "Normal", link = false })
        vim.api.nvim_set_hl(0, entry.hl, { fg = entry.id, bg = normal.bg, nocombine = true })
        -- The first cell encodes (row, 0) for each reserved row;
        -- Kitty infers following columns. paint() admits only full rectangles.
        for row = 1, p.scale do
          local text = placeholder_origin(row) .. string.rep(PLACEHOLDER, entry.cols - 1)
          local tail = row == 1 and math.max(0, vim.fn.strdisplaywidth(p.text) - entry.cols) or 0
          entry.mask_ids[row] = vim.api.nvim_buf_set_extmark(state.buf, state.mask_ns, p.line + row - 1, 0, {
            virt_text = { { text, entry.hl }, { string.rep(" ", tail), p.normal or "Normal" } },
            virt_text_win_col = mask_col,
            priority = vim.hl.priorities.user + 1,
          })
        end
      else
        entry.mask_ids[1] = vim.api.nvim_buf_set_extmark(state.buf, state.mask_ns, p.line, p.col, {
          virt_text = { { string.rep(" ", vim.fn.strdisplaywidth(p.text)), p.normal or "Normal" } },
          virt_text_pos = "overlay",
          priority = vim.hl.priorities.user + 1,
        })
      end
    elseif not masks[entry] and entry.mask_ids then
      clear_mask(state, entry)
    end
  end
  state.masked = next(masks) ~= nil
  -- Apply mask changes before the physical repaint; recompute visibility
  -- afterwards. :mode performs its own synchronized update.
  if clear_links(state) then return paint(state) end
  -- Finish raw cell writes before opening the synchronized graphics batch.
  if not paint_links(state, visible) then return end
  if not state.tmux then image.begin_sync_update() end
  erase(state, false, true)
  if not state.tmux then image.begin_batch() end
  for _, entry in ipairs(visible) do
    local p = entry.placement
    if not state.tmux then
      image.put_image(entry.id, state.win, p.line, entry.col, entry.cols, p.scale, nil, entry.width, entry.height)
    end
    entry.visible = true
  end
  if not state.tmux then
    image.end_sync_update()
    image.flush_batch()
  end
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
  local connection = vim.env.TMUX and require("md-render.heading_tmux").status()
  local cell = image.get_cell_size(true)
  if not cell or (connection and not connection.key) or (not connection and not image.supports_kitty()) then
    return nil
  end
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
    tmux = connection ~= nil,
    connection = connection and connection.key,
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
        hl = "MdRenderHeadingImage_" .. win .. "_" .. (#state.entries + 1),
      })
      local urls, linked = {}, false
      for column, byte in ipairs(entry.columns or {}) do
        urls[column] = ""
        for _, link in ipairs(content.link_metadata or {}) do
          if byte and link.line == p.line and p.col + byte >= link.col_start and p.col + byte < link.col_end then
            -- URLs enter a terminal control sequence here, not just an API.
            urls[column] = require("md-render.links").osc8_url(link.url)
            linked = true
            break
          end
        end
      end
      if linked then
        entry.links = {}
        for row = 1, p.scale do
          local runs, previous = {}, nil
          for column, url in ipairs(urls) do
            if url ~= previous then
              runs[#runs + 1] = "\x1b]8;;" .. url .. "\x1b\\"
              previous = url
            end
            runs[#runs + 1] = state.tmux and (column == 1 and placeholder_origin(row) or PLACEHOLDER) or " "
          end
          entry.links[row] = table.concat(runs) .. "\x1b]8;;\x1b\\"
        end
      end
      state.entries[#state.entries + 1] = entry
      local failure
      entry.id, failure = image.transmit_png(raster.data, function(err)
        if state.closed then return end
        if err then
          state.failed = true
          erase(state)
          image.fail_png(err)
        else
          entry.ready = true
          repaint(state)
        end
      end, entry.cols, p.scale)
      if not entry.id then
        state.failed = true
        image.fail_png(failure or "terminal PNG transmission is unavailable")
      end
    end
  end
  repaint(state)
  if state.tmux then
    vim.api.nvim_create_autocmd("User", {
      group = state.group,
      pattern = require("md-render.heading_tmux").EVENT,
      callback = function()
        erase(state)
        repaint(state)
      end,
    })
  end
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
  require("md-render.heading_mouse").attach(state, M.mouse_position, repaint, erase)
  return state
end

return M
