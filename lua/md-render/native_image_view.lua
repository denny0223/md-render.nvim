-- A fitted tab for PNGs already displayed by the direct Kitty backend.
local M = {}
local image = require "md-render.image"
local display = require "md-render.display_utils"

function M.path(state, placement)
  local path = placement.path
  local source = state and not state.closed and state.ready_images and state.ready_images[path]
  if not source or vim.env.TMUX or not source.png_revision or source.png_revision ~= image.file_revision(path) then
    return
  end
  if require("md-render.tty").kitty_version() then return path, source end
end

function M.open(path, source)
  source = source or { png_revision = image.file_revision(path) }
  local iw, ih = image.image_dimensions(path)
  if not iw or not ih or iw < 1 or ih < 1 then return end
  local view = require("md-render.image_view_tab").open()
  local win, buf = view.win, view.buf
  local width, height
  local status
  local status_ns = vim.api.nvim_create_namespace ""
  vim.api.nvim__ns_set(status_ns, { wins = { win } })
  local function update_status()
    if not view.valid() then return end
    local hint
    if status == nil then
      hint = "Loading…"
    elseif not status then
      hint = "Could not load image"
    end
    vim.api.nvim_buf_set_extmark(buf, status_ns, 0, 0, {
      id = 1,
      virt_text = hint and { { " · " .. hint } } or {},
    })
  end
  local opts = {
    png_revision = source.png_revision,
    on_view_ready = function(ready)
      status = ready
      update_status()
    end,
  }
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
    lines[1] = "  Enter / q / Esc: back"
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
    update_status()

    local placements = {}
    if height > 1 then
      local w, h = image.calc_display_size(iw, ih, width, height - 1, true)
      placements[1] = {
        path = path,
        img_w = iw,
        img_h = ih,
        cols = w,
        rows = h,
        col = math.floor((width - w) / 2),
        line = 1 + math.floor((height - 1 - h) / 2),
      }
    end
    view.images = display.update_images(view.images, win, { image_placements = placements }, nil, opts)
  end
  vim.api.nvim_create_autocmd({ "WinResized", "TabEnter" }, { group = view.group, callback = layout })
  layout()
  return view
end

return M
