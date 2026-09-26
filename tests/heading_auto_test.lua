-- Policy decisions and failed async work must remain bounded and retryable.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local size = require "md-render.text_size"
assert(size.config().enabled and size.config().backend == "auto", "automatic headings are the default")
local image = require "md-render.image"
local layout = require "md-render.heading_layout"
local Builder = require("md-render.content_builder").ContentBuilder
vim.o.termguicolors = true
local native, probe, cells = true, { supported = true }, { cell_w = 19, cell_h = 44 }
local native_checks, image_checks = 0, 0
size.supports = function()
  native_checks = native_checks + 1
  return native
end
image.png_status = function()
  image_checks = image_checks + 1
  return probe
end
image.get_cell_size = function()
  return cells
end
size.setup { backend = "auto" }
assert(size.resolve_backend() == "image" and native_checks == 0)
native = false
assert(size.resolve_backend() == "image", "PNG must not depend on OSC 66")
probe = { reason = "waiting" }
native_checks = 0
assert(size.resolve_backend() == "plain" and native_checks == 0, "pending PNG leaves plain text without a second probe")
probe = { supported = false, reason = "PNG unavailable" }
assert(size.resolve_backend() == "plain")
native = true
assert(size.resolve_backend() == "native")
assert(size.status() == "auto -> native: PNG unavailable")
size.setup { backend = "image" }
assert(size.resolve_backend() == "plain", "explicit image must not silently become native")
size.setup { backend = "native" }
image_checks = 0
assert(size.resolve_backend() == "native" and image_checks == 0)
size.setup { backend = "auto", enabled = false }
native_checks = 0
assert(size.resolve_backend() == "plain" and image_checks == 0 and native_checks == 0)
size.setup { enabled = true }
probe, cells = { supported = true }, nil
assert(size.resolve_backend() == "native")
cells = { cell_w = 19, cell_h = 44 }
vim.o.termguicolors = false
assert(size.resolve_backend() == "native")
vim.o.termguicolors = true

local function build(text)
  local builder = Builder.new()
  builder:render_document({ "Body", "## " .. text }, { max_width = 80, indent = "  " })
  return builder:result()
end
local jobs, rebuilds, warnings = {}, {}, 0
package.loaded["md-render.preview"] = {
  rebuild_visible = function(batch)
    rebuilds[#rebuilds + 1] = batch or "all"
  end,
}
vim.notify_once = function()
  warnings = warnings + 1
end
local system = vim.system
vim.system = function(cmd, opts, callback)
  assert(opts.timeout == 5000)
  local job = { python = cmd[1], callback = callback, requests = vim.json.decode(opts.stdin).requests }
  jobs[#jobs + 1] = job
  return {
    kill = function() end,
  }
end
local function wait_for(fn)
  assert(vim.wait(1000, fn, 5))
end
local pending = build "First"
assert(pending.heading_backend == "image" and #pending.text_placements == 0)
wait_for(function()
  return #jobs == 1
end)
jobs[1].callback { code = 1, stderr = "Pango is unavailable" }
wait_for(function()
  return layout.failure "python3" ~= nil
end)
assert(rebuilds[#rebuilds] == "all" and warnings == 0, "auto fails quietly and updates every preview")
local fallback = build "First"
assert(fallback.heading_backend == "native" and #fallback.text_placements == 1)
build "Another heading"
assert(#jobs == 1, "cached environment failure must not spawn once per heading")
assert(size.status():find("Pango is unavailable", 1, true))
native = false
assert(build("First").heading_backend == "plain")

-- A supported local fallback (e.g. missing glyphs) must not disable image
-- rendering for the rest of the document or change the configured policy.
size.retry_image()
local local_fallback = build "Missing glyph"
wait_for(function()
  return #jobs == 2
end)
local request = jobs[2].requests[1]
local text = request.entries[1].text
jobs[2].callback {
  code = 0,
  stdout = vim.json.encode {
    {
      lines = {
        {
          start = 0,
          ["end"] = #text,
          text = text,
          cols = 20,
          fallback = "missing glyph",
        },
      },
    },
  },
}
wait_for(function()
  for _, entry in pairs(local_fallback.heading_layouts) do
    if not entry.ready then return false end
  end
  return true
end)
assert(layout.failure "python3" == nil and size.resolve_backend() == "image")
assert(#build("Missing glyph").text_placements == 0)

layout.retry_failed()
vim.system = system
print "Auto headings: independent capabilities, bounded failures, local fallback and retry OK"
