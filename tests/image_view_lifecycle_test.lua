-- Real Snacks integration; point MD_RENDER_SNACKS_PATH at an installed checkout.
local snacks_path = vim.env.MD_RENDER_SNACKS_PATH
if not snacks_path or snacks_path == "" then
  print "SKIP image_view_lifecycle_test: set MD_RENDER_SNACKS_PATH to an installed Snacks checkout"
  return
end
assert(vim.fn.filereadable(snacks_path .. "/lua/snacks/init.lua") == 1, "invalid MD_RENDER_SNACKS_PATH")
if vim.fn.executable "magick" ~= 1 then
  print "SKIP image_view_lifecycle_test: ImageMagick is unavailable"
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
terminal.write = function() end
terminal.size = function()
  return { width = 80, height = 24, columns = 80, rows = 24, cell_width = 1, cell_height = 1, scale = 1 }
end
require("md-render.image")._test_cell_size = { cell_w = 1, cell_h = 1 }

-- Hold only Snacks' placement debounce; all placement and image methods remain real.
local updates, debounce = {}, Snacks.util.debounce
Snacks.util.debounce = function(fn, opts)
  if opts.ms ~= 10 then return debounce(fn, opts) end
  return function()
    updates[fn] = true
  end
end
local function flush_updates()
  while next(updates) do
    local pending = updates
    updates = {}
    for update in pairs(pending) do
      update()
    end
  end
end
local function wait_for(fn, message)
  assert(vim.wait(3000, fn, 5), message)
end

