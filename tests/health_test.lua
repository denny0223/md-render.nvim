package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local repo, real_system = vim.fn.getcwd(), vim.system

local messages = {}
for _, level in ipairs { "start", "info", "ok", "warn", "error" } do
  vim.health[level] = function(message)
    messages[#messages + 1] = level .. ": " .. message
  end
end
local original_has, original_version, original_notify = vim.fn.has, vim.version, vim.notify_once
local startup
vim.fn.has = function()
  return 0
end
vim.version = function()
  return original_version.parse "0.11.5"
end
vim.notify_once = function(message)
  startup = message
end
require("md-render.health").check()
dofile "plugin/md-render.lua"
assert(not package.loaded["md-render.image"], "unsupported Neovim must not load rendering dependencies")
assert(not vim.g.loaded_md_render and not vim.api.nvim_get_commands({}).MdRender)
assert(startup:find("running 0.11.5", 1, true) and startup:find("upgrade Neovim", 1, true), startup)
assert(messages[2]:find("Neovim 0.12+ required", 1, true), table.concat(messages, "\n"))
vim.fn.has, vim.version, vim.notify_once = original_has, original_version, original_notify
local provider_loads = 0
for _, name in ipairs { "nvim-web-devicons", "mini.icons" } do
  package.preload[name] = function()
    provider_loads = provider_loads + 1
    error "health must not load or configure optional icon providers"
  end
end
messages = {}
vim.fn.executable = function()
  return 0
end
vim.api.nvim_list_uis = function()
  return {}
end
vim.system = function()
  error "native headings must not start Python or probe a terminal"
end
local image = require "md-render.image"
image.supports_kitty = function()
  error "headless health must not probe a terminal"
end
require("md-render.text_size").setup { backend = "native" }
require("md-render.health").check()
local report = table.concat(messages, "\n")
assert(report:find("No attached UI", 1, true), report)
assert(report:find("magick unavailable", 1, true), report)
assert(report:find("Mermaid CLI unavailable", 1, true), report)
assert(report:find("Mermaid npx fallback: false", 1, true), report)
assert(report:find("install ImageMagick 7", 1, true), report)
assert(report:find("install PlantUML 1.2020.11+", 1, true), report)
assert(report:find("restart Neovim and reopen", 1, true), report)
assert(report:find("Icon style: nerd", 1, true), report)
assert(
  report:find("Icon fonts are configured in the terminal", 1, true) and report:find("md-render-icons", 1, true),
  report
)
assert(provider_loads == 0, "health icon guidance must not require optional providers")
assert(not report:find("error:", 1, true), report)
local icons = require "md-render.icons"
local original_emoji = vim.o.emoji
for _, style in ipairs { "nerd", "unicode" } do
  icons.setup { style = style }
  for _, emoji in ipairs { true, false } do
    vim.o.emoji = emoji
    messages = {}
    require("md-render.health").check()
    report = table.concat(messages, "\n")
    assert(report:find("Icon style: " .. style, 1, true), report)
    local warned = report:find("warn: Unicode icons expect 'emoji'; use :set emoji and reopen previews", 1, true) ~= nil
    assert(warned == (style == "unicode" and not emoji), report)
    assert(vim.o.emoji == emoji, "health must not change the user's emoji setting")
    assert(provider_loads == 0, "icon health must remain passive")
  end
end
vim.o.emoji = original_emoji
icons.setup { style = "nerd" }
messages = {}
vim.fn.executable = function(name)
  return name == "npx" and 1 or 0
end
require("md-render.health").check()
report = table.concat(messages, "\n")
assert(not report:find("may download and run", 1, true), "npx availability is not permission")
image.setup { mermaid_allow_npx = true }
messages = {}
require("md-render.health").check()
report = table.concat(messages, "\n")
assert(report:find("may download and run", 1, true), report)
image.setup { backend = "snacks" }
package.preload["snacks.image"] = function()
  error "health must not load or configure optional plugins"
end
messages = {}
require("md-render.health").check()
report = table.concat(messages, "\n")
assert(report:find("Snacks.image is not loaded", 1, true), report)
assert(report:find("image.enabled = true", 1, true), report)
assert(not package.loaded["snacks.image"])
local original_snacks = _G.Snacks
local text_size = require "md-render.text_size"
local original_status = text_size.status
local lazy_lookups, terminal_checks = 0, 0
_G.Snacks = setmetatable({}, {
  __index = function()
    lazy_lookups = lazy_lookups + 1
    error "health must not trigger Snacks' lazy module loader"
  end,
})
vim.api.nvim_list_uis = function()
  return { {} }
end
image.supports_kitty = function()
  terminal_checks = terminal_checks + 1
  return true
end
text_size.status = function()
  error "canary: heading status failed"
end
messages = {}
require("md-render.health").check()
report = table.concat(messages, "\n")
assert(lazy_lookups == 0 and terminal_checks == 0, "unloaded Snacks must not trigger module or terminal probes")
assert(report:find("Snacks.image is not loaded", 1, true), report)
assert(report:find("canary: heading status failed", 1, true) and report:find("textsize off", 1, true), report)
assert(report:find("Media cache:", 1, true) and report:find("restart Neovim and reopen", 1, true), report)
assert(not package.loaded["snacks.image"])
rawset(_G.Snacks, "image", {})
messages = {}
require("md-render.health").check()
report = table.concat(messages, "\n")
assert(lazy_lookups == 0 and terminal_checks == 1, "loaded Snacks may check terminal support")
assert(report:find("Snacks image module is available", 1, true), report)
_G.Snacks, text_size.status = original_snacks, original_status
vim.api.nvim_list_uis = function()
  return {}
end
require("md-render.text_size").setup { backend = "image" }
vim.system = function(cmd, opts)
  assert(opts.timeout == 5000 and cmd[3]:find("hasattr(Pango.FontMetrics, 'get_height')", 1, true))
  assert(opts.cwd == repo .. "/lua/md-render", "Python imports must use the trusted plugin directory")
  return {
    wait = function()
      return {
        code = 1,
        stderr = "Traceback\nAssertionError: automatic font size requires Pango 1.44+; upgrade Pango\n",
      }
    end,
  }
end
messages = {}
require("md-render.health").check()
report = table.concat(messages, "\n")
assert(report:find("Pango 1.44+; upgrade Pango", 1, true), report)
require("md-render.text_size").setup { image = { font_size = 16 } }
vim.system = function(cmd)
  assert(not cmd[3]:find("get_height", 1, true), "fixed font size must not impose an unused API requirement")
  return {
    wait = function()
      return { code = 0 }
    end,
  }
end
messages = {}
require("md-render.health").check()
report = table.concat(messages, "\n")
assert(report:find("available for image headings", 1, true), report)
vim.system = function()
  return {
    wait = function()
      return { code = 124, stderr = "" }
    end,
  }
end
messages = {}
require("md-render.health").check()
report = table.concat(messages, "\n")
assert(report:find("timed out after 5000 ms", 1, true), report)

-- Real Python can import project-side gi/cairo and startup hooks. Health must
-- remain safe when first loaded from that project, without disabling user sites.
do
  local python = vim.fn.exepath "python3"
  if python ~= "" then
    local project = vim.fn.tempname()
    vim.fn.mkdir(project, "p")
    local modules = { "gi", "cairo", "sitecustomize" }
    for _, name in ipairs(modules) do
      vim.fn.writefile({
        "from pathlib import Path",
        "Path(" .. vim.json.encode(project .. "/" .. name .. "-executed") .. ').write_text("loaded")',
      }, project .. "/" .. name .. ".py")
    end
    local control = real_system({ python, "-c", "import gi, cairo" }, {
      text = true,
      timeout = 5000,
      cwd = project,
      env = { PYTHONPATH = project, PYTHONSAFEPATH = "" },
    }):wait()
    assert(control.code == 0, control.stderr)
    for _, name in ipairs(modules) do
      assert(vim.fn.filereadable(project .. "/" .. name .. "-executed") == 1, "shadow-module control did not run")
      os.remove(project .. "/" .. name .. "-executed")
    end
    vim.fn.mkdir(project .. "/venv/bin", "p")
    assert(vim.uv.fs_symlink(python, project .. "/venv/bin/python"))
    local system = vim.system
    local expected, started
    vim.system = function(cmd, opts)
      assert(cmd[1] == expected and cmd[2] == "-c", "probe must retain the chosen Python and invocation")
      assert(opts.cwd == repo .. "/lua/md-render" and opts.env == nil and not opts.clear_env)
      local proc = real_system(cmd, opts)
      started = true
      return proc
    end
    vim.api.nvim_set_current_dir(project)
    -- Neovim resolves symlinked temporary directories when changing cwd.
    project = vim.fn.getcwd()
    for _, configured in ipairs { python, "./venv/bin/python" } do
      expected, started = configured == python and python or project .. "/venv/bin/python", false
      text_size.setup { image = { python = configured } }
      package.loaded["md-render.health"] = nil
      messages = {}
      require("md-render.health").check()
      report = table.concat(messages, "\n")
      assert(started, "configured Python failed to start from the trusted cwd: " .. report)
      assert(report:find("Media cache:", 1, true), "health did not finish the real probe")
      assert(not report:find("ENOENT", 1, true), "relative Python became unavailable after switching cwd")
      for _, name in ipairs(modules) do
        assert(vim.fn.filereadable(project .. "/" .. name .. "-executed") == 0, "health executed project-side " .. name)
      end
    end
    text_size.setup { image = { python = "./venv/bin/missing-python" } }
    vim.system = function(cmd, opts)
      assert(cmd[1] == "./venv/bin/missing-python" and opts.cwd == repo .. "/lua/md-render")
      return {
        wait = function()
          return { code = 1, stderr = "controlled unavailable interpreter" }
        end,
      }
    end
    messages = {}
    require("md-render.health").check()
    assert(table.concat(messages, "\n"):find("Image headings unavailable with ./venv/bin/missing-python", 1, true))
    vim.api.nvim_set_current_dir(repo)
    vim.system = system
    vim.fn.delete(project, "rf")
  else
    print "SKIP health shadow-module integration: python3 unavailable"
  end
end
print "Health: clear recovery, no lazy Snacks loads, isolated Python imports and safe native/headless probes"
