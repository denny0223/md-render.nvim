-- Literal media paths.
-- Run: nvim --headless -u NONE --noplugin -l tests/media_policy_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local image = require "md-render.image"
local uv = vim.uv or vim.loop
local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. "/.obsidian", "p")
vim.fn.mkdir(temp .. "/notes", "p")
local original = {
  expand = vim.fn.expand,
  executable = vim.fn.executable,
  system = vim.system,
  stdpath = vim.fn.stdpath,
  os_homedir = uv.os_homedir,
  ui_send = vim.api.nvim_ui_send,
}
local function file(name, data)
  local path = temp .. "/" .. name
  local f = assert(io.open(path, "wb"))
  f:write(data or "test")
  f:close()
  return path
end

-- These are literal filenames, including text that expand() interprets as Vim syntax.
vim.fn.expand = function()
  error "document media paths must not call expand()"
end
local names = { "空 白.png", "`=1 + 1`.png", "$MEDIA_ASSET.png", "%#.png", "-image.png" }
if vim.fn.has "win32" == 0 then names[#names + 1] = "file\nname.png" end
for _, name in ipairs(names) do
  local path = file(name)
  assert(image.resolve_local(name, temp) == path, name)
  assert(image.resolve(name, temp) == path, name)
  assert(image.resolve_local(path, temp .. "/notes") == path, name)
end
uv.os_homedir = function()
  return temp
end
assert(image.resolve_local("~/空 白.png", temp .. "/notes") == temp .. "/空 白.png")
assert(image.resolve_local("空 白.png", temp .. "/notes") == temp .. "/空 白.png", "vault fallback")
for _, path in ipairs { "", "a\0.png", "file:///tmp/a.png", "data:image/png,a", "ftp://host/a.png" } do
  assert(image.resolve_local(path, temp) == nil, "invalid local source: " .. vim.inspect(path))
end
assert(not image.is_url "https://example.test/a\n.png", "reject URL control characters too")
assert(image.is_url "HTTPS://example.test/a.png", "HTTP scheme is case insensitive")
assert(image.resolve_local "tests/fixtures/test_4x4.png" == vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png")
vim.fn.expand, uv.os_homedir = original.expand, original.os_homedir

vim.fn.executable, vim.fn.stdpath = original.executable, original.stdpath
vim.system, vim.api.nvim_ui_send = original.system, original.ui_send
image.reset_cache()
vim.fn.delete(temp, "rf")
print "media_policy_test: literal paths passed"
