-- Real Snacks integration; point MD_RENDER_SNACKS_PATH at an installed checkout.
local snacks_path = vim.env.MD_RENDER_SNACKS_PATH
if not snacks_path or snacks_path == "" then
  print "SKIP snacks_image_test: set MD_RENDER_SNACKS_PATH to an installed Snacks checkout"
  return
end
assert(vim.fn.filereadable(snacks_path .. "/lua/snacks/init.lua") == 1, "invalid MD_RENDER_SNACKS_PATH")
if vim.fn.executable "magick" ~= 1 and vim.fn.executable "identify" ~= 1 then
  print "SKIP snacks_image_test: ImageMagick identify is unavailable"
  return
end

local root, cache = vim.fn.getcwd(), vim.fn.tempname()
vim.opt.rtp:prepend(root)
vim.opt.rtp:prepend(snacks_path)
vim.o.showtabline = 0
require("snacks").setup {
  image = { enabled = true, cache = cache, doc = { enabled = false }, math = { enabled = false } },
}
local terminal = Snacks.image.terminal
terminal._terminal, terminal._env = { terminal = "kitty" }, { supported = true, placeholders = true }
terminal.write = function() end -- Headless test: keep real placements, intercept terminal bytes.
terminal.size = function()
  return { width = 80, height = 24, columns = 80, rows = 24, cell_width = 1, cell_height = 1, scale = 1 }
end
local image = require "md-render.image"
image._set_kitty_supported(false)
image.setup { backend = "snacks" }
assert(image.supports_kitty(), "switching backends must discard native detection results")
assert(image.config().backend == "snacks", "select the optional backend")
local function wait_for(fn, message)
  assert(vim.wait(3000, fn, 5), message)
