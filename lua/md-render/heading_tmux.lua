--- Connection checks for image headings. Never changes tmux options or focus.
local M = {}
M.EVENT = "MdRenderTmuxChanged"
M.CHECKED_EVENT = "MdRenderTmuxChecked"

local state = { pending = true, reason = "checking tmux connection" }
local pending, timer, closed, process
local cleanup_pending = false
local checked_at = 0
local pane_fields = {
  "pane_id",
  "pane_in_mode",
  "allow-passthrough",
  "window_width",
  "window_height",
  "input-buffer-size",
  "window_id",
}
local client_fields = {
  "client_pid",
  "client_created",
  "client_termtype",
  "client_flags",
  "client_cell_width",
  "client_cell_height",
  "client_termfeatures",
  "client_width",
  "client_height",
  "status",
}
local pane_format = "#{" .. table.concat(pane_fields, "}\t#{") .. "}"
local client_format = "#{" .. table.concat(client_fields, "}\t#{") .. "}\t#{W:#{window_id}:}"
local fields = vim.list_extend(vim.deepcopy(pane_fields), client_fields)
fields[#fields + 1] = "windows"

local function publish(next_state)
  if vim.deep_equal(state, next_state) then return end
  state = next_state
  vim.api.nvim_exec_autocmds("User", { pattern = M.EVENT, modeline = false })
end

local function decode(result)
  if result.code ~= 0 then return { reason = "cannot inspect tmux connection" } end
  local lines = vim.split(vim.trim(result.stdout or ""), "\n", { trimempty = true })
  -- One pane snapshot followed by exactly one attached client.
  if #lines ~= 2 then return { reason = "image headings require one attached tmux client" } end
  local values = vim.split(lines[1] .. "\t" .. lines[2], "\t", { plain = true })
  if #values ~= #fields then return { reason = "tmux heading information is unavailable" } end
  local client = {}
  for index, name in ipairs(fields) do
    client[name] = values[index] or ""
  end
  if client.pane_id ~= vim.env.TMUX_PANE then return { reason = "tmux heading pane information is unavailable" } end
  -- A linked window can resolve to a different session than the attached client.
  if not vim.list_contains(vim.split(client.windows, ":", { trimempty = true }), client.window_id) then
    return { reason = "the heading pane has no attached tmux client" }
  end
  if client.pane_in_mode ~= "0" then return { reason = "tmux copy mode suspends image rendering" } end
  if client["allow-passthrough"] ~= "all" then
    return { reason = "tmux image headings require allow-passthrough all (on can drop uploads during redraw)" }
  end
  if client.client_flags:find "control%-mode" or client.client_flags:find "active%-pane" then
    return { reason = "this tmux client topology is not supported for image headings" }
  end
  local major, minor = client.client_termtype:match "^kitty%((%d+)%.(%d+)"
  if not major or (tonumber(major) == 0 and tonumber(minor) < 28) then
    return { reason = "tmux image headings require a confirmed Kitty 0.28 or newer client" }
  end
  if not client.client_termfeatures:find("RGB", 1, true) then
    return { reason = "tmux must preserve RGB colors for image placeholders" }
  end
  if not client.client_termfeatures:find("hyperlinks", 1, true) then
    return { reason = "tmux must preserve hyperlinks for image headings" }
  end
  local width, height = tonumber(client.client_cell_width), tonumber(client.client_cell_height)
  if not width or not height or width < 1 or height < 1 then
    return { reason = "tmux client cell dimensions are unavailable" }
  end
  local window_width, window_height = tonumber(client.window_width), tonumber(client.window_height)
  local client_width, client_height = tonumber(client.client_width), tonumber(client.client_height)
  local status_rows = tonumber(client.status) or (client.status == "on" and 1 or 0)
  -- Placeholder columns are inferred from the preceding cell. A panned tmux
  -- viewport can clip that origin without changing Neovim's own text area.
  if not window_width or not window_height or not client_width or not client_height then
    return { reason = "tmux viewport dimensions are unavailable" }
  end
  if window_width > client_width or window_height + status_rows > client_height then
    return { reason = "image headings require a tmux window that fits the client viewport" }
  end
  local buffer_size = tonumber(client["input-buffer-size"])
  if not buffer_size or buffer_size < 1 then return { reason = "tmux input buffer limit is unavailable" } end
  -- Tmux grows the control-sequence buffer by powers of two. Leave room for
  -- framing and its trailing NUL even when the configured limit is not a power.
  local limit = 1
  while limit * 2 <= buffer_size do
    limit = limit * 2
  end
  local owner = table.concat({ client.client_pid, client.client_created, client.client_termtype }, ":")
  return {
    owner = owner,
    key = table.concat({ owner, width, height }, ":"),
    cell = { cell_w = width, cell_h = height },
    limit = limit,
  }
end

local function preview_visible()
  local config = require("md-render.text_size").config()
  if not config.enabled or config.backend == "native" then return false end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.b[vim.api.nvim_win_get_buf(win)].md_render then return true end
  end
  return false
end

local function observe()
  if timer or closed or not (cleanup_pending or preview_visible()) then return end
  timer = vim.defer_fn(function()
    timer = nil
    if cleanup_pending or preview_visible() then M.status() end
  end, 250)
end

local function complete(next_state)
  pending, process = false, nil
  if closed then return end
  checked_at = vim.uv.now()
  publish(next_state)
  vim.api.nvim_exec_autocmds("User", { pattern = M.CHECKED_EVENT, modeline = false })
  observe()
end

local function check()
  if pending or closed then return end
  local socket = (vim.env.TMUX or ""):match "^(.*),%d+,%d+$"
  if not socket or not vim.env.TMUX_PANE or not vim.env.TMUX_PANE:match "^%%%d+$" or vim.fn.executable "tmux" == 0 then
    complete { reason = "tmux pane information is unavailable" }
    return
  end
  pending = true
  -- A late recheck is not a connection change; keep verified PNGs until its result.
  if not state.key and vim.uv.now() - checked_at > 500 then
    publish { pending = true, reason = "checking tmux connection" }
  end
  local ok, job = pcall(
    vim.system,
    -- list-clients' pane fields follow focus; inspect our own pane instead.
    {
      "tmux",
      "-S",
      socket,
      "display-message",
      "-p",
      "-t",
      vim.env.TMUX_PANE,
      pane_format,
      ";",
      "list-clients",
      "-F",
      client_format,
    },
    { text = true, timeout = 1000 },
    function(result)
      vim.schedule(function()
        complete(decode(result))
      end)
    end
  )
  if ok then
    process = job
  else
    complete { reason = "cannot inspect tmux connection: " .. tostring(job) }
  end
end

--- Cached paint context and whether an inspection is in flight.
function M.status()
  if not timer and vim.uv.now() - checked_at >= 250 then check() end
  observe()
  return state, pending
end

--- Retired PNGs may outlive a preview while tmux displays its copy-mode snapshot.
function M.watch_cleanup(waiting)
  cleanup_pending = waiting
  observe()
end

vim.api.nvim_create_autocmd("FocusGained", { callback = check })

--- Only graphics commands cross the boundary; placeholder cells use the TUI.
function M.wrap(data)
  return "\27Ptmux;" .. data:gsub("\27", "\27\27") .. "\27\\"
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    closed = true
    if process then process:kill(15) end
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end,
})

return M
