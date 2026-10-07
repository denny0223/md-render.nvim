--- Icon resolution for md-render.nvim
--- Uses icon providers or built-in icons, with an explicit Unicode fallback mode.
local M = {}

--- Nerd Font icon mapping for common file extensions.
--- Used as fallback when nvim-web-devicons / mini.icons is not available.
---@type table<string, string>
local file_ext_icons = {
  lua = "",
  py = "",
  js = "",
  ts = "",
  jsx = "",
  tsx = "",
  rb = "",
  go = "",
  rs = "",
  c = "",
  cpp = "",
  h = "",
  hpp = "",
  cs = "󰌛",
  java = "",
  kt = "",
  swift = "",
  php = "",
  r = "",
  sh = "",
  bash = "",
  zsh = "",
  fish = "",
  ps1 = "󰨊",
  vim = "",
  html = "",
  css = "",
  scss = "",
  sass = "",
  less = "",
  json = "",
  yaml = "",
  yml = "",
  toml = "",
  xml = "󰗀",
  md = "",
  markdown = "",
  txt = "󰈙",
  sql = "",
  graphql = "",
  dockerfile = "",
  docker = "",
  makefile = "",
  cmake = "",
  ex = "",
  exs = "",
  erl = "",
  hs = "",
  ml = "",
  clj = "",
  scala = "",
  dart = "",
  vue = "",
  svelte = "",
  zig = "",
  nim = "",
  perl = "",
  pl = "",
  diff = "",
  patch = "",
  lock = "",
  conf = "",
  cfg = "",
  ini = "",
  env = "",
  csv = "",
  svg = "󰜡",
  png = "",
  jpg = "",
  jpeg = "",
  gif = "",
  pdf = "",
  zip = "",
  gz = "",
  tar = "",
  tf = "󱁢",
  nix = "",
}

--- Special filename → icon mapping (case-insensitive basenames).
---@type table<string, string>
local file_name_icons = {
  makefile = "",
  dockerfile = "",
  gemfile = "",
  rakefile = "",
  procfile = "",
  vagrantfile = "⍱",
  [".gitignore"] = "",
  [".gitconfig"] = "",
  [".editorconfig"] = "",
  [".env"] = "",
}

--- Default image icon (Nerd Font)
local DEFAULT_IMAGE_ICON = "󰋩"

-- Emoji presentation uses two-cell slots with Neovim's default 'emoji' option.
-- A monochrome symbol font can supply the glyphs; the terminal selects fonts.
local UNICODE_IMAGE_ICON = "🖼️"
local UNICODE_VIDEO_ICON = "🎬"
local UNICODE_FILE_ICON = "📄"
local CHECKBOX_ICONS = {
  nerd = { [" "] = "󰄱", x = "󰄲", X = "󰄲", ["-"] = "󰡖" },
  unicode = { [" "] = "⬜", x = "✅", X = "✅", ["-"] = "➖" },
}
local UNICODE_CALLOUT_ICONS = {
  NOTE = "ℹ️",
  TIP = "💡",
  IMPORTANT = "❗️",
  WARNING = "⚠️",
  CAUTION = "⚠️",
  ABSTRACT = "📝",
  TODO = "📋",
  SUCCESS = "✅",
  QUESTION = "❓",
  FAILURE = "❌",
  DANGER = "⛔️",
  BUG = "🐛",
  EXAMPLE = "⚗️",
  QUOTE = "💬",
}

local config = { style = "nerd" }

--- Configure icons before opening a preview.
---@param opts? {style?: "nerd"|"unicode"}
function M.setup(opts)
  opts = opts or {}
  assert(type(opts) == "table", "icons.setup expects a table")
  if opts.style ~= nil then
    assert(opts.style == "nerd" or opts.style == "unicode", "icons.style must be nerd or unicode")
    config.style = opts.style
  end
end

---@return {style: "nerd"|"unicode"}
function M.config()
  return config
end

local function contains_private_use(icon)
  for _, code in ipairs(vim.fn.str2list(icon)) do
    if
      (code >= 0xE000 and code <= 0xF8FF)
      or (code >= 0xF0000 and code <= 0xFFFFD)
      or (code >= 0x100000 and code <= 0x10FFFD)
    then
      return true
    end
  end
  return false
end

local function accepts_provider_icon(icon)
  return icon and (config.style == "nerd" or (type(icon) == "string" and not contains_private_use(icon)))
