-- Bounded metadata/conversion work and completed, immutable frame caches.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local image = require "md-render.image"
local uv = vim.uv or vim.loop
local fixture = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"

-- Independent Neovim processes emulate decoders that pause after their first
-- frame. Their real filesystem publications race, rather than sharing Lua state.
if arg[1] == "frame-worker" then
  local source, cache, ready, release, result, outcome = unpack(arg, 2)
  vim.fn.stdpath = function()
    return cache
  end
  vim.fn.executable = function(cmd)
    return cmd == "ffmpeg" and 1 or 0
  end
  vim.notify_once = function() end
  vim.system = function(cmd, opts, callback)
    assert(opts.timeout == 30000)
    local first = cmd[#cmd]:gsub("%%04d", "0001")
    assert(uv.fs_copyfile(fixture, first))
    vim.fn.writefile({ vim.fs.dirname(first) }, ready)
    assert(
      vim.wait(15000, function()
        return vim.fn.filereadable(release) == 1
      end, 5),
      "parent did not release decoder"
    )
    if outcome == "success" then assert(uv.fs_copyfile(fixture, first:gsub("0001.png$", "0002.png"))) end
    vim.schedule(function()
      callback { code = outcome == "success" and 0 or 124, stderr = "test timeout" }
    end)
    return {}
  end
  local done
  image.extract_frames_async(source, function(frames)
    vim.fn.writefile(frames or { "failed" }, result)
    done = true
  end)
  assert(
    vim.wait(20000, function()
      return done
    end, 5),
    "worker callback was lost"
  )
  return
end

local temp = vim.fn.tempname()
vim.fn.mkdir(temp, "p")
local function file(name, data)
  local path = temp .. "/" .. name
  local f = assert(io.open(path, "wb"))
  f:write(data or "source")
  f:close()
  return path
end
local function segment(marker, data)
  local length = #data + 2
  return string.char(255, marker, math.floor(length / 256), length % 256) .. data
end
local function sof(marker)
  return segment(marker or 0xC0, string.char(8, 0, 12, 0, 34, 1, 1, 0x11, 0))
end
local soi = "\255\216"
for _, marker in ipairs { 0xC0, 0xC2 } do
  local path = file("jpeg-" .. marker, soi .. segment(0xE1, "metadata") .. "\255" .. sof(marker))
  local f = assert(io.open(path, "ab"))
  f:seek("set", 64 * 1024 * 1024)
  f:write "x"
  f:close()
  local open, read_bytes, closes = io.open, 0, 0
  io.open = function(name, mode)
    local handle = open(name, mode)
    if name ~= path or not handle then return handle end
    return {
      read = function(_, n)
        assert(type(n) == "number" and n <= 6, "JPEG read must only consume short marker headers")
        read_bytes = read_bytes + n
        return handle:read(n)
      end,
      seek = function(_, ...)
        return handle:seek(...)
      end,
      close = function()
        closes = closes + 1
        handle:close()
      end,
    }
  end
  local width, height = image.image_dimensions(path)
  io.open = open
  assert(width == 34 and height == 12 and read_bytes < 40 and closes == 2, "bounded baseline/progressive JPEG")
end
for i, data in ipairs {
  soi .. "\255\225\0\1" .. sof(), -- invalid length
  soi .. "\255\225\0\20short", -- truncated segment
  soi .. "\255\192\0\8short", -- truncated SOF
  soi .. string.rep("\255\1", 1024) .. sof(), -- marker budget
  soi .. string.rep("\255", 2048) .. sof(), -- fill-byte budget
  soi .. "\255\218" .. sof(), -- do not search entropy data for a false SOF
} do
  assert(image.image_dimensions(file("invalid-" .. i, data)) == nil, "malformed JPEG " .. i)
end
assert(image.image_dimensions(file("arithmetic", soi .. segment(0xCC, "not a SOF") .. sof())) == 34)
local metadata = file("metadata-budget", soi)
local f = assert(io.open(metadata, "r+b"))
f:seek "end"
for _ = 1, 257 do
  f:write "\255\225\255\255"
  f:seek("cur", 65533)
end
f:write(sof())
f:close()
assert(image.image_dimensions(metadata) == nil, "metadata span has a finite budget")

local stdpath, executable, system, notify = vim.fn.stdpath, vim.fn.executable, vim.system, vim.notify
vim.fn.stdpath = function()
  return temp
end
vim.fn.executable = function(cmd)
  return cmd == "ffmpeg" and 1 or 0
end
vim.notify = function() end
image.reset_cache()
for _, asynchronous in ipairs { false, true } do
  for _, outcome in ipairs { "timeout", "spawn", "invalid", "success" } do
    local output, calls, result, done
    calls = 0
    vim.system = function(cmd, opts, callback)
      assert(opts.timeout == 30000, "static conversion timeout")
      output = cmd[#cmd]
      assert(uv.fs_copyfile(fixture, output))
      if outcome == "spawn" then error "test spawn error" end
      if outcome == "invalid" then vim.fn.writefile({ "not PNG" }, output) end
      local answer = { code = outcome == "timeout" and 124 or 0 }
      if callback then vim.schedule(function()
        callback(answer)
      end) end
      return {
        wait = function()
          return answer
        end,
      }
    end
    local source = file("convert-" .. tostring(asynchronous) .. "-" .. outcome)
    if asynchronous then
      image.ensure_png_async(source, function(path, temporary)
        calls, result, done = calls + 1, path, true
        assert(not temporary)
      end)
      assert(
        vim.wait(2000, function()
          return done
        end, 5),
        "conversion callback lost"
      )
      assert(calls == 1)
    else
      result = image.ensure_png(source)
    end
    assert(output and vim.fn.filereadable(output) == 0, "conversion left a staging file")
    assert((result ~= nil) == (outcome == "success"), "conversion accepted failed or invalid output")
    if result then assert(image.image_dimensions(result) == 4) end
  end
end
for _, outcome in ipairs { "spawn", "changed" } do
  local source = file("extract-" .. outcome .. ".gif")
  local staging, done
  vim.system = function(cmd, _, callback)
    local output = cmd[#cmd]:gsub("%%04d", "0001")
    staging = vim.fs.dirname(output)
    assert(uv.fs_copyfile(fixture, output))
    if outcome == "spawn" then error "test extraction spawn error" end
    vim.fn.writefile({ "new source version" }, source)
    vim.schedule(function()
      callback { code = 0 }
    end)
    return {}
  end
  image.extract_frames_async(source, function(frames)
    assert(not frames, "failed/retired extraction published output")
    done = true
  end)
  assert(
    vim.wait(2000, function()
      return done
    end, 5),
    "extraction callback lost"
  )
  assert(staging and vim.fn.isdirectory(staging) == 0, "failed/retired extraction left staging output")
end
vim.system, vim.fn.executable, vim.notify = system, executable, notify
image.reset_cache()

for _, count in ipairs { 301, 602, 9001, 1000000000 } do
  local cmd = image._build_frame_extract_cmd("magick", "input.gif", "output", count)
  assert(#table.concat(cmd, " ") < 7000, "frame sampling argument grew with discarded frames")
  if count < 10000 then
    local removed = {}
    for token in cmd[5]:gmatch "[^,]+" do
      local first, last = token:match "^(%d+)%-(%d+)$"
      first, last = tonumber(first or token), tonumber(last or token)
      for n = first, last do
        removed[n] = true
      end
    end
    local step = math.ceil(count / 300)
    for n = 0, count - 1 do
      assert((removed[n] == nil) == (n % step == 0), "frame sampling changed")
    end
  end
end

local function await_file(path)
  assert(
    vim.wait(10000, function()
      return vim.fn.filereadable(path) == 1
    end, 5),
    "worker did not write " .. path
  )
end
local function worker(source, name, outcome)
  local ready, release, result =
    temp .. "/" .. name .. ".ready", temp .. "/" .. name .. ".release", temp .. "/" .. name .. ".result"
  local job = system({
    vim.v.progpath,
    "--headless",
    "-u",
    "NONE",
    "--noplugin",
    "-i",
    "NONE",
    "-l",
    "tests/media_resources_test.lua",
    "frame-worker",
    source,
    temp,
    ready,
    release,
    result,
    outcome,
  }, { text = true })
  await_file(ready)
  return { job = job, staging = vim.fn.readfile(ready)[1], release = release, result = result }
end
for _, loser_outcome in ipairs { "failure", "success" } do
  local source = file("race-" .. loser_outcome .. ".gif")
  local first = worker(source, loser_outcome .. "-first", loser_outcome)
  local final = first.staging:gsub("%.[^.]+$", "")
  assert(vim.fn.isdirectory(final) == 0, "partial frame cache became visible")
  local second = worker(source, loser_outcome .. "-second", "success")
  assert(first.staging ~= second.staging, "processes shared staging output")
  vim.fn.writefile({}, second.release)
  await_file(second.result)
  local peer = vim.fn.readfile(second.result)
  assert(#peer == 2 and peer[1]:find(final, 1, true) == 1, "peer cache not published completely")
  vim.fn.writefile({}, first.release)
  await_file(first.result)
  for _, pending in ipairs { first, second } do
    local exit = pending.job:wait(10000)
    assert(exit.code == 0, exit.stderr)
    assert(vim.fn.isdirectory(pending.staging) == 0, "staging directory leaked")
  end
  assert(vim.fn.filereadable(peer[1]) == 1 and vim.fn.filereadable(peer[2]) == 1, "late producer removed peer cache")
  local answer = vim.fn.readfile(first.result)
  assert(loser_outcome == "failure" and answer[1] == "failed" or vim.deep_equal(answer, peer), "collision result")
end

-- Compare actual decoded pixels after sampling an optimized multi-frame GIF.
if executable "magick" == 1 then
  local gif, out = temp .. "/sample.gif", temp .. "/sample-frames"
  vim.fn.mkdir(out, "p")
  local function run(cmd)
    local result = system(cmd, { text = true, timeout = 30000 }):wait()
    assert(result.code == 0, result.stderr)
    return result.stdout
  end
  run { "magick", "assets/demo/test_animated.gif", "-duplicate", "100,0-2", gif }
  local all = vim.split(vim.trim(run { "magick", gif, "-coalesce", "-format", "%#\n", "info:" }), "\n")
  assert(#all == 303)
  run(image._build_frame_extract_cmd("magick", gif, out, #all))
  local frames = vim.fn.glob(out .. "/frame_*.png", false, true)
  table.sort(frames)
  local cmd = vim.list_extend({ "magick" }, frames)
  vim.list_extend(cmd, { "-format", "%#\n", "info:" })
  local sampled = vim.split(vim.trim(run(cmd)), "\n")
  assert(#sampled == 152)
  for i, hash in ipairs(sampled) do
    assert(hash == all[(i - 1) * 2 + 1], "coalesced frame pixels changed")
  end
  vim.fn.executable = function(cmd)
    return cmd == "magick" and 1 or 0
  end
  image.reset_cache()
  local before = #vim.fn.glob(temp .. "/md-render/converted/*", false, true)
  local png = image.ensure_png "assets/demo/test_animated.gif"
  assert(png and image.image_dimensions(png) == 160, "ImageMagick static fallback must keep the first frame")
  assert(
    #vim.fn.glob(temp .. "/md-render/converted/*", false, true) == before + 1,
    "static conversion leaked extra frames"
  )
  vim.fn.executable = executable
else
  print "SKIP real ImageMagick sampling: magick unavailable"
end

vim.fn.stdpath = stdpath
vim.fn.delete(temp, "rf")
print "media_resources_test: bounded metadata, cleanup, sampling, and cross-process frame publication passed"
