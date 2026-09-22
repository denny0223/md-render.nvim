-- Focus one image in a Neovim tab, anchored by Snacks.
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
  local state = { zoom = 1, x = 0.5, y = 0.5, serial = 0, win = win, buf = buf, playing = true }
  local drag
  vim.b[buf].md_render_image_view = true
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  vim.bo[buf].filetype = "md-render-image"
  vim.wo[win].wrap, vim.wo[win].number, vim.wo[win].relativenumber = false, false, false
  vim.wo[win].signcolumn, vim.wo[win].foldcolumn = "no", "0"
  vim.wo[win].conceallevel, vim.wo[win].scrolloff = 2, 0
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local group = vim.api.nvim_create_augroup("md_render_image_view_" .. buf, { clear = true })
  local mouse_ns = vim.api.nvim_create_namespace("md_render_image_mouse_" .. buf)

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
      elseif current == win then
        drag = nil
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
    vim.on_key(nil, mouse_ns)
    if state.job then state.job:kill(15) end
    local media = state.media
    if media and media._md_render_upload then media._md_render_upload:close() end
    if state.pending then state.pending:close() end
    if state.placement then state.placement:close() end
    if media then Snacks.image.terminal.request { a = "d", d = "I", i = media.id } end
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

  local function header(zoom_level)
    local playback = state.frames and (state.playing and "Space pause · " or "Space play · ") or ""
    return ("  %.0f%% · %shjkl · +/- · f fit · ? help · q back"):format(zoom_level * 100, playback)
  end
  local function paint()
    if not valid() or not state.path then return end
    local cols = math.max(1, vim.api.nvim_win_get_width(win) - 2)
    local rows = math.max(1, vim.api.nvim_win_get_height(win) - 2)
    local cell = image.get_cell_size()
    if not cell then return end
    local g = M.geometry(state.iw, state.ih, cols, rows, cell, state.zoom, state.x, state.y)
    state.x, state.y, state.crop = g.cx, g.cy, g
    -- Finish the current frame during input bursts, then draw the latest view.
    if state.job or state.pending then
      state.dirty = true
      return
    end
    state.dirty = false
    state.serial = state.serial + 1
    local serial, zoom_level = state.serial, state.zoom
    local file = state.frames and state.path or dir .. "/" .. serial .. ".png"
    local started = vim.uv.hrtime()
    local function show(result)
      if not valid() or serial ~= state.serial then return end
      state.job = nil
      if result.code ~= 0 then
        vim.notify("md-render: image crop failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
        if state.dirty then paint() end
        return
      end
      local col = math.floor((cols + 2 - g.cols) / 2)
      local lines = {
        header(zoom_level),
      }
      for _ = 1, rows do
        lines[#lines + 1] = string.rep(" ", cols + 2)
      end
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
      local opts = {
        inline = true,
        conceal = true,
        pos = { 2, col },
        range = state.media and { 2, col, 2, col + 1 } or { 2, col, g.rows + 1, col },
        width = state.media and 1 or g.cols,
        height = state.media and 1 or g.rows,
        on_update = function(p)
          if not valid() or (serial ~= state.serial and p ~= state.placement) then
            p:close()
            return
          end
          -- Snacks fits to natural size. The focused view explicitly allows upscaling.
          Snacks.image.terminal.request {
            a = "p",
            U = 1,
            i = p.img.id,
            p = p.id,
            C = 1,
            c = state.media and 1 or g.cols,
            r = state.media and 1 or g.rows,
          }
          p:render_grid { 2, col, width = state.media and 1 or g.cols, height = state.media and 1 or g.rows }
          if state.media and state.media.sent then
            -- Virtual placements ignore source crops. Anchor the cropped media
            -- to a transparent cell so it follows Snacks across tabs/tmux.
            local fit_width = g.cols * cell.cell_w / g.w <= g.rows * cell.cell_h / g.h
            Snacks.image.terminal.request {
              a = "p",
              i = state.media.id,
              p = 1,
              P = p.img.id,
              Q = p.id,
              C = 1,
              c = fit_width and g.cols or 0,
              r = fit_width and 0 or g.rows,
              x = g.x,
              y = g.y,
              w = g.w,
              h = g.h,
            }
          end
          if state.placement ~= p then
            if state.placement then state.placement:close() end
            if state.file and state.file ~= file then vim.fn.delete(state.file) end
            state.placement, state.file = p, file
            state.pending, state.pending_file = nil, nil
          end
          state.elapsed_ms = (vim.uv.hrtime() - started) / 1e6
          if state.dirty then vim.schedule(function()
            if state.dirty then paint() end
          end) end
        end,
      }
      if state.frames and state.placement then
        -- Replacing the anchor would also delete its attached animation.
        state.placement.opts = opts
        opts.on_update(state.placement)
      else
        state.pending_file = file
        state.pending = Snacks.image.placement.new(buf, file, opts)
      end
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview { topline = 1, leftcol = 0 }
      end)
    end
    if state.frames then
      show { code = 0 }
    else
      -- ponytail: crop cached PNGs; profile before changing the static-image renderer.
      state.job = vim.system(
        { "magick", state.path, "-crop", ("%dx%d+%d+%d"):format(g.w, g.h, g.x, g.y), "+repage", file },
        { text = true },
        vim.schedule_wrap(show)
      )
    end
  end
  local function zoom(factor)
    state.zoom = math.max(1, math.min(16, state.zoom * factor))
    paint()
  end
  local function pan(dx, dy, count)
    if not state.crop then return end
    count = count or vim.v.count1
    state.x = state.x + dx * count * state.crop.w / state.iw
    state.y = state.y + dy * count * state.crop.h / state.ih
    paint()
  end
  local function scroll(dx, dy, count)
    if not state.crop then return end
    pan(dx / state.crop.cols, dy / state.crop.rows, count)
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
    ["<Space>"] = function()
      if not state.frames then return end
      state.playing = not state.playing
      if state.media and state.media.sent then
        Snacks.image.terminal.request { a = "a", i = state.media.id, s = state.playing and 3 or 1 }
      end
      vim.bo[buf].modifiable = true
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, { header(state.zoom) })
      vim.bo[buf].modifiable = false
    end,
    ["+"] = function()
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
    ["<C-e>"] = function()
      scroll(0, 1)
    end,
    ["<C-y>"] = function()
      scroll(0, -1)
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
    ["?"] = function()
      vim.cmd.help "md-render-image-view"
    end,
  }
  for alias, key in pairs {
    ["="] = "+",
    ["<kPlus>"] = "+",
    ["<kMinus>"] = "-",
    ["^"] = "0",
    ["<Esc>"] = "q",
    ["<Left>"] = "h",
    ["<Right>"] = "l",
    ["<Up>"] = "k",
    ["<Down>"] = "j",
    ["<PageUp>"] = "<C-b>",
    ["<PageDown>"] = "<C-f>",
    ["<kPageUp>"] = "<C-b>",
    ["<kPageDown>"] = "<C-f>",
    ["<Home>"] = "0",
    ["<End>"] = "$",
    ["<kHome>"] = "0",
    ["<kEnd>"] = "$",
    ["<C-Home>"] = "gg",
    ["<C-End>"] = "G",
  } do
    keys[alias] = keys[key]
  end
  for key, action in pairs(keys) do
    vim.keymap.set("n", key, action, { buffer = buf, silent = true })
  end
  local mouse_actions = {
    ["<ScrollWheelUp>"] = "zoom_in",
    ["<ScrollWheelDown>"] = "zoom_out",
    ["<ScrollWheelLeft>"] = "ignore",
    ["<ScrollWheelRight>"] = "ignore",
    ["<LeftMouse>"] = "press",
    ["<LeftDrag>"] = "drag",
    ["<LeftRelease>"] = "release",
  }
  -- Follow the pointer for zoom, and capture drags until release, even outside
  -- the image window. Repeated clicks must not select the placeholder text.
  vim.on_key(function(key)
    local action = mouse_actions[vim.fn.keytrans(key):gsub("^<[234]%-", "<")]
    if not action then return end
    if vim.o.mouse == "" then
      drag = nil
      return
    end
    local mouse = vim.fn.getmousepos()
    if action == "press" then drag = nil end
    if action == "release" and drag then
      drag = nil
      return ""
    end
    if action == "drag" and drag then
      local previous = drag
      drag = mouse
      scroll(previous.screencol - mouse.screencol, previous.screenrow - mouse.screenrow, 1)
      return ""
    end
    if mouse.winid ~= win or mouse.line == 0 then return end
    if action == "zoom_in" then
      zoom(1.25)
    elseif action == "zoom_out" then
      zoom(1 / 1.25)
    elseif action == "press" then
      if state.crop then
        vim.api.nvim_set_current_win(win)
        drag = mouse
      end
    elseif action ~= "ignore" then
      return
    end
    return ""
  end, mouse_ns)
  vim.api.nvim_create_autocmd("WinResized", { group = group, callback = paint })
  require("md-render.async").run(function()
    local async = require "md-render.async"
    local frames
    if image.is_video_file(path) or image.is_video_content(path) or image.is_animated_gif(path) then
      frames = async.await(2, image.extract_frames_async, path)
    end
    if not valid() then return end
    local png = frames and frames[1] or async.await(2, image.ensure_png_async, path)
    if not valid() then return end
    local iw, ih
    if png then
      iw, ih = image.image_dimensions(png)
    end
    if not iw or not ih then
      vim.notify("md-render: unable to load image", vim.log.levels.ERROR)
      return
    end
    if frames and #frames > 1 then
      -- Private media keeps playback independent of inline previews. A separate
      -- transparent anchor avoids showing uncropped pixels behind transparent GIFs.
      local file = dir .. "/media.png"
      assert(vim.uv.fs_copyfile(png, file))
      state.frames, state.media = frames, Snacks.image.image.new(file)
      require("md-render.snacks_image").animate(state.media, frames, function()
        return state.playing
      end)
      local on_send = state.media.on_send
      state.media.on_send = function(self)
        if state.closed then
          Snacks.image.terminal.request { a = "d", d = "I", i = self.id }
          return
        end
        on_send(self)
        if state.placement then state.placement.opts.on_update(state.placement) end
      end
      png = dir .. "/anchor.png"
      local anchor = assert(io.open(png, "wb"))
      anchor:write(
        vim.base64.decode "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABpfZFQAAAAABJRU5ErkJggg=="
      )
      anchor:close()
    end
    state.path, state.iw, state.ih = png, iw, ih
    paint()
  end)
  return state
end

return M
