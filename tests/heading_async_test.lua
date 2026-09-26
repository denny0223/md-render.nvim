-- Valid JSON can still have the wrong protocol shape. All such responses must
-- retain the original text and expose a useful retryable error.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. package.path
local layout = require "md-render.heading_layout"
local system, notify = vim.system, vim.notify_once
local callback, warning
vim.system = function(_, _, fn)
  callback = fn
  return { kill = function() end }
end
vim.notify_once = function(message)
  warning = message
end
for index, response in ipairs {
  "null",
  "false",
  "{}",
  "[null]",
  "[false]",
  '[{"lines":false}]',
  '[{"lines":[false]}]',
  '[{"lines":[{"start":0,"end":7,"text":"changed","cols":1}]}]',
  '[{"lines":[{"start":0,"end":7,"text":"Heading","cols":1,"data":"png","width":19,"height":44,"columns":false}]}]',
  '[{"lines":[{"start":0,"end":7,"text":"Heading","cols":1,"data":"png","width":19,"height":44,"columns":[999]}]}]',
} do
  callback, warning = nil, nil
  local entry = layout.request({ entries = { { text = "Heading" } }, test = index }, "python3")
  assert(vim.wait(1000, function()
    return callback ~= nil
  end))
  callback { code = 0, stdout = response, stderr = "" }
  assert(vim.wait(1000, function()
    return entry.ready
  end))
  assert(not entry.output and entry.error == "invalid renderer response", response)
  assert(warning and warning:find("using text", 1, true), response)
end
vim.system, vim.notify_once = system, notify
print "Heading async: malformed renderer responses retain text"
