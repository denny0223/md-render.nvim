-- Native conditional writes must save the source, never a rendered filename.
-- Run: nvim --headless -n -u NONE --noplugin -i NONE -l tests/render_write_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local preview = require "md-render.preview"
local image = require "md-render.image"
require("md-render.text_size").setup { enabled = false }
vim.o.hidden, vim.o.swapfile = true, false
vim.api.nvim_ui_send = function() end
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = assert(vim.uv.fs_realpath(root))
local serial, checks = 0, 0
local function eq(actual, expected, message)
  checks = checks + 1
  assert(vim.deep_equal(actual, expected), message .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end

local function cleanup()
  vim.o.hidden = true
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then vim.api.nvim_win_close(win, true) end
  end
  vim.cmd "silent! tabonly!"
  vim.cmd "silent! only!"
  vim.cmd "enew!"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):sub(1, #root) == root then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  vim.wait(20)
end

local function open(mode, dirty, lines, filename)
  cleanup()
  serial = serial + 1
  local path = root .. "/" .. (filename or "source-" .. serial .. ".md")
  vim.fn.writefile(lines or { "# Original" }, path)
  if filename then
    -- Ex :edit normalizes newlines; load the literal filename through the API.
    local buf = vim.fn.bufadd(path)
    vim.fn.bufload(buf)
    vim.api.nvim_set_current_buf(buf)
  else
    vim.cmd.edit(path)
  end
  vim.bo.filetype = "markdown"
  local state =
    { source = vim.api.nvim_get_current_buf(), source_win = vim.api.nvim_get_current_win(), path = path, writes = 0 }
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = state.source,
    callback = function()
      state.writes = state.writes + 1
      state.cmdarg = vim.v.cmdarg
    end,
  })
  if dirty then vim.api.nvim_buf_set_lines(state.source, 0, -1, false, { "# Changed before preview" }) end
  if mode == "float" then
    preview.show()
  elseif mode == "tab" then
    preview.show_tab()
  elseif mode == "pager" then
    preview.show_pager()
  elseif mode == "split" then
    preview.split()
    vim.api.nvim_set_current_win(assert(preview._toggle_sessions[state.source]).win)
  else
    preview.toggle()
  end
  state.win, state.render = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  state.session = assert(preview._sessions[state.render])
  state.render_name = vim.api.nvim_buf_get_name(state.render)
  return state
end

local function keep_other_window(state, exclude_source)
  local normal
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= state.win and vim.api.nvim_win_get_config(win).relative == "" then
      if not exclude_source or vim.api.nvim_win_get_buf(win) ~= state.source then return end
      normal = win
    end
  end
  if normal then vim.api.nvim_set_current_win(normal) end
  vim.cmd.vsplit()
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
  vim.api.nvim_set_current_win(state.win)
end

local function bytes(path)
  local file = assert(io.open(path, "rb"))
  local data = file:read "*a"
  file:close()
  return data
end

local function settle_modified(state)
  -- Neovim 0.13 defers even explicit modified changes through OptionSet.
  if vim.fn.exists "##BufModifiedSet" == 0 then
    assert(
      vim.wait(1000, function()
        return vim.bo[state.render].modified == vim.bo[state.source].modified
      end, 5),
      "deferred modified event did not synchronize the preview"
    )
  end
end

