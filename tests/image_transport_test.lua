-- PNG bytes must survive a TTY without access to the renderer's filesystem.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. package.path
local image = require "md-render.image"
image.supports_kitty = function()
  return true
end
local chunks = {}
vim.api.nvim_ui_send = function(data)
  chunks[#chunks + 1] = data
end
local png = "\137PNG\r\n\26\n" .. string.rep("pixels", 2100)
local encoded = vim.base64.encode(png)
local id = assert(image.transmit_png(encoded))
assert(table.remove(chunks, 1):find("a=d,d=A", 1, true), "initialize before the first heading transmission")
local payloads = {}
assert(#chunks > 1)
for index, chunk in ipairs(chunks) do
  local params, payload = chunk:match "^\27_G([^;]+);(.*)\27\\$"
  assert(params and #payload <= 4096)
  assert(params:find(index == #chunks and "m=0" or "m=1", 1, true))
  if index == 1 then assert(params:find("t=d,i=" .. id, 1, true)) end
  payloads[#payloads + 1] = payload
end
assert(vim.base64.decode(table.concat(payloads)) == png)
assert(image.transmit_png "" == nil)

-- An ordinary image may be opened after a heading-only preview. Its setup
-- must not delete the live heading data or recycle the heading's ID.
chunks = {}
image.clear_all()
local ensure_png = image.ensure_png
image.ensure_png = function(path)
  return path, false
end
local body_id = assert(image.transmit_image "/tmp/heading-transport-body.png")
assert(body_id ~= id, "headings and later body images must own distinct IDs")
assert(#chunks == 1 and not chunks[1]:find("a=d,d=A", 1, true), "later setup must not delete live headings")
image.ensure_png = ensure_png

-- The optional backend can already own images when a heading first appears.
-- Avoid a global delete, including if the backend is subsequently changed.
image.reset_cache()
image.setup { backend = "snacks" }
chunks = {}
local snacks_id = assert(image.transmit_png(encoded))
for _, chunk in ipairs(chunks) do
  assert(not chunk:find("a=d,d=A", 1, true), "heading initialization must preserve Snacks images")
end
image.setup { backend = "kitty" }
chunks = {}
image.clear_all()
local next_id = assert(image.transmit_png "YWJj")
assert(next_id > snacks_id and #chunks == 1, "backend changes must not reset live heading IDs")
print "Heading transport: lossless chunked PNG data without file paths OK"

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
local term = vim.env.TERM_PROGRAM
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
print "TTY identity: cached SSH-safe response and native version gate OK"
