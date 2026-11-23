-- A fitted tab for an image already displayed by the direct Kitty backend.
local M = {}
local image = require "md-render.image"
local display = require "md-render.display_utils"

function M.path(state, placement)
  local path = placement.path
  local source = state and not state.closed and state.ready_images and state.ready_images[path]
  if not source or vim.env.TMUX then return end
  local anim = source.animation
  if anim then
    if #anim.frame_ids < 2 or not anim.frame_files or not anim.frame_w or not anim.frame_h then return end
    -- Native frame uploads ask Kitty to read local files by path.
    if vim.env.SSH_TTY or vim.env.SSH_CONNECTION or vim.fn.filereadable(path) ~= 1 then return end
  elseif not source.png_revision or image.file_revision(path) ~= source.png_revision then
    return
  end
  if require("md-render.tty").kitty_version() then return path, source end
end

function M.open(path, source)
  source = source or { png_revision = image.file_revision(path) }
  local anim = source.animation
  local iw, ih
  if anim then
    iw, ih = anim.frame_w, anim.frame_h
  else
    iw, ih = image.image_dimensions(path)
  end
  if not iw or not ih or iw < 1 or ih < 1 then return end
  local tab = require "md-render.image_view_tab"
  local view = tab.open()
  local win, buf = view.win, view.buf
  local width, height
  local playback = anim and { playing = image.config().autoplay ~= false, frame_files = anim.frame_files }
  local back = tab.back_padding .. (playback and "  Enter/q: back" or "  Enter / q / Esc: back")
  local status
  local status_ns = vim.api.nvim_create_namespace ""
  vim.api.nvim__ns_set(status_ns, { wins = { win } })
  local function update_status()
    if not view.valid() then return end
    local hint
    if status == nil then
      hint = "Loading…"
    elseif not status then
      hint = playback and "Could not load animation" or "Could not load image"
    elseif playback then
      hint = playback.playing and "Space pause" or "Space play"
    end
    vim.api.nvim_buf_set_extmark(buf, status_ns, 0, 0, {
      id = 1,
      virt_text = hint and { { " · " .. hint } } or {},
    })
  end
  local opts = {
    playback = playback,
    png_revision = source.png_revision,
    on_view_ready = function(ready)
      status = ready
      update_status()
    end,
  }
  if playback then
    vim.keymap.set("n", "<Space>", function()
      if not status or view.closed or vim.api.nvim_get_current_win() ~= win then return end
      playback.playing = not playback.playing
      view.images.start_anim_timer()
      update_status()
    end, { buffer = buf, silent = true, desc = "Play or pause this animation" })
  end
  view.on_close = function()
    display.cleanup_images(view.images)
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, status_ns, 0, -1) end
  end
  local function layout()
    if not view.valid() or vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then return end
    local info = vim.fn.getwininfo(win)[1]
    local cols = math.max(1, info.width - info.textoff)
    if cols == width and info.height == height then return end
    width, height = cols, info.height
    local lines = vim.fn["repeat"]({ "" }, height)
    lines[1] = back
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
    update_status()

    local placements = {}
    if height > 1 or playback then
      local w, h = image.calc_display_size(iw, ih, width, math.max(1, height - 1), true)
      -- Keep an in-flight upload and its IDs when only the viewer geometry changes.
      local p = playback and view.images and view.images.placements[1] or { path = path, img_w = iw, img_h = ih }
      p.cols, p.rows = w, h
      p.col, p.line = math.floor((width - w) / 2), 1 + math.max(0, math.floor((height - 1 - h) / 2))
      if playback and view.images then
        view.images.schedule_redraw()
        return
      end
      placements[1] = p
    end
    view.images = display.update_images(view.images, win, { image_placements = placements }, nil, opts)
  end
  vim.api.nvim_create_autocmd({ "WinResized", "TabEnter" }, { group = view.group, callback = layout })
  layout()
  return view
end

return M
