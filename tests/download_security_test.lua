-- Literal URL handling and atomic publication for built-in/custom media downloads.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local image = require "md-render.image"
local uv = vim.uv or vim.loop
local temp = vim.fn.tempname()
vim.fn.stdpath = function()
  return temp
end
vim.fn.mkdir(temp, "p")
local fixture = assert(io.open("tests/fixtures/test_4x4.png", "rb"))
local png = fixture:read "*a"
fixture:close()
local function write(path, data)
  local f = assert(io.open(path, "wb"))
  f:write(data)
  f:close()
end
local jobs, fail_spawn, messages = {}, false, {}
vim.notify = function(message)
  messages[#messages + 1] = message
end
vim.notify_once = vim.notify
vim.system = function(cmd, opts, callback)
  assert(cmd[1] == "curl" and cmd[2] == "-q" and vim.tbl_contains(cmd, "--globoff"))
  assert(cmd[#cmd - 1] == "--")
  local output, seconds
  for i, arg in ipairs(cmd) do
    if arg == "-o" then output = cmd[i + 1] end
    if arg == "--max-time" then seconds = tonumber(cmd[i + 1]) end
    if arg == "--proto" or arg == "--proto-redir" then assert(cmd[i + 1] == "=http,https") end
  end
  assert(opts.timeout == seconds * 1000 + 1000)
  write(output, png:sub(1, 24)) -- enough of a PNG header to fool the old cache-first path
  jobs[#jobs + 1] = { output = output, callback = callback, url = cmd[#cmd] }
  if fail_spawn then error "controlled spawn failure" end
  return { pid = 0 }
end
local function wait_for(predicate)
  assert(vim.wait(2000, predicate, 5))
end
local function receiver()
  local values, reasons = {}, {}
  local function receive(path, reason)
    values[#values + 1] = path or false
    reasons[#values] = reason or false
  end
  return values, receive, reasons
end
local function cache_path(url)
  return image.cache_dir() .. "/images/" .. vim.fn.sha256(url):sub(1, 16) .. ".png"
end
for _, video in ipairs { false, true } do
  local download = video and image.download_video_async or image.download_async
  local cached = video and image.get_video_cached or image.get_cached
  local url = "https://example.invalid/{a,b}[1-3]-" .. tostring(video) .. ".png"
  local values, receive, reasons = receiver()
  local before = #jobs
  download(url, receive)
  wait_for(function()
    return #jobs == before + 1
  end)
  local job = jobs[#jobs]
  assert(job.url == url, "URL was transformed before reaching curl")
  assert(not cached(url) and vim.fn.filereadable(cache_path(url)) == 0, "partial output reached cache")
  download(url, receive)
  vim.wait(10)
  assert(#values == 0 and #jobs == before + 1, "second reader did not join pending download")
  job.callback { code = 124, signal = 0 }
  wait_for(function()
    return #values == 2
  end)
  assert(not values[1] and not values[2] and vim.fn.filereadable(job.output) == 0)
  assert(reasons[1] == "curl exit 124" and reasons[2] == reasons[1], "both waiters need the same download error")
  assert(messages[#messages]:find("(exit 124): no error details", 1, true), messages[#messages])
  local success_args
  download(url, function(...)
    success_args = select("#", ...)
    receive(...)
  end)
  wait_for(function()
    return #jobs == before + 2
  end)
  job = jobs[#jobs]
  write(job.output, png)
  job.callback { code = 0 }
  wait_for(function()
    return #values == 3
  end)
  assert(values[3] == cache_path(url) and cached(url) == values[3])
  assert(success_args == 1, "successful downloads should still call back with just the path")
  assert(vim.fn.filereadable(job.output) == 0)

  local peer_url = "https://example.invalid/peer-" .. tostring(video) .. ".png"
  download(peer_url, receive)
  wait_for(function()
    return #jobs == before + 3
  end)
  local failed = jobs[#jobs]
  write(cache_path(peer_url), png) -- another process completes while this writer is pending
  failed.callback { code = 7, stderr = "curl: (7) Failed to connect to the test server\n" }
  wait_for(function()
    return #values == 4
  end)
  assert(not values[4] and vim.fn.filereadable(failed.output) == 0)
  assert(reasons[4] == "could not connect")
  assert(messages[#messages]:find("Failed to connect to the test server", 1, true), messages[#messages])
  assert(cached(peer_url) == cache_path(peer_url), "failed writer deleted its peer's completed output")
end

-- Image and video readers can join one transfer, but use different limits.
do
  local url = "https://example.invalid/shared-mode.png"
  local failures, peer_failures, before = {}, {}, #jobs
  local values, receive, reasons = receiver()
  image.download_async(url, receive) -- a different caller starts the smaller transfer
  image.download_video_async(url, receive, failures)
  image.download_video_async(url, receive, peer_failures)
  wait_for(function()
    return #jobs == before + 1
  end)
  jobs[#jobs].callback { code = 63 }
  wait_for(function()
    return #values == 3
  end)
  assert(reasons[1] == "file too large" and reasons[2] == reasons[1] and reasons[3] == reasons[1])
  image.download_async(url, receive, failures)
  assert(reasons[4] == "file too large" and #jobs == before + 1)
  image.download_video_async(url, receive, peer_failures)
  wait_for(function()
    return #jobs == before + 2
  end)
  image.download_async(url, receive, failures)
  assert(#values == 4, "a reader replayed its previous failure instead of waiting for the peer")
  write(jobs[#jobs].output, png)
  jobs[#jobs].callback { code = 0 }
  wait_for(function()
    return #values == 6
  end)
  assert(values[5] == cache_path(url) and values[6] == values[5])
  assert(not next(failures) and not next(peer_failures), "the completed transfer left a stale failure")
  image.download_async(url, receive, failures)
  assert(values[7] == cache_path(url) and #jobs == before + 2, "a remembered failure hid the completed file")
end

fail_spawn = true
local values, receive, reasons = receiver()
image.download_async("https://example.invalid/spawn.png", receive)
wait_for(function()
  return #values == 1
end)
assert(not values[1] and vim.fn.filereadable(jobs[#jobs].output) == 0, "spawn failure leaked staging output")
assert(reasons[1] == "could not run curl")
fail_spawn = false
for i, result in ipairs {
  { code = 28, stdout = "200" },
  { code = 124, signal = 15 },
  { code = 124, signal = 9 },
} do
  local before = #jobs
  image.download_async("https://example.invalid/spawn.png", receive)
  wait_for(function()
    return #jobs == before + 1
  end)
  jobs[#jobs].callback(result)
  wait_for(function()
    return #values == i + 1
  end)
  assert(reasons[i + 1] == "timed out", vim.inspect(result))
  assert(messages[#messages]:find("(exit " .. result.code .. "): timed out", 1, true), messages[#messages])
end

local custom_calls, stage, complete = 0, nil, nil
image.set_download_fn(function(_, output, callback)
  custom_calls = custom_calls + 1
  stage, complete = output, callback
  assert(output:sub(1, 1) == "/" and output:match "%.png$", "custom output must remain absolute and preserve suffix")
  write(output, png)
  return true
end)
local custom_url = "https://example.invalid/custom.png"
values, receive = receiver()
image.download_async(custom_url, receive)
image.download_async(custom_url, receive)
wait_for(function()
  return custom_calls == 1
end)
assert(#values == 0 and not image.get_cached(custom_url))
complete(true)
wait_for(function()
  return #values == 2
end)
assert(values[1] == values[2] and values[1] ~= stage and image.get_cached(custom_url) == values[1])
assert(vim.fn.filereadable(stage) == 0)
values, receive, reasons = receiver()
local failed_url, failures = "https://example.invalid/custom-fail.png", {}
image.download_video_async(failed_url, receive, failures)
wait_for(function()
  return custom_calls == 2
end)
complete(false)
wait_for(function()
  return #values == 1
end)
assert(not values[1] and not reasons[1] and vim.fn.filereadable(stage) == 0)
assert(messages[#messages]:find("custom media downloader reported failure", 1, true))
image.download_video_async(failed_url, function(...)
  assert(select("#", ...) == 1, "a remembered generic failure should still call back with just nil")
  receive(...)
end, failures)
assert(#values == 2 and not reasons[2] and custom_calls == 2, "a generic download failure was retried")
image.set_download_fn(function(_, output)
  custom_calls = custom_calls + 1
  stage = output
  write(output, png)
  error "controlled custom downloader failure"
end)
values, receive, reasons = receiver()
image.download_async("https://example.invalid/custom-throw.png", receive)
wait_for(function()
  return #values == 1
end)
assert(not values[1] and not reasons[1] and vim.fn.filereadable(stage) == 0)
local process_count = #jobs
for _, url in ipairs { "file:///tmp/a", "ftp://example.invalid/a", "https://example.invalid/\n-a", "http://a/\0", 123 } do
  values, receive = receiver()
  image.download_async(url, receive)
  image.download_video_async(url, receive)
  assert(#values == 2 and not values[1] and not values[2])
end
assert(custom_calls == 3 and #jobs == process_count, "invalid URLs caused downloader side effects")
image.set_download_fn(function(_, output, callback)
  write(output, "\0\0\0\x18ftypmp42\0\0\0\0")
  callback(true)
  return true
end)
values, receive = receiver()
image.download_async("https://example.invalid/video-as-image.png", receive)
wait_for(function()
  return #values == 1
end)
assert(values[1] and values[1]:match "%.mp4$", "video content lost its corrected published extension")
image.set_download_fn(nil)

-- A successful transfer can still return an empty file, a login page or an
-- output that cannot be published. Shared readers receive one useful reason.
for _, video in ipairs { false, true } do
  for _, outcome in ipairs { "missing", "empty", "invalid", "rename" } do
    if not video or outcome ~= "invalid" then
      messages = {}
      local url = "https://example.invalid/" .. outcome .. "-" .. tostring(video) .. ".png"
      local download = video and image.download_video_async or image.download_async
      local before = #jobs
      values, receive = receiver()
      download(url, receive)
      download(url, receive)
      wait_for(function()
        return #jobs == before + 1
      end)
      local job = jobs[#jobs]
      local expected
      if outcome == "missing" then
        os.remove(job.output)
        expected = "download produced no file"
      elseif outcome == "empty" then
        write(job.output, "")
        expected = "download produced an empty file"
      elseif outcome == "invalid" then
        write(job.output, "<html>Sign in to view this image</html>")
        expected = "not a supported image or video"
      else
        write(job.output, png)
        expected = "could not publish downloaded media to the cache: EACCES"
      end
      local rename = uv.fs_rename
      if outcome == "rename" then
        uv.fs_rename = function()
          return nil, "EACCES: controlled cache permission failure"
        end
      end
      job.callback { code = 0 }
      wait_for(function()
        return #values == 2
      end)
      uv.fs_rename = rename
      assert(not values[1] and not values[2] and not image.get_cached(url))
      assert(vim.fn.filereadable(job.output) == 0 and vim.fn.filereadable(cache_path(url)) == 0)
      assert(#messages == 1 and messages[1]:find(expected, 1, true), vim.inspect(messages))
      assert(messages[1]:find(":checkhealth md-render", 1, true))
    end
  end
end

for _, in_memory in ipairs { false, true } do
  local url = "https://example.invalid/stale-reader-" .. tostring(in_memory) .. ".png"
  local path = cache_path(url)
  if in_memory then
    write(path, png)
    assert(image.get_cached(url) == path)
  end
  write(path, "legacy incomplete image")
  local is_video_content, published = image.is_video_content, false
  image.is_video_content = function(input)
    local recognized = is_video_content(input)
    if input == path then
      assert(not recognized)
      -- A peer finishes after this reader saw invalid bytes, before its miss returns.
      write(path .. ".peer", png)
      assert(uv.fs_rename(path .. ".peer", path))
      published = true
    end
    return recognized
  end
  local stale = image.get_cached(url)
  image.is_video_content = is_video_content
  assert(published and not stale)
  assert(image.image_dimensions(path) == 4, "stale reader deleted its peer's completed cache")
  assert(image.get_cached(url) == path, "reader did not discover the completed replacement")
end
vim.fn.delete(temp, "rf")
print "Downloads: literal URLs, staged built-in/custom publication, bounded jobs, validation, and failure cleanup passed"
