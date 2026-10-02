-- Decode with an installed tool; nil means unavailable, false means invalid.
return function(path)
  local file = assert(io.open(path, "rb"))
  local signature = file:read(8)
  file:close()
  if signature ~= "\137PNG\r\n\26\n" then return false, "invalid PNG signature" end

  local command, output
  if vim.fn.executable "magick" == 1 then
    command = { "magick", path, "null:" }
  elseif vim.fn.executable "convert" == 1 then
    command = { "convert", path, "null:" }
  elseif vim.fn.executable "sips" == 1 then
    output = vim.fn.tempname() .. ".png"
    command = { "sips", "-s", "format", "png", path, "--out", output }
  else
    return nil, "PNG decoding requires ImageMagick (magick/convert) or sips"
  end
  local result = vim.system(command, { text = true, timeout = 10000 }):wait()
  if output then vim.fn.delete(output) end
  return result.code == 0, result.stderr
end