-- Copy PNG pixels instead of cropping; control crop completion without replacing Snacks.
local crops = {}
local system = vim.system
vim.system = function(cmd, _, callback)
  assert(cmd[1] == "magick" and cmd[3] == "-crop", "unexpected process")
  local job = { file = cmd[#cmd], crop = cmd[4] }
  assert(vim.uv.fs_copyfile(cmd[2], job.file))
  function job:kill()
    self.killed = true
  end
  function job:complete(code)
    callback { code = code or 0 }
  end
  crops[#crops + 1] = job
  return job
end
local view = require("md-render.image_view").open(root .. "/tests/fixtures/test_4x4.png")
wait_for(function()
  return #crops == 1
end, "initial crop did not start")
local tab = vim.api.nvim_get_current_tabpage()
local zoom = vim.fn.maparg("+", "n", false, true).callback
local function finish_crop(n)
  crops[n]:complete()
  wait_for(function()
    return view.pending and view.pending:ready() and next(updates) ~= nil
  end, "crop did not reach its pending Snacks placement")
  return view.pending
end
local function assert_only_drawn(placement)
  local allowed, drawn = {}, 0
  for _, id in ipairs(placement.eids) do
    allowed[id] = true
  end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.buf, Snacks.image.placement.ns, 0, -1, { details = true })) do
    assert(allowed[mark[1]], "retired frame left an orphan extmark")
    if mark[4].virt_text then drawn = drawn + 1 end
  end
  assert(drawn > 0, "displayed frame has no image extmarks")
end

local first = finish_crop(1)
flush_updates()
assert(view.placement == first and not view.pending, "first frame was not promoted")
assert_only_drawn(first)
zoom()
zoom()
assert(#crops == 2 and not crops[2].killed, "new input must not cancel a running crop")
local second = finish_crop(2)
for _ = 1, 10 do
  zoom() -- Keep B alive while newer input waits for its placement to finish.
end
local latest = view.crop
assert(#crops == 2 and not crops[2].killed and not second.closed, "input bursts must let the pending frame finish")
assert(not first.closed and vim.fn.filereadable(crops[1].file) == 1, "displayed frame must survive pending work")
flush_updates()
wait_for(function()
  return #crops == 3
end, "latest view was not rendered after the pending frame")
assert(
  crops[3].crop == ("%dx%d+%d+%d"):format(latest.w, latest.h, latest.x, latest.y),
  "queued render used a stale crop"
)
assert_only_drawn(second)
local third = finish_crop(3)
flush_updates()
assert(view.placement == third and not view.pending, "latest frame was not promoted")
assert(first.closed and second.closed, "latest frame stranded a displayed predecessor")
assert(
  vim.fn.filereadable(crops[1].file) == 0 and vim.fn.filereadable(crops[2].file) == 0,
  "retired crops were not removed"
)
assert_only_drawn(third)

zoom()
vim.cmd "tabprevious"
local background = finish_crop(4)
flush_updates()
assert(background.hidden and view.pending == background, "completion did not exercise off-tab hidden placement")
vim.api.nvim_set_current_tabpage(tab)
wait_for(function()
  return next(updates) ~= nil
end, "returning to the viewer did not schedule placement restoration")
flush_updates()
assert(view.placement == background and not background.hidden, "off-tab frame did not become visible on return")
assert(third.closed and vim.fn.filereadable(crops[3].file) == 0, "restored frame did not retire its predecessor")
assert_only_drawn(background)

zoom()
local pending = finish_crop(5)
zoom() -- Closing must also discard queued input.
vim.api.nvim_buf_delete(view.buf, { force = true })
assert(view.closed and background.closed and pending.closed, "wipe must close both displayed and pending frames")
assert(vim.fn.isdirectory(vim.fs.dirname(crops[5].file)) == 0, "wipe left crop files behind")
flush_updates() -- Queued callbacks after cleanup must be harmless.
assert(#crops == 5, "closing the viewer started a queued crop")

-- A failed conversion must not strand input queued while it was running.
view = require("md-render.image_view").open(root .. "/tests/fixtures/test_4x4.png")
wait_for(function()
  return #crops == 6
end, "error recovery view did not start")
vim.fn.maparg("+", "n", false, true).callback()
local notify, errors = vim.notify, {}
vim.notify = function(message)
  errors[#errors + 1] = message
end
crops[6]:complete(1)
wait_for(function()
  return #crops == 7
end, "failed conversion stranded queued input")
vim.notify = notify
assert(#errors == 1 and errors[1]:find("image crop failed", 1, true), "crop error was not reported")
vim.api.nvim_buf_delete(view.buf, { force = true })
assert(crops[7].killed, "closing the viewer must cancel its active conversion")

vim.system, Snacks.util.debounce = system, debounce
if vim.fn.executable "ffmpeg" == 1 then
  local image = require "md-render.image"
  image.setup { backend = "snacks" }
  image._set_kitty_supported(true)
  local viewer = require "md-render.image_view"
  local open, opened = viewer.open, nil
  viewer.open = function(path)
    opened, view = path, open(path)
    return view
  end
  local requests, request = {}, terminal.request
  terminal.request = function(opts)
    requests[#requests + 1] = vim.deepcopy(opts)
    request(opts)
  end
  vim.cmd "enew"
  local source = vim.api.nvim_get_current_buf()
  vim.bo[source].filetype = "markdown"
  local gif, video = root .. "/assets/demo/test_animated.gif", root .. "/assets/demo/test.mp4"
  vim.api.nvim_buf_set_lines(
    source,
    0,
    -1,
    false,
    { "![GIF](" .. gif .. ")", "", '<video src="' .. video .. '"></video>' }
  )
  local preview = require "md-render.preview"
  preview.toggle()
  local session = preview._toggle_sessions[source]
  local function key(name)
    vim.fn.maparg(name, "n", false, true).callback()
  end
  for idx, path in ipairs { gif, video } do
    assert(
      vim.wait(15000, function()
        local p = session.image_state.objects[idx]
        return p and p:ready() and p.img._md_render_upload and p.img._md_render_upload:completed()
      end, 10),
      "inline media did not load"
    )
    local inline = session.image_state.objects[idx]
    vim.api.nvim_win_set_cursor(session.win, { session.content.image_placements[idx].line + 1, 0 })
    key "<CR>"
    assert(opened == path, "Enter must pass the media source, not its first PNG frame")
    wait_for(function()
      return view.placement and view.media._md_render_upload and view.media._md_render_upload:completed()
    end, "viewer must load the complete animation")
    local img, anchor = view.media, view.placement
    assert(#view.frames > 1 and view.playing, "media must open playing")
    assert(img.id ~= inline.img.id, "viewer playback must be independent of inline media")
    key "<Space>"
    assert(not view.playing and requests[#requests].s == 1, "Space must pause the current frame")
    local paused = #requests
    for _ = 1, 4 do
      key "+"
    end
    wait_for(function()
      return not view.pending and not view.dirty
    end, "zoom did not settle")
    assert(view.crop.w < view.iw or view.crop.h < view.ih, "zoom must crop animated media")
    local x, y = view.crop.x, view.crop.y
    key "h"
    key "k"
    wait_for(function()
      return not view.pending and not view.dirty
    end, "pan did not settle")
    assert(view.crop.x < x or view.crop.y < y, "pan must move the animated crop")
    assert(
      view.media == img and view.placement == anchor and vim.fn.filereadable(view.path) == 1,
      "zoom/pan must preserve the animation"
    )
    local crop
    for n = paused + 1, #requests do
      local req = requests[n]
      assert(not (req.a == "a" and req.s ~= 1), "zoom/pan resumed paused media")
      assert(req.a ~= "f", "zoom/pan must not upload frames again")
      assert(req.a ~= "d", "zoom/pan must not delete the anchor or animation")
      if req.a == "p" and req.i == img.id and req.w then crop = req end
    end
    assert(
      crop
        and crop.U ~= 1
        and crop.P == anchor.img.id
        and crop.Q == anchor.id
        and (crop.c == 0 or crop.r == 0)
        and crop.x == view.crop.x
        and crop.y == view.crop.y
        and crop.w == view.crop.w,
      "placement crop or aspect ratio was lost"
    )
    key "<Space>"
    assert(view.playing and requests[#requests].s == 3, "Space must resume playback")
    local file = view.path
    key "q"
    wait_for(function()
      return vim.api.nvim_get_current_win() == session.win
    end, "closing must return to the document")
    assert(view.closed and vim.fn.filereadable(file) == 0, "closing must remove the private base image")
    local last = requests[#requests]
    assert(last.a == "d" and last.d == "I" and last.i == img.id, "closing must release the viewer's animation")
    assert(not inline.closed, "closing the viewer must preserve inline media")
    local closed = #requests
    img:on_send() -- A late base-image completion must not restart the upload.
    assert(#requests == closed + 1 and requests[#requests].d == "I", "closed media was uploaded again")
  end
  viewer.open, terminal.request = open, request
  preview.toggle()
  print "Image view media: Enter source, autoplay, pause/resume, animated zoom/pan and independent cleanup OK"
end
vim.fn.delete(cache, "rf")
print "Image view lifecycle: input coalescing, off-tab completion and pending/displayed cleanup OK"
