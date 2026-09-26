-- Cache environment failures, bound workers, and reject stale completions.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. package.path
local layout = require "md-render.heading_layout"
require("md-render.text_size").setup { enabled = false }
local jobs, killed = {}, 0
vim.system = function(cmd, opts, callback)
  assert(opts.timeout == 5000)
  jobs[#jobs + 1] = { python = cmd[1], callback = callback, requests = vim.json.decode(opts.stdin).requests }
  return {
    kill = function()
      killed = killed + 1
    end,
  }
end
local function request(text, python)
  return layout.request({ entries = { { text = text } } }, python)
end
local function wait_for(fn)
  assert(vim.wait(1000, fn, 5))
end
request("old", "python-old")
wait_for(function()
  return #jobs == 1
end)
layout.retry_failed()
assert(killed == 1)
jobs[1].callback { code = 1, stderr = "stale failure" }
request("one", "python-one")
request("two", "python-two")
wait_for(function()
  return #jobs == 3
end)
assert(layout.failure "python-old" == nil, "old completion must not poison the retry")
assert(jobs[2].python ~= jobs[3].python and #jobs[2].requests == 1 and #jobs[3].requests == 1)
jobs[2].callback { code = 124, stderr = "" }
jobs[3].callback { code = 0, stdout = "invalid" }
wait_for(function()
  return layout.failure(jobs[2].python) ~= nil and layout.failure(jobs[3].python) ~= nil
end)
assert(layout.failure(jobs[2].python) == "image layout timed out after 5000 ms")
assert(layout.failure(jobs[3].python) == "invalid renderer response")
local failed = request("a different heading", jobs[2].python)
assert(failed.ready and failed.error and #jobs == 3, "a cached failure must not start another worker")
layout.retry_failed()
request("repaired", jobs[2].python)
wait_for(function()
  return #jobs == 4
end)
layout.retry_failed()
assert(killed == 2, "retry cancels remaining workers")
print "Heading layout: bounded workers, per-executable batches, cached failures and stale callback protection OK"
