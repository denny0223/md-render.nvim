-- Ordinary image downloads publish through the preview owner after selection.
local child = vim.fn.jobstart(
  { vim.v.progpath, "--embed", "--headless", "-n", "-u", "NONE", "--noplugin", "-i", "NONE" },
  { rpc = true }
)
local function lua(code, ...)
  return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
end
local function wait_for(code)
  assert(
    vim.wait(2000, function()
      return lua(code)
    end, 5),
    code
  )
end
local ok, err = pcall(function()
  lua [[
    package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
    vim.o.lines, vim.o.columns = 40, 120
    vim.o.termguicolors = true
    vim.api.nvim_ui_send = function() end
    require("md-render.text_size").setup { enabled = false }
    local image = require "md-render.image"
    image.supports_kitty = function() return true end
    image.get_cell_size = function() return {cell_w=19, cell_h=44} end
    _G.cached = false
    _G.png = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"
    local resolve = image.get_cached
    image.get_cached = function(url)
      if url == "https://example.invalid/ordinary.png" then return cached and png or nil end
      return resolve(url)
    end
    image.download_async = function(_, callback) _G.download = callback end
    image.transmit_image_async = function(_, callback) callback(10, 4, 4) end
    local preview = require "md-render.preview"
    vim.bo.filetype = "markdown"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "Body before", "", "![image](https://example.invalid/ordinary.png)", "", "SELECT THIS BODY", "", "end",
    })
    preview.toggle()
    _G.session = preview._sessions[vim.api.nvim_get_current_buf()]
    for row, line in ipairs(session.content.lines) do
      if line:find("SELECT THIS BODY", 1, true) then
        vim.api.nvim_win_set_cursor(0, {row, 0})
        _G.selected_line = line
      end
    end
    _G.before = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    vim.cmd "normal! 0v$"
    _G.anchor, _G.cursor = vim.fn.getpos "v", vim.fn.getpos "."
  ]]
  wait_for "return download ~= nil"
  lua [[cached = true; download(png)]]
  wait_for "return session.dirty"
  assert(
    lua [[return vim.deep_equal(before, vim.api.nvim_buf_get_lines(0,0,-1,false))]],
    "download changed selected text"
  )
  assert(
    lua [[return vim.deep_equal(anchor, vim.fn.getpos "v") and vim.deep_equal(cursor, vim.fn.getpos ".")]],
    "download moved selection endpoints"
  )
  vim.rpcrequest(child, "nvim_input", "y")
  wait_for "return vim.api.nvim_get_mode().mode == 'n' and not session.dirty"
  assert(lua [[return vim.fn.getreg '"' == selected_line .. "\n"]], "download changed the yank text")
  assert(lua [[return #vim.api.nvim_buf_get_lines(0,0,-1,false) < #before]], "owner did not publish the loaded image")
end)
vim.fn.jobstop(child)
assert(ok, err)

-- Valid JSON can still have the wrong protocol shape. All such responses must
-- retain the original text and expose a useful retryable error.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. package.path
require("md-render.text_size").config().backend = "image"
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
  layout.retry_failed()
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
