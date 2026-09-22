-- Optional Snacks transport: real buffer rows own image space and scrolling.
local M = {}
local image = require "md-render.image"
local async = require "md-render.async"
local permits = async.semaphore(2)

-- Keep Snacks' placement/transport lifecycle; Kitty cycles frames itself.
local function animate(img, frames)
  if img._md_render_animation then return end
  img._md_render_animation = true
  local on_send = img.on_send
  img.on_send = function(self)
    on_send(self)
    if self._md_render_upload then self._md_render_upload:close() end
    self._md_render_upload = async.run(function()
      local terminal = Snacks.image.terminal
      terminal.request { a = "a", i = self.id, r = 1, z = 200, s = 2, v = 1 }
      for idx = 2, #frames do
        if terminal.env().remote then
          local file = assert(io.open(frames[idx], "rb"))
          local data = vim.base64.encode(file:read "*a")
          file:close()
          for pos = 1, #data, 4096 do
            terminal.request {
              a = "f",
              i = self.id,
              t = "d",
              f = 100,
              z = 200,
              m = pos + 4096 <= #data and 1 or 0,
              data = data:sub(pos, pos + 4095),
            }
          end
        else
          terminal.request { a = "f", i = self.id, t = "f", f = 100, z = 200, data = vim.base64.encode(frames[idx]) }
        end
        if idx % 10 == 0 then async.sleep(10) end
      end
      terminal.request { a = "a", i = self.id, s = 3 }
    end)
    self._md_render_upload:detach()
  end
  if img.sent then img:on_send() end
end

function M.supported()
  if not (_G.Snacks and Snacks.image) then return false end
  -- Reattached tmux panes can lack KITTY_WINDOW_ID; ask the current client.
  -- Set Snacks' public override before its XTVERSION probe can time out.
  if vim.env.SNACKS_KITTY == nil then
    local kitty = vim.env.KITTY_WINDOW_ID ~= nil
    if vim.env.TMUX then
      local cmd = { "tmux", "display-message", "-p" }
      if vim.env.TMUX_PANE then vim.list_extend(cmd, { "-t", vim.env.TMUX_PANE }) end
      cmd[#cmd + 1] = "#{client_termname}"
      local result = vim.system(cmd, { text = true }):wait(1000)
      kitty = result.code == 0 and vim.trim(result.stdout or "") == "xterm-kitty"
    end
    if kitty then vim.env.SNACKS_KITTY = "1" end
  end
  return Snacks.image.terminal.env().placeholders == true
end

local function stop_timer(state)
  if not state.timer then return end
  state.timer:stop()
  if not state.timer:is_closing() then state.timer:close() end
  state.timer = nil
end

function M.cleanup(state)
  if not state or state.closed then return end
  state.closed = true
  stop_timer(state)
  for _, placement in pairs(state.objects) do
    placement:close()
  end
  pcall(vim.api.nvim_del_augroup_by_id, state.group)
end

function M.update(state, content)
  if state.closed then return state end
  state.content = content
  if not state.transport_ready then return state end
  state.revision = state.revision + 1
  local revision = state.revision
  state.placements = content.image_placements or {}
  -- Rebuilding replaces buffer rows even when the image coordinates stay the
  -- same. Recreate placements so Snacks cannot reuse displaced extmarks.
  for _, object in pairs(state.objects) do
    object:close()
  end
  state.objects = {}
  local function ready()
    stop_timer(state)
    state.timer = vim.defer_fn(function()
      state.timer = nil
      if state.closed or not vim.api.nvim_buf_is_valid(state.buf) then return end
      if state.opts.on_ready then
        state.opts.on_ready()
      elseif state.opts.build_content then
        local fresh = state.opts.build_content()
        local display = require "md-render.display_utils"
        local modifiable = vim.bo[state.buf].modifiable
        vim.bo[state.buf].modifiable = true
        vim.api.nvim_buf_clear_namespace(state.buf, state.ns, 0, -1)
        display.apply_content_to_buffer(state.buf, state.ns, fresh)
        vim.bo[state.buf].modifiable, vim.bo[state.buf].modified = modifiable, false
        M.update(state, fresh)
        if state.opts.on_content_applied then state.opts.on_content_applied(fresh) end
      else
        M.update(state, content)
      end
    end, 100)
  end
  for idx, p in ipairs(state.placements) do
    if p.path then
      local opts = {
        inline = true,
        conceal = true,
        pos = { p.line + 1, p.col },
        range = { p.line + 1, p.col, p.line + p.rows, p.col },
        width = p.cols,
        height = p.rows,
      }
      local function place(path, frames)
        local object = Snacks.image.placement.new(state.buf, path, opts)
        state.objects[idx] = object
        if frames and #frames > 1 then animate(object.img, frames) end
      end
      if p.animated or p.video or image.is_video_file(p.path) or image.is_animated_gif(p.path) then
        async.run(function()
          permits:with(function()
            if state.closed or revision ~= state.revision then return end
            local frames = async.await(2, image.extract_frames_async, p.path)
            if state.closed or revision ~= state.revision then return end
            place(frames and frames[1] or p.path, frames)
          end)
        end)
      else
        place(p.path)
      end
    else
      -- Shared producers outlive their callers. Keep the permit until their
      -- callback finishes; cancelled waiters would let new edits exceed the cap.
      async.run(function()
        permits:with(function()
          if state.closed or revision ~= state.revision then return end
          local path
          if p.mermaid_source then
            path = async.await(2, image.render_mermaid_async, p.mermaid_source)
          elseif p.plantuml_source then
            path = async.await(2, image.render_plantuml_async, p.plantuml_source)
          elseif p.src_url then
            path = async.await(2, image.download_async, p.src_url)
          end
          if state.closed or revision ~= state.revision then return end
          if path then
            p.path = path
            ready()
          else
            vim.api.nvim_buf_set_extmark(state.buf, state.ns, p.line, 0, {
              virt_text = { { "Image conversion failed; edit the source and retry", "ErrorMsg" } },
              virt_text_pos = "overlay",
            })
          end
        end)
      end)
    end
  end
  return state
end

function M.setup(win, content, ns, opts)
  assert(_G.Snacks and Snacks.image, "md-render: the snacks image backend requires Snacks.image")
  local state = {
    snacks = true,
    win = win,
    buf = vim.api.nvim_win_get_buf(win),
    ns = ns or vim.api.nvim_create_namespace "md_render_snacks",
    opts = opts or {},
    revision = 0,
    objects = {},
    group = vim.api.nvim_create_augroup("md_render_snacks_" .. win, { clear = true }),
  }
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = state.group,
    buffer = state.buf,
    callback = function()
      M.cleanup(state)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.group,
    pattern = tostring(win),
    callback = function()
      M.cleanup(state)
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
    group = state.group,
    buffer = state.buf,
    callback = function()
      vim.schedule(function()
        if state.closed then return end
        for _, placement in pairs(state.objects) do
          placement:show()
          placement:update()
        end
      end)
    end,
  })
  state.content = content
  Snacks.image.terminal.detect(function()
    if state.closed then return end
    if not Snacks.image.terminal.env().placeholders then
      vim.notify("md-render: the Snacks backend requires Kitty Unicode placeholders", vim.log.levels.ERROR)
      return
    end
    state.transport_ready = true
    M.update(state, state.content)
  end)
  return state
end

return M
