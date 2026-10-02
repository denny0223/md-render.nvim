-- Literal media paths and completed diagram output.
-- Run: nvim --headless -u NONE --noplugin -l tests/media_policy_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local image = require "md-render.image"
local uv = vim.uv or vim.loop
local temp = vim.fn.tempname()
vim.fn.mkdir(temp .. "/.obsidian", "p")
vim.fn.mkdir(temp .. "/notes", "p")
local original = {
  expand = vim.fn.expand,
  executable = vim.fn.executable,
  system = vim.system,
  stdpath = vim.fn.stdpath,
  os_homedir = uv.os_homedir,
  ui_send = vim.api.nvim_ui_send,
}
local function file(name, data)
  local path = temp .. "/" .. name
  local f = assert(io.open(path, "wb"))
  f:write(data or "test")
  f:close()
  return path
end

-- These are literal filenames, including text that expand() interprets as Vim syntax.
vim.fn.expand = function()
  error "document media paths must not call expand()"
end
local names = { "空 白.png", "`=1 + 1`.png", "$MEDIA_ASSET.png", "%#.png", "-image.png" }
if vim.fn.has "win32" == 0 then names[#names + 1] = "file\nname.png" end
for _, name in ipairs(names) do
  local path = file(name)
  assert(image.resolve_local(name, temp) == path, name)
  assert(image.resolve(name, temp) == path, name)
  assert(image.resolve_local(path, temp .. "/notes") == path, name)
end
uv.os_homedir = function()
  return temp
end
assert(image.resolve_local("~/空 白.png", temp .. "/notes") == temp .. "/空 白.png")
assert(image.resolve_local("空 白.png", temp .. "/notes") == temp .. "/空 白.png", "vault fallback")
for _, path in ipairs { "", "a\0.png", "file:///tmp/a.png", "data:image/png,a", "ftp://host/a.png" } do
  assert(image.resolve_local(path, temp) == nil, "invalid local source: " .. vim.inspect(path))
end
assert(not image.is_url "https://example.test/a\n.png", "reject URL control characters too")
assert(image.is_url "HTTPS://example.test/a.png", "HTTP scheme is case insensitive")
assert(image.resolve_local "tests/fixtures/test_4x4.png" == vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png")
vim.fn.expand, uv.os_homedir = original.expand, original.os_homedir

vim.fn.stdpath = function(kind)
  return kind == "cache" and temp or original.stdpath(kind)
end

-- A readable output is not success until the renderer exits successfully.
local policy_executable = vim.fn.executable
local fixture = assert(io.open("tests/fixtures/test_4x4.png", "rb"))
local png_data = fixture:read "*a"
fixture:close()
local diagram_jobs, local_plantuml = {}, true
vim.fn.executable = function(cmd)
  return (cmd == "mmdc" or cmd == "curl" or (cmd == "plantuml" and local_plantuml)) and 1 or 0
end
vim.system = function(cmd, _, callback)
  assert(cmd[1] == "mmdc" or cmd[1] == "plantuml" or cmd[1] == "curl")
  local job = { callback = callback }
  for i, arg in ipairs(cmd) do
    if arg == "-i" then job.input = cmd[i + 1] end
    if arg == "-o" then job.output = cmd[i + 1] end
  end
  if job.output then assert(uv.fs_copyfile("tests/fixtures/test_4x4.png", job.output)) end
  diagram_jobs[#diagram_jobs + 1] = job
  return {
    wait = function()
      return { code = 7, stdout = png_data }
    end,
  }
end
image.reset_cache()
assert(image.render_mermaid "graph LR\nA-->B" == nil, "sync Mermaid accepted nonzero exit")
assert(image.get_mermaid_cached "graph LR\nA-->B" == nil)
assert(vim.fn.filereadable(diagram_jobs[1].output) == 0 and vim.fn.filereadable(diagram_jobs[1].input) == 0)

local renderer_system, renderer_notify = vim.system, vim.notify
local spawn_error
vim.system = function(...)
  renderer_system(...)
  error "simulated renderer startup failure"
end
vim.notify = function(message)
  spawn_error = message
end
assert(image.render_mermaid "graph LR\nA-->C" == nil)
assert(spawn_error and spawn_error:find("simulated renderer startup failure", 1, true))
assert(vim.fn.filereadable(diagram_jobs[2].output) == 0 and vim.fn.filereadable(diagram_jobs[2].input) == 0)
vim.system, vim.notify = renderer_system, renderer_notify

-- Synchronous and shared asynchronous calls must not use the same staging file.
diagram_jobs = {}
local concurrent_result
image.render_mermaid_async("graph LR\nC-->D", function(path)
  concurrent_result = path
end)
assert(vim.wait(2000, function()
  return #diagram_jobs == 1
end, 5))
assert(image.render_mermaid "graph LR\nC-->D" == nil)
assert(diagram_jobs[1].output ~= diagram_jobs[2].output, "concurrent renderers shared a staging file")
assert(vim.fn.filereadable(diagram_jobs[1].output) == 1 and vim.fn.filereadable(diagram_jobs[2].output) == 0)
assert(image.get_mermaid_cached "graph LR\nC-->D" == nil)
diagram_jobs[1].callback { code = 0, stdout = png_data }
assert(vim.wait(2000, function()
  return concurrent_result ~= nil
end, 5))

for _, kind in ipairs { "mermaid", "plantuml", "remote plantuml" } do
  local_plantuml = kind ~= "remote plantuml"
  image.setup { plantuml_server = local_plantuml and "" or "https://example.invalid/plantuml" }
  image.reset_cache()
  diagram_jobs = {}
  local render = kind == "mermaid" and image.render_mermaid_async or image.render_plantuml_async
  local cached = kind == "mermaid" and image.get_mermaid_cached or image.get_plantuml_cached
  local source = kind == "mermaid" and "graph LR\nB-->C" or "@startuml\nAlice -> Bob: " .. kind .. "\n@enduml"
  local done, result = 0, nil
  local function receive(path)
    done, result = done + 1, path
  end
  render(source, receive)
  assert(vim.wait(2000, function()
    return #diagram_jobs == 1
  end, 5))
  assert(cached(source) == nil, kind .. " exposed output before command completion")
  render(source, receive)
  vim.wait(10)
  assert(#diagram_jobs == 1 and done == 0, kind .. " did not share pending work")
  local failed = diagram_jobs[1]
  failed.callback { code = 7, stdout = png_data }
  assert(vim.wait(2000, function()
    return done == 2
  end, 5))
  assert(result == nil and cached(source) == nil, kind .. " accepted nonzero exit")
  if failed.output then assert(vim.fn.filereadable(failed.output) == 0, "partial output leaked") end
  if failed.input then assert(vim.fn.filereadable(failed.input) == 0, "diagram input leaked") end
  render(source, receive)
  assert(
    vim.wait(2000, function()
      return #diagram_jobs == 2
    end, 5),
    kind .. " could not retry"
  )
  diagram_jobs[2].callback { code = 0, stdout = png_data }
  assert(vim.wait(2000, function()
    return done == 3
  end, 5))
  assert(result ~= nil and result == cached(source), kind .. " did not publish successful output")
  if diagram_jobs[2].output then assert(vim.fn.filereadable(diagram_jobs[2].output) == 0, "staging output leaked") end
end
image.setup { plantuml_server = "" }
vim.fn.executable = policy_executable
image.reset_cache()

vim.fn.executable, vim.fn.stdpath = original.executable, original.stdpath
vim.system, vim.api.nvim_ui_send = original.system, original.ui_send
image.reset_cache()
vim.fn.delete(temp, "rf")
print "media_policy_test: literal paths and diagram output passed"
