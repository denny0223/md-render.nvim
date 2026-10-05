-- Run: nvim --headless -u NONE --noplugin -l tests/tmux_refresh_trace_test.lua
local source = vim
  .system({
    "python3",
    "-c",
    'import sys; sys.path.insert(0, "tests"); import tmux_terminal_test; sys.stdout.write(tmux_terminal_test.TMUX_REFRESH_TRACE)',
  }, { text = true, env = { PYTHONDONTWRITEBYTECODE = "1" } })
  :wait(10000)
assert(source.code == 0, source.stderr)

local system, schedule, tmux_env = vim.system, vim.schedule, vim.env.TMUX
vim.env.TMUX = "/tmp/refresh-test.sock,123,0"
local target = { "tmux", "-S", "/tmp/refresh-test.sock", "refresh-client", "-t", "/dev/pts/9" }
local opts = { timeout = 150 }
local result = { code = 23, signal = 9, stderr = "observed stderr", stdout = "unchanged" }
local sentinel = {}
local object = {
  pid = 4321,
  wait = function()
    error "observer must not wait"
  end,
  kill = function()
    error "observer must not kill"
  end,
}
local calls, mode, completion = {}, "pending", nil
vim.system = function(cmd, ...)
  local options, callback = ...
  calls[#calls + 1] = { cmd = cmd, opts = options, callback = callback, argc = select("#", ...) }
  if mode == "spawn_error" then error(sentinel, 0) end
  completion = callback
  if mode == "synchronous" then callback(result) end
  return object
end
vim.schedule = function()
  error "observer must not schedule"
end
assert(loadstring(source.stdout))()
local events = _G.tmux_refresh_events
local forwarded
local callback = function(value)
  forwarded = value
end

-- Every near miss delegates the original arguments and callback unchanged.
for _, change in ipairs {
  { 1, "/usr/bin/tmux" },
  { 2, "-L" },
  { 3, "/tmp/other.sock" },
  { 4, "display-message" },
  { 5, "-c" },
  { 6, false },
  { 7, "extra" },
} do
  local cmd = vim.deepcopy(target)
  cmd[change[1]] = change[2]
  assert(vim.system(cmd, opts, callback) == object)
  local call = calls[#calls]
  assert(call.cmd == cmd and call.opts == opts and call.callback == callback and call.argc == 2)
  assert(#events == 0)
end
local missing_client = { unpack(target, 1, 5) }
assert(vim.system(missing_client) == object and calls[#calls].argc == 0 and #events == 0)

-- The renderer's two-argument call gets the same object/options and no wait.
assert(vim.system(target, opts) == object)
local call, entry = calls[#calls], events[1]
assert(call.cmd == target and call.opts == opts and opts.timeout == 150)
assert(type(call.callback) == "function")
assert(entry.socket == target[3] and entry.client == target[6] and entry.pid == object.pid)
assert(type(entry.started) == "number" and not entry.finished and not entry.spawn_error)
completion(result)
assert(entry.finished >= entry.started and entry.code == result.code and entry.signal == result.signal)
assert(entry.stderr == result.stderr)

-- Completion before the delegated call returns must survive assigning the PID.
mode = "synchronous"
assert(vim.system(target, opts, callback) == object and forwarded == result)
entry = events[2]
assert(entry.finished >= entry.started and entry.pid == object.pid and entry.code == result.code)
assert(result.stdout == "unchanged" and result.stderr == "observed stderr")
forwarded = nil
assert(vim.system(target, callback, function()
  error "the third argument is ignored by the callback overload"
end) == object)
assert(calls[#calls].opts == nil and forwarded == result and #events == 3)

-- Use a real uv fast event; the original callback sees the identical result.
mode = "pending"
forwarded = nil
local done, callback_error
assert(vim.system(target, opts, function(value)
  assert(vim.in_fast_event() and value == result)
  forwarded = value
end) == object)
local pending = completion
local timer = assert(vim.uv.new_timer())
timer:start(0, 0, function()
  local ok, err = pcall(function()
    assert(vim.in_fast_event())
    pending(result)
  end)
  if not ok then callback_error = err end
  timer:stop()
  timer:close()
  done = true
end)
assert(
  vim.wait(1000, function()
    return done
  end, 1),
  "fast callback did not complete"
)
assert(not callback_error, tostring(callback_error))
entry = events[4]
assert(forwarded == result and entry.finished >= entry.started and entry.signal == result.signal)
assert(entry.stderr == result.stderr and entry.pid == object.pid)

-- Spawn failure preserves the thrown Lua value, while the cache stays scalar.
mode = "spawn_error"
local ok, err = pcall(vim.system, target, opts)
assert(not ok and err == sentinel)
entry = events[5]
assert(entry.spawn_error == tostring(sentinel) and not entry.pid and not entry.finished)
ok, err = pcall(vim.system, missing_client, opts, callback)
assert(not ok and err == sentinel and #events == 5 and calls[#calls].callback == callback)

vim.system, vim.schedule, vim.env.TMUX = system, schedule, tmux_env
print "tmux_refresh_trace_test: passed"
