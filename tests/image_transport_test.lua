package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. package.path
-- A remote Kitty need not export terminal-specific environment hints. Both
-- renderers reuse a real response, while native text keeps its version gate.
local tty = require "md-render.tty"
local size = require "md-render.text_size"
local list_uis, send = vim.api.nvim_list_uis, vim.api.nvim_ui_send
vim.api.nvim_list_uis = function()
  return { {} }
end
local queries = 0
vim.api.nvim_ui_send = function(data)
  assert(data == "\27[>0q")
  queries = queries + 1
  vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27P>|kitty(0.45.0)\27\\" } })
end
tty.reset()
assert(vim.deep_equal(tty.kitty_version(), { 0, 45 }))
assert(vim.deep_equal(tty.kitty_version(), { 0, 45 }) and queries == 1)
size.reset_cache()
local term, tmux = vim.env.TERM_PROGRAM, vim.env.TMUX
vim.env.TMUX = nil
vim.env.TERM_PROGRAM = nil
assert(size.supports())
assert(queries == 2)
tty.reset()
vim.api.nvim_ui_send = function()
  vim.api.nvim_exec_autocmds("TermResponse", { data = { sequence = "\27P>|kitty(0.39.0)\27\\" } })
end
size.reset_cache()
assert(not size.supports() and vim.deep_equal(tty.kitty_version(), { 0, 39 }))
vim.api.nvim_list_uis, vim.api.nvim_ui_send, vim.env.TERM_PROGRAM = list_uis, send, term
vim.env.TMUX = tmux
print "TTY identity: cached SSH-safe response and native version gate OK"
