-- Optional real Mermaid/Puppeteer configuration-discovery regression.
-- nvim --headless -u NONE --noplugin -l tests/mermaid_security_integration.lua
local repo = vim.fn.getcwd()
package.path = repo .. "/lua/?.lua;" .. repo .. "/lua/?/init.lua;" .. package.path
local mmdc = vim.fn.exepath "mmdc"
if mmdc == "" then
  print "SKIP Mermaid configuration isolation: mmdc unavailable"
  return
end
local image = require "md-render.image"
local temp = vim.fn.tempname()
local doc, ancestor = temp .. "/document", temp .. "/temporary-ancestor"
vim.fn.mkdir(doc, "p")
vim.fn.mkdir(ancestor .. "/control", "p")
vim.fn.stdpath = function()
  return temp .. "/cache"
end
local marker = temp .. "/config-executed"
local script = 'require("node:fs").writeFileSync(' .. vim.json.encode(marker) .. ', "loaded"); module.exports = {};'
vim.fn.writefile({ script }, doc .. "/.puppeteerrc.cjs")
vim.fn.writefile({ script }, ancestor .. "/.puppeteerrc.cjs")
local input = temp .. "/input.mmd"
vim.fn.writefile({ "flowchart LR", "A --> B" }, input)
-- Fail before launching a browser: config discovery happens first and needs no network.
vim.env.PUPPETEER_EXECUTABLE_PATH = temp .. "/browser-intentionally-unavailable"
vim.env.PUPPETEER_SKIP_DOWNLOAD = "true"
vim.env.PUPPETEER_CACHE_DIR = temp .. "/browser-cache"
for _, cwd in ipairs { doc, ancestor .. "/control" } do
  vim.system({ mmdc, "-i", input, "-o", temp .. "/control.png" }, { cwd = cwd, timeout = 10000 }):wait()
  assert(vim.fn.filereadable(marker) == 1, "control did not exercise Puppeteer's executable config discovery")
  vim.fn.delete(marker)
end
vim.api.nvim_set_current_dir(doc)
local serial = 0
vim.fn.tempname = function()
  serial = serial + 1
  return ancestor .. "/job-" .. serial
end
image.setup { mermaid_allow_npx = false }
assert(image.has_mmdc())
assert(image.render_mermaid "flowchart LR\nA --> B" == nil, "invalid browser path unexpectedly rendered")
assert(vim.fn.filereadable(marker) == 0, "synchronous render executed project/ancestor configuration")
local done = false
image.render_mermaid_async("flowchart LR\nB --> C", function(path)
  assert(path == nil)
  done = true
end)
assert(vim.wait(15000, function()
  return done
end))
assert(vim.fn.filereadable(marker) == 0, "asynchronous render executed project/ancestor configuration")
for _, name in ipairs(vim.fn.readdir(ancestor)) do
  assert(not name:match "^job%-", "Mermaid job directory leaked")
end
vim.api.nvim_set_current_dir(repo)
vim.fn.delete(temp, "rf")
print "Mermaid isolation: document and temporary-ancestor controls execute; private sync/async jobs do not"
