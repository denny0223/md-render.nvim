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
          img = { src = path },
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
