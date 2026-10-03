-- Tool execution remains explicit and independent of a document's project.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local image = require "md-render.image"
local uv = vim.uv or vim.loop
local original = {
  system = vim.system,
  executable = vim.fn.executable,
  exepath = vim.fn.exepath,
  mkdir = vim.fn.mkdir,
  tempname = vim.fn.tempname,
  writefile = vim.fn.writefile,
  symlink = uv.fs_symlink,
}
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/project/control", "p")
vim.fn.writefile({ '{"private":true}' }, root .. "/project/package.json")
vim.fn.writefile({ "@mermaid-js:registry=https://document-project.invalid" }, root .. "/project/.npmrc")
local node = original.exepath "node"
local trusted_node = node ~= "" and node or vim.v.progpath -- Mocked launches do not need Node installed.
vim.fn.mkdir(root .. "/project/node_modules/.bin", "p")
assert(uv.fs_symlink(trusted_node, root .. "/project/node_modules/.bin/node"))
vim.fn.exepath = function(name)
  return name == "node" and trusted_node or original.exepath(name)
end
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
local diagnosed = false
vim.system = function(cmd, opts, callback)
  calls = calls + 1
  local input, output
  for i, arg in ipairs(cmd) do
    if arg == "-i" then input = cmd[i + 1] end
    if arg == "-o" then output = cmd[i + 1] end
  end
  assert(vim.fn.filereadable(input) == 1)
  assert(vim.fs.dirname(input) == opts.cwd and vim.fn.isdirectory(opts.cwd) == 1)
  assert(not opts.env and not opts.clear_env, "user PATH and Puppeteer settings must remain inherited")
  assert(
    table.concat(vim.fn.readfile(opts.cwd .. "/.puppeteerrc"), "\n") == "{}",
    "Puppeteer config search is not bounded"
  )
  if cmd[1] == "npx" then
    assert(cmd[2] == "--prefix" and cmd[3] == opts.cwd)
    assert(vim.tbl_contains(cmd, "@mermaid-js/mermaid-cli@12.0.0"))
    assert(uv.fs_readlink(opts.cwd .. "/node_modules/.bin/node") == trusted_node, "npm must use the user's Node")
    if not diagnosed and npm ~= "" and python ~= "" and node ~= "" then
      diagnosed = true
      local control = root .. "/project/control"
      local query = {
        python,
        "-c",
        "import subprocess,sys; sys.stdout.buffer.write(subprocess.check_output(sys.argv[1:]))",
        npm,
        "config",
        "get",
        "@mermaid-js:registry",
      }
      local inherited = original.system(query, { cwd = control, text = true, timeout = 5000 }):wait()
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
      query = {
        python,
        "-c",
        "import subprocess,sys; sys.stdout.buffer.write(subprocess.check_output(sys.argv[1:]))",
        npm,
        "exec",
        "--offline",
        "--ignore-scripts",
        "--prefix",
        control,
        "--call",
        "command -v node",
      }
      inherited = original.system(query, { cwd = control, text = true, timeout = 5000 }):wait()
      assert(
        inherited.code == 0 and vim.trim(inherited.stdout) == root .. "/project/node_modules/.bin/node",
        "fixture must expose ancestor npm binary lookup"
      )
      query[9] = opts.cwd
      isolated = original.system(query, { cwd = opts.cwd, text = true, timeout = 5000 }):wait()
      assert(
        isolated.code == 0 and vim.trim(isolated.stdout) == opts.cwd .. "/node_modules/.bin/node",
        "npm's Node lookup escaped the private job directory"
      )
    end
  else
    assert(
      cmd[1] == "mmdc" and not vim.tbl_contains(cmd, "--prefix"),
      "npm options must not reach the installed renderer"
    )
    assert(not uv.fs_lstat(opts.cwd .. "/node_modules/.bin/node"), "installed renderer must retain normal PATH lookup")
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
local before = calls
vim.fn.exepath = function(name)
  return name == "node" and "" or original.exepath(name)
end
assert(image.render_mermaid "graph LR; missing-->node" == nil)
assert(
  calls == before and vim.fn.isdirectory(root .. "/project/job-" .. n) == 0,
  "missing Node launched npm or leaked a job"
)
vim.fn.exepath = function(name)
  return name == "node" and trusted_node or original.exepath(name)
end
uv.fs_symlink = function()
  return nil, "controlled symlink failure"
end
done = false
image.render_mermaid_async("graph LR; denied-->symlink", function(path)
  done, answer = true, path
end)
assert(vim.wait(2000, function()
  return done
end) and not answer)
assert(
  calls == before and vim.fn.isdirectory(root .. "/project/job-" .. n) == 0,
  "failed Node isolation launched npm or leaked a job"
)
uv.fs_symlink = original.symlink
vim.fn.mkdir = function(path, ...)
  if path:match "/node_modules/%.bin$" then
    original.mkdir(vim.fs.dirname(path), "p", 448)
    error "controlled partial Node directory failure"
  end
  return original.mkdir(path, ...)
end
assert(image.render_mermaid "graph LR; mkdir-->failure" == nil)
assert(
  calls == before and vim.fn.isdirectory(root .. "/project/job-" .. n) == 0,
  "Node directory creation error launched npm or leaked its partial directory"
)
vim.fn.mkdir = original.mkdir
fail, local_mmdc = false, true
vim.fn.exepath = function(name)
  return name == "node" and "" or original.exepath(name)
end
image.reset_cache()
assert(image.render_mermaid "graph LR; E-->F")
local denied_dir
before = calls
vim.fn.writefile = function(_, path)
  denied_dir = vim.fs.dirname(path)
  error "controlled Puppeteer sentinel write failure"
end
assert(image.render_mermaid "graph LR; F-->G" == nil)
assert(
  calls == before and denied_dir and vim.fn.isdirectory(denied_dir) == 0,
  "failed config isolation launched a tool or leaked a job"
)
vim.fn.writefile = original.writefile
vim.fn.exepath = original.exepath
vim.fn.delete(root, "rf")
print(
  "Execution policy: npm opt-in, local precedence, isolated project context, and cleanup passed"
    .. (not diagnosed and " (npm configuration/PATH integration skipped: npm, Python, or Node unavailable)" or "")
)
