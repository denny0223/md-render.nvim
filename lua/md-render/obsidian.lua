--- Obsidian vault detection and file resolution.
--- Resolves Obsidian-style wikilink image references (![[image.png]])
--- by locating the vault root and searching for files within the vault.
local M = {}

--- Cache: dir → { vault_root = string|false, attachment_folder = string|false|nil }
--- false means "searched and not found" to avoid re-scanning.
---@type table<string, table|false>
local _vault_cache = {}

local CONFIG_BYTES = 1024 * 1024
local CACHE_NS = 30 * 1000000000
local SEARCH_NS = 50 * 1000000
local SEARCH_ENTRIES = 10000

--- Vault-wide fallback indexes, including misses, expire without editor restarts.
local _search_cache = {}

--- Find the Obsidian vault root by walking up from the given directory.
---@param buf_dir string  absolute directory path to start from
---@return string?  vault root directory, or nil if not in a vault
function M.find_vault_root(buf_dir)
  if _vault_cache[buf_dir] ~= nil then
    local cached = _vault_cache[buf_dir]
    if cached then return cached.vault_root or nil end
    return nil
  end

  local dir = buf_dir
  while dir and dir ~= "" do
    -- Check if an ancestor was already cached
    if dir ~= buf_dir and _vault_cache[dir] ~= nil then
      _vault_cache[buf_dir] = _vault_cache[dir]
      local cached = _vault_cache[dir]
      if cached then return cached.vault_root or nil end
      return nil
    end

    if vim.fn.isdirectory(dir .. "/.obsidian") == 1 then
      local info = { vault_root = dir }
      _vault_cache[dir] = info
      _vault_cache[buf_dir] = info
      return dir
    end

    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end

  _vault_cache[buf_dir] = false
  return nil
end

--- Read the attachment folder path from the vault's app.json config.
---@param vault_root string  vault root directory
---@return string?  attachment folder path, or nil if not configured
function M.get_attachment_folder(vault_root)
  local info = _vault_cache[vault_root]
  local now = vim.uv.hrtime()
  if info and now < (info.config_expires or 0) then return info.attachment_folder or nil end
  if info then
    info.attachment_folder = false
    info.config_expires = now + CACHE_NS
  end

  local config_path = vault_root .. "/.obsidian/app.json"
  local stat = vim.uv.fs_stat(config_path)
  if not stat or stat.type ~= "file" or stat.size > CONFIG_BYTES then return nil end

  -- The read itself is bounded even if the file grows after stat().
  local fd = vim.uv.fs_open(config_path, "r", 438)
  if not fd then return nil end
  local json_str = vim.uv.fs_read(fd, CONFIG_BYTES + 1, 0)
  vim.uv.fs_close(fd)
  if not json_str or #json_str > CONFIG_BYTES then return nil end

  local ok2, config = pcall(vim.json.decode, json_str)
  if not ok2 or type(config) ~= "table" or type(config.attachmentFolderPath) ~= "string" then
    if info then info.attachment_folder = false end
    return nil
  end

  local folder = config.attachmentFolderPath
  if info then info.attachment_folder = folder end
  return folder
end

--- Resolve an Obsidian file reference to an absolute path.
--- Explicit paths resolve directly; short names search attachments, then the vault.
---@param filename string  filename (e.g. "image.png" or "subfolder/image.png")
---@param buf_dir string  directory of the source markdown file
---@return string?  absolute path to the file, or nil if not found
function M.resolve(filename, buf_dir)
  local vault_root = M.find_vault_root(buf_dir)
  if not vault_root then return nil end

  if filename:find("/", 1, true) then
    if filename:sub(1, 1) == "/" then return nil end
    local relative = filename:sub(1, 2) == "./" or filename:sub(1, 3) == "../"
    local path = (relative and buf_dir or vault_root) .. "/" .. filename
    return vim.fn.filereadable(path) == 1 and path or nil
  end

  -- Try attachment folder first (most common location)
  local att_folder = M.get_attachment_folder(vault_root)
  if att_folder then
    local att_path
    if att_folder == "." or att_folder:sub(1, 2) == "./" then
      -- Relative to current file's directory
      local sub = att_folder:sub(3)
      if sub == "" then
        att_path = buf_dir .. "/" .. filename
      else
        att_path = buf_dir .. "/" .. sub .. "/" .. filename
      end
    else
      -- Relative to vault root
      att_path = vault_root .. "/" .. att_folder .. "/" .. filename
    end
    if vim.fn.filereadable(att_path) == 1 then return att_path end
  end

  -- Try vault root directly
  local root_path = vault_root .. "/" .. filename
  if vim.fn.filereadable(root_path) == 1 then return root_path end

  local now = vim.uv.hrtime()
  local search = _search_cache[vault_root]
  if not search or now >= search.expires then
    search = { expires = now + CACHE_NS, files = {} }
    _search_cache[vault_root] = search
    -- ponytail: fallback scans stop at 10,000 entries or 50 ms; explicit paths
    -- and attachment folders remain available beyond this discovery budget.
    local dirs, next_dir, count = { vault_root }, 1, 0
    while dirs[next_dir] do
      -- A recursive iterator can visit many empty directories without yielding.
      if count >= SEARCH_ENTRIES or vim.uv.hrtime() - now >= SEARCH_NS then break end
      local dir = dirs[next_dir]
      next_dir = next_dir + 1
      for name, kind in vim.fs.dir(dir) do
        count = count + 1
        if count > SEARCH_ENTRIES or vim.uv.hrtime() - now >= SEARCH_NS then break end
        local path = dir .. "/" .. name
        if kind == "file" and not search.files[name] then
          search.files[name] = path
        elseif kind == "directory" then
          dirs[#dirs + 1] = path
        end
      end
    end
  end
  local path = search.files[filename]
  return path and vim.fn.filereadable(path) == 1 and path or nil
end

--- Clear all caches (for testing).
function M.reset_cache()
  _vault_cache = {}
  _search_cache = {}
end

return M
