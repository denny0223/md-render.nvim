--- Native heading transport. Read tmux's own terminal identification instead
--- of probing through a pane: terminal replies go to the active pane's input.
local M = {}

local pane_fields = {
  "pane_id",
  "session_id",
  "window_id",
  "pane_left",
  "pane_top",
  "pane_width",
  "pane_height",
  "pane_in_mode",
  "allow-passthrough",
  "window_linked",
  "pane_active",
  "window_width",
  "window_height",
  "focus-events",
}
local client_fields = {
  "client_tty",
  "session_id",
  "window_id",
  "client_termtype",
  "client_width",
  "client_height",
  "status",
  "status-position",
  "client_pid",
  "client_created",
  "client_control_mode",
  "client_flags",
}

local function format(fields)
  return "#{" .. table.concat(fields, "}\t#{") .. "}"
end

local function record(line, fields)
  local values, out = vim.split(line, "\t", { plain = true }), {}
  if #values ~= #fields then return nil end
  for i, name in ipairs(fields) do
    out[name] = values[i]
  end
  return out
end

function M.active()
  return vim.env.TMUX ~= nil or vim.env.TERM_PROGRAM == "tmux"
end

--- Interpret one read-only snapshot. Linked windows and multiple clients can
--- deliver the same absolute-position output to different grids; stay plain.
function M.parse(output, pane)
  local lines = vim.split(vim.trim(output), "\n", { plain = true })
  local p = record(lines[1], pane_fields)
  local ctx = { supported = false, drawable = false, key = output }
  if not p or p.pane_id ~= pane then
    ctx.reason = "tmux pane information is unavailable"
    return ctx
  end
  local clients = {}
  for i = 2, #lines do
    local client = record(lines[i], client_fields)
    if client and client.session_id == p.session_id and client.client_control_mode == "0" then
      clients[#clients + 1] = client
    end
  end
  if p["allow-passthrough"] ~= "on" and p["allow-passthrough"] ~= "all" then
    ctx.reason = "native headings require tmux allow-passthrough on or all"
  elseif p["focus-events"] ~= "1" then
    ctx.reason = "native headings require tmux focus-events on (reattach after changing it)"
  elseif p.window_linked ~= "0" then
    ctx.reason = "native headings do not support linked tmux windows"
  elseif #clients ~= 1 then
    ctx.reason = "native headings require one attached tmux client"
  else
    local c = clients[1]
    ctx.client = c.client_tty
    ctx.connection = c.client_pid .. ":" .. c.client_created
    local major, minor = c.client_termtype:match "^kitty%((%d+)%.(%d+)"
    if not major or (tonumber(major) == 0 and tonumber(minor) < 40) then
      ctx.reason = "tmux has not identified the client as Kitty >= 0.40"
    else
      local left, top = tonumber(p.pane_left), tonumber(p.pane_top)
      local width, height = tonumber(p.pane_width), tonumber(p.pane_height)
      local cols, rows = tonumber(c.client_width), tonumber(c.client_height)
      local window_width, window_height = tonumber(p.window_width), tonumber(p.window_height)
      local status = c.status == "on" and 1 or c.status == "off" and 0 or tonumber(c.status)
      if not (left and top and width and height and cols and rows and window_width and window_height and status) then
        ctx.reason = "tmux terminal geometry is unavailable"
      elseif left < 0 or top < 0 or width < 1 or height < 1 or window_width > cols or window_height > rows - status then
        ctx.reason = "native headings do not support cropped tmux windows"
      else
        ctx.supported = true
        ctx.left, ctx.top = left, top + (c["status-position"] == "top" and status or 0)
        ctx.width, ctx.height = width, height
        ctx.drawable = c.window_id == p.window_id
          and p.pane_in_mode == "0"
          and p.pane_active == "1"
          and not c.client_flags:find("suspended", 1, true)
      end
    end
  end
  ctx.key = table.concat({
    p.pane_id,
    ctx.connection or "",
    ctx.reason or "",
    tostring(ctx.drawable),
    ctx.left or "",
    ctx.top or "",
    ctx.width or "",
    ctx.height or "",
  }, ":")
  return ctx
end

local cached, sampled_at, connection, pending
local retry_ms = 50

function M.reset()
  if pending and pending.job then pcall(pending.job.kill, pending.job, 15) end
  cached, sampled_at, connection, pending = nil, nil, nil, nil
  retry_ms = 50
end

--- Redraw callbacks only read the last snapshot; they never wait for tmux.
--- Retry failures less often and discard results from a previous connection.
function M.get()
  local socket = (vim.env.TMUX or ""):match "^(.*),%d+,%d+$"
  local pane = vim.env.TMUX_PANE or ""
  local key = (socket or "") .. ":" .. pane
  local now = vim.uv.hrtime() / 1e6
  if connection ~= key then
    M.reset()
    connection = key
  end
  local unavailable =
    { supported = false, drawable = false, key = key, reason = "tmux connection information is unavailable" }
  if not socket or not pane:match "^%%%d+$" then return unavailable end
  if cached and (pending or now - sampled_at < retry_ms) then return cached end
  cached = cached or unavailable
  local request = {}
  pending, sampled_at = request, now
  local ok, job = pcall(
    vim.system,
    {
      "tmux",
      "-S",
      socket,
      "display-message",
      "-p",
      "-t",
      pane,
      format(pane_fields),
      ";",
      "list-clients",
      "-F",
      format(client_fields),
    },
    { text = true, timeout = 150 },
    vim.schedule_wrap(function(result)
      if pending ~= request then return end
      pending, sampled_at = nil, vim.uv.hrtime() / 1e6
      if result.code == 0 then
        cached, retry_ms = M.parse(result.stdout or "", pane), 50
      else
        cached, retry_ms = unavailable, 1000
        cached.reason = "cannot read the current tmux connection"
      end
    end)
  )
  if ok then
    request.job = job
  else
    pending, retry_ms = nil, 1000
    cached = unavailable
    cached.reason = "cannot read the current tmux connection"
  end
  return cached
end

function M.wrap(bytes)
  return "\27Ptmux;" .. bytes:gsub("\27", "\27\27") .. "\27\\"
end

--- Let tmux restore its own screen after a pane/client change. Clearing old
--- absolute coordinates ourselves could erase an unrelated pane or window.
function M.redraw(client)
  local socket = (vim.env.TMUX or ""):match "^(.*),%d+,%d+$"
  if socket and client then
    pcall(vim.system, { "tmux", "-S", socket, "refresh-client", "-t", client }, { timeout = 150 })
  end
end

return M
