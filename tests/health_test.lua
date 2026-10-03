package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local messages = {}
for _, level in ipairs { "start", "info", "ok", "warn", "error" } do
  vim.health[level] = function(message)
    messages[#messages + 1] = level .. ": " .. message
  end
end
vim.fn.executable = function()
  return 0
end
vim.api.nvim_list_uis = function()
  return {}
end
vim.system = function()
  error "native headings must not start Python or probe a terminal"
end
local image = require "md-render.image"
image.has_plantuml = function()
  return false
end
image.supports_kitty = function()
  error "headless health must not probe a terminal"
end
require("md-render.text_size").setup { backend = "native" }
require("md-render.health").check()
local report = table.concat(messages, "\n")
assert(report:find("No attached UI", 1, true), report)
assert(report:find("magick unavailable", 1, true), report)
assert(report:find("Mermaid CLI unavailable", 1, true), report)
assert(report:find("Mermaid npx fallback: false", 1, true), report)
assert(not report:find("error:", 1, true), report)
messages = {}
vim.fn.executable = function(name)
  return name == "npx" and 1 or 0
end
require("md-render.health").check()
report = table.concat(messages, "\n")
assert(not report:find("may download and run", 1, true), "npx availability is not permission")
image.setup { mermaid_allow_npx = true }
messages = {}
require("md-render.health").check()
report = table.concat(messages, "\n")
assert(report:find("may download and run", 1, true), report)
print "Health: optional dependencies degrade clearly, native mode has no Python or terminal side effects"
