-- Run: nvim --headless -n -u NONE --noplugin -i NONE -l tests/session_lifecycle_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local preview = require "md-render.preview"
require("md-render.text_size").setup { enabled = false }
vim.o.hidden, vim.o.swapfile = true, false

local function source(lines)
  local buf = vim.api.nvim_create_buf(false, false)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or { "body" })
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

-- A real input loop is needed: -l runs outside Insert mode, and invoking the
-- private scheduling helper cannot expose the rapid InsertLeave/Enter race.
if vim.env.MD_RENDER_AUTO_INPUT_CHILD == "1" then
  local buf = source()
  preview.auto_on()
  preview.toggle()
  vim.defer_fn(function()
    vim.api.nvim_input "i<Esc>i"
  end, 10)
  vim.defer_fn(function()
    local ok, err = pcall(function()
      assert(vim.api.nvim_get_mode().mode == "i", "fixture must reenter Insert mode")
      assert(vim.api.nvim_get_current_buf() == buf, "old InsertLeave timer switched an active edit to render")
      assert(vim.bo.modifiable, "source remains editable")
      vim.api.nvim_input "X"
    end)
    if not ok then
      io.stderr:write(tostring(err) .. "\n")
      vim.cmd "cquit 1"
      return
    end
    vim.defer_fn(function()
      if vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= "Xbody" then vim.cmd "cquit 1" end
      vim.cmd "qa!"
    end, 40)
  end, 180)
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
    "luafile tests/session_lifecycle_test.lua",
  }, { text = true, timeout = 5000, env = { MD_RENDER_AUTO_INPUT_CHILD = "1", NVIM_LOG_FILE = vim.fn.tempname() } })
  :wait()
assert(child.code == 0, "real auto-mode input failed: " .. (child.stderr or ""))

-- An InsertLeave in one window cannot switch another view of the same source.
local auto_buf = source()
local auto_win = vim.api.nvim_get_current_win()
preview.auto_on()
preview.toggle()
vim.cmd.split()
local other_source_win = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(auto_win)
vim.api.nvim_exec_autocmds("InsertLeave", { buffer = auto_buf })
vim.api.nvim_set_current_win(other_source_win)
vim.wait(100)
assert(vim.api.nvim_win_get_buf(other_source_win) == auto_buf, "old transition switched another source window")
assert(vim.api.nvim_win_get_buf(auto_win) == auto_buf, "old transition switched a window after focus left it")
vim.api.nvim_win_close(other_source_win, true)
preview.auto_off()
vim.api.nvim_buf_delete(auto_buf, { force = true })

local buf = source()
local source_win = vim.api.nvim_get_current_win()
preview.split()
local session = preview._toggle_sessions[buf]
local render_win = session.win
vim.api.nvim_set_current_win(render_win)
local custom = function() end
vim.keymap.set("n", "<CR>", custom, { buffer = session.buf })
vim.keymap.del("n", "za", { buffer = session.buf })
vim.api.nvim_set_current_win(source_win)
vim.api.nvim_set_current_win(render_win)
assert(vim.fn.maparg("<CR>", "n", false, true).callback == custom, "WinEnter replaced a user mapping")
assert(vim.fn.maparg("za", "n") == "", "WinEnter restored a deleted mapping")
vim.cmd.split()
local other_render_win = vim.api.nvim_get_current_win()
vim.wait(50)
for _, key in ipairs { "gf", "<C-]>" } do
  vim.keymap.set("n", key, custom, { buffer = session.buf })
  vim.api.nvim_set_current_win(render_win)
  assert(
    vim.fn.maparg(key, "n", false, true).callback == custom,
    "render-window rebind replaced a user " .. key .. " mapping"
  )
  vim.keymap.del("n", key, { buffer = session.buf })
  vim.api.nvim_set_current_win(other_render_win)
  assert(vim.fn.maparg(key, "n") == "", "render-window rebind restored a deleted " .. key .. " mapping")
end
vim.api.nvim_win_close(other_render_win, true)
vim.api.nvim_set_current_win(source_win)

local function timer_count()
  collectgarbage "collect"
  local count = 0
  vim.uv.walk(function(handle)
    if handle:get_type() == "timer" and not handle:is_closing() then count = count + 1 end
  end)
  return count
end
vim.wait(200)
local baseline = timer_count()
for index = 1, 100 do
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "body " .. index })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
end
vim.wait(250)
assert(timer_count() <= baseline, "replaced debounce timers left open handles")
vim.api.nvim_win_close(render_win, true)
vim.wait(50)
local content = session.content
preview._schedule_live_rebuild(session)
assert(session.content == content, "unchanged hidden source rebuilt its content")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "updated hidden body" })
preview._schedule_live_rebuild(session)
assert(
  session.content ~= content and not session.dirty,
  "hidden edits must still update native jump targets immediately"
)
assert(session.image_state == nil, "hidden rebuild attached a renderer")
vim.api.nvim_buf_delete(buf, { force = true })
vim.wait(50)
assert(timer_count() <= baseline, "disposal left timer handles")

local first = source { "# A", "", "paragraph" }
local editor = vim.api.nvim_get_current_win()
preview.show_tab()
local first_win, first_render = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
vim.api.nvim_win_set_cursor(first_win, { 3, 0 })
local first_view = vim.fn.winsaveview()
vim.cmd.tabprevious()
vim.wait(50)
assert(vim.api.nvim_win_is_valid(first_win), "switching tabs closed the document preview")
vim.api.nvim_set_current_win(first_win)
assert(vim.api.nvim_get_current_buf() == first_render, "returning to the tab lost the render buffer")
assert(vim.fn.winsaveview().lnum == first_view.lnum, "returning to the tab lost the reading position")
local async = require "md-render.async"
local run, executable = async.run, vim.fn.executable
async.run = function() end -- Exercise the real image tab lifecycle without converters.
vim.fn.executable = function(name)
  return name == "magick" and 1 or executable(name)
end
local viewer = require("md-render.image_view").open "unused.png"
vim.wait(50)
assert(vim.api.nvim_win_is_valid(first_win), "opening an image destroyed its origin document tab")
vim.fn.maparg("q", "n", false, true).callback()
assert(
  vim.wait(500, function()
    return vim.api.nvim_get_current_win() == first_win
  end),
  "image q did not return to the document preview"
)
assert(viewer.closed and vim.api.nvim_get_current_buf() == first_render, "image close lost the preview buffer")
assert(vim.fn.winsaveview().lnum == first_view.lnum, "image return lost the reading position")
async.run, vim.fn.executable = run, executable
vim.api.nvim_set_current_win(editor)
local second = source { "# B" }
preview.show_tab()
local second_render = vim.api.nvim_get_current_buf()
assert(preview._sessions[second_render].source_bufnr == second, "first tab command on another source failed to open it")
assert(not vim.api.nvim_win_is_valid(first_win), "new managed tab retained the obsolete tab handle")
preview.show_tab()
assert(vim.api.nvim_get_current_buf() == second, "calling tab in the preview did not close back to source")
vim.api.nvim_buf_delete(first, { force = true })
vim.api.nvim_buf_delete(second, { force = true })
print "session_lifecycle_test: passed"
