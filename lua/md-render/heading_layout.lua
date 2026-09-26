--- Shape each distinct heading once. Live contents own their cached layouts;
--- closing them releases PNG data without a persistent disk cache.
local M = {}
local cache = setmetatable({}, { __mode = "v" })
local pending, jobs = {}, {}
local closing = false
local script = debug.getinfo(1, "S").source:sub(2):match "(.*/)" .. "../../scripts/render-heading.py"

local function integer(value)
  return type(value) == "number" and value % 1 == 0
end

--- A failed or incompatible helper must leave usable text, not throw from an
--- async callback or replace the heading with malformed byte ranges.
local function valid_output(output, request)
  if type(output) ~= "table" or type(output.lines) ~= "table" or not vim.islist(output.lines) then return false end
  if #output.lines == 0 then return false end
  local text = request.entries[1].text
  local offset = 0
  for _, line in ipairs(output.lines) do
    if type(line) ~= "table" or not integer(line.start) or not integer(line["end"]) then return false end
    if line.start ~= offset or line["end"] < offset or line["end"] > #text then return false end
    if line.text ~= text:sub(line.start + 1, line["end"]) or not integer(line.cols) or line.cols < 1 then
      return false
    end
    offset = line["end"]
    if line.fallback then
      if type(line.fallback) ~= "string" then return false end
    else
      if type(line.data) ~= "string" or line.data == "" then return false end
      if not integer(line.width) or line.width < 1 or not integer(line.height) or line.height < 1 then return false end
      if type(line.columns) ~= "table" or not vim.islist(line.columns) or #line.columns ~= line.cols then
        return false
      end
      for _, byte in ipairs(line.columns) do
        if byte ~= false and (not integer(byte) or byte < 0 or byte >= #line.text) then return false end
      end
    end
  end
  return offset == #text
end

local function flush()
  local batch = pending
  pending = {}
  if #batch == 0 then return end
  local requests = {}
  for _, entry in ipairs(batch) do
    requests[#requests + 1] = entry.request
  end
  local function complete(result)
    vim.schedule(function()
      jobs[batch] = nil
      if closing then return end
      local ok, outputs = pcall(vim.json.decode, result.stdout or "")
      ok = ok and type(outputs) == "table" and vim.islist(outputs) and #outputs == #batch
      local failure
      for index, entry in ipairs(batch) do
        entry.ready = true
        local output = ok and outputs[index] or nil
        entry.output = result.code == 0 and valid_output(output, entry.request) and output or nil
        entry.error = not entry.output
            and (result.stderr and result.stderr ~= "" and result.stderr or "invalid renderer response")
          or nil
        failure = failure or entry.error
      end
      if failure then
        vim.notify_once("md-render: image heading renderer failed; using text. " .. failure, vim.log.levels.WARN)
      end
      local preview = package.loaded["md-render.preview"]
      if preview then preview.rebuild_visible(batch) end
    end)
  end
  local ok, job = pcall(
    vim.system,
    { batch[1].python, script },
    { stdin = vim.json.encode { requests = requests }, text = true },
    complete
  )
  if ok then
    jobs[batch] = job
  else
    complete { code = 1, stderr = tostring(job) }
  end
end

function M.request(request, python)
  local key = vim.fn.sha256(vim.inspect { request, python })
  if cache[key] then return cache[key] end
  local entry = { key = key, request = request, python = python }
  cache[key] = entry
  pending[#pending + 1] = entry
  if #pending == 1 then vim.schedule(flush) end
  return entry
end

function M.retry_failed()
  for key, entry in pairs(cache) do
    if entry.error then cache[key] = nil end
  end
end

vim.api.nvim_create_autocmd({ "ColorScheme", "VimResized" }, {
  callback = function()
    vim.schedule(function()
      local preview = package.loaded["md-render.preview"]
      if preview then preview.rebuild_visible() end
    end)
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    closing = true
    for _, job in pairs(jobs) do
      job:kill(15)
    end
  end,
})

return M
