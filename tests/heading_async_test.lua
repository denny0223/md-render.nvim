-- Delayed image layout must not change an operation's underlying text.
local child = vim.fn.jobstart(
  { vim.v.progpath, "--embed", "--headless", "-n", "-u", "NONE", "--noplugin", "-i", "NONE" },
  { rpc = true }
)
local function lua(code, ...)
  return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
end
local function wait_for(code)
  assert(
    vim.wait(2000, function()
      return lua(code)
    end, 5),
    code
  )
end
local function input(keys)
  vim.rpcrequest(child, "nvim_input", keys)
end
local phase
local ok, err = pcall(function()
  lua [[
    package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
    vim.o.termguicolors = true
    vim.o.lines, vim.o.columns = 40, 120
    vim.api.nvim_ui_send = function() end
    local image = require "md-render.image"
    image.supports_kitty = function() return true end
    image.get_cell_size = function() return { cell_w = 19, cell_h = 44 } end
    image.transmit_png = function() return 1 end
    image.put_image = function() end
    image.delete_image = function() end
    image.clear_placements = function() end
    _G.jobs = {}
    vim.system = function(_, opts, callback)
      if opts.stdin then jobs[#jobs + 1] = { callback = callback, requests = vim.json.decode(opts.stdin).requests } end
      return { kill = function() end, wait = function() return {code=1,stdout=""} end }
    end
    local size = require "md-render.text_size"
    size.supports = function() return true end
    size.setup { backend = "image" }
    _G.preview = require "md-render.preview"
    _G.complete = function()
      local batch = jobs
      jobs = {}
      for _, job in ipairs(batch) do
        local outputs = {}
        for index, request in ipairs(job.requests) do
          local entry = request.entries[1]
          local columns = vim.fn["repeat"]({false}, 30)
          columns[1] = 0
          outputs[index] = { lines = {{ start = 0, ["end"] = #entry.text, text = entry.text,
            data = "png", cols = 30, width = 570, height = 88, columns = columns }} }
        end
        job.callback { code = 0, stdout = vim.json.encode(outputs) }
      end
    end
    _G.start = function(tag, with_image)
      if _G.session then
        local old = session
        preview.toggle()
        old:cleanup_images()
        vim.api.nvim_buf_delete(old.buf, {force=true})
      end
      vim.cmd "enew!"
      vim.bo.filetype = "markdown"
      local lines = { "# Top " .. tag, "", "## Next " .. tag, "", "SELECT THIS BODY", "", "end" }
      if with_image then
        table.insert(lines, 5, "![image](https://example.invalid/review.png)")
        table.insert(lines, 6, "")
      end
      vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
      preview.toggle()
      _G.session = preview._sessions[vim.api.nvim_get_current_buf()]
      for row, line in ipairs(session.content.lines) do
        if line:find("SELECT THIS BODY", 1, true) then
          vim.api.nvim_win_set_cursor(0, { row, 0 })
          _G.selected_line = line
        end
      end
      _G.before = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    end
  ]]
  for _, mode in ipairs { "v", "s", "no", "c" } do
    phase = mode
    lua("start(...)", mode)
    wait_for "return #jobs > 0"
    if mode == "v" or mode == "s" then
      lua [[vim.cmd "normal! v$"]]
      if mode == "s" then input "<C-g>" end
    elseif mode == "no" then
      input "y"
    else
      input "/SELECT"
    end
    wait_for("return vim.api.nvim_get_mode().mode == " .. vim.inspect(mode))
    lua [[_G.anchor, _G.cursor = vim.fn.getpos "v", vim.fn.getpos "."; complete()]]
    if mode == "v" then
      lua [[
        vim.api.nvim_exec_autocmds("ColorScheme", {})
        vim.api.nvim_exec_autocmds("VimResized", {})
      ]]
    end
    wait_for "return session.dirty"
    assert(lua [[return vim.deep_equal(before, vim.api.nvim_buf_get_lines(0,0,-1,false))]], mode .. " text changed")
    assert(
      lua [[return vim.deep_equal(anchor, vim.fn.getpos "v") and vim.deep_equal(cursor, vim.fn.getpos ".")]],
      mode .. " endpoints changed"
    )
    if mode == "v" or mode == "s" then
      if mode == "s" then input "<C-g>" end
      input "y"
      wait_for [[return vim.fn.getreg '"' == selected_line .. "\n"]]
    elseif mode == "no" then
      input "$"
      wait_for [[return vim.fn.getreg '"' == selected_line]]
    else
      input "<CR>"
      wait_for [[return vim.fn.getreg "/" == "SELECT"]]
    end
    wait_for "return vim.api.nvim_get_mode().mode == 'n' and not session.dirty and #session.content.text_placements == 2"
    lua [[vim.cmd "nohlsearch"]]
  end

  -- The ordinary window-resize handler calls Session:rebuild directly.
  phase = "resize"
  lua [[
    vim.cmd "vnew"
    _G.other = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(session.win)
  ]]
  vim.wait(200)
  lua [[complete()]]
  wait_for "return #session.content.text_placements == 2"
  lua [[
    vim.cmd "normal! 0v$"
    _G.before = vim.api.nvim_buf_get_lines(0,0,-1,false)
    vim.api.nvim_win_set_width(other, 85)
    vim.api.nvim_exec_autocmds("WinResized", {})
  ]]
  wait_for "return session.dirty"
  assert(
    lua [[return vim.deep_equal(before, vim.api.nvim_buf_get_lines(0,0,-1,false))]],
    "resize changed selected text"
  )
  input "<Esc>"
  wait_for "return not session.dirty"
  lua [[vim.api.nvim_win_close(other, true); complete()]]

  -- An inline image's completion must not publish ready heading layouts through
  -- the older download path while a selection is still using the previous rows.
  phase = "inline image completion"
  lua [[
    local image = require "md-render.image"
    _G.cached, _G.downloads, _G.rebuild_attempts = false, 0, 0
    _G.png = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"
    local resolve, transmit = image.get_cached, image.transmit_image_async
    image.get_cached = function(url)
      if url == "https://example.invalid/review.png" then return cached and png or nil end
      return resolve(url)
    end
    image.download_async = function(_, callback)
      downloads = downloads + 1
      _G.download = callback
    end
    image.transmit_image_async = function(path, callback)
      if path == png then callback(10, 4, 4) else transmit(path, callback) end
    end
    start("download", true)
    local rebuild = session.rebuild
    session.rebuild = function(self)
      rebuild_attempts = rebuild_attempts + 1
      return rebuild(self)
    end
    vim.cmd "normal! 0v$"
  ]]
  wait_for "return #jobs > 0 and download ~= nil"
  lua [[complete(); cached = true; download(png)]]
  wait_for "return rebuild_attempts >= 2 and session.image_state._rebuild_timer == nil"
  assert(
    lua [[return vim.deep_equal(before, vim.api.nvim_buf_get_lines(0,0,-1,false))]],
    "download bypassed the operation gate"
  )
  input "y"
  wait_for [[return vim.fn.getreg '"' == selected_line .. "\n" and not session.dirty]]
  wait_for "return session.image_state.image_ids[png] ~= nil"
  assert(lua "return downloads == 1", "publishing new dimensions must not restart the download")

  -- Publishing just after y must also leave Neovim's timed yank feedback intact.
  phase = "yank feedback"
  lua [[
    start("yank feedback")
    vim.api.nvim_create_autocmd("TextYankPost", {callback=function() vim.hl.on_yank {timeout=300} end})
  ]]
  wait_for "return #jobs > 0"
  lua [[
    vim.cmd "normal! 0v$y"
    complete()
  ]]
  wait_for "return session.dirty"
  assert(
    lua [[return vim.deep_equal(before, vim.api.nvim_buf_get_lines(0,0,-1,false))]],
    "reflow moved live yank feedback"
  )
  wait_for "return not session.dirty and #session.content.text_placements == 2"

  -- Demo owns a separate rebuild hook but must honor the same operation gate.
  phase = "demo"
  lua [[
    preview.show_demo()
    _G.demo = vim.api.nvim_get_current_buf()
    vim.cmd "normal! G0v$"
    _G.before = vim.api.nvim_buf_get_lines(0,0,-1,false)
    _G.anchor, _G.cursor = vim.fn.getpos "v", vim.fn.getpos "."
  ]]
  wait_for "return #jobs > 0"
  lua [[complete()]]
  vim.wait(100)
  assert(
    lua [[return vim.deep_equal(before, vim.api.nvim_buf_get_lines(demo,0,-1,false))]],
    "demo changed selected text"
  )
  assert(
    lua [[return vim.deep_equal(anchor, vim.fn.getpos "v") and vim.deep_equal(cursor, vim.fn.getpos ".")]],
    "demo moved selection"
  )
  input "<Esc>"
  wait_for "return not vim.deep_equal(before, vim.api.nvim_buf_get_lines(demo,0,-1,false))"
  lua [[
    vim.cmd "normal! v$"
    preview._demo_rebuild()
    local owner = vim.api.nvim_get_current_win()
    vim.api.nvim_open_win(demo, true, {split="below", win=-1})
    vim.api.nvim_win_close(owner, true)
    vim.cmd("normal! " .. vim.keycode "<Esc>")
    vim.api.nvim_exec_autocmds("SafeState", {})
  ]]
end)
if not ok then
  print(
    phase,
    lua [[return vim.inspect {mode=vim.fn.mode(1),dirty=session and session.dirty,jobs=#jobs,lines=vim.api.nvim_buf_line_count(0)}]]
  )
end
vim.fn.jobstop(child)
assert(ok, err)

-- Valid JSON can still have the wrong protocol shape. All such responses must
-- retain the original text and expose a useful retryable error.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. package.path
local layout = require "md-render.heading_layout"
local system, notify = vim.system, vim.notify_once
local callback, warning
vim.system = function(_, _, fn)
  callback = fn
  return { kill = function() end }
end
vim.notify_once = function(message)
  warning = message
end
for index, response in ipairs {
  "null",
  "false",
  "{}",
  "[null]",
  "[false]",
  '[{"lines":false}]',
  '[{"lines":[false]}]',
  '[{"lines":[{"start":0,"end":7,"text":"changed","cols":1}]}]',
  '[{"lines":[{"start":0,"end":7,"text":"Heading","cols":1,"data":"png","width":19,"height":44,"columns":false}]}]',
  '[{"lines":[{"start":0,"end":7,"text":"Heading","cols":1,"data":"png","width":19,"height":44,"columns":[999]}]}]',
} do
  callback, warning = nil, nil
  local entry = layout.request({ entries = { { text = "Heading" } }, test = index }, "python3")
  assert(vim.wait(1000, function()
    return callback ~= nil
  end))
  callback { code = 0, stdout = response, stderr = "" }
  assert(vim.wait(1000, function()
    return entry.ready
  end))
  assert(not entry.output and entry.error == "invalid renderer response", response)
  assert(warning and warning:find("using text", 1, true), response)
end
vim.system, vim.notify_once = system, notify
print "Heading async: native operations survive reflow; malformed renderer responses retain text"
