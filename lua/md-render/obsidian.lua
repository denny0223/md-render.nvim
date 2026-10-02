--- Obsidian vault detection and file resolution.
--- Resolves Obsidian-style wikilink image references (![[image.png]])
--- by locating the vault root and searching for files within the vault.
local M = {}

--- Cache: dir → { vault_root = string|false, attachment_folder = string|false|nil }
--- false means "searched and not found" to avoid re-scanning.
---@type table<string, table|false>
local _vault_cache = {}

--- Cache: source directory + short filename → absolute path
---@type table<string, string>
local _file_cache = {}

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
  if info and info.attachment_folder ~= nil then
    if info.attachment_folder then return info.attachment_folder end
    return nil
  end

  local config_path = vault_root .. "/.obsidian/app.json"
  if vim.fn.filereadable(config_path) ~= 1 then
    if info then info.attachment_folder = false end
    return nil
  end

  local ok, lines = pcall(vim.fn.readfile, config_path)
  if not ok or not lines then
    if info then info.attachment_folder = false end
    return nil
  end

  local json_str = table.concat(lines, "\n")
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

  -- A ./attachments setting belongs to the source note's directory.
  local cache_key = buf_dir .. "\0" .. filename
  local cached = _file_cache[cache_key]
  if cached then
    if vim.fn.filereadable(cached) == 1 then return cached end
    _file_cache[cache_key] = nil
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
    if vim.fn.filereadable(att_path) == 1 then
      _file_cache[cache_key] = att_path
      return att_path
    end
  end

  -- Try vault root directly
  local root_path = vault_root .. "/" .. filename
  if vim.fn.filereadable(root_path) == 1 then
    _file_cache[cache_key] = root_path
    return root_path
  end

  -- Vault-wide search using vim.fs.find (limit=1 for early termination)
  local results = vim.fs.find(filename, {
    path = vault_root,
    upward = false,
    type = "file",
    limit = 1,
  })
  if results[1] then
    _file_cache[cache_key] = results[1]
    return results[1]
  end

  return nil
end

--- Clear all caches (for testing).
function M.reset_cache()
  _vault_cache = {}
  _file_cache = {}
end

return M