end

--- Pad one-cell icon text to two display cells.
---@param icon string icon text
---@return string
function M.pad_icon(icon)
  if vim.api.nvim_strwidth(icon) == 1 then return icon .. " " end
  return icon
end

local function resolve_file(filename)
  -- Try nvim-web-devicons
  local ok, devicons = pcall(require, "nvim-web-devicons")
  if ok then
    local icon, hl = devicons.get_icon(filename, nil, { default = false })
    if accepts_provider_icon(icon) then return icon, hl, "nvim-web-devicons" end
  end

  -- Try mini.icons
  local ok2, mini_icons = pcall(require, "mini.icons")
  if ok2 then
    local ok3, icon, hl = pcall(mini_icons.get, "file", filename)
    if ok3 and accepts_provider_icon(icon) then return icon, hl, "mini.icons" end
  end

  -- Built-in fallback: check special filenames first
  local base = filename:match "[^/]+$" or filename
  local base_lower = base:lower()
  if file_name_icons[base_lower] then return file_name_icons[base_lower], nil, "builtin" end

  -- Then check extension
  local ext = base:match "%.([^.]+)$"
  if ext then
    ext = ext:lower()
    local icon = file_ext_icons[ext]
    if icon then
      if config.style == "unicode" and icon ~= "" then
        icon = ext == "svg" and UNICODE_IMAGE_ICON or UNICODE_FILE_ICON
      end
      return icon, nil, "builtin"
    end
  end

  -- Default file icon
  return "", nil, "generic"
end

local function resolve_media(path, kind)
  assert(kind == nil or kind == "image" or kind == "video", "media icon kind must be image or video")
  -- Extract basename from path or URL (strip query string / fragment)
  local clean = path:gsub("[?#].*$", "")
  local base = clean:match "([^/]+)$" or clean
  if base ~= "" then
    local icon, hl, source = resolve_file(base)
    if icon ~= "" and (config.style == "nerd" or source ~= "builtin") then return icon, hl, source end
  end
  if config.style == "unicode" then
    return kind == "video" and UNICODE_VIDEO_ICON or UNICODE_IMAGE_ICON, nil, "generic"
  end
  return DEFAULT_IMAGE_ICON, nil, "generic"
end

--- Get a file icon, preserving provider priority and colors.
---@param filename string
---@return string icon
---@return string? hl_group
function M.get_file_icon(filename)
  local icon, hl = resolve_file(filename)
  return icon, hl
end

--- Get an image/video icon; omitted kind retains the original image API.
---@param path string
---@param kind? "image"|"video"
---@return string icon
---@return string? hl_group
function M.get_image_icon(path, kind)
  local icon, hl = resolve_media(path, kind)
  return icon, hl
end

---@param key string canonical callout type
---@param original_icon string
---@return string
function M.get_callout_icon(key, original_icon)
  return config.style == "unicode" and UNICODE_CALLOUT_ICONS[key] or original_icon
end

---@param state " "|"x"|"X"|"-" parsed task marker
---@return string
function M.get_checkbox_icon(state)
  return CHECKBOX_ICONS[config.style][state]
end

---@param collapsed boolean
---@return string
function M.get_fold_icon(collapsed)
  if config.style == "unicode" then return collapsed and "▶️" or "🔽" end
  return collapsed and "󰅂" or "󰅀"
end

--- Resolve a requested icon for diagnostics, not terminal font detection.
---@param path string
---@param kind? "file"|"image"|"video" defaults to file
---@return {style: string, icon: string, hl?: string, source: string, codepoints: string[], width: integer} width is Neovim display cells
function M.inspect(path, kind)
  assert(kind == nil or kind == "file" or kind == "image" or kind == "video", "icon kind must be file, image or video")
  local icon, hl, source
  if kind == nil or kind == "file" then
    icon, hl, source = resolve_file(path)
  else
    icon, hl, source = resolve_media(path, kind)
  end
  local codepoints = {}
  for _, code in ipairs(vim.fn.str2list(icon)) do
    codepoints[#codepoints + 1] = string.format("U+%04X", code)
  end
  return {
    style = config.style,
    icon = icon,
    hl = hl,
    source = source,
    codepoints = codepoints,
    width = vim.api.nvim_strwidth(icon),
  }
end

return M