-- API command exceptions and interactive Ex errors have different abort paths.
-- Drive the native input loop so a failed :saveas / :wq! cannot keep executing.
if vim.env.MD_RENDER_WRITE_INPUT_CHILD == "1" then
  vim.o.more = false
  -- A queued native key confirms Ex finished before inspecting its effects.
  local function native_input(command, done)
    vim.keymap.set("n", "<F24>", function()
      vim.schedule(done)
    end)
    vim.api.nvim_input(":" .. command .. "<CR><F24>")
  end
  local cases, index = {}, 0
  for _, mode in ipairs { "toggle", "split", "float", "tab", "pager" } do
    for _, command in ipairs {
      "saveas",
      "saveas!",
      "file",
      "1wq!",
      "wq! >>",
      "readonly",
      "missing",
      "unload",
      "abort-unload",
      "unload-update",
      "unload-x",
      "unload-write",
      "unload-wq!",
    } do
      cases[#cases + 1] = { mode = mode, command = command }
    end
  end
  local function next_case()
    index = index + 1
    local case = cases[index]
    if not case then
      cleanup()
      vim.fn.delete(root, "rf")
      print("native-write-input:" .. checks)
      vim.cmd "qa!"
      return
    end
    local state = open(case.mode, true)
    local unload_write = case.command:match "^unload%-(.+)$"
    keep_other_window(state, case.command == "unload" or case.command == "abort-unload" or unload_write ~= nil)
    local target = root .. "/input-target-" .. serial .. ".md"
    local target_exists = case.command ~= "saveas"
    if target_exists then vim.fn.writefile({ "Existing target" }, target) end
    local command = case.command .. " " .. vim.fn.fnameescape(target)
    if case.command == "readonly" then
      vim.bo[state.source].readonly = true
      vim.o.hidden = false
      command = "wq"
    elseif case.command == "missing" then
      vim.api.nvim_buf_set_name(state.source, root .. "/missing-" .. serial .. "/source.md")
      vim.o.hidden = false
      command = "wq!"
    elseif case.command == "unload" or case.command == "abort-unload" then
      command = "bunload! " .. state.source
      if case.command == "abort-unload" then
        vim.api.nvim_create_autocmd("BufUnload", {
          buffer = state.source,
          once = true,
          command = "throw 'render_write_test: cancel source unload'",
        })
      end
    elseif unload_write then
      -- Queue both native commands before the deferred detach mirror can run.
      command = "bunload! " .. state.source .. "<CR>:" .. unload_write
      vim.api.nvim_create_autocmd("BufWritePre", {
        buffer = state.source,
        callback = function()
          vim.api.nvim_buf_set_lines(state.source, 0, -1, false, { "# Unexpected formatter rewrite" })
        end,
      })
    end
    local source_name = vim.api.nvim_buf_get_name(state.source)
    local function check_case()
      vim.api.nvim_input "<Esc>"
      local ok, err = pcall(function()
        local label = case.mode .. " interactive " .. case.command
        local unloaded = case.command == "unload" or unload_write ~= nil
        eq(vim.api.nvim_win_is_valid(state.win), true, label .. " preserves the operated window")
        eq(vim.api.nvim_get_current_buf(), state.render, label .. " keeps the preview focused")
        eq(vim.api.nvim_buf_is_loaded(state.source), not unloaded, label .. " retains the final source load state")
        eq(vim.bo[state.source].modified, not unloaded, label .. " retains the final source dirty state")
        eq(vim.bo[state.render].modified, not unloaded, label .. " mirrors the final source dirty state")
        eq(vim.api.nvim_buf_get_name(state.render), state.render_name, label .. " preserves render identity")
        eq(vim.api.nvim_buf_get_name(state.source), source_name, label .. " preserves source identity")
        local lines = unloaded and {}
          or { case.command == "abort-unload" and "# Changed after aborted unload" or "# Changed before preview" }
        eq(vim.api.nvim_buf_get_lines(state.source, 0, -1, false), lines, label .. " retains the final source contents")
        eq(vim.fn.readfile(state.path), { "# Original" }, label .. " preserves source file")
        if target_exists then
          eq(vim.fn.readfile(target), { "Existing target" }, label .. " preserves destination file")
        else
          eq(vim.fn.filereadable(target), 0, label .. " creates no destination file")
        end
        eq(state.writes, case.command == "missing" and 1 or 0, label .. " only attempts an explicit source save")
        if unload_write then
          eq(
            vim.v.errmsg:find("source buffer is unloaded", 1, true) ~= nil,
            true,
            label .. " reports the unloaded source through the native error path"
          )
        end
      end)
      if not ok then
        io.stderr:write(tostring(err) .. "\n")
        vim.cmd "cquit 1"
        return
      end
      vim.defer_fn(next_case, 10)
    end
    vim.v.errmsg = ""
    native_input(command, function()
      if case.command == "unload" then
        -- The next native command skips the now clean, unloaded source.
        native_input("update", check_case)
      elseif case.command == "abort-unload" then
        -- Let the queued source reattachment finish before testing a new API edit.
        vim.schedule(function()
          local ok, err = pcall(function()
            eq(vim.api.nvim_buf_is_loaded(state.source), true, case.mode .. " aborted unload keeps the source loaded")
            eq(vim.bo[state.source].modified, true, case.mode .. " aborted unload keeps the source dirty")
            eq(vim.bo[state.render].modified, true, case.mode .. " aborted unload keeps the mirror dirty")
            vim.bo[state.source].modified = false
            settle_modified(state)
            eq(vim.bo[state.render].modified, false, case.mode .. " aborted unload clears the mirror before a new edit")
            vim.api.nvim_buf_set_lines(state.source, 0, -1, false, { "# Changed after aborted unload" })
          end)
          if not ok then
            io.stderr:write(tostring(err) .. "\n")
            vim.cmd "cquit 1"
            return
          end
          check_case()
        end)
      else
        check_case()
      end
    end)
  end
  vim.defer_fn(next_case, 10)
  return
end

local child = vim
  .system({
    vim.v.progpath,
    "--headless",
    "-n",
    "-u",
    "NONE",
    "--noplugin",
    "-i",
    "NONE",
    "-c",
    "luafile tests/render_write_test.lua",
  }, {
    text = true,
    timeout = 75000, -- 65 cases; native error reporting takes about one second per failure.
    env = {
      MD_RENDER_WRITE_INPUT_CHILD = "1",
      NVIM_LOG_FILE = "/tmp/md-render-write-input-" .. vim.fn.getpid() .. ".log",
    },
  })
  :wait()
assert(
  child.code == 0,
  "native input write safeguards failed (code " .. tostring(child.code) .. "): " .. (child.stderr or ""):sub(-2000)
)
local native_checks = tonumber(((child.stdout or "") .. (child.stderr or "")):match "native%-write%-input:(%d+)")
assert(native_checks == 755, "native input write safeguards did not finish")
checks = checks + native_checks

for _, mode in ipairs { "toggle", "split", "float", "tab", "pager" } do
  local state = open(mode)
  vim.cmd "silent update"
  eq(state.writes, 0, mode .. " clean :update skips writing")
  vim.api.nvim_buf_set_lines(state.source, 0, -1, false, { "# Temporary edit" })
  vim.api.nvim_buf_call(state.source, function()
    vim.cmd "silent undo"
  end)
  eq(vim.bo[state.source].modified, false, mode .. " undo returns the source to its saved state")
  eq(vim.bo[state.render].modified, false, mode .. " undo synchronously clears the render mirror")
  vim.cmd "silent update"
  eq(state.writes, 0, mode .. " :update after undo skips writing")
  vim.api.nvim_buf_set_lines(state.source, 0, -1, false, { "# Changed synchronously" })
  eq(vim.bo[state.render].modified, true, mode .. " API edits immediately mark the render dirty")
  vim.cmd "silent update"
  eq(vim.fn.readfile(state.path), { "# Changed synchronously" }, mode .. " :update saves hidden source edits")
  eq(state.writes, 1, mode .. " :update runs source save autocmds once")
  eq(vim.bo[state.source].modified, false, mode .. " :update cleans the source")
  eq(vim.bo[state.render].modified, false, mode .. " :update cleans the render mirror")
  eq(vim.api.nvim_get_current_buf(), state.render, mode .. " :update preserves the preview")
  eq(vim.fn.filereadable(state.render_name), 0, mode .. " :update never writes the synthetic filename")
  vim.cmd "silent update"
  eq(state.writes, 1, mode .. " repeat :update skips writing")
  vim.cmd "silent write"
  eq(state.writes, 2, mode .. " explicit clean :write still writes normally")

  vim.g.md_render_write_test_injected = nil
  state = open(mode, true, nil, "quote'\" | let g:md_render_write_test_injected=1 |\nsecond.md")
  vim.cmd "silent write"
  eq(vim.fn.readfile(state.path), { "# Changed before preview" }, mode .. " saves literal filename contents")
  eq(vim.api.nvim_buf_get_name(state.source), state.path, mode .. " preserves the literal source filename")
  eq(vim.api.nvim_get_current_buf(), state.render, mode .. " unusual filename retains the preview")
  eq(vim.bo[state.source].modified, false, mode .. " unusual filename cleans the source")
  eq(vim.bo[state.render].modified, false, mode .. " unusual filename cleans the mirror")
  eq(vim.fn.filereadable(state.render_name), 0, mode .. " unusual filename never creates a render file")
  eq(vim.g.md_render_write_test_injected, nil, mode .. " filename text cannot execute as Ex commands")
  eq(state.writes, 1, mode .. " unusual filename runs source save handlers once")

  state = open(mode)
  vim.bo[state.source].modified = true
  settle_modified(state)
  eq(vim.bo[state.render].modified, true, mode .. " explicit source modified marking reaches the mirror")
  vim.cmd "silent update"
  eq(state.writes, 1, mode .. " :update after metadata marking saves the source")
  vim.api.nvim_buf_set_lines(state.source, 0, -1, false, { "# Changes marked unmodified" })
  vim.bo[state.source].modified = false
  settle_modified(state)
  eq(vim.bo[state.render].modified, false, mode .. " explicit source unmarking reaches the mirror")
  vim.cmd "silent update"
  eq(state.writes, 1, mode .. " :update after metadata unmarking skips writing")
  eq(vim.fn.readfile(state.path), { "# Original" }, mode .. " unmodified metadata does not silently save changed text")

  state = open(mode, true)
  eq(vim.bo[state.render].modified, true, mode .. " initial dirty source is mirrored")
  state.session:rebuild()
  eq(vim.bo[state.render].modified, true, mode .. " reflow preserves source dirtiness")
  vim.cmd "silent update"
  eq(vim.fn.readfile(state.path), { "# Changed before preview" }, mode .. " saves edits predating the preview")

  for _, command in ipairs { "x", "normal! ZZ" } do
    for _, dirty in ipairs { false, true } do
      state = open(mode, dirty)
      keep_other_window(state)
      vim.cmd("silent " .. command)
      eq(state.writes, dirty and 1 or 0, mode .. " " .. command .. " writes only dirty sources")
      eq(vim.api.nvim_win_is_valid(state.win), false, mode .. " " .. command .. " closes its window")
      eq(vim.bo[state.source].modified, false, mode .. " " .. command .. " leaves source saved")
      eq(vim.fn.filereadable(state.render_name), 0, mode .. " " .. command .. " never writes rendered output")
    end
  end

  state = open(mode, true)
  vim.bo[state.source].readonly = true
  vim.o.hidden = false
  for _, command in ipairs { "update", "x", "normal! ZZ", "write", "wq", "write ++ff=dos", "write ++enc=utf-16le" } do
    local ok, err = pcall(vim.cmd, command)
    eq(ok, false, mode .. " " .. command .. " propagates source write failure")
    eq(tostring(err):find("E45", 1, true) ~= nil, true, mode .. " " .. command .. " reports the source readonly error")
    eq(vim.api.nvim_win_is_valid(state.win), true, mode .. " failed write keeps its window")
    eq(vim.bo[state.source].modified, true, mode .. " failed write preserves dirty source")
    eq(vim.bo[state.render].modified, true, mode .. " failed write preserves dirty mirror")
    eq(vim.fn.readfile(state.path), { "# Original" }, mode .. " failed write preserves disk contents")
    eq(vim.api.nvim_get_current_buf(), state.render, mode .. " failed write restores the preview")
  end
  vim.cmd "silent update!"
  eq(vim.fn.readfile(state.path), { "# Changed before preview" }, mode .. " :update! forwards the source bang")
  eq(vim.bo[state.render].modified, false, mode .. " successful forced write clears the mirror")
  vim.o.hidden = true

  state = open(mode, true)
  keep_other_window(state)
  local formatted = { "# Changed by failed formatter" }
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = state.source,
    once = true,
    callback = function()
      vim.api.nvim_buf_set_lines(state.source, 0, -1, false, formatted)
      error("render_write_test: formatter failed", 0)
    end,
  })
  local formatter_ok, formatter_err = pcall(vim.cmd, "silent wq!")
  eq(formatter_ok, false, mode .. " failed formatter aborts the write and quit")
  eq(
    tostring(formatter_err):find("formatter failed", 1, true) ~= nil,
    true,
    mode .. " reports the original formatter error"
  )
  eq(vim.api.nvim_win_is_valid(state.win), true, mode .. " failed formatter preserves its window")
  eq(vim.api.nvim_get_current_buf(), state.render, mode .. " failed formatter restores the preview")
  eq(
    vim.api.nvim_buf_get_lines(state.source, 0, -1, false),
    formatted,
    mode .. " failed formatter retains source changes"
  )
  eq(vim.bo[state.source].modified, true, mode .. " failed formatter retains unsaved source")
  eq(vim.bo[state.render].modified, true, mode .. " failed formatter retains the dirty mirror")
  eq(vim.fn.readfile(state.path), { "# Original" }, mode .. " failed formatter preserves the saved source file")
  eq(vim.fn.filereadable(state.render_name), 0, mode .. " failed formatter never writes the render path")
  eq(
    vim.wait(2000, function()
      return vim.deep_equal(state.session.source_lines, formatted)
    end, 5),
    true,
    mode .. " failed formatter refreshes the source snapshot"
  )
  eq(
    table
      .concat(vim.api.nvim_buf_get_lines(state.render, 0, -1, false), "\n")
      :find("Changed by failed formatter", 1, true) ~= nil,
    true,
    mode .. " failed formatter refreshes the visible preview"
  )
  eq(vim.bo[state.render].modified, true, mode .. " failed formatter repaint retains unsaved state")
  vim.cmd "silent update"
  eq(vim.fn.readfile(state.path), formatted, mode .. " retry saves the formatter's retained changes")
  eq(vim.bo[state.source].modified, false, mode .. " retry clears source dirtiness")
  eq(vim.bo[state.render].modified, false, mode .. " retry clears mirror dirtiness")
  eq(vim.api.nvim_get_current_buf(), state.render, mode .. " retry retains the preview")
  eq(state.writes, 2, mode .. " retry invokes the source save handler once more")

  for _, command in ipairs { "write", "saveas", "file", "wq" } do
    state = open(mode, true)
    keep_other_window(state)
    local target = root .. "/target-" .. serial .. ".md"
    local ok = pcall(vim.cmd, command .. " " .. vim.fn.fnameescape(target))
    eq(ok, false, mode .. " rejects " .. command .. " to another filename")
    eq(vim.api.nvim_buf_get_name(state.render), state.render_name, mode .. " rejected rename preserves render identity")
    eq(vim.api.nvim_buf_get_name(state.source), state.path, mode .. " rejected rename preserves source identity")
    eq(vim.bo[state.source].modified, true, mode .. " rejected alternate write preserves unsaved source")
    eq(vim.fn.readfile(state.path), { "# Original" }, mode .. " rejected alternate write does not save the source")
    eq(vim.fn.filereadable(target), 0, mode .. " rejected alternate write creates no destination")
    eq(vim.api.nvim_win_is_valid(state.win), true, mode .. " rejected write cannot close the preview")
  end

  state = open(mode, true)
  keep_other_window(state)
  local target = root .. "/existing-target-" .. serial .. ".md"
  local new_target = root .. "/new-target-" .. serial .. ".md"
  vim.fn.writefile({ "Existing target" }, target)
  for _, command in ipairs {
    "1write!",
    "1write! " .. vim.fn.fnameescape(state.path),
    "1wq! " .. vim.fn.fnameescape(state.path),
    "1write! " .. vim.fn.fnameescape(target),
    "1write " .. vim.fn.fnameescape(new_target),
    "write! " .. vim.fn.fnameescape(state.path),
    "write! " .. vim.fn.fnameescape(target),
    "write! >> " .. vim.fn.fnameescape(state.path),
    "write! >> " .. vim.fn.fnameescape(target),
    "1write! >> " .. vim.fn.fnameescape(state.path),
    "1write! >> " .. vim.fn.fnameescape(target),
    "wq! >> " .. vim.fn.fnameescape(state.path),
  } do
    local ok = pcall(vim.cmd, "silent " .. command)
    eq(ok, false, mode .. " refuses " .. command)
    eq(vim.fn.readfile(state.path), { "# Original" }, mode .. " partial/append rejection preserves source file")
    eq(vim.fn.readfile(target), { "Existing target" }, mode .. " partial/append rejection preserves alternate file")
    eq(vim.fn.filereadable(new_target), 0, mode .. " partial write does not create an alternate file")
    eq(vim.fn.filereadable(state.render_name), 0, mode .. " partial/append rejection never creates a render file")
    eq(vim.bo[state.source].modified, true, mode .. " partial/append rejection preserves unsaved source")
    eq(vim.bo[state.render].modified, true, mode .. " partial/append rejection preserves unsaved mirror")
    eq(vim.api.nvim_get_current_buf(), state.render, mode .. " partial/append rejection keeps the preview")
    eq(vim.api.nvim_win_is_valid(state.win), true, mode .. " partial/append rejection cannot close the preview")
    eq(state.writes, 0, mode .. " partial/append rejection does not invoke source save handlers")
  end

  -- Compare actual bytes and option state against native writes on the source.
  local content = { "# 編碼 Encoding", "", "line with trailing spaces  ", "Final line" }
  for _, args in ipairs { "++ff=dos", "++enc=utf-16le", "++ff=dos ++enc=utf-16le", "++bin", "++nobin" } do
    cleanup()
    local reference = root .. "/native-reference.md"
    vim.fn.writefile({ "# Original" }, reference)
    vim.cmd.edit(reference)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, content)
    vim.bo.endofline = false
    local native_cmdarg
    vim.api.nvim_create_autocmd("BufWritePre", {
      buffer = vim.api.nvim_get_current_buf(),
      callback = function()
        native_cmdarg = vim.v.cmdarg
      end,
    })
    vim.cmd("silent write " .. args)
    local expected = bytes(reference)
    local options = { vim.bo.fileformat, vim.bo.fileencoding, vim.bo.binary, vim.bo.endofline }
    state = open(mode)
    vim.api.nvim_buf_set_lines(state.source, 0, -1, false, content)
    vim.bo[state.source].endofline = false
    vim.cmd("silent write " .. args)
    eq(state.cmdarg, native_cmdarg, mode .. " forwards " .. args .. " with native source save arguments")
    eq(bytes(state.path), expected, mode .. " forwards " .. args .. " with native file bytes")
    eq({
      vim.bo[state.source].fileformat,
      vim.bo[state.source].fileencoding,
      vim.bo[state.source].binary,
      vim.bo[state.source].endofline,
    }, options, mode .. " forwards " .. args .. " with native source options")
    eq(vim.bo[state.source].modified, false, mode .. " option write saves the source")
    eq(vim.bo[state.render].modified, false, mode .. " option write cleans the mirror")
    eq(vim.api.nvim_get_current_buf(), state.render, mode .. " option write retains the preview")
    eq(vim.fn.filereadable(state.render_name), 0, mode .. " option write never creates a render file")
  end
