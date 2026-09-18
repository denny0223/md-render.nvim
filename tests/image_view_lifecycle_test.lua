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
vim.system = function(cmd, _, callback)
  assert(cmd[1] == "magick" and cmd[3] == "-crop", "unexpected process")
  local job = { file = cmd[#cmd] }
  assert(vim.uv.fs_copyfile(cmd[2], job.file))
  function job:kill()
    self.killed = true
  end
  function job:complete()
    callback { code = 0 }
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
local superseded = finish_crop(2)
zoom() -- Supersede B before its debounced update can retire displayed A.
assert(superseded.closed and vim.fn.filereadable(crops[2].file) == 0, "superseded pending frame was not retired")
assert(not first.closed and vim.fn.filereadable(crops[1].file) == 1, "displayed frame must survive pending work")
local third = finish_crop(3)
flush_updates()
assert(view.placement == third and not view.pending, "latest frame was not promoted")
assert(first.closed and vim.fn.filereadable(crops[1].file) == 0, "latest frame stranded its displayed predecessor")
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
vim.api.nvim_buf_delete(view.buf, { force = true })
assert(view.closed and background.closed and pending.closed, "wipe must close both displayed and pending frames")
assert(vim.fn.isdirectory(vim.fs.dirname(crops[5].file)) == 0, "wipe left crop files behind")
flush_updates() -- Queued callbacks after cleanup must be harmless.
vim.fn.delete(cache, "rf")
print "Image view lifecycle: rapid zoom, off-tab completion and pending/displayed cleanup OK"