end
local buf, win, tab = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
local lines = { "        ", "        ", "        " }
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
local function drawn_rows()
  local rows = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, Snacks.image.placement.ns, 0, -1, { details = true })) do
    if mark[4].virt_text then rows[#rows + 1] = mark[2] end
  end
  table.sort(rows)
  return rows
end
local content = {
  image_placements = { { path = root .. "/tests/fixtures/test_4x4.png", line = 0, col = 0, cols = 4, rows = 3 } },
}
local backend = require "md-render.snacks_image"
local state = backend.setup(win, content)
wait_for(function()
  return vim.deep_equal(drawn_rows(), { 0, 1, 2 })
end, "initial image must occupy the three reserved rows")

-- Session rebuilds replace all rows even when an image's layout stays equal.
vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
backend.update(state, content)
wait_for(function()
  return vim.deep_equal(drawn_rows(), { 0, 1, 2 })
end, "same-layout rebuild left image extmarks at EOF")

-- A distinct path forces asynchronous identification while its tab is inactive.
local uncached = cache .. "/off-tab.png"
assert(vim.uv.fs_copyfile(content.image_placements[1].path, uncached))
content.image_placements[1].path = uncached
vim.cmd "tabnew"
local other_win = vim.api.nvim_get_current_win()
backend.update(state, content)
wait_for(function()
  return state.objects[1].hidden == true
end, "off-tab completion must exercise Snacks' hidden placement state")
vim.api.nvim_set_current_tabpage(tab)
wait_for(function()
  return not state.objects[1].hidden and vim.deep_equal(drawn_rows(), { 0, 1, 2 })
end, "returning to the tab must restore the completed image")

local placement = state.objects[1]
backend.cleanup(state)
assert(state.closed and placement.closed, "cleanup must retire the placement")
assert(#drawn_rows() == 0, "cleanup must remove image extmarks")
vim.api.nvim_win_close(other_win, true)

-- Animated sources must bypass Snacks' first-page conversion. Exercise the
-- real decoder and placements, recording only the requests sent to Kitty.
if vim.fn.executable "ffmpeg" == 1 then
  local requests, request = {}, terminal.request
  terminal.request = function(opts)
    requests[#requests + 1] = vim.deepcopy(opts)
    request(opts)
  end
  local media = { image_placements = {} }
  for idx, name in ipairs { "test_animated.gif", "test.mp4", "test_animated.gif" } do
    media.image_placements[idx] = { path = root .. "/assets/demo/" .. name, line = 0, col = 0, cols = 4, rows = 3 }
  end
  local animated = backend.setup(win, media)
  local function loaded()
    for idx = 1, 3 do
      local object = animated.objects[idx]
      local task = object and object.img._md_render_upload
      if not object or not object:ready() or not task or not task:completed() then return false end
    end
    return true
  end
  assert(vim.wait(15000, loaded, 10), "GIF and MP4 must upload animation frames")
  assert(animated.objects[1].img == animated.objects[3].img, "repeated GIFs must share the uploaded animation")
  local function count(action, id)
    local total = 0
    for _, req in ipairs(requests) do
      if req.a == action and req.i == id then total = total + 1 end
    end
    return total
  end
  for idx = 1, 2 do
    local img = animated.objects[idx].img
    assert(img.info.dpi.width == img.info.dpi.height, "decoded frames must not distort Snacks' placement size")
    assert(count("f", img.id) > 0, "animated media was reduced to a still image")
    assert(count("a", img.id) == 2, "animation must load once and loop")
    local frames = count("f", img.id)
    local old_task = img._md_render_upload
    img.sent = false -- Snacks can resend an image after evicting it from its cache.
    img:send()
    assert(
      vim.wait(3000, function()
        return img._md_render_upload ~= old_task and img._md_render_upload:completed()
      end, 10),
      "retransmitted images must restore their frames"
    )
    assert(count("f", img.id) == frames * 2, "resend lost animation frames")
  end
  -- SSH must send PNG bytes, not paths on the remote host. Reassemble chunks
  -- and compare them with the same decoded frames sent by the local transport.
  local video = animated.objects[2].img
  local expected = {}
  for _, req in ipairs(requests) do
    if req.a == "f" and req.i == video.id then expected[#expected + 1] = vim.base64.decode(req.data) end
  end
  local first_remote = #requests + 1
  terminal._env.remote = true
  video.sent = false
  video:send()
  assert(
    vim.wait(3000, function()
      return video._md_render_upload:completed()
    end, 10),
    "remote upload timed out"
  )
  local data, frame, chunked = "", 1, false
  for idx = first_remote, #requests do
    local req = requests[idx]
    if req.a == "f" then
      assert(req.i == video.id and req.t == "d" and #req.data <= 4096, "invalid remote frame chunk")
      data = data .. req.data
      chunked = chunked or req.m == 1
      if req.m == 0 then
        local file = assert(io.open(expected[frame], "rb"))
        assert(vim.base64.decode(data) == file:read "*a", "remote frame bytes were corrupted")
        file:close()
        data, frame = "", frame + 1
      end
    end
  end
  assert(chunked and frame - 1 == #expected / 2, "remote transport must send every frame exactly once")
  terminal._env.remote = nil
  local before = #requests
  backend.update(animated, media)
  assert(vim.wait(3000, loaded, 10), "rebuild must restore animated placements")
  for idx = before + 1, #requests do
    assert(requests[idx].a ~= "f", "rebuild appended duplicate frames to a cached image")
  end
  backend.cleanup(animated)
  assert(#drawn_rows() == 0, "animation cleanup must remove placeholders")
  terminal.request = request
  print "Snacks animation: GIF, MP4, shared frames, retransmit, remote chunks, rebuild and cleanup OK"
else
  print "SKIP Snacks animation: ffmpeg unavailable"
end
-- Core resolution keeps local filenames literal; the downstream Snacks
-- normalizer must never substitute an environment-named decoy file.
do
  local saved_dir, saved_asset = vim.env.MEDIA_DIR, vim.env.MEDIA_ASSET
  vim.env.MEDIA_DIR, vim.env.MEDIA_ASSET = "expanded", "replacement"
  local literal_dir, decoy_dir = cache .. "/literal-$MEDIA_DIR", cache .. "/literal-expanded"
  vim.fn.mkdir(literal_dir, "p")
  vim.fn.mkdir(decoy_dir, "p")
  local literal, decoy = literal_dir .. "/$MEDIA_ASSET.png", decoy_dir .. "/replacement.png"
  assert(vim.uv.fs_copyfile(root .. "/tests/fixtures/test_4x4.png", literal))
  local transparent =
    vim.base64.decode "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABpfZFQAAAAABJRU5ErkJggg=="
  local file = assert(io.open(decoy, "wb"))
  file:write(transparent)
  file:close()
  local resolved = assert(image.resolve_local("$MEDIA_ASSET.png", literal_dir))
  assert(
    resolved == literal and Snacks.image.convert.norm(resolved) == decoy,
    "fixture must exercise Snacks' downstream expansion"
  )
  local media = { image_placements = { { path = resolved, line = 0, col = 0, cols = 4, rows = 3 } } }
  local owned = backend.setup(win, media)
  wait_for(function()
    return owned.objects[1] and owned.objects[1]:ready()
  end, "literal local filename did not load")
  local original = owned.objects[1].img
  assert(original.info.size.width == 4, "Snacks opened the environment-expanded decoy")
  local original_file, alias_file = assert(io.open(literal, "rb")), assert(io.open(original.file, "rb"))
  assert(original_file:read "*a" == alias_file:read "*a", "literal alias changed source bytes")
  original_file:close()
  alias_file:close()
  assert(media.image_placements[1].path == literal, "alias replaced the navigation path")
  assert(
    not original.src:find("$", 1, true) and Snacks.image.convert.norm(original.src) == original.src,
    "alias parent still expands"
  )
  backend.update(owned, media)
  assert(owned.objects[1].img == original, "unchanged literal source did not reuse its alias")
  assert(vim.uv.fs_copyfile(decoy, literal))
  backend.update(owned, media)
  wait_for(function()
    return owned.objects[1] and owned.objects[1]:ready()
  end, "edited literal file did not load")
  assert(
    owned.objects[1].img ~= original and owned.objects[1].img.info.size.width == 1,
    "alias cache reused stale file contents"
  )
  assert(Snacks.image.convert.norm(resolved) == decoy, "adapter changed Snacks' global normalization")
  backend.cleanup(owned)
  vim.env.MEDIA_DIR, vim.env.MEDIA_ASSET = saved_dir, saved_asset
  print "Snacks literal sources: filename and parent variables, exact bytes, navigation and edited-file cache OK"
end
vim.fn.delete(cache, "rf")
print "Snacks image lifecycle: same-layout rebuild, off-tab completion and cleanup OK"
