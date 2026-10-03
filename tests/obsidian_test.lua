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

-- One bounded fallback index serves both repeated and different misses. Expiry
-- must discover files created during the real session, without reset_cache().
local hrtime, fs_dir = vim.uv.hrtime, vim.fs.dir
local now, scans = hrtime(), 0
vim.uv.hrtime = function()
  return now
end
vim.fs.dir = function(path, opts)
  if path == root then scans = scans + 1 end
  return fs_dir(path, opts)
end
obsidian.reset_cache()
for i = 1, 25 do
  assert(obsidian.resolve("later.png", one) == nil)
  assert(obsidian.resolve("missing" .. i .. ".png", two) == nil)
end
assert(scans == 1, "missing names repeatedly scanned the vault")
vim.fn.writefile({ "new" }, root .. "/a/later.png")
assert(obsidian.resolve("later.png", one) == nil, "negative results must share the bounded cache")
now = now + 31 * 1000000000
assert(obsidian.resolve("later.png", one) == root .. "/a/later.png", "expiry did not discover a new attachment")
assert(scans == 2, "expired fallback did not rebuild exactly once")

-- Direct attachment locations are checked even while the fallback is cached.
vim.fn.writefile({ '{"attachmentFolderPath":"./attachments"}' }, root .. "/.obsidian/app.json")
now = now + 31 * 1000000000
assert(obsidian.resolve("later.png", one) == root .. "/a/later.png")
vim.fn.writefile({ "preferred" }, one .. "/attachments/later.png")
assert(
  obsidian.resolve("later.png", one) == one .. "/attachments/later.png",
  "cached fallback hid a new local attachment"
)
assert(obsidian.resolve("later.png", two) == root .. "/a/later.png", "attachment precedence crossed source directories")

local entries = 0
vim.fs.dir = function()
  scans = scans + 1
  return function()
    entries = entries + 1
    return "entry" .. entries .. ".png", "file"
  end
end
obsidian.reset_cache()
assert(obsidian.resolve("absent.png", one) == nil)
assert(entries == 10001, "fallback exceeded its entry budget")
local before = scans
assert(obsidian.resolve("another.png", two) == nil)
assert(scans == before and entries == 10001, "distinct misses restarted an exhausted scan")
assert(obsidian.resolve("a/same.png", one) == root .. "/a/same.png", "bounded discovery broke explicit paths")
assert(obsidian.resolve("same.png", one) == one .. "/attachments/same.png", "bounded discovery broke attachments")

entries = 0
obsidian.reset_cache()
vim.uv.hrtime = function()
  now = now + 10 * 1000000
  return now
end
assert(obsidian.resolve("absent.png", one) == nil)
assert(entries > 0 and entries <= 5, "fallback ignored its elapsed-time budget")
vim.uv.hrtime, vim.fs.dir = hrtime, fs_dir

-- Native recursive iterators can open every queued empty directory without
-- yielding another entry. Check the budget before directory opens as well.
local empty_root = vim.fn.tempname()
vim.fn.mkdir(empty_root .. "/.obsidian", "p")
for i = 1, 150 do
  vim.fn.mkdir(empty_root .. "/empty-" .. i, "p")
end
local scandir, opens = vim.uv.fs_scandir, 0
now = hrtime()
local start = now
vim.uv.hrtime = function()
  return now
end
vim.uv.fs_scandir = function(path, ...)
  opens = opens + 1
  if path ~= empty_root then now = now + 10 * 1000000 end
  return scandir(path, ...)
end
assert(obsidian.resolve("missing.png", empty_root) == nil)
assert(opens <= 6 and now - start <= 50 * 1000000, "empty directories bypassed the scan deadline")
vim.uv.hrtime, vim.uv.fs_scandir = hrtime, scandir
vim.fn.delete(empty_root, "rf")

-- Oversized/invalid configuration must retain fallback, and a growing file
-- must not turn the bounded read into a full-file allocation.
local config_path = root .. "/.obsidian/app.json"
local fs_read, fs_stat = vim.uv.fs_read, vim.uv.fs_stat
local read_bytes, reads = 0, 0
vim.uv.fs_read = function(fd, size, offset)
  reads = reads + 1
  read_bytes = read_bytes + size
  return fs_read(fd, size, offset)
end
vim.fn.writefile({ '{"padding":"' .. string.rep("x", 2 * 1024 * 1024) .. '"}' }, config_path)
obsidian.reset_cache()
assert(obsidian.resolve("same.png", one), "oversized configuration disabled vault fallback")
assert(reads == 0, "known oversized configuration was read")
vim.uv.fs_stat = function(path)
  local stat = fs_stat(path)
  if path == config_path and stat then stat.size = 1 end
  return stat
end
obsidian.reset_cache()
assert(obsidian.resolve("same.png", one), "growing configuration disabled vault fallback")
assert(reads == 1 and read_bytes == 1024 * 1024 + 1, "growing configuration was not read with a byte limit")
vim.uv.fs_read, vim.uv.fs_stat = fs_read, fs_stat
vim.fn.writefile({ "{invalid json" }, config_path)
obsidian.reset_cache()
assert(obsidian.resolve("same.png", one), "malformed configuration disabled vault fallback")
vim.fn.delete(root, "rf")
print "Obsidian resolution: bounded reads/scans, live cache expiry, explicit paths and attachment precedence OK"
