-- Focus one image in a Neovim tab; keep terminal placement owned by Snacks.
local M = {}
local image = require "md-render.image"

-- Source-pixel crop for the requested view. Zoom 1 is a complete overview.
function M.geometry(iw, ih, cols, rows, cell, zoom, cx, cy)
  local scale = math.min(cols * cell.cell_w / iw, rows * cell.cell_h / ih, 1) * zoom
  local w = math.max(1, math.min(iw, math.floor(cols * cell.cell_w / scale)))
  local h = math.max(1, math.min(ih, math.floor(rows * cell.cell_h / scale)))
  local x = math.max(0, math.min(iw - w, math.floor(cx * iw - w / 2)))
  local y = math.max(0, math.min(ih - h, math.floor(cy * ih - h / 2)))
  return {
    x = x,
    y = y,
    w = w,
    h = h,
    cols = math.min(cols, math.max(1, math.ceil(w * scale / cell.cell_w))),
    rows = math.min(rows, math.max(1, math.ceil(h * scale / cell.cell_h))),
    cx = (x + w / 2) / iw,
    cy = (y + h / 2) / ih,
  }
end

function M.open(path)
  if vim.fn.executable "magick" ~= 1 then
    vim.notify("md-render: image zoom requires ImageMagick (magick)", vim.log.levels.ERROR)
    return
  end
  local origin_win, origin_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local origin_view = vim.fn.winsaveview()
  vim.cmd "tabnew"
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local state = { zoom = 1, x = 0.5, y = 0.5, serial = 0, win = win, buf = buf }
  vim.b[buf].md_render_image_view = true
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  vim.bo[buf].filetype = "md-render-image"
  vim.wo[win].wrap, vim.wo[win].number, vim.wo[win].relativenumber = false, false, false
  vim.wo[win].signcolumn, vim.wo[win].foldcolumn = "no", "0"
  vim.wo[win].conceallevel, vim.wo[win].scrolloff = 2, 0
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local group = vim.api.nvim_create_augroup("md_render_image_view_" .. buf, { clear = true })

  -- Track the latest reading position, including scrolling without moving the
  -- cursor. WinClosed runs after Neovim has already selected a fallback window,
  -- but before WinEnter, so remember whether the viewer was active there.
  local viewer_active = true
  vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
    group = group,
    callback = function(event)
      local current = vim.api.nvim_get_current_win()
      if event.event == "WinEnter" then
        viewer_active = current == win
      elseif current == origin_win and vim.api.nvim_win_get_buf(current) == origin_buf then
        origin_view = vim.fn.winsaveview()
      end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    callback = function()
      if not viewer_active then return end
      -- Finish the tab layout change before returning; background closes must
      -- leave the reader's current window alone.
      vim.schedule(function()
        if not vim.api.nvim_win_is_valid(origin_win) or vim.api.nvim_win_get_buf(origin_win) ~= origin_buf then
          return
        end
        vim.api.nvim_set_current_win(origin_win)
        local cursor = vim.api.nvim_win_get_cursor(origin_win)
        if cursor[1] ~= origin_view.lnum or cursor[2] ~= origin_view.col then return end
        vim.fn.winrestview(origin_view)
      end)
    end,
  })

  local function valid()
    return not state.closed and vim.api.nvim_win_is_valid(win) and vim.api.nvim_buf_is_valid(buf)
  end
  local function cleanup()
    if state.closed then return end
    state.closed = true
    if state.job then state.job:kill(15) end
    if state.pending then state.pending:close() end
    if state.placement then state.placement:close() end
    vim.fn.delete(dir, "rf")
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
  vim.api.nvim_create_autocmd("BufWipeout", { group = group, buffer = buf, callback = cleanup })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = cleanup })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = group,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        if not valid() then return end
        for _, placement in pairs { state.placement, state.pending } do
          placement:show()
          placement:update()
        end
      end)
    end,
  })

  local function paint()
    if not valid() or not state.path then return end
    state.serial = state.serial + 1
    local serial = state.serial
    if state.job then state.job:kill(15) end
    if state.pending then
      state.pending:close()
      state.pending = nil
      vim.fn.delete(state.pending_file)
      state.pending_file = nil
    end
    local cols = math.max(1, vim.api.nvim_win_get_width(win) - 2)
    local rows = math.max(1, vim.api.nvim_win_get_height(win) - 2)
    local cell = image.get_cell_size()
    if not cell then return end
    local g = M.geometry(state.iw, state.ih, cols, rows, cell, state.zoom, state.x, state.y)
    state.x, state.y, state.crop = g.cx, g.cy, g
    local file = dir .. "/" .. serial .. ".png"
    local started = vim.uv.hrtime()
    -- ponytail: crop the cached PNG per input; profile before adding a custom GPU/placeholder renderer.
    state.job = vim.system(
      { "magick", state.path, "-crop", ("%dx%d+%d+%d"):format(g.w, g.h, g.x, g.y), "+repage", file },
      { text = true },
      vim.schedule_wrap(function(result)
        if not valid() or serial ~= state.serial then return end
        state.job = nil
        if result.code ~= 0 then
          vim.notify("md-render: image crop failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
          return
        end
        local col = math.floor((cols + 2 - g.cols) / 2)
        local lines = {
          ("  %.0f%%  +/- zoom · hjkl zH/zL ^F/^B/^D/^U pan · gg/G 0/$ edges · f fit · q back"):format(
            state.zoom * 100
          ),
        }
        for _ = 1, rows do
          lines[#lines + 1] = string.rep(" ", cols + 2)
        end
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.bo[buf].modifiable = false
        state.pending_file = file
        state.pending = Snacks.image.placement.new(buf, file, {
          inline = true,
          conceal = true,
          pos = { 2, col },
          range = { 2, col, g.rows + 1, col },
          width = g.cols,
          height = g.rows,
          on_update = function(p)
            if not valid() or (serial ~= state.serial and p ~= state.placement) then
              p:close()
              return
            end
            -- Snacks fits to natural size. The focused view explicitly allows upscaling.
            Snacks.image.terminal.request { a = "p", U = 1, i = p.img.id, p = p.id, C = 1, c = g.cols, r = g.rows }
            p:render_grid { 2, col, width = g.cols, height = g.rows }
            if state.placement ~= p then
              if state.placement then state.placement:close() end
              if state.file then vim.fn.delete(state.file) end
              state.placement, state.file = p, file
              state.pending, state.pending_file = nil, nil
            end
            state.elapsed_ms = (vim.uv.hrtime() - started) / 1e6
          end,
        })
        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        vim.api.nvim_win_call(win, function()
          vim.fn.winrestview { topline = 1, leftcol = 0 }
        end)
      end)
    )
  end
  local function zoom(factor)
    state.zoom = math.max(1, math.min(16, state.zoom * factor))
    paint()
  end
  local function pan(dx, dy)
    if not state.crop then return end
    state.x = state.x + dx * state.crop.w / state.iw
    state.y = state.y + dy * state.crop.h / state.ih
    paint()
  end
  local function page(direction)
    if not state.crop then return end
    -- Keep two screen rows of overlap, with at least one row of progress.
    pan(0, direction * math.max(1, state.crop.rows - 2) / state.crop.rows)
  end
  local function edge(x, y)
    if not state.crop then return end
    state.x, state.y = x or state.x, y or state.y
    paint()
  end
  local keys = {
    ["+"] = function()
      zoom(1.25)
    end,
    ["="] = function()
      zoom(1.25)
    end,
    ["-"] = function()
      zoom(1 / 1.25)
    end,
    f = function()
      state.zoom, state.x, state.y = 1, 0.5, 0.5
      paint()
    end,
    h = function()
      pan(-1 / 8, 0)
    end,
    l = function()
      pan(1 / 8, 0)
    end,
    k = function()
      pan(0, -1 / 8)
    end,
    j = function()
      pan(0, 1 / 8)
    end,
    zH = function()
      pan(-1 / 2, 0)
    end,
    zL = function()
      pan(1 / 2, 0)
    end,
    ["<C-d>"] = function()
      pan(0, 1 / 2)
    end,
    ["<C-u>"] = function()
      pan(0, -1 / 2)
    end,
    ["<C-f>"] = function()
      page(1)
    end,
    ["<C-b>"] = function()
      page(-1)
    end,
    gg = function()
      edge(nil, 0)
    end,
    G = function()
      edge(nil, 1)
    end,
    ["0"] = function()
      edge(0, nil)
    end,
    ["$"] = function()
      edge(1, nil)
    end,
    q = function()
      vim.api.nvim_win_close(win, true)
    end,
  }
  keys["^"] = keys["0"]
  keys["<Esc>"], keys["<Left>"], keys["<Right>"], keys["<Up>"], keys["<Down>"] = keys.q, keys.h, keys.l, keys.k, keys.j
  for key, action in pairs(keys) do
    vim.keymap.set("n", key, action, { buffer = buf, silent = true })
  end
  vim.api.nvim_create_autocmd("WinResized", { group = group, callback = paint })
  require("md-render.async").run(function()
    local png = require("md-render.async").await(2, image.ensure_png_async, path)
    if not valid() then return end
    local iw, ih
    if png then
      iw, ih = image.image_dimensions(png)
    end
    if not iw or not ih then
      vim.notify("md-render: unable to load image", vim.log.levels.ERROR)
      return
    end
    state.path, state.iw, state.ih = png, iw, ih
    paint()
  end)
  return state
end

return M
