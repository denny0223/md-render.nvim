-- Run: nvim --headless -u NONE --noplugin -i NONE -l tests/cache_lifecycle_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local preview = require "md-render.preview"
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.o.hidden, vim.o.swapfile = true, false
local checks, serial = 0, 0
local function check(value, message)
  checks = checks + 1
  assert(value, message)
end
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  vim.wait(30)
end
local function fixture()
  serial = serial + 1
  local dir = root .. "/" .. serial
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(
    { "# A", "", "> [!NOTE]- Details", "> Fold content", "", "[B](b.md)", "", "[edit](t.txt)" },
    dir .. "/a.md"
  )
  vim.fn.writefile({ "# B", "", "[A](a.md)" }, dir .. "/b.md")
  vim.fn.writefile({ "ordinary file" }, dir .. "/t.txt")
  vim.cmd.edit(dir .. "/a.md")
  return dir, vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
end
local function show(mode)
  if mode == "tab" then
    preview.show_tab()
  else
    preview.show()
  end
  return preview._sessions[vim.api.nvim_get_current_buf()], vim.api.nvim_get_current_win()
end
local function follow(url)
  local session = assert(preview._sessions[vim.api.nvim_get_current_buf()])
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(session.buf, session.ns, 0, -1, { details = true })) do
    if mark[4].url == url then
      vim.api.nvim_win_set_cursor(0, { mark[2] + 1, mark[3] })
      feed "gf"
      return
    end
  end
  error("missing link " .. url)
end
local function group_gone(name)
  local ok, commands = pcall(vim.api.nvim_get_autocmds, { group = name })
  return not ok or #commands == 0
end
local function disposed(session)
  check(not vim.api.nvim_buf_is_valid(session.buf), "unreferenced render buffer is wiped")
  check(preview._sessions[session.buf] == nil, "disposed Session leaves registry")
  check(session.cache[session.source_bufnr] ~= session, "disposed Session leaves its presentation cache")
  check(group_gone("md_render_toggle_resize_" .. session.buf), "disposed resize callback is removed")
end

-- Fresh float/tab previews cannot accumulate hidden render buffers after q.
for _, mode in ipairs { "float", "tab" } do
  local _, source = fixture()
  for _ = 1, 3 do
    local session = show(mode)
    feed "q"
    disposed(session)
  end
  check(vim.api.nvim_buf_is_valid(source), "closing preview preserves source")
  local session = show(mode)
  follow "b.md"
  local second = preview._sessions[vim.api.nvim_get_current_buf()]
  feed "q"
  disposed(session)
  disposed(second)
end

-- Ordinary-file handoff keeps the preceding rendered document in native history.
for _, mode in ipairs { "float", "tab" } do
  fixture()
  local session = show(mode)
  session.fold_state[3] = false
  session:rebuild()
  follow "t.txt"
  check(vim.api.nvim_buf_is_valid(session.buf), "handoff keeps native return target")
  feed "<C-o>"
  check(vim.api.nvim_get_current_buf() == session.buf, "native Ctrl-O returns the same Session")
  check(session.fold_state[3] == false, "native return retains folds")
  feed "<C-i>"
  check(vim.api.nvim_buf_get_name(0):match "t%.txt$" ~= nil, "native Ctrl-I returns to editor")
  vim.cmd.clearjumps()
  vim.cmd.vnew()
  vim.cmd.close()
  vim.wait(30)
  disposed(session)
end

-- A native copy owns its visible buffer and the hidden earlier documents.
local dir = fixture()
local first, float = show "float"
follow "b.md"
local second = preview._sessions[vim.api.nvim_get_current_buf()]
vim.cmd.split()
local copy = vim.api.nvim_get_current_win()
vim.api.nvim_win_close(float, true)
vim.wait(30)
check(vim.api.nvim_buf_is_valid(first.buf) and vim.api.nvim_buf_is_valid(second.buf), "copy retains its presentation")
feed "<C-o>"
check(vim.api.nvim_get_current_buf() == first.buf, "copied native history returns to earlier render")
vim.cmd.edit(dir .. "/t.txt")
vim.cmd.vnew()
vim.cmd.close()
vim.wait(30)
check(vim.api.nvim_buf_is_valid(first.buf), "hidden document remains in the copy's jumplist")
vim.api.nvim_win_close(copy, true)
vim.wait(30)
disposed(first)
disposed(second)

-- Query jumplists in their own tab, including a copy now showing an ordinary file.
local _, _, editor = fixture()
local cross_tab, original_float = show "float"
follow "b.md"
local cross_tab_second = preview._sessions[vim.api.nvim_get_current_buf()]
vim.cmd "tab split"
local copy_tab = vim.api.nvim_get_current_win()
vim.cmd.enew()
vim.api.nvim_set_current_win(editor)
vim.api.nvim_win_close(original_float, true)
vim.wait(30)
check(vim.api.nvim_buf_is_valid(cross_tab.buf), "other-tab native history protects hidden render")
vim.api.nvim_set_current_win(copy_tab)
feed "<C-o>"
check(vim.api.nvim_get_current_buf() == cross_tab_second.buf, "other-tab return still works")
vim.api.nvim_win_close(copy_tab, true)
vim.wait(30)
disposed(cross_tab)
disposed(cross_tab_second)

-- The source side of a toggle still owns its render, even after :clearjumps.
fixture()
local toggled = show "float"
follow "t.txt"
feed "<C-o>"
preview.toggle()
vim.cmd.clearjumps()
local source_win = vim.api.nvim_get_current_win()
vim.cmd.vnew()
vim.cmd.close()
vim.wait(30)
check(vim.api.nvim_buf_is_valid(toggled.buf), "source-side toggle state retains its Session")
vim.cmd.vnew()
vim.api.nvim_win_close(source_win, true)
vim.wait(30)
disposed(toggled)

-- Recreating an externally wiped render releases its per-render callbacks.
fixture()
preview.toggle()
local old = preview._sessions[vim.api.nvim_get_current_buf()]
preview.toggle()
vim.api.nvim_buf_delete(old.buf, { force = true })
preview.toggle()
check(vim.api.nvim_get_current_buf() ~= old.buf, "external wipe creates a fresh render")
disposed(old)
check(vim.fn.maparg("<C-o>", "n") == "" and vim.fn.maparg("<C-i>", "n") == "", "jump keys remain native")
vim.fn.delete(root, "rf")
print("cache_lifecycle_test: " .. checks .. " passed")
vim.cmd "qa!"
