package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local image = require "md-render.image"
local file = vim.fn.tempname() .. ".svg"
for _, case in ipairs {
  { [[<svg width="1200" height="760" viewBox="0 0 1200 760"></svg>]], 1200, 760 },
  { [[<svg width='120px' height='40px'></svg>]], 120, 40 },
  { [[<svg stroke-width="2" width="600" data-height="8" height="400"></svg>]], 600, 400 },
  { [[<svg data-width="2" data-height="8" data-viewBox="0 0 1 2" viewBox="0 0 300 150"></svg>]], 300, 150 },
  { [[<svg width="100%" viewBox="0 0 300 150"></svg>]], 300, 150 },
  { [[<svg width="0" height="-5"></svg>]] },
  { [[<html width="20" height="10"></html>]] },
} do
  vim.fn.writefile({ case[1] }, file)
  local w, h = image.image_dimensions(file)
  assert(w == case[2] and h == case[3], vim.inspect { w, h, case })
end
vim.fn.delete(file)
print "SVG dimensions and viewBox fallback OK"