end

-- Independent presentations share one synchronous source watcher and dirty state.
local attach = vim.api.nvim_buf_attach
local attachments, state = 0, open "toggle"
local source = state.source
vim.api.nvim_buf_attach = function(buf, ...)
  if buf == source then attachments = attachments + 1 end
  return attach(buf, ...)
end
vim.cmd.vsplit()
local editor = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(editor, source)
preview.show()
local floating = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(editor)
preview.show_tab()
vim.api.nvim_buf_attach = attach
eq(attachments, 0, "additional presentations reuse the source's existing attachment")
local sessions = {}
for _, session in pairs(preview._sessions) do
  if session.source_bufnr == source then sessions[#sessions + 1] = session end
end
eq(#sessions, 3, "toggle, float and tab retain independent Sessions")
vim.api.nvim_buf_set_lines(source, 0, -1, false, { "# Shared unsaved source" })
for _, session in ipairs(sessions) do
  eq(vim.bo[session.buf].modified, true, "source edits synchronously mark every presentation dirty")
  session:refresh_source()
  session:rebuild()
  eq(vim.bo[session.buf].modified, true, "each independent rebuild retains source dirtiness")
end
vim.api.nvim_set_current_win(floating)
vim.cmd "silent update"
for _, session in ipairs(sessions) do
  eq(vim.bo[session.buf].modified, false, "one save synchronously cleans every presentation")
end
vim.api.nvim_set_current_win(state.win)
vim.cmd "silent update"
eq(state.writes, 1, "another presentation's :update does not resave the clean source")
vim.api.nvim_buf_delete(source, { force = true })
for _, session in ipairs(sessions) do
  eq(vim.api.nvim_buf_is_valid(session.buf), false, "source wipe retires every rendered buffer")
  eq(preview._sessions[session.buf], nil, "source wipe drops every session registry entry")
end

-- Unload/reload reattaches the source watcher; external render wipes retire it.
state = open "toggle"
vim.api.nvim_buf_delete(state.source, { unload = true, force = true })
eq(vim.api.nvim_buf_is_loaded(state.source), false, "fixture unloads the hidden source")
vim.fn.bufload(state.source)
vim.api.nvim_buf_set_lines(state.source, 0, -1, false, { "# Changed after reload" })
eq(vim.bo[state.render].modified, true, "reloaded source regains synchronous modified tracking")
vim.cmd "silent update"
eq(vim.fn.readfile(state.path), { "# Changed after reload" }, "reloaded source can save from its retained preview")
vim.api.nvim_buf_delete(state.render, { force = true })
vim.api.nvim_buf_set_lines(state.source, 0, -1, false, { "# Changed without a preview" })
vim.api.nvim_win_set_buf(0, state.source)
preview.toggle()
local renewed = vim.api.nvim_get_current_buf()
eq(vim.bo[renewed].modified, true, "a replacement preview mirrors the source after the retired watcher detaches")
vim.cmd "silent update"
eq(
  vim.fn.readfile(state.path),
  { "# Changed without a preview" },
  "replacement preview can save after source watcher retirement"
)

-- Async image placeholder replacement must not clear the source dirty mirror.
local ensure_png, pending = image.ensure_png_async, {}
image.setup { backend = "kitty" }
image._set_kitty_supported(true)
image._test_cell_size = { cell_w = 8, cell_h = 16 }
local png = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"
image.ensure_png_async = function(_, callback)
  pending[#pending + 1] = callback
end
state = open("toggle", false, { "# Image", "", "![image](" .. png .. ")" })
assert(
  vim.wait(2000, function()
    return #pending > 0
  end, 5),
  "image conversion did not start"
)
vim.api.nvim_buf_set_lines(state.source, 0, 1, false, { "# Unsaved image source" })
pending[#pending](png, false)
eq(vim.bo[state.render].modified, true, "async placeholder writes preserve unsaved source dirtiness")
state.session:refresh_source()
state.session:rebuild()
eq(vim.bo[state.render].modified, true, "image reflow preserves unsaved source dirtiness")
vim.cmd "silent update"
eq(vim.bo[state.render].modified, false, "image preview can save through :update")
image.ensure_png_async = ensure_png
cleanup()
vim.fn.delete(root, "rf")
print(string.format("render_write_test: %d passed", checks))
