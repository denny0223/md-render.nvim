-- Run: nvim --headless -u NONE --noplugin -i NONE -l tests/obsidian_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local obsidian = require "md-render.obsidian"
local root = vim.fn.tempname()
for _, dir in ipairs { ".obsidian", "a", "b", "notes/one/attachments", "notes/two/attachments" } do
  vim.fn.mkdir(root .. "/" .. dir, "p")
end
for _, file in ipairs { "a/same.png", "b/same.png", "notes/one/attachments/same.png", "notes/two/attachments/same.png" } do
  vim.fn.writefile({ file }, root .. "/" .. file)
end
vim.fn.writefile({ '{"attachmentFolderPath":"./attachments"}' }, root .. "/.obsidian/app.json")
local one, two = root .. "/notes/one", root .. "/notes/two"
for _ = 1, 2 do
  assert(obsidian.resolve("a/same.png", one) == root .. "/a/same.png", "full vault-relative path was discarded")
  assert(obsidian.resolve("b/same.png", one) == root .. "/b/same.png", "same basename reused the wrong path")
  assert(obsidian.resolve("missing/same.png", one) == nil, "missing explicit path fell back to a different image")
  assert(obsidian.resolve("same.png", one) == one .. "/attachments/same.png", "first note attachments failed")
  assert(obsidian.resolve("same.png", two) == two .. "/attachments/same.png", "relative attachment cache crossed notes")
end
assert(obsidian.resolve("./attachments/same.png", one) == one .. "/./attachments/same.png")
assert(
  require("md-render.image").resolve("b/same.png", one) == root .. "/b/same.png",
  "image fallback lost the vault path"
)
vim.fn.writefile({ '{"attachmentFolderPath":"."}' }, root .. "/.obsidian/app.json")
vim.fn.writefile({ "local" }, one .. "/local.png")
obsidian.reset_cache()
assert(obsidian.resolve("local.png", one) == one .. "/local.png", "current-directory attachment setting failed")
vim.fn.writefile({ '{"attachmentFolderPath":true}' }, root .. "/.obsidian/app.json")
obsidian.reset_cache()
assert(obsidian.resolve("same.png", one), "invalid attachment setting should retain short-name vault lookup")
vim.fn.delete(root, "rf")
print "Obsidian resolution: explicit paths, same-name attachments and source-scoped cache OK"
