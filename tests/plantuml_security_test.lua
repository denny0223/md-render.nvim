-- PlantUML execution policy and cache boundaries, without a renderer install.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local image = require "md-render.image"
local uv = vim.uv or vim.loop
local real_system, real_executable = vim.system, vim.fn.executable
local real_renderer, real_java = vim.fn.exepath "plantuml", vim.fn.exepath "java"
local real_jar = vim.env.PLANTUML_JAR
if not real_jar and vim.fn.filereadable "/usr/share/java/plantuml.jar" == 1 then
  real_jar = "/usr/share/java/plantuml.jar"
end
local conflicts = { PLANTUML_SECURITY_PROFILE = "SANDBOX" }
for _, name in ipairs { "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS" } do
  conflicts[name] = "-Dmd.render.keep=retained -Djava.awt.headless=true -DPLANTUML_SECURITY_PROFILE=LEGACY"
  vim.env[name] = conflicts[name]
end
local temp = vim.fn.tempname()
vim.fn.mkdir(temp, "p")
vim.fn.stdpath = function()
  return temp
end
vim.env.PLANTUML_JAR = temp .. "/plantuml.jar"
vim.fn.writefile({ "fixture" }, vim.env.PLANTUML_JAR)
local wrapper, jar, curl = true, false, true
vim.fn.executable = function(name)
  return ((name == "curl" and curl) or (name == "plantuml" and wrapper) or (name == "java" and jar)) and 1 or 0
