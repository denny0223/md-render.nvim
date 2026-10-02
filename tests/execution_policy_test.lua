-- Tool execution remains explicit and independent of a document's project.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local image = require "md-render.image"
local uv = vim.uv or vim.loop
local original = { system = vim.system, executable = vim.fn.executable, tempname = vim.fn.tempname }
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/project", "p")
vim.fn.writefile({ '{"private":true}' }, root .. "/project/package.json")
vim.fn.writefile({ "@mermaid-js:registry=https://document-project.invalid" }, root .. "/project/.npmrc")
vim.fn.stdpath = function()
  return root .. "/cache"
end
local n = 0
vim.fn.tempname = function()
  n = n + 1
  return root .. "/project/job-" .. n
end
local local_mmdc = false
vim.fn.executable = function(name)
  return (name == "npx" or (name == "mmdc" and local_mmdc)) and 1 or 0
end
local calls, jobs = 0, {}
local fail = false
local npm = vim.fn.exepath "npm"
local python = vim.fn.exepath "python3"
vim.system = function(cmd, opts, callback)
  calls = calls + 1
  local input, output
  for i, arg in ipairs(cmd) do
    if arg == "-i" then input = cmd[i + 1] end
    if arg == "-o" then output = cmd[i + 1] end
  end
  assert(vim.fn.filereadable(input) == 1)
  if cmd[1] == "npx" then
    assert(cmd[2] == "--prefix" and cmd[3] == opts.cwd)
    assert(vim.fs.dirname(input) == opts.cwd and vim.fn.isdirectory(opts.cwd) == 1)
    assert(vim.tbl_contains(cmd, "@mermaid-js/mermaid-cli@12.0.0"))
    if npm ~= "" and python ~= "" then
      local query = {
        python,
        "-c",
        "import subprocess,sys; sys.stdout.buffer.write(subprocess.check_output(sys.argv[1:]))",
        npm,
        "config",
        "get",
        "@mermaid-js:registry",
      }
      local inherited = original.system(query, { cwd = opts.cwd, text = true, timeout = 5000 }):wait()
      assert(
        inherited.code == 0 and inherited.stdout:find("document-project.invalid", 1, true),
        "fixture must expose ancestor npm configuration"
      )
      table.insert(query, 5, opts.cwd)
      table.insert(query, 5, "--prefix")
      local isolated = original.system(query, { cwd = opts.cwd, text = true, timeout = 5000 }):wait()
      assert(
        isolated.code == 0 and not isolated.stdout:find("document-project.invalid", 1, true),
        "npm inherited document configuration"
      )
    end
  else
    assert(cmd[1] == "mmdc" and opts.cwd == nil, "installed renderer keeps its existing cwd")
  end
  assert(uv.fs_copyfile("tests/fixtures/test_4x4.png", output))
  jobs[#jobs + 1] = { callback = callback, input = input, output = output }
  if fail then error "controlled spawn failure" end
  return {
    wait = function()
      return { code = 0 }
    end,
  }
end

assert(not image.has_mmdc())
assert(image.render_mermaid "graph LR; A-->B" == nil and calls == 0)
image.setup { mermaid_allow_npx = true }
assert(image.render_mermaid "graph LR; A-->B")
assert(vim.fn.isdirectory(vim.fs.dirname(jobs[1].input)) == 0, "sync job directory leaked")
local done, answer = false, nil
image.render_mermaid_async("graph LR; B-->C", function(path)
  done, answer = true, path
end)
assert(vim.wait(2000, function()
  return #jobs == 2
end))
assert(not done and vim.fn.isdirectory(vim.fs.dirname(jobs[2].input)) == 1)
jobs[2].callback { code = 0 }
assert(vim.wait(2000, function()
  return done
end) and answer)
assert(vim.fn.isdirectory(vim.fs.dirname(jobs[2].input)) == 0, "async job directory leaked")
fail = true
vim.notify = function() end
assert(image.render_mermaid "graph LR; C-->D" == nil)
assert(vim.fn.isdirectory(vim.fs.dirname(jobs[3].input)) == 0 and vim.fn.filereadable(jobs[3].output) == 0)
done = false
image.render_mermaid_async("graph LR; D-->E", function(path)
  done, answer = true, path
end)
assert(vim.wait(2000, function()
  return done
end) and not answer)
assert(vim.fn.isdirectory(vim.fs.dirname(jobs[4].input)) == 0, "failed async job directory leaked")
fail, local_mmdc = false, true
image.reset_cache()
assert(image.render_mermaid "graph LR; E-->F")
vim.fn.delete(root, "rf")
print(
  "Execution policy: npm opt-in, local precedence, isolated project context, and cleanup passed"
    .. (npm == "" and " (npm configuration integration skipped: npm unavailable)" or "")
)
