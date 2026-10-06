-- Optional Snacks transport: real buffer rows own image space and scrolling.
local M = {}
local image = require "md-render.image"
local async = require "md-render.async"
local permits = async.semaphore(2)

-- Keep Snacks' placement/transport lifecycle; Kitty cycles frames itself.
function M.animate(img, frames, playing)
  local owns_placements = playing == nil
  playing = playing or function()
    return image.config().autoplay ~= false
  end
  if img._md_render_animation then
    if img._md_render_stopped and img._md_render_frames_ready then
      img._md_render_stopped = false
      Snacks.image.terminal.request { a = "a", i = img.id, s = playing() and 3 or 1 }
    end
    return
  end
  img._md_render_animation = true
  local function has_owners(self)
    for _, placement in pairs(self.placements) do
      if not placement.closed then return true end
    end
    return false
  end
  local function retire(self)
    if self._md_render_upload then self._md_render_upload:close() end
    if self._md_render_frames_ready then
      Snacks.image.terminal.request { a = "a", i = self.id, s = 1 }
    else
      -- Appending a complete upload to partially retained frames duplicates
      -- them. Let the next owner resend the base image and all frames instead.
      Snacks.image.terminal.request { a = "d", d = "I", i = self.id }
      self.sent = false
    end
    self._md_render_stopped = true
  end
  if owns_placements then
    local del, place = img.del, img.place
    img.del = function(self, ...)
      del(self, ...)
      if not has_owners(self) then retire(self) end
    end
    img.place = function(self, ...)
      place(self, ...)
      if self._md_render_stopped and self._md_render_frames_ready and self.sent then
        self._md_render_stopped = false
        Snacks.image.terminal.request { a = "a", i = self.id, s = playing() and 3 or 1 }
      end
    end
  end
  local on_send = img.on_send
  img.on_send = function(self)
    on_send(self)
    if self._md_render_upload then self._md_render_upload:close() end
    self._md_render_frames_ready = false
    if owns_placements and not has_owners(self) then
      retire(self)
      return
    end
    self._md_render_stopped = false
    self._md_render_upload = async.run(function()
      local terminal = Snacks.image.terminal
      terminal.request { a = "a", i = self.id, r = 1, z = 200, s = playing() and 2 or 1, v = 1 }
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
      self._md_render_frames_ready = true
      terminal.request { a = "a", i = self.id, s = playing() and 3 or 1 }
    end)
    self._md_render_upload:detach()
  end
  if img.sent then img:on_send() end
end

-- Snacks interprets $variables and #page= before opening local sources. Its
-- public constructors have no literal-path option, so isolate those names in
-- per-process aliases; keep the document's original path for navigation.
local aliases, alias_dir = {}, nil
local function literal_source(path)
  if not path:find("$", 1, true) and not path:find("#page=", 1, true) then return path end
  local stat = vim.uv.fs_stat(path)
  if not stat then return nil end
  local key = vim.fn.sha256(table.concat({
    path,
    stat.ino,
    stat.size,
    stat.mtime.sec,
    stat.mtime.nsec,
    stat.ctime.sec,
    stat.ctime.nsec,
  }, ":"))
  if aliases[key] and vim.uv.fs_stat(aliases[key]) then return aliases[key] end
  if not alias_dir then
    local dir = vim.fn.tempname()
    if dir:find("$", 1, true) or dir:find("#page=", 1, true) then return nil end
    vim.fn.mkdir(dir, "p")
    alias_dir = dir
    vim.api.nvim_create_autocmd("VimLeavePre", {
      once = true,
      callback = function()
        vim.fn.delete(dir, "rf")
      end,
    })
  end
  local alias = alias_dir .. "/" .. key .. "." .. (path:match "%.([%w]+)$" or "img")
  if not vim.uv.fs_symlink(path, alias) and not vim.uv.fs_copyfile(path, alias) then return nil end
  aliases[key] = alias
  return alias
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
  if not vim.api.nvim_win_is_valid(state.win) or vim.api.nvim_win_get_buf(state.win) ~= state.buf then
    M.cleanup(state)
    return state
  end
  state.content = content
  if not state.transport_ready then return state end
  state.revision = state.revision + 1
  local revision = state.revision
  local function current()
    return not state.closed
      and revision == state.revision
      and vim.api.nvim_buf_is_valid(state.buf)
      and vim.api.nvim_win_is_valid(state.win)
      and vim.api.nvim_win_get_buf(state.win) == state.buf
  end
  stop_timer(state)
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
      if not current() then return end
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
        local source = literal_source(path)
        if not source then
          require("md-render.display_utils").show_image_error(state.buf, state.ns, p)
          vim.notify_once("md-render: image source could not be prepared; check the file path", vim.log.levels.WARN)
          return
        end
        local object = Snacks.image.placement.new(state.buf, source, opts)
        state.objects[idx] = object
        local original_error, reported = object.error, false
        object.error = function(self)
          if not current() or self.closed or state.objects[idx] ~= self or reported then return end
          reported = true
          original_error(self)
          require("md-render.display_utils").show_image_error(state.buf, state.ns, p)
          local reason = self.img._convert and self.img._convert:error() or "image conversion failed"
          if vim.fn.executable "magick" ~= 1 and vim.fn.executable "identify" ~= 1 then
            reason = "install ImageMagick 7 (magick) on Neovim's PATH"
          end
          reason = vim.fn.strcharpart(tostring(reason):gsub("%c", " "), 0, 240)
          vim.notify_once(
            "md-render: Snacks image conversion failed: "
              .. reason
              .. "; run :checkhealth md-render and :checkhealth snacks",
            vim.log.levels.WARN
          )
        end
        -- Cached failures can call error() inside the constructor, before this hook exists.
        if object.img:failed() then
          object:error()
          return
        end
        if frames and #frames > 1 then
          if image.config().autoplay ~= false then
            M.animate(object.img, frames)
          elseif object.img._md_render_animation then
            Snacks.image.terminal.request { a = "a", i = object.img.id, s = 1, c = 1 }
            object.img._md_render_stopped = true
          end
        end
      end
      if p.animated or p.video or image.is_video_file(p.path) or image.is_animated_gif(p.path) then
        async.run(function()
          permits:with(function()
            if not current() then return end
            if not p.img_w and (p.video or image.is_video_file(p.path)) then
              local width, height = async.await(2, image.video_dimensions_async, p.path)
              if not current() then return end
              if width and height then
                p.img_w, p.img_h = width, height
                ready()
              end
            end
            local frames = async.await(2, image.extract_frames_async, p.path)
            if not current() then return end
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
          if not current() then return end
          local path
          if p.mermaid_source then
            path = async.await(2, image.render_mermaid_async, p.mermaid_source)
          elseif p.plantuml_source then
            path = async.await(2, image.render_plantuml_async, p.plantuml_source)
          elseif p.src_url then
            path = async.await(2, image.download_async, p.src_url)
          end
          if not current() then return end
          if path then
            p.path = path
            ready()
          else
            require("md-render.display_utils").show_image_error(state.buf, state.ns, p)
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