end
local png = table.concat(vim.fn.readfile("tests/fixtures/test_4x4.png", "b"), "\n")
local jobs, probes, notices = {}, 0, {}
local real_notify_once = vim.notify_once
vim.notify_once = function(message, level)
  notices[#notices + 1] = { message = message, level = level }
end
local version_result = { code = 0, stdout = "PlantUML version 1.2020.11" }
vim.system = function(cmd, opts, callback)
  if cmd[1] ~= "curl" then
    assert(opts.env.PLANTUML_SECURITY_PROFILE == "SANDBOX", "every local launch must set SANDBOX")
    for name, value in pairs(conflicts) do
      if name ~= "PLANTUML_SECURITY_PROFILE" then
        assert(opts.env[name]:sub(1, #value) == value, "unrelated JVM options were removed")
        assert(opts.env[name]:match "%-DPLANTUML_SECURITY_PROFILE=SANDBOX %-Djava.awt.headless=true$")
      end
    end
    if cmd[1] == "java" then assert(cmd[2] == "-DPLANTUML_SECURITY_PROFILE=SANDBOX" and cmd[3] == "-jar") end
  end
  if cmd[#cmd] == "-version" then
    probes = probes + 1
    assert(opts.stdin == nil and opts.timeout == 1500, "probe must be bounded and have no document input")
    if version_result == false then error "controlled probe startup failure" end
    return {
      wait = function()
        return version_result
      end,
    }
  end
  jobs[#jobs + 1] = { cmd = cmd, callback = callback, env = opts.env }
  return { pid = 0 }
end
local function start(source)
  local result = {}
  image.render_plantuml_async(source, function(path)
    result.done, result.path = true, path
  end)
  return result
end
local function finish(index, ok)
  local job = assert(jobs[index])
  if job.cmd[1] == "curl" then
    for i, arg in ipairs(job.cmd) do
      if arg == "-o" then assert(uv.fs_copyfile("tests/fixtures/test_4x4.png", job.cmd[i + 1])) end
    end
  end
  job.callback { code = ok == false and 1 or 0, stdout = png }
  vim.wait(20)
end
local source = "@startuml\nAlice -> Bob: policy\n@enduml"
for _, result in ipairs {
  { code = 0, stdout = "PlantUML version 1.2020.2" },
  { code = 0, stdout = "PlantUML version 1.2020.10" },
  { code = 0, stdout = "unknown version" },
  { code = 124, stdout = "PlantUML version 1.2026.8" },
  { code = 1, stdout = "PlantUML version 1.2026.8" },
  false,
} do
  version_result = result
  image.reset_cache()
  local before = probes
  local available, reason = image.has_plantuml()
  assert(not available and not image.has_plantuml())
  if result and result.code == 0 and result.stdout:find("1.2020", 1, true) then
    assert(reason:find("too old", 1, true) and reason:find("upgrade to 1.2020.11+", 1, true), reason)
  elseif result and result.code == 0 then
    assert(reason:find("version unrecognized", 1, true), reason)
  else
    assert(reason:find("version check failed", 1, true) and reason:find("check Java", 1, true), reason)
  end
  assert(probes == before + 1, "unavailable result must be cached")
  local blocked = start(source)
  assert(blocked.done and not blocked.path and #jobs == 0, "unverified renderer received document source")
end
version_result = { code = 0, stderr = "PlantUML version 1.2020.11" }
image.reset_cache()
assert(image.has_plantuml(), "version may be on stderr")
assert(select(2, image.has_plantuml()):find("PlantUML 1.2020.11; local SANDBOX", 1, true))
local legacy = image.cache_dir() .. "/plantuml/" .. vim.fn.sha256(source):sub(1, 16) .. ".png"
vim.fn.mkdir(vim.fs.dirname(legacy), "p")
assert(uv.fs_copyfile("tests/fixtures/test_4x4.png", legacy))
assert(not image.get_plantuml_cached(source), "legacy cache crossed into SANDBOX")
local local_result = start(source)
assert(#jobs == 1 and not local_result.done)
finish(1)
assert(local_result.path and local_result.path ~= legacy)
assert(image.get_plantuml_cached(source) == local_result.path)

wrapper, jar = false, true
image.reset_cache()
local jar_result = start(source .. "\n'jar")
assert(jobs[2].cmd[1] == "java")
finish(2)
assert(jar_result.path)

jar = false
image.reset_cache()
image.setup { plantuml_server = "https://server-a.invalid/plantuml/" }
assert(not image.get_plantuml_cached(source), "local output crossed into remote policy")
local remote_a = start(source)
finish(3)
assert(remote_a.path and remote_a.path ~= local_result.path)
assert(image.get_plantuml_cached(source) == remote_a.path)
image.setup { plantuml_server = "https://server-a.invalid/plantuml" }
assert(image.get_plantuml_cached(source) == remote_a.path, "trailing slash should not invalidate identical server")
image.setup { plantuml_server = "https://server-b.invalid/plantuml" }
assert(not image.get_plantuml_cached(source), "output crossed between remote servers")
local remote_b = start(source)
finish(4)
assert(remote_b.path and remote_b.path ~= remote_a.path)

wrapper = true
image.reset_cache()
assert(image.get_plantuml_cached(source) == local_result.path, "remote output replaced local SANDBOX cache")
local uncached = source .. "\n'fallback"
image.setup { plantuml_server = "https://server-a.invalid" }
local available, status = image.has_plantuml()
assert(available and status:find("server fallback may receive diagram source on local failure", 1, true), status)
local notices_before = #notices
local first = start(uncached)
image.setup { plantuml_server = "https://server-b.invalid" }
local second = start(uncached)
assert(#jobs == 6, "different fallback policies shared in-flight work")
finish(5, false)
assert(jobs[7].cmd[#jobs[7].cmd]:find("https://server-a.invalid/", 1, true) == 1)
finish(6, false)
assert(jobs[8].cmd[#jobs[8].cmd]:find("https://server-b.invalid/", 1, true) == 1)
assert(#notices == notices_before, "local failure was reported before the final fallback outcome")
finish(7)
finish(8)
assert(first.path and second.path and first.path ~= second.path)
assert(#notices == notices_before + 2)
for i = notices_before + 1, #notices do
  assert(notices[i].level == vim.log.levels.INFO)
  assert(notices[i].message:find("rendered using configured server output", 1, true), notices[i].message)
  assert(notices[i].message:find("server rendering sends diagram source", 1, true), notices[i].message)
end
assert(not image.get_plantuml_cached(uncached), "remote fallback masqueraded as local SANDBOX output")
wrapper = false
image.reset_cache()
assert(image.get_plantuml_cached(uncached) == second.path)
-- An unsupported local executable may only fall back to an explicitly named server.
wrapper = true
version_result = { code = 0, stdout = "PlantUML version 1.2020.2" }
image.reset_cache()
local old_fallback = start(source .. "\n'old renderer")
assert(jobs[9].cmd[1] == "curl")
finish(9)
assert(old_fallback.path)

version_result = { code = 0, stdout = "PlantUML version 1.2020.11" }
image.reset_cache()
notices_before = #notices
local both_failed = start(source .. "\n'both failed")
finish(10, false)
assert(#notices == notices_before and not both_failed.done)
finish(11, false)
assert(both_failed.done and not both_failed.path and #notices == notices_before + 1)
assert(notices[#notices].message:find("local and configured server rendering both failed", 1, true))
assert(notices[#notices].message:find("PlantUML failed (exit 1)", 1, true))
assert(notices[#notices].message:find("curl (PlantUML server) failed (exit 1)", 1, true))
image.setup { plantuml_server = "file:///tmp/server" }
available, status = image.has_plantuml()
assert(available and status:find("fallback unavailable: an HTTP(S) URL is required", 1, true), status)
image.setup { plantuml_server = "https://server-b.invalid" }
curl = false
available, status = image.has_plantuml()
assert(available and status:find("fallback unavailable: curl is required", 1, true), status)
curl = true

-- Exercise the real tool only after the plugin's own version gate accepts it.
vim.system, vim.fn.executable = real_system, real_executable
vim.notify_once = real_notify_once
vim.env.PLANTUML_JAR = real_jar
image.setup { plantuml_server = "" }
local marker = "md-render-controlled-local-marker"
local json = temp .. "/marker.json"
vim.fn.writefile({ vim.json.encode { marker = marker } }, json)
local fixture = '@startuml\n!$data = %load_json("' .. json .. '")\nnote as N\n$data.marker\nend note\n@enduml'
local function real_render(cmd, env, source_text)
  return real_system(vim.list_extend(vim.deepcopy(cmd), { "-tsvg", "-pipe" }), {
    stdin = source_text,
    text = true,
    timeout = 30000,
    env = env,
  }):wait()
end
for _, mode in ipairs { "wrapper", "jar" } do
  local cmd, guarded_env
  if mode == "wrapper" and real_renderer ~= "" then
    cmd, guarded_env = { real_renderer }, jobs[1].env
  elseif mode == "jar" and real_java ~= "" and real_jar and vim.fn.filereadable(real_jar) == 1 then
    cmd, guarded_env = { real_java, "-DPLANTUML_SECURITY_PROFILE=SANDBOX", "-jar", real_jar }, jobs[2].env
    vim.fn.executable = function(name)
      return name ~= "plantuml" and real_executable(name) or 0
    end
  end
  image.reset_cache()
  if cmd and image.has_plantuml() then
    local legacy_cmd = vim.deepcopy(cmd)
    if mode == "jar" then legacy_cmd[2] = "-DPLANTUML_SECURITY_PROFILE=LEGACY" end
    local legacy_result = real_render(legacy_cmd, conflicts, fixture)
    assert(
      legacy_result.code == 0 and legacy_result.stdout:find(marker, 1, true),
      "LEGACY control must read the fixture"
    )
    local sandbox_result = real_render(cmd, guarded_env, fixture)
    assert(not sandbox_result.stdout:find(marker, 1, true), mode .. " inherited JVM options exposed the local marker")
    local ordinary = real_render(cmd, guarded_env, "@startuml\nAlice -> Bob\n@enduml")
    assert(ordinary.code == 0 and ordinary.stdout:find("<svg", 1, true), mode .. " ordinary rendering failed")
    print("PlantUML integration: " .. mode .. " overrides conflicting JVM options; LEGACY control reads marker")
  else
    assert(
      vim.env.MD_RENDER_REQUIRE_PLANTUML ~= "1",
      "required PlantUML integration unavailable: " .. mode .. " (missing or unsupported/unknown version)"
    )
    print("PlantUML integration skipped: " .. mode .. " unavailable or has an unsupported/unknown version")
  end
end
vim.fn.delete(temp, "rf")
print "PlantUML: wrapper/JAR SANDBOX, legacy/local/server cache separation, and in-flight policy capture passed"
