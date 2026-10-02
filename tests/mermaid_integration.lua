-- Explicit external-tool check; never auto-installs a renderer or browser.
-- Run: nvim --headless -u NONE --noplugin -l tests/mermaid_integration.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
assert(vim.fn.executable "mmdc" == 1, "Mermaid integration requires mmdc and its browser")

local cache, stdpath = vim.fn.tempname(), vim.fn.stdpath
vim.fn.stdpath = function(kind)
  return kind == "cache" and cache or stdpath(kind)
end
local image = require "md-render.image"
local decode_png = dofile "tests/decode_png.lua"
local ok, err = pcall(function()
  local source = "graph TD\n  A[Cold cache] --> B[Real browser PNG]"
  assert(not image.get_mermaid_cached(source), "integration must force a cache miss")
  local done, png = false, nil
  image.render_mermaid_async(source, function(path)
    png, done = path, true
  end)
  assert(
    vim.wait(45000, function()
      return done
    end, 20),
    "real Mermaid render timed out"
  )
  assert(png and vim.fn.filereadable(png) == 1, "mmdc/browser failed to produce a PNG")
  local decoded, reason = decode_png(png)
  assert(decoded, "Mermaid PNG decoding failed: " .. (reason or ""))
  local width, height = image.image_dimensions(png)
  assert(width and height and width > 0 and height > 0, "Mermaid output is not a readable image")
  assert(image.get_mermaid_cached(source) == png, "successful render must enter the cache")
  print(string.format("Real Mermaid render: %dx%d PNG from cold cache", width, height))
end)
vim.fn.stdpath = stdpath
vim.fn.delete(cache, "rf")
assert(ok, err)
