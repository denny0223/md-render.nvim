-- Real async/shared_work; control only external renderer completion and the UI sink.
-- Run: nvim --headless -u NONE --noplugin -l tests/snacks_concurrency_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local temp = vim.fn.tempname()
vim.fn.mkdir(temp, "p")
local original = {
  system = vim.system,
  stdpath = vim.fn.stdpath,
  executable = vim.fn.executable,
  set_extmark = vim.api.nvim_buf_set_extmark,
  snacks = _G.Snacks,
}
vim.fn.stdpath = function(kind)
  return kind == "cache" and temp or original.stdpath(kind)
end
vim.fn.executable = function(cmd)
  return cmd == "mmdc" and 1 or original.executable(cmd)
end

local jobs, states = {}, {}
local active, peak, ui_writes = 0, 0, 0
vim.system = function(cmd, _, callback)
  assert(cmd[1] == "mmdc", "unexpected external command: " .. vim.inspect(cmd))
  local input, output
  for i, arg in ipairs(cmd) do
    if arg == "-i" then input = cmd[i + 1] end
    if arg == "-o" then output = cmd[i + 1] end
  end
  local job = { source = table.concat(vim.fn.readfile(input), "\n"), output = output }
  function job:finish(success)
    assert(not self.done, "renderer finished twice")
    self.done = true
    active = active - 1
    if success then assert(vim.uv.fs_copyfile("tests/fixtures/test_4x4.png", self.output)) end
    callback { code = success and 0 or 1, stdout = "", stderr = "" }
  end
  jobs[#jobs + 1] = job
  active = active + 1
  peak = math.max(peak, active)
  return {
    kill = function()
      job:finish(false)
    end,
  }
end

vim.api.nvim_buf_set_extmark = function(...)
  ui_writes = ui_writes + 1
  return original.set_extmark(...)
end
_G.Snacks = {
  image = {
    terminal = {
      detect = function(callback)
        callback()
      end,
      env = function()
        return { placeholders = true }
      end,
    },
    placement = {
      new = function(_, path)
        ui_writes = ui_writes + 1
        return {
          img = {
            src = path,
            failed = function()
              return false
            end,
          },
          error = function() end,
          close = function()
            ui_writes = ui_writes + 1
          end,
          show = function() end,
          update = function() end,
        }
      end,
    },
  },
}

local transport = require "md-render.snacks_image"
local function pump(done, message)
  assert(vim.wait(2000, done, 5), message)
end
local function drain()
  vim.wait(30, function()
    return false
  end, 5)
end
local function source(label)
  return "graph TD\nA --> B\n%% " .. label
end
local function content(prefix, count)
  local placements = {}
  for i = 1, count do
    placements[i] = { line = i, col = 0, rows = 1, cols = 10, mermaid_source = source(prefix .. i) }
  end
  return { image_placements = placements }
end
local function setup(initial)
  local state
  state = transport.setup(vim.api.nvim_get_current_win(), initial, nil, {
    on_ready = function()
      ui_writes = ui_writes + 1
      transport.update(state, state.content)
    end,
  })
  states[#states + 1] = state
  return state
end

local ok, err = pcall(function()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "heading", "image", "image", "image", "image", "end" })
  local state = setup(content("old", 4))
  pump(function()
    return #jobs == 2
  end, "initial producers did not start")
  for revision = 1, 3 do
    transport.update(state, content("edit" .. revision .. "-", 4))
  end
  local latest = content("final", 3)
  transport.update(state, latest)
  drain()
  assert(#jobs == 2 and active == 2, "burst edits bypassed the two-producer limit")

  jobs[1]:finish(true)
  jobs[2]:finish(true)
  pump(function()
    return #jobs >= 4
  end, "final content did not start after old producers finished")
  assert(jobs[3].source == source "final1" and jobs[4].source == source "final2", "stale queued sources were rendered")
  jobs[3]:finish(true)
  jobs[4]:finish(true)
  pump(function()
    return #jobs >= 5
  end, "last final image did not start")
  assert(jobs[5].source == source "final3", "a stale or duplicate producer started")
  jobs[5]:finish(true)
  pump(function()
    return #state.objects == 3
  end, "final content did not reach image placements")
  for _, p in ipairs(latest.image_placements) do
    assert(p.path and vim.fn.filereadable(p.path) == 1, "final image was not resolved")
  end
  assert(#jobs == 5 and active == 0 and peak == 2, "unexpected producer count after burst edits")

  transport.update(state, content("closing", 3))
  pump(function()
    return #jobs == 7
  end, "cleanup producers did not start")
  transport.cleanup(state)
  local writes_after_cleanup = ui_writes
  local reopened = setup(content("reopened", 2))
  drain()
  assert(#jobs == 7 and active == 2, "close/reopen bypassed the shared producer limit")
  jobs[6]:finish(true)
  jobs[7]:finish(false)
  pump(function()
    return #jobs >= 9
  end, "reopened content did not start")
  assert(jobs[8].source == source "reopened1" and jobs[9].source == source "reopened2", "closed queued work started")
  drain()
  assert(ui_writes == writes_after_cleanup, "closed success/failure callbacks wrote to the UI")
  jobs[8]:finish(true)
  jobs[9]:finish(true)
  pump(function()
    return #reopened.objects == 2
  end, "reopened content did not complete")
  assert(#jobs == 9 and active == 0 and peak == 2, "producer limit did not survive cleanup")

  -- A viewer waiting behind two producers can keep its selected diagram
  -- even when the original preview closes before the queue reaches it.
  local queued = setup(content("waiting", 4))
  pump(function()
    return #jobs == 11
  end, "initial waiting producers did not start")
  local abandoned, selected = unpack(queued.content.image_placements, 3, 4)
  local cancelled, skipped, result = false, false, nil
  local function viewer_open()
    return not cancelled
  end
  local async = require "md-render.async"
  async.run(function()
    local path = queued.wait_for_source[abandoned](viewer_open)
    skipped = path == nil
  end)
  async.run(function()
    queued.wait_for_source[selected](viewer_open)
  end)
  async.run(function()
    result = queued.wait_for_source[selected](function()
      return true
    end)
  end)
  cancelled = true
  transport.cleanup(queued)
  jobs[10]:finish(true)
  jobs[11]:finish(true)
  pump(function()
    return #jobs >= 12
  end, "the selected queued diagram was dropped")
  assert(#jobs == 12 and jobs[12].source == source "waiting4", "a cancelled viewer took a producer slot")
  assert(skipped, "abandoned queued work must finish without rendering")
  jobs[12]:finish(true)
  pump(function()
    return result
  end, "closed document did not deliver the selected file to its viewer")
  assert(vim.fn.filereadable(result) == 1 and peak == 2 and #jobs == 12, "waiting bypassed the producer limit")

  -- A pending local animation also shares extraction with its inline owner.
  local image = require "md-render.image"
  local frames, extracted = { "frame.png" }, {}
  local extract = image.extract_frames_async
  image.extract_frames_async = function(path, done)
    extracted[#extracted + 1] = { path = path, done = done }
  end
  local videos = content("animation", 3)
  for i, p in ipairs(videos.image_placements) do
    p.mermaid_source, p.animated, p.path = nil, true, "animation" .. i .. ".gif"
  end
  local animations = setup(videos)
  local standalone_open = true
  local standalone = async.run(function()
    transport.extract_frames("closed.gif", function()
      return standalone_open
    end)
  end)
  standalone_open = false
  local target = videos.image_placements[3]
  local file, decoded
  require("md-render.async").run(function()
    file, decoded = animations.wait_for_source[target](function()
      return true
    end)
  end)
  assert(#extracted == 2, "waiting animated view decoded a third image outside the queue")
  transport.cleanup(animations)
  extracted[1].done(frames)
  pump(function()
    return #extracted == 3
  end, "selected animation was skipped after its document closed")
  assert(extracted[3].path == target.path, "the viewer decoded another animation")
  extracted[2].done(frames)
  extracted[3].done(frames)
  pump(function()
    return file
  end, "the waiting animation did not receive its source")
  assert(
    file == target.path and decoded == frames and #extracted == 3,
    "viewer lost or decoded the shared frames twice"
  )
  pump(function()
    return standalone:completed() or #extracted > 3
  end, "the standalone viewer did not release its turn")
  assert(standalone:completed() and #extracted == 3, "a closed standalone viewer started its queued decode")
  image.extract_frames_async = extract

  -- Terminal detection can finish after the owning window changes buffers.
  local detect, pending_detect = Snacks.image.terminal.detect, nil
  Snacks.image.terminal.detect = function(callback)
    pending_detect = callback
  end
  local late = setup {
    image_placements = {
      { path = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png", line = 0, col = 0, cols = 4, rows = 1 },
    },
  }
  local old_buf = vim.api.nvim_get_current_buf()
  local other = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(late.win, other)
  local before_detect = ui_writes
  pending_detect()
  assert(late.closed and ui_writes == before_detect, "late detection placed an image after window ownership changed")
  Snacks.image.terminal.detect = detect
  vim.api.nvim_win_set_buf(late.win, old_buf)
  vim.api.nvim_buf_delete(other, { force = true })

  require("md-render.image").setup { backend = "snacks" }
  local ns = vim.api.nvim_create_namespace "snacks_reopened"
  local opts = { on_ready = function() end }
  local restored = require("md-render.display_utils").update_images(late, late.win, late.content, ns, opts)
  states[#states + 1] = restored
  assert(restored ~= late and not restored.closed and restored.objects[1], "closed Snacks state was not recreated")
  assert(restored.ns == ns and restored.opts == opts, "recreated Snacks state lost its owner options")
end)

for _, state in ipairs(states) do
  transport.cleanup(state)
end
for _, job in ipairs(jobs) do
  if not job.done then job:finish(false) end
end
drain()
vim.system, vim.fn.stdpath, vim.fn.executable = original.system, original.stdpath, original.executable
vim.api.nvim_buf_set_extmark, _G.Snacks = original.set_extmark, original.snacks
vim.fn.delete(temp, "rf")
assert(ok, err)
print "Snacks concurrency: burst edits, stale queues, final completion and cleanup OK (peak 2 producers)"
