-- Focus one image in a Neovim tab, anchored by Snacks.
local M = {}
local image = require "md-render.image"
local async = require "md-render.async"

-- Source-pixel crop for the requested view. Zoom 1 is a complete overview.
function M.geometry(iw, ih, cols, rows, cell, zoom, cx, cy)
  local scale = math.min(cols * cell.cell_w / iw, rows * cell.cell_h / ih, 1) * zoom
  local w = math.max(1, math.min(iw, math.floor(cols * cell.cell_w / scale)))
  local h = math.max(1, math.min(ih, math.floor(rows * cell.cell_h / scale)))
  -- A center reconstructed from a pixel crop can land one floating-point step below its origin.
  local epsilon = 2 ^ -52
  local x = math.max(0, math.min(iw - w, math.floor((cx + epsilon) * iw - w / 2)))
  local y = math.max(0, math.min(ih - h, math.floor((cy + epsilon) * ih - h / 2)))
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

---@param path string
---@param name? string caption of the selected occurrence
function M.open(path, name)
  if vim.fn.executable "magick" ~= 1 then
    vim.notify(
      "md-render: image zoom requires ImageMagick 7 (magick) on Neovim's PATH; run :checkhealth md-render",
      vim.log.levels.ERROR
    )
    return
  end
  local state = require("md-render.image_view_tab").open()
  local win, buf, group, valid = state.win, state.buf, state.group, state.valid
  state.zoom, state.x, state.y, state.serial = 1, 0.5, 0.5, 0
  state.playing = image.config().autoplay ~= false
  local caption = image.display_name(path, name)
  local detail
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local mouse_ns = vim.api.nvim_create_namespace("md_render_image_mouse_" .. buf)
  local drag
  state.on_leave = function()
    drag = nil
  end
  state.on_close = function()
    vim.on_key(nil, mouse_ns)
    if state.job then state.job:kill(9) end
    local media = state.media
    if media and media._md_render_upload then media._md_render_upload:close() end
    if state.pending then state.pending:close() end
    if state.placement then state.placement:close() end
    if media then Snacks.image.terminal.request { a = "d", d = "I", i = media.id } end
    vim.fn.delete(dir, "rf")
  end
  local function playing()
    return valid() and state.playing and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
  end
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
        if state.media and state.media.sent then
          Snacks.image.terminal.request { a = "a", i = state.media.id, s = playing() and 3 or 1 }
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("TabLeave", {
    group = group,
    callback = function()
      if valid() and state.media and state.media.sent then
        Snacks.image.terminal.request { a = "a", i = state.media.id, s = 1 }
      end
    end,
  })

  local function header(zoom_level)
    local playback = state.frames and (state.playing and "Space pause · " or "Space play · ") or ""
    local fit_key = zoom_level == 1 and detail and "F restore" or "f fit"
    return ("  Enter/q: back · %.0f%% · %shjkl · +/- · %s · ? help"):format(zoom_level * 100, playback, fit_key)
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { header(state.zoom) })
  vim.bo[buf].modifiable = false
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
      if not valid() or serial ~= state.serial then
        if not state.frames then os.remove(file) end
        return
      end
      state.job = nil
      if result.code ~= 0 or (not state.frames and not image.image_dimensions(file)) then
        if not state.frames then os.remove(file) end
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
      lines[#lines + 1] = caption
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
      local ok, job = pcall(async.start_system, {
        "magick",
        state.path,
        "-crop",
        ("%dx%d+%d+%d"):format(g.w, g.h, g.x, g.y),
        "+repage",
        "-delete",
        "1--1",
        file,
      }, { text = true, timeout = 5000 }, vim.schedule_wrap(show))
      if ok then
        state.job = job
      else
        show { code = -1, stderr = tostring(job) }
      end
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
    F = function()
      if not detail then return end
      state.zoom, state.x, state.y = detail.zoom, detail.x, detail.y
      paint()
    end,
    f = function()
      if state.crop and state.zoom > 1 then detail = { zoom = state.zoom, x = state.x, y = state.y } end
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
    ["?"] = function()
      vim.cmd.help "md-render-image-view"
    end,
  }
  for alias, key in pairs {
    ["="] = "+",
    ["<kPlus>"] = "+",
    ["<kMinus>"] = "-",
    ["^"] = "0",
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
  async.run(function()
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
      require("md-render.snacks_image").animate(state.media, frames, playing)
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
