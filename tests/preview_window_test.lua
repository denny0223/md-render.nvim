-- Run: nvim --headless -u NONE --noplugin -l tests/preview_window_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local preview = require "md-render.preview"
local text_size = require "md-render.text_size"
text_size.supports = function()
  return true
end
vim.api.nvim_ui_send = function() end
local failures = 0
local function test(name, run)
  local source_win = vim.api.nvim_get_current_win()
  local source = vim.api.nvim_create_buf(false, false)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, {
    "[Jump](#target)",
    "",
    "## 日本中文共同文字",
    "",
    "Body",
    "",
    "## Target",
    "",
    "End",
  })
  vim.api.nvim_win_set_buf(source_win, source)
  vim.wo[source_win].number = true
  preview.split { mods = { vertical = true } }
  local session = preview._toggle_sessions[source]
  local original = session.win
  vim.api.nvim_set_current_win(original)
  vim.cmd.vsplit()
  local survivor = vim.api.nvim_get_current_win()

  local ok, err = pcall(run, session, original, survivor, source_win)
  if not ok then
    failures = failures + 1
    print("FAIL: " .. name .. ": " .. err)
  end
  local keep = vim.api.nvim_win_is_valid(source_win) and source_win or vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= keep then vim.api.nvim_win_close(win, true) end
  end
  if vim.api.nvim_buf_is_valid(source) then vim.api.nvim_buf_delete(source, { force = true }) end
  vim.wait(20, function()
    return false
  end)
end

test("a duplicated preview can toggle back before the owner closes", function(session, _, survivor)
  preview.toggle()
  assert(vim.api.nvim_win_get_buf(survivor) == session.source_bufnr, "toggle lost the source association")
  assert(vim.wo[survivor].number, "toggle did not restore source window options")
end)

test(
  "split copies retain their own source options across later bindings",
  function(session, original, survivor, source_win)
    vim.api.nvim_set_current_win(source_win)
    vim.wo[source_win].number = false
    preview.toggle()
    vim.api.nvim_set_current_win(original)
    preview.toggle()
    vim.api.nvim_win_set_buf(original, session.buf) -- Returning via :buffer leaves the saved mode as source.
    vim.cmd "tab split"
    preview.toggle()
    assert(vim.api.nvim_get_current_buf() == session.source_bufnr, "tab copy lost its source")
    assert(vim.wo.number, "tab copy inherited options from another preview")
    vim.cmd.tabclose()
    vim.api.nvim_set_current_win(survivor)
    preview.toggle()
    assert(vim.wo.number, "existing split copy inherited options from another preview")
    assert(not vim.w[source_win].md_render_state.source_wo.number, "another window's saved options were changed")
  end
)

test("auto mode follows the source opened by MdRender split", function(session)
  preview.auto_on()
  preview.split()
  preview.auto_off()
  assert(vim.api.nvim_get_current_buf() == session.source_bufnr, "auto off rendered the source split")
  assert(not vim.b[session.source_bufnr].md_render_auto, "auto off did not disable the source")
  preview.auto_on()
  assert(vim.api.nvim_get_current_buf() == session.buf, "auto on left the source split unrendered")
  preview.auto_off()
end)

test("copied state cannot redirect auto mode to another document", function(session)
  preview.auto_on()
  vim.cmd.new()
  local other = vim.api.nvim_get_current_buf()
  vim.bo[other].filetype = "markdown"
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { "## Other", "", "Body" })
  preview.auto_off()
  assert(vim.b[session.source_bufnr].md_render_auto, "auto off changed the previous document")
  assert(vim.api.nvim_get_current_buf() == other, "auto off rendered an unrelated buffer")
  preview.auto_on()
  assert(vim.b[other].md_render_auto, "auto on targeted the previous document")
  assert(
    vim.api.nvim_get_current_buf() == preview._toggle_sessions[other].buf,
    "auto on did not render the new document"
  )
  preview.auto_off()
  vim.api.nvim_buf_delete(other, { force = true })
end)

assert(failures == 0, failures .. " preview window tests failed")
print "preview_window_test: 4 passed"
