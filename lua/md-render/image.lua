--- Image display support for md-render.nvim
--- Uses Kitty Graphics Protocol to display images in terminal.
--- Supports PNG, JPEG, and WebP formats.
---
--- Two-phase approach:
---   1. transmit_image(): send image data to terminal with a=t (store, no display)
---   2. put_image(): display stored image at cursor with a=p (lightweight, repeatable)
--- This allows re-displaying images after redraws without retransmitting data.
---
--- Terminal output goes through `vim.api.nvim_ui_send` (Neovim >= 0.12), which
--- emits a "ui_send" event to the attached TUI. This avoids the /dev/tty open
--- dance and survives `:restart`.

local M = {}

local uv = vim.uv or vim.loop
local ffi = require "ffi"
local async = require "md-render.async"
local tty_mod = require "md-render.tty"

local IS_WINDOWS = ffi.os == "Windows"
local _kitty_supported = nil

-- ============================================================================
-- Configuration
-- ============================================================================

---@class MdRender.Image.Config
---@field backend? "kitty"|"snacks"
---@field plantuml_server string? base URL of a PlantUML server, e.g. `"https://www.plantuml.com/plantuml"`
---@field autoplay? boolean play GIF/video animations automatically (default true)
---@field mermaid_allow_npx? boolean allow npx to download/run Mermaid CLI (default false)

---@type MdRender.Image.Config
local config = {
  backend = "kitty",
  autoplay = true,
  mermaid_allow_npx = false,
  -- Unset on purpose. A PlantUML fence is rendered by a local `plantuml` or
  -- `java -jar $PLANTUML_JAR` if there is one; naming a server here is what
  -- allows the source of a diagram to leave the machine, and nothing else
  -- turns that on.
  plantuml_server = nil,
}

local _mmdc_cmd = nil
local _mmdc_checked = false

--- Configure image rendering.
---@param opts? MdRender.Image.Config
function M.setup(opts)
  opts = opts or {}
  if opts.backend then
    assert(opts.backend == "kitty" or opts.backend == "snacks", "unknown image backend")
    config.backend = opts.backend
    _kitty_supported = nil
  end
  if opts.plantuml_server ~= nil then
    config.plantuml_server = opts.plantuml_server ~= "" and opts.plantuml_server or nil
  end
  for _, name in ipairs { "autoplay", "mermaid_allow_npx" } do
    if opts[name] ~= nil then
      assert(type(opts[name]) == "boolean", name .. " must be a boolean")
      config[name] = opts[name]
    end
  end
  if opts.mermaid_allow_npx ~= nil then
    _mmdc_cmd = nil
    _mmdc_checked = false
  end
end

---@return MdRender.Image.Config
function M.config()
  return config
end

--- Directory containing this plugin's persistent media/diagram caches.
---@return string
function M.cache_dir()
  return vim.fn.stdpath "cache" .. "/md-render"
end

-- ============================================================================
-- Batched terminal writes
-- ============================================================================

local _batch_buffer = nil
local _batch_stack = nil
local _retained_images = {}

---@param data string
local function term_write(data)
  if data == "" then return end
  if _batch_buffer then
    table.insert(_batch_buffer, data)
    return
  end
  vim.api.nvim_ui_send(data)
end

local function retain_image(id)
  -- Kitty's screen clear frees image data after removing its last placement.
  -- A virtual placement is invisible and survives that clear, so redraws can
  -- reuse the upload. Other KGP terminals may ignore U and draw it instead.
  local version = tty_mod.kitty_version()
  if version and (version[1] > 0 or version[2] >= 28) then
    term_write(string.format("\x1b_Ga=p,i=%d,p=1,U=1,c=1,r=1,q=2\x1b\\", id))
    _retained_images[id] = true
  end
end

local function move_cursor(x, y)
  term_write("\x1b[" .. y .. ";" .. x .. "H")
end

--- Start batching terminal writes. Subsequent term_write calls accumulate
--- in memory instead of writing to the terminal immediately.
--- Supports nesting: inner batches append to the parent batch on flush.
function M.begin_batch()
  if _batch_buffer then
    -- Already batching: push current buffer onto stack
    _batch_stack = _batch_stack or {}
    table.insert(_batch_stack, _batch_buffer)
  end
  _batch_buffer = {}
end

--- Flush all accumulated terminal writes as a single write operation.
--- If nested, appends to the parent batch instead of writing to terminal.
function M.flush_batch()
  if not _batch_buffer then return end
  local data = table.concat(_batch_buffer)
  -- Pop parent batch if nested
  if _batch_stack and #_batch_stack > 0 then
    _batch_buffer = table.remove(_batch_stack)
    if data ~= "" then table.insert(_batch_buffer, data) end
  else
    _batch_buffer = nil
    if data ~= "" then term_write(data) end
  end
end

-- ============================================================================
-- Synchronized terminal update (DEC private mode 2026)
-- ============================================================================

--- Begin synchronized update. The terminal buffers all subsequent output
--- and renders it atomically when end_sync_update() is called.
--- Supported by WezTerm, Kitty, foot, and others.
function M.begin_sync_update()
  term_write "\x1b[?2026h"
end

--- End synchronized update and flush buffered output to screen.
function M.end_sync_update()
  term_write "\x1b[?2026l"
end

-- ============================================================================
-- Terminal cell size detection via TIOCGWINSZ
-- ============================================================================

local _ffi_declared = false
local function ensure_ffi()
  if _ffi_declared then return end
  _ffi_declared = true
  -- ioctl/winsize are POSIX-only; Windows has no equivalent in MSVCRT.
  if IS_WINDOWS then return end
  ffi.cdef [[
    typedef struct { unsigned short row; unsigned short col; unsigned short xpixel; unsigned short ypixel; } winsize;
    int ioctl(int, unsigned long, ...);
    int open(const char *path, int flags);
    int close(int fd);
  ]]
end

local TIOCGWINSZ = (vim.fn.has "mac" == 1 or vim.fn.has "bsd" == 1) and 0x40087468 or 0x5413

---@param exact? boolean require measured pixels for heading hit targets
---@return { cell_w: number, cell_h: number }?
function M.get_cell_size(exact)
  if M._test_cell_size then return M._test_cell_size end
  if exact and vim.env.TMUX then return require("md-render.heading_tmux").status().cell end
  if IS_WINDOWS then return nil end
  ensure_ffi()
  local sz = ffi.new "winsize"
  -- Try stdout (fd 1) first; after :restart it may be /dev/null,
  -- so fall back to opening the discovered TTY device.
  if ffi.C.ioctl(1, TIOCGWINSZ, sz) ~= 0 then
    local tty = tty_mod.get_tty_path()
    if not tty then return nil end
    local fd = ffi.C.open(tty, 0) -- O_RDONLY
    if fd < 0 then return nil end
    local rc = ffi.C.ioctl(fd, TIOCGWINSZ, sz)
    ffi.C.close(fd)
    if rc ~= 0 then return nil end
  end
  local xpixel, ypixel = sz.xpixel, sz.ypixel
  if sz.col == 0 or sz.row == 0 then return nil end
  if xpixel == 0 or ypixel == 0 then
    if exact then return nil end
    xpixel = sz.col * 8
    ypixel = sz.row * 16
  end
  return { cell_w = xpixel / sz.col, cell_h = ypixel / sz.row }
end

-- ============================================================================
-- Work already under way
-- ============================================================================

--- Work in flight, keyed by what it will produce.
---
--- The same image is asked for again long before the first request has
--- answered. Rebuilding the content is what does it, and that happens for
--- reasons that have nothing to do with the image: a resize reflows the text
--- (`WinResized` → live rebuild), a fold or an expandable region toggles, and
--- every burst of typing behind the live update in a split does too. Each ask
--- used to start its own work — another JVM for a PlantUML diagram, another
--- browser for a Mermaid one — and for a download, another curl writing over
--- the file the first curl had not finished writing.
---@type table<string, vim.async.Task>
local _in_flight = {}

--- Do `produce` for `key`, or join the run already under way, and answer
--- `callback` either way.
---
--- A task is a value: whoever asks second awaits the first one's rather than
--- starting its own, and both get the same answer. `produce` runs once.
---@param key string what the work will produce, usually the file's path
---@param produce async fun(): ... the work, run only if nobody else is on it
---@param callback fun(...) given whatever `produce` returned, or nothing on failure
local function shared_work(key, produce, callback)
  local task = _in_flight[key]
  if not task then
    task = async.run(produce)
    _in_flight[key] = task
    -- Release the key once the work is done, so a later ask — a retry after a
    -- failure, or a source file that changed — is allowed to try again.
    task:on_complete(function()
      _in_flight[key] = nil
    end)
  end

  async.run(function()
    local answer = vim.F.pack_len(async.pawait(task))
    if answer[1] then
      callback(unpack(answer, 2, answer.n))
    else
      callback(nil)
    end
  end)
end

-- ============================================================================
-- Image dimension detection from file headers
-- ============================================================================

local function read_header(path, n)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read(n)
  f:close()
  return data
end

local function be16(s, o)
  return s:byte(o) * 256 + s:byte(o + 1)
end
local function be32(s, o)
  return s:byte(o) * 16777216 + s:byte(o + 1) * 65536 + s:byte(o + 2) * 256 + s:byte(o + 3)
end
local function le16(s, o)
  return s:byte(o) + s:byte(o + 1) * 256
end
local function le24(s, o)
  return s:byte(o) + s:byte(o + 1) * 256 + s:byte(o + 2) * 65536
end

local function png_dimensions(path)
  local h = read_header(path, 24)
  if not h or #h < 24 or h:sub(1, 4) ~= "\137PNG" then return nil end
  return be32(h, 17), be32(h, 21)
end

local function jpeg_dimensions(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local offset, limit = 0, 16 * 1024 * 1024
  local function read(n)
    if offset + n > limit then return nil end
    local data = f:read(n)
    offset = offset + n
    return data and #data == n and data or nil
  end
  local function dimensions()
    if read(2) ~= "\255\216" then return nil end
    -- Bound both marker work and metadata span; skip APP/ICC payloads without
    -- reading the compressed image (or a large trailing payload) into Lua.
    for _ = 1, 1024 do
      local pair = read(2)
      if not pair or pair:byte(1) ~= 0xFF then return nil end
      local marker = pair:byte(2)
      if marker == 0xFF then
        if not f:seek("cur", -1) then return nil end
        offset = offset - 1 -- repeated FF fill byte
      elseif marker == 0 or marker == 0xDA or marker == 0xD9 then
        return nil -- dimensions must precede scan data/end of image
      elseif marker ~= 1 and marker ~= 0xD8 and not (marker >= 0xD0 and marker <= 0xD7) then
        local size = read(2)
        if not size then return nil end
        local length = be16(size, 1)
        if length < 2 then return nil end
        if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
          local data = length >= 8 and read(6)
          if not data then return nil end
          local components = data:byte(6)
          if components == 0 or length ~= 8 + 3 * components or not read(3 * components) then return nil end
          local width, height = be16(data, 4), be16(data, 2)
          if width > 0 and height > 0 then return width, height end
          return nil
        end
        offset = offset + length - 2
        if offset > limit or not f:seek("cur", length - 2) then return nil end
      end
    end
  end
  local width, height = dimensions()
  f:close()
  return width, height
end

local function webp_dimensions(path)
  local h = read_header(path, 30)
  if not h or #h < 16 or h:sub(1, 4) ~= "RIFF" or h:sub(9, 12) ~= "WEBP" then return nil end
  local chunk_type = h:sub(13, 16)
  if chunk_type == "VP8 " and #h >= 30 then
    if h:byte(24) == 0x9D and h:byte(25) == 0x01 and h:byte(26) == 0x2A then
      return bit.band(le16(h, 27), 0x3FFF), bit.band(le16(h, 29), 0x3FFF)
    end
  elseif chunk_type == "VP8L" and #h >= 26 then
    if h:byte(22) == 0x2F then
      local b = le16(h, 23) + le16(h, 25) * 65536
      return bit.band(b, 0x3FFF) + 1, bit.band(bit.rshift(b, 14), 0x3FFF) + 1
    end
  elseif chunk_type == "VP8X" and #h >= 30 then
    return le24(h, 25) + 1, le24(h, 28) + 1
  end
  return nil
end

local function gif_dimensions(path)
  local h = read_header(path, 10)
  if not h or #h < 10 then return nil end
  if h:sub(1, 3) ~= "GIF" then return nil end
  return le16(h, 7), le16(h, 9)
end

--- Check if a GIF file has multiple frames (is animated).
--- Only reads the first 64KB to avoid loading huge files.
---@param path string
---@return boolean
function M.is_animated_gif(path)
  local h = read_header(path, 6)
  if not h or h:sub(1, 3) ~= "GIF" then return false end
  -- Read first 64KB — enough to find a second Image Descriptor
  local f = io.open(path, "rb")
  if not f then return false end
  local data = f:read(65536)
  f:close()
  if not data then return false end
  local count = 0
  for pos = 1, #data do
    if data:byte(pos) == 0x2C then
      count = count + 1
      if count > 1 then return true end
    end
  end
  return false
end

--- Video file extensions supported for frame extraction
local VIDEO_EXTENSIONS = {
  mp4 = true,
  webm = true,
  mov = true,
  avi = true,
  mkv = true,
  m4v = true,
}

--- Check if a file path points to a video file (by extension).
---@param path string
---@return boolean
function M.is_video_file(path)
  local ext = path:match "%.(%w+)$"
  if not ext then return false end
  return VIDEO_EXTENSIONS[ext:lower()] == true
end

--- Check if a file contains video content by examining magic bytes.
--- Detects MP4 (ftyp), WebM/MKV (EBML), AVI (RIFF+AVI).
---@param path string
---@return boolean
function M.is_video_content(path)
  local h = read_header(path, 12)
  if not h or #h < 8 then return false end
  -- MP4/M4V: bytes 5-8 are "ftyp"
  if h:sub(5, 8) == "ftyp" then return true end
  -- WebM/MKV: starts with EBML header (0x1A45DFA3)
  if h:byte(1) == 0x1A and h:byte(2) == 0x45 and h:byte(3) == 0xDF and h:byte(4) == 0xA3 then return true end
  -- AVI: RIFF....AVI
  if h:sub(1, 4) == "RIFF" and #h >= 12 and h:sub(9, 11) == "AVI" then return true end
  return false
end

local _video_dimensions_cache = {}
local _video_dimensions_generation = 0

local function video_signature(path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then return nil end
  return table.concat({ stat.size, stat.mtime.sec, stat.mtime.nsec }, ":")
end

local function video_probe_cmd(path)
  return {
    "ffprobe",
    "-v",
    "error",
    "-select_streams",
    "v:0",
    "-show_entries",
    "stream=width,height",
    "-of",
    "csv=p=0:s=x",
    path,
  }
end

local function cache_video_dimensions(path, signature, generation, result)
  if generation ~= _video_dimensions_generation or signature ~= video_signature(path) then return nil, nil end
  local dimensions = { signature = signature }
  if result.code == 0 and result.stdout then
    local w, h = result.stdout:match "(%d+)x(%d+)"
    if w and h and tonumber(w) > 0 and tonumber(h) > 0 then
      dimensions[1], dimensions[2] = tonumber(w), tonumber(h)
    end
  end
  -- Cache failed probes too; retry when the file changes or reset_cache is called.
  _video_dimensions_cache[path] = dimensions
  return dimensions[1], dimensions[2]
end

--- Get original video dimensions. Successes and failures are cached by file stat.
---@param path string absolute path to video file
---@param cache_only? boolean never launch ffprobe during a content rebuild
---@return integer? width, integer? height
function M.video_dimensions(path, cache_only)
  local signature = video_signature(path)
  if not signature then return nil, nil end
  local cached = _video_dimensions_cache[path]
  if cached and cached.signature == signature then return cached[1], cached[2] end
  if cache_only then return nil, nil end
  local generation = _video_dimensions_generation
  if vim.fn.executable "ffprobe" ~= 1 then return cache_video_dimensions(path, signature, generation, {}) end
  return cache_video_dimensions(
    path,
    signature,
    generation,
    async.start_system(video_probe_cmd(path), { text = true, timeout = 5000 }):wait()
  )
end

--- Get video frame dimensions asynchronously using ffprobe.
--- Returns the original video dimensions (not the downscaled frame size).
---@param path string absolute path to video file
---@param callback fun(width: integer?, height: integer?)
function M.video_dimensions_async(path, callback)
  local signature = video_signature(path)
  if not signature then
    callback(nil, nil)
    return
  end
  local cached = _video_dimensions_cache[path]
  if cached and cached.signature == signature then
    callback(cached[1], cached[2])
    return
  end
  local generation = _video_dimensions_generation
  shared_work("dimensions:" .. generation .. ":" .. path .. ":" .. signature, function()
    if vim.fn.executable "ffprobe" ~= 1 then return cache_video_dimensions(path, signature, generation, {}) end
    return cache_video_dimensions(
      path,
      signature,
      generation,
      async.system(video_probe_cmd(path), { text = true, timeout = 5000 })
    )
  end, callback)
end

---@param path string
---@return integer? width, integer? height
function M.image_dimensions(path)
  local h = read_header(path, 4)
  if not h then return nil end
  if h:sub(1, 4) == "\137PNG" then return png_dimensions(path) end
  if h:byte(1) == 0xFF and h:byte(2) == 0xD8 then return jpeg_dimensions(path) end
  if h:sub(1, 4) == "RIFF" then return webp_dimensions(path) end
  if h:sub(1, 3) == "GIF" then return gif_dimensions(path) end
  local svg = read_header(path, 4096)
  local attrs = svg and svg:match "<svg%s(.-)>"
  if attrs then
    attrs = " " .. attrs
    local function dimension(name)
      local value = attrs:match("%s" .. name .. [=[%s*=%s*["']([^"']+)["']]=])
      return value and tonumber(value:match "^([%d.]+)$" or value:match "^([%d.]+)px$")
    end
    local w, height = dimension "width", dimension "height"
    if not w or not height then
      local box = attrs:match [=[%sviewBox%s*=%s*["']([^"']+)["']]=]
      if box then
        local values = {}
        for n in box:gmatch "[-+]?[%d.]+" do
          values[#values + 1] = tonumber(n)
        end
        if #values == 4 then
          w, height = values[3], values[4]
        end
      end
    end
    if w and height and w > 0 and height > 0 then return w, height end
  end
  return nil
end

-- ============================================================================
-- Mermaid diagram rendering
-- ============================================================================

--- Get cache directory for rendered mermaid diagrams
---@return string
local function get_mermaid_cache_dir()
  local dir = M.cache_dir() .. "/mermaid"
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Find the mmdc executable (mermaid CLI).
--- Searches PATH first, then falls back to npx.
---@return string[]? command prefix
local function find_mmdc()
  if _mmdc_checked then return _mmdc_cmd end
  _mmdc_checked = true
  if vim.fn.executable "mmdc" == 1 then
    _mmdc_cmd = { "mmdc" }
  elseif config.mermaid_allow_npx and vim.fn.executable "npx" == 1 then
    _mmdc_cmd = { "npx", "-y", "@mermaid-js/mermaid-cli@12.0.0" }
  end
  return _mmdc_cmd
end

--- Check if mermaid rendering is available
---@param notify? boolean explain the source fallback when rendering a document
---@return boolean
---@return string? reason
function M.has_mmdc(notify)
  if find_mmdc() then return true end
  local reason = "Mermaid CLI unavailable; install @mermaid-js/mermaid-cli (mmdc) and its browser"
  if config.mermaid_allow_npx then
    reason = reason .. "; npx fallback also needs Node.js/npm on Neovim's PATH"
  else
    reason = reason .. "; npx fallback is disabled"
  end
  if notify then
    vim.notify_once("md-render: " .. reason .. "; keeping code blocks; run :checkhealth md-render", vim.log.levels.WARN)
  end
  return false, reason
end

--- Detect whether Neovim is using a dark or light background and return
--- the appropriate mermaid theme name and background color hex string.
---@return string theme, string bg_hex
local function mermaid_theme_args()
  local bg = vim.o.background -- "dark" or "light"
  local hl = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  if not hl.bg then hl = vim.api.nvim_get_hl(0, { name = "Normal", link = false }) end
  local bg_color = hl.bg
  if bg == "dark" then
    local hex = bg_color and string.format("#%06x", bg_color) or "#1e1e2e"
    return "dark", hex
  else
    local hex = bg_color and string.format("#%06x", bg_color) or "#ffffff"
    return "default", hex
  end
end

--- Compute cache path for mermaid source (includes theme in hash).
---@param source string
---@return string
local function mermaid_cache_path(source)
  local theme, bg_hex = mermaid_theme_args()
  local hash = vim.fn.sha256(source .. "|" .. theme .. "|" .. bg_hex):sub(1, 16)
  return get_mermaid_cache_dir() .. "/" .. hash .. ".png"
end

--- Build the mmdc command arguments with theme-aware colors.
---@param cmd_prefix string[]
---@param input_path string
---@param output_path string
---@return string[]
local function build_mmdc_cmd(cmd_prefix, input_path, output_path)
  local theme, bg_hex = mermaid_theme_args()
  local cmd = vim.list_extend({}, cmd_prefix)
  vim.list_extend(cmd, {
    "-i",
    input_path,
    "-o",
    output_path,
    "-t",
    theme,
    "-b",
    bg_hex,
    "-s",
    "2",
  })
  return cmd
end

local function notify_failure(reason, level)
  reason = vim.fn.strcharpart(reason:gsub("%c", " "), 0, 500)
  vim.notify_once("md-render: " .. reason .. "; run :checkhealth md-render", level or vim.log.levels.WARN)
end

--- Keep a short useful tool error instead of its banner.
---@param tool string
---@param result vim.SystemCompleted
---@param purpose string
---@return string
local function tool_failure(tool, result, purpose)
  -- Keep the last couple of non-empty stderr lines. FFmpeg prints its banner
  -- and build configuration first, and splits the reason across two lines
  -- ("Unrecognized option 'vsync'." / "Error splitting the argument list: ..."),
  -- so one line is rarely the whole story. Anchoring a `$` match on the raw
  -- output silently matches nothing, because stderr ends with a newline.
  local lines = {}
  for line in (result.stderr or ""):gmatch "[^\r\n]+" do
    local trimmed = vim.trim(line)
    if trimmed ~= "" then table.insert(lines, trimmed) end
  end
  local detail = (result.stderr or ""):match "([^\r\n]*[Ee]rror:[^\r\n]*)"
    or table.concat(vim.list_slice(lines, math.max(1, #lines - 1)), " / ")
  if detail == "" then detail = result.code == 124 and "timed out" or "no error details" end
  detail = vim.fn.strcharpart(detail:gsub("%c", " "), 0, 240)
  return string.format("%s %s (exit %s): %s", tool, purpose, tostring(result.code), detail)
end

--- Publish only completed diagram output; cache readers must never see a partial file.
---@param quiet? boolean defer notification until the caller knows the final outcome
---@return string? path, string? reason
local function render_diagram_file(cache_path, render, tool, quiet)
  -- Keep the temporary output on the cache filesystem, with a name unique to this run.
  local tmp_output = cache_path .. "." .. vim.fn.sha256(vim.fn.tempname()):sub(1, 16) .. ".png"
  local ok, result = pcall(render, tmp_output)
  local installed, reason
  if not ok then
    reason = tool .. " could not complete: " .. tostring(result)
  elseif result.code ~= 0 then
    reason = tool_failure(tool, result, "failed")
  else
    local stat = uv.fs_stat(tmp_output)
    if not stat or stat.type ~= "file" or stat.size == 0 then
      reason = tool .. " produced no PNG output"
    elseif not png_dimensions(tmp_output) then
      reason = tool .. " produced invalid PNG output"
    else
      local err
      installed, err = uv.fs_rename(tmp_output, cache_path)
      if not installed then reason = "could not publish " .. tool .. " output to the media cache: " .. tostring(err) end
    end
  end
  os.remove(tmp_output)
  if reason and not quiet then notify_failure(reason, not ok and vim.log.levels.ERROR or nil) end
  return installed and cache_path or nil, reason
end

--- Built-in downloads have one literal HTTP(S) URL and a whole-process deadline.
local function curl_download(url, output, seconds, bytes)
  return async.system({
    "curl",
    "-q",
    "--globoff",
    "-fsSL",
    "--proto",
    "=http,https",
    "--proto-redir",
    "=http,https",
    "--max-time",
    tostring(seconds),
    "--max-filesize",
    tostring(bytes),
    "-o",
    output,
    "--",
    url,
  }, { text = true, timeout = seconds * 1000 + 1000 })
end

--- Keep npm/Puppeteer project configuration outside the viewed repository.
local function render_mermaid_file(source, cmd_prefix, cache_path, run)
  local tmp_dir = vim.fn.tempname()
  if vim.fn.mkdir(tmp_dir, "p", 448) == 0 then return nil end
  -- Puppeteer searches ancestors for executable configuration. A private cwd
  -- alone is insufficient when the temporary directory is inside a project.
  local ok, written = pcall(vim.fn.writefile, { "{}" }, tmp_dir .. "/.puppeteerrc")
  if not ok or written ~= 0 then
    vim.fn.delete(tmp_dir, "rf")
    return nil
  end
  if cmd_prefix[1] == "npx" then
    -- npm puts ancestor .bin directories before PATH, even with --prefix.
    local prepared, isolated = pcall(function()
      local node = vim.fn.exepath "node"
      local bin = tmp_dir .. "/node_modules/.bin"
      return node ~= "" and vim.fn.mkdir(bin, "p", 448) ~= 0 and uv.fs_symlink(node, bin .. "/node")
    end)
    if not prepared or not isolated then
      vim.fn.delete(tmp_dir, "rf")
      return nil
    end
  end
  local input = tmp_dir .. "/diagram.mmd"
  local f = io.open(input, "w")
  if not f then
    vim.fn.delete(tmp_dir, "rf")
    return nil
  end
  f:write(source)
  f:close()
  local path = render_diagram_file(cache_path, function(output)
    local cmd = build_mmdc_cmd(cmd_prefix, input, output)
    local opts = { text = true, timeout = 30000, cwd = tmp_dir }
    if cmd_prefix[1] == "npx" then
      -- cwd alone still lets npm discover a package.json/.npmrc in an ancestor.
      table.insert(cmd, 2, tmp_dir)
      table.insert(cmd, 2, "--prefix")
    end
    return run(cmd, opts)
  end, "mmdc (Mermaid)")
  vim.fn.delete(tmp_dir, "rf")
  return path
end

--- Check if a mermaid diagram is already cached (no rendering).
---@param source string mermaid diagram source code
---@return string? cached_path
function M.get_mermaid_cached(source)
  local cache_path = mermaid_cache_path(source)
  if vim.fn.filereadable(cache_path) == 1 then return cache_path end
  return nil
end

--- Render mermaid source code to a PNG image (synchronous, cached).
---@param source string mermaid diagram source code
---@return string? png_path
function M.render_mermaid(source)
  local cmd_prefix = find_mmdc()
  if not cmd_prefix then return nil end

  local cache_path = mermaid_cache_path(source)
  if vim.fn.filereadable(cache_path) == 1 then return cache_path end

  return render_mermaid_file(source, cmd_prefix, cache_path, function(cmd, opts)
    return async.start_system(cmd, opts):wait()
  end)
end

--- Render mermaid source code to a PNG image (asynchronous, cached).
---@param source string mermaid diagram source code
---@param callback fun(png_path: string?)
function M.render_mermaid_async(source, callback)
  local cmd_prefix = find_mmdc()
  if not cmd_prefix then
    callback(nil)
    return
  end

  local cache_path = mermaid_cache_path(source)
  if vim.fn.filereadable(cache_path) == 1 then
    callback(cache_path)
    return
  end

  shared_work(cache_path, function()
    return render_mermaid_file(source, cmd_prefix, cache_path, async.system)
  end, callback)
end

-- ============================================================================
-- PlantUML diagram rendering
-- ============================================================================

--- Get cache directory for rendered PlantUML diagrams
---@return string
local function get_plantuml_cache_dir()
  local dir = M.cache_dir() .. "/plantuml"
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Hex-encode a diagram source for PlantUML's "~h" URL scheme.
--- The server also accepts deflate+custom-base64, but that needs a compression
--- library; the hex scheme trades a longer URL for zero dependencies.
---@param source string
---@return string hex digits, without the "~h" prefix
local function plantuml_encode_hex(source)
  local parts = {}
  for i = 1, #source do
    parts[i] = string.format("%02x", source:byte(i))
  end
  return table.concat(parts)
end

--- Exposed for testing.
---@param source string
---@return string
function M._plantuml_encode_hex(source)
  return plantuml_encode_hex(source)
end

--- Find a local PlantUML renderer.
--- Prefers a `plantuml` wrapper on PATH; otherwise uses `java -jar` only when
--- PLANTUML_JAR explicitly points at a readable jar.
---@return string[]? command prefix
local _plantuml_cmd = nil
local _plantuml_checked = false
local _plantuml_status

local function plantuml_env()
  local env = { PLANTUML_SECURITY_PROFILE = "SANDBOX" }
  -- JVM properties override OS variables; each supported option source must end
  -- with our policy while retaining unrelated user options (heap size, proxies, etc.).
  for _, name in ipairs { "JAVA_TOOL_OPTIONS", "JDK_JAVA_OPTIONS", "_JAVA_OPTIONS" } do
    env[name] = (vim.env[name] or "") .. " -DPLANTUML_SECURITY_PROFILE=SANDBOX -Djava.awt.headless=true"
  end
  return env
end

local function find_plantuml()
  if _plantuml_checked then return _plantuml_cmd, _plantuml_status end
  _plantuml_checked = true
  _plantuml_status =
    "PlantUML unavailable; install PlantUML 1.2020.11+ or set PLANTUML_JAR to a readable JAR with java on PATH"
  local candidate
  if vim.fn.executable "plantuml" == 1 then
    candidate = { "plantuml" }
  elseif vim.fn.executable "java" == 1 and vim.env.PLANTUML_JAR and vim.fn.filereadable(vim.env.PLANTUML_JAR) == 1 then
    candidate = { "java", "-DPLANTUML_SECURITY_PROFILE=SANDBOX", "-jar", vim.env.PLANTUML_JAR }
  end
  if not candidate then return nil, _plantuml_status end
  -- Releases before 1.2020.11 silently ignore the security profile. Probe only
  -- the tool version, never document source, and cache an unavailable result too.
  local ok, result = pcall(function()
    local cmd = vim.list_extend(vim.list_extend({}, candidate), { "-version" })
    return async.start_system(cmd, { text = true, timeout = 1500, env = plantuml_env() }):wait()
  end)
  _plantuml_status =
    "PlantUML version check failed; run plantuml -version (or java -jar $PLANTUML_JAR -version) and check Java"
  if ok and result.code == 0 then
    local version = (result.stdout or "") .. "\n" .. (result.stderr or "")
    local major, year, release = version:match "PlantUML version%s+(%d+)%.(%d+)%.(%d+)"
    major, year, release = tonumber(major), tonumber(year), tonumber(release)
    if major and (major > 1 or (major == 1 and (year > 2020 or (year == 2020 and release >= 11)))) then
      _plantuml_cmd = candidate
      _plantuml_status = string.format("PlantUML %d.%d.%d; local SANDBOX rendering", major, year, release)
    elseif major then
      _plantuml_status =
        string.format("PlantUML %d.%d.%d is too old; upgrade to 1.2020.11+ for SANDBOX rendering", major, year, release)
    else
      _plantuml_status = "PlantUML version unrecognized; install PlantUML 1.2020.11+ with a working -version command"
    end
  end
  return _plantuml_cmd, _plantuml_status
end

--- Check if PlantUML rendering is available, locally or via a configured
--- server. Network availability can't be cheaply probed, so a server plus
--- curl counts as viable without asking whether it answers.
---@param notify? boolean explain the source fallback when rendering a document
---@return boolean
---@return string status
function M.has_plantuml(notify)
  local cmd, reason = find_plantuml()
  if cmd then
    if config.plantuml_server then
      if not M.is_url(config.plantuml_server) then
        reason = reason .. "; configured server fallback unavailable: an HTTP(S) URL is required"
      elseif vim.fn.executable "curl" ~= 1 then
        reason = reason .. "; configured server fallback unavailable: curl is required on Neovim's PATH"
      else
        reason = reason
          .. "; configured server fallback may receive diagram source on local failure (connection not checked)"
      end
    end
    return true, reason
  end
  if config.plantuml_server then
    if not M.is_url(config.plantuml_server) then
      reason = "PlantUML server must use an HTTP(S) URL"
    elseif vim.fn.executable "curl" ~= 1 then
      reason = "PlantUML server needs curl on Neovim's PATH"
    else
      return true, reason .. "; configured server will receive diagram source (connection not checked)"
    end
  end
  if notify then
    vim.notify_once("md-render: " .. reason .. "; keeping code blocks; run :checkhealth md-render", vim.log.levels.WARN)
  end
  return false, reason
end

--- Keep local SANDBOX results separate from legacy and remote-server output.
---@param source string
---@param server? string normalized remote server URL; nil means local SANDBOX
---@return string
local function plantuml_cache_path(source, server)
  local policy = server and "remote:" .. server or "local:SANDBOX:2"
  local hash = vim.fn.sha256("v2|" .. policy .. "|" .. source):sub(1, 16)
  return get_plantuml_cache_dir() .. "/" .. hash .. ".png"
end

local function plantuml_server()
  local server = config.plantuml_server
  return server and server:gsub("/+$", "") or nil
end

--- Check if a PlantUML diagram is already cached (no rendering).
---@param source string PlantUML diagram source code
---@return string? cached_path
function M.get_plantuml_cached(source)
  local local_renderer = find_plantuml() ~= nil
  local server = not local_renderer and plantuml_server() or nil
  if not local_renderer and not server then return nil end
  local cache_path = plantuml_cache_path(source, server)
  if vim.fn.filereadable(cache_path) == 1 then return cache_path end
  return nil
end

--- Render PlantUML source via a remote HTTP server.
---
--- Only ever reached when the user has named a server: a diagram is the
--- document, and sending it somewhere is not a fallback this plugin will pick
--- on its own. Without a local renderer and without a server, a `plantuml`
--- fence stays a code block — which is what a `mermaid` fence does without
--- `mmdc`.
---@async
---@param source string
---@param server string
---@param quiet? boolean
---@return string? png_path
---@return string? reason
local function render_plantuml_remote(source, server, quiet)
  local reason
  if not M.is_url(server) then
    reason = "configured PlantUML server must use an HTTP(S) URL"
  elseif vim.fn.executable "curl" ~= 1 then
    reason = "configured PlantUML server needs curl on Neovim's PATH"
  end
  if reason then
    if not quiet then notify_failure(reason) end
    return nil, reason
  end
  local cache_path = plantuml_cache_path(source, server)
  if vim.fn.filereadable(cache_path) == 1 then return cache_path end
  local url = server .. "/png/~h" .. plantuml_encode_hex(source)
  return render_diagram_file(cache_path, function(output)
    return curl_download(url, output, 15, 20000000)
  end, "curl (PlantUML server)", quiet)
end

--- Render PlantUML source code to a PNG image (asynchronous, cached).
--- Tries a local renderer first, and falls back to a server only when the user
--- has named one — see `M.setup`.
---@param source string PlantUML diagram source code
---@param callback fun(png_path: string?)
function M.render_plantuml_async(source, callback)
  local cmd_prefix = find_plantuml()
  local server = plantuml_server()
  if not cmd_prefix and not server then
    callback(nil)
    return
  end
  local cache_path = plantuml_cache_path(source, not cmd_prefix and server or nil)
  if vim.fn.filereadable(cache_path) == 1 then
    callback(cache_path)
    return
  end

  -- Capture the fallback policy too: a settings change must not join a request
  -- whose local failure would send the source to a different server.
  shared_work(cache_path .. "|" .. (server or ""), function()
    if not cmd_prefix then
      local path = render_plantuml_remote(source, server)
      return path
    end

    local cmd = vim.list_extend(vim.list_extend({}, cmd_prefix), { "-tpng", "-pipe" })
    local fallback = M.is_url(server) and vim.fn.executable "curl" == 1
    local path, reason = render_diagram_file(cache_path, function(output)
      local result = async.system(cmd, {
        stdin = source,
        text = false,
        timeout = 30000,
        env = plantuml_env(),
      })
      if result.code == 0 and result.stdout and #result.stdout > 0 then
        local f = io.open(output, "wb")
        if f then
          f:write(result.stdout)
          f:close()
        end
      end
      return result
    end, "PlantUML", fallback)
    if path or not fallback then return path end
    local remote, remote_reason = render_plantuml_remote(source, server, true)
    if remote then
      notify_failure(
        "PlantUML rendered using configured server output (server rendering sends diagram source); local failure: "
          .. reason,
        vim.log.levels.INFO
      )
    else
      notify_failure("PlantUML local and configured server rendering both failed: " .. reason .. " / " .. remote_reason)
    end
    return remote
  end, callback)
end

--- Check if file is a format the terminal can display directly (no conversion needed)
---@param path string
---@return boolean
function M.is_native_format(path)
  local h = read_header(path, 4)
  if not h then return false end
  -- Only PNG is natively supported by Kitty graphics protocol (f=100).
  -- GIF must be converted to PNG before transmission.
  return h:sub(1, 4) == "\137PNG"
end

-- ============================================================================
-- Kitty Graphics Protocol support detection
-- ============================================================================

local _is_ghostty = nil

-- Mutable module state hoisted here so M.reset_cache() (defined below, before the
-- sections that use these) resolves to the same upvalues. Declaring them only in
-- the later sections left reset_cache() writing to accidental globals instead.
local _convert_cmd = nil
local _convert_checked = false
local _anim_cmd = nil
local _anim_checked = false
local _image_id = 100
local _session_cleared = false

--- Check if running inside Ghostty terminal.
--- Ghostty does not support t=t (temporary file transfer mode) in Kitty
--- graphics protocol, so we must use t=f and clean up temp files ourselves.
local function is_ghostty()
  if _is_ghostty ~= nil then return _is_ghostty end
  _is_ghostty = vim.env.TERM_PROGRAM == "ghostty" or vim.env.GHOSTTY_RESOURCES_DIR ~= nil
  return _is_ghostty
end

--- Probe via APC query (Neovim 0.13+: vim.tty.query_apc).
--- Returns true when the terminal answered with a Kitty APC response, nil
--- otherwise (silent terminals are "unknown" — caller should fall back to
--- env var heuristics rather than treat silence as a definitive "no").
---@return true?
local function probe_kitty_via_apc()
  local ok, tty = pcall(require, "vim.tty")
  if not ok or type(tty) ~= "table" or type(tty.query_apc) ~= "function" then return nil end
  -- Some terminals (notably Apple Terminal) echo unknown APC payloads back
  -- into the buffer; skip the probe outright there.
  if vim.env.TERM_PROGRAM == "Apple_Terminal" then return nil end
  local supported = nil
  -- s=1, v=1 with no payload: the terminal replies "OK" or an error code
  -- without actually drawing anything.
  local query = "\x1b_Ga=q,s=1,v=1\x1b\\"
  pcall(tty.query_apc, query, { timeout = 200 }, function(resp)
    if type(resp) == "string" and resp:find("\x1b_G", 1, true) then
      supported = true
      return true
    end
  end)
  vim.wait(250, function()
    return supported ~= nil
  end, 20)
  return supported
end

function M.supports_kitty()
  if _kitty_supported ~= nil then return _kitty_supported end
  -- Windows lacks the POSIX TTY plumbing (isatty/ttyname/ioctl) this module
  -- relies on, so disable image rendering entirely on Windows.
  if IS_WINDOWS then
    _kitty_supported = false
    return false
  end
  -- The selected transport owns capability detection, including tmux clients.
  if config.backend == "snacks" then
    _kitty_supported = require("md-render.snacks_image").supported()
    return _kitty_supported
  end
  -- Prefer a real APC probe when Neovim provides one (0.13+). A silent
  -- terminal returns nil and we fall through to env var heuristics — only
  -- a positive APC response short-circuits.
  if probe_kitty_via_apc() then
    _kitty_supported = true
    return true
  end
  local term = vim.env.TERM_PROGRAM
  if term then
    local supported = { ["WezTerm"] = true, ["kitty"] = true, ["ghostty"] = true }
    if supported[term] then
      _kitty_supported = true
      return true
    end
  end
  -- Fallback: detect via terminal-specific env vars that Neovim may preserve
  -- even when TERM_PROGRAM is cleared
  if vim.env.KITTY_WINDOW_ID then
    _kitty_supported = true
    return true
  end
  if vim.env.GHOSTTY_RESOURCES_DIR then
    _kitty_supported = true
    return true
  end
  if vim.env.WEZTERM_EXECUTABLE then
    _kitty_supported = true
    return true
  end
  -- SSH normally forwards TERM, but not KITTY_WINDOW_ID or TERM_PROGRAM.
  -- Share the positive XTVERSION result with native heading detection.
  _kitty_supported = (vim.env.SSH_TTY ~= nil or vim.env.TERM == "xterm-kitty") and tty_mod.kitty_version() ~= nil
  return _kitty_supported
end

--- Reset in-memory capability/probe caches; does not remove persistent files.
function M.reset_cache()
  _kitty_supported = nil
  _is_ghostty = nil
  _session_cleared = false
  _convert_cmd = nil
  _convert_checked = false
  _anim_cmd = nil
  _anim_checked = false
  _plantuml_cmd = nil
  _plantuml_checked = false
  _plantuml_status = nil
  _mmdc_cmd = nil
  _mmdc_checked = false
  _video_dimensions_cache = {}
  _video_dimensions_generation = _video_dimensions_generation + 1
  tty_mod.reset()
  M.reset_png()
end

--- Override kitty support detection for testing.
---@param val boolean?
function M._set_kitty_supported(val)
  _kitty_supported = val
end

--- Reset image ID counter for testing.
function M._reset_image_id()
  _image_id = 100
end

-- ============================================================================
-- URL detection and download with cache
-- ============================================================================

--- Custom download function for authenticated or special URL handling.
--- Signature: fn(url, output_path, callback) -> handled
---   - url: the image URL to download
---   - output_path: absolute temporary path where the completed file should be saved
---   - callback: fun(ok: boolean) — finish writing before calling true; false means failure
---   - return true if this function handles the URL (callback will be called later)
---   - return false to fall back to the default curl downloader
---@type fun(url: string, output_path: string, callback: fun(ok: boolean)): boolean
local _custom_download_fn = nil

--- Register a custom download function for URL images.
--- The function is called before the default curl downloader. If it returns
--- true, it is expected to handle the download and call the callback. If it
--- returns false, the default curl-based downloader is used as a fallback.
---@param fn fun(url: string, output_path: string, callback: fun(ok: boolean)): boolean
function M.set_download_fn(fn)
  _custom_download_fn = fn
end

--- Check if a string is an HTTP(S) URL
---@param s string
---@return boolean
function M.is_url(s)
  return type(s) == "string" and not s:find "%c" and s:lower():match "^https?://" ~= nil
end

--- URLs that are badges or tiny icons — not worth displaying as block images
local BADGE_PATTERNS = {
  "img%.shields%.io",
  "badge%.fury%.io",
  "badgen%.net",
  "badges%.gitter%.im",
  "coveralls%.io/repos",
  "travis%-ci%.org",
  "ci%.appveyor%.com",
  "codecov%.io",
  "scan%.coverity%.com",
  "repology%.org/badge",
  "badges%.debian%.net",
  "github%.com/.*badge",
  "github%.com/.*/workflows/.*/badge",
  "img%.shields%.io",
  "flat%-square",
  "for%-the%-badge",
}

--- Check if a URL looks like a badge/shield image
---@param url string
---@return boolean
function M.is_badge_url(url)
  for _, pat in ipairs(BADGE_PATTERNS) do
    if url:match(pat) then return true end
  end
  return false
end

-- In-memory cache: URL -> local file path
local _url_cache = {}

--- Get cache directory for downloaded images
---@return string
local function get_cache_dir()
  local dir = M.cache_dir() .. "/images"
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Generate a cache filename from a URL
---@param url string
---@return string
local function url_to_cache_path(url)
  -- Use a hash of the URL as filename, preserve extension
  local hash = vim.fn.sha256(url):sub(1, 16)
  local ext = url:match "%.(%w+)$" or "png"
  -- Clean extension (remove query params)
  ext = ext:match "^(%w+)" or "png"
  return get_cache_dir() .. "/" .. hash .. "." .. ext
end

--- Check if a URL is already cached (in-memory or on disk).
---@param url string
---@return string? cached_path
function M.get_cached(url)
  if _url_cache[url] and vim.fn.filereadable(_url_cache[url]) == 1 then
    -- Validate cached file is a recognized image or video format
    if M.image_dimensions(_url_cache[url]) or M.is_video_content(_url_cache[url]) then return _url_cache[url] end
    -- Clear only our reference; a peer may have replaced these invalid bytes.
    _url_cache[url] = nil
    return nil
  end
  local cache_path = url_to_cache_path(url)
  if vim.fn.filereadable(cache_path) == 1 then
    -- Validate cached file is a recognized image or video format
    if M.image_dimensions(cache_path) or M.is_video_content(cache_path) then
      _url_cache[url] = cache_path
      return cache_path
    end
    -- A successful download atomically replaces invalid cache files.
    return nil
  end
  -- Try video extensions (file may have been renamed by finalize_download)
  local hash = cache_path:match "/([^/]+)%.[^.]+$"
  if hash then
    for _, ext in ipairs { "mp4", "webm", "avi" } do
      local alt_path = get_cache_dir() .. "/" .. hash .. "." .. ext
      if vim.fn.filereadable(alt_path) == 1 and M.is_video_content(alt_path) then
        _url_cache[url] = alt_path
        return alt_path
      end
    end
  end
  return nil
end

--- Detect video format from magic bytes and return the correct extension.
---@param path string
---@return string? ext  "mp4", "webm", or "avi"
local function detect_video_ext(path)
  local h = read_header(path, 12)
  if not h or #h < 8 then return nil end
  if h:sub(5, 8) == "ftyp" then return "mp4" end
  if h:byte(1) == 0x1A and h:byte(2) == 0x45 and h:byte(3) == 0xDF and h:byte(4) == 0xA3 then return "webm" end
  if h:sub(1, 4) == "RIFF" and #h >= 12 and h:sub(9, 11) == "AVI" then return "avi" end
  return nil
end

--- Validate completed output, then atomically publish it. Never remove a peer's cache entry.
---@param url string
---@param output string private staging path
---@param cache_path string
---@param video boolean skip image header validation for explicit video downloads
---@return string? path  nil when the download is not usable
---@return string? reason
local function finalize_download(url, output, cache_path, video)
  local stat = uv.fs_stat(output)
  if not stat or stat.type ~= "file" then return nil, "download produced no file" end
  if stat.size == 0 then return nil, "download produced an empty file" end
  if not video and not M.image_dimensions(output) then
    -- Check if it's a video with wrong extension
    local video_ext = detect_video_ext(output)
    if not video_ext then return nil, "downloaded content is not a supported image or video" end
    cache_path = cache_path:gsub("%.[^./]+$", "." .. video_ext)
  end
  local installed, err = uv.fs_rename(output, cache_path)
  if installed then
    _url_cache[url] = cache_path
    return cache_path
  end
  return nil, "could not publish downloaded media to the cache: " .. tostring(err)
end

--- Offer the download to the user's `set_download_fn`, if one is registered.
---
--- That function answers twice: it returns whether it took the job, and calls
--- back with the outcome if it did. A user's function is free to call back
--- before it returns, so reading `taken` after the await is only sound because
--- `vim.async` queues the resume rather than running it from inside the
--- callback. 0.12's `vim._async` did resume inline, which is one of the reasons
--- the plugin carries a copy of `vim.async` for it.
---@async
---@param url string
---@param cache_path string
---@return boolean taken  whether the user's function took the job
---@return boolean ok  what it reported; meaningless when `taken` is false
local function custom_download(url, cache_path)
  if not _custom_download_fn then return false, false end
  local taken = false
  local ok = async.await(1, function(callback)
    taken = _custom_download_fn(url, cache_path, callback)
    if not taken then callback(false) end
  end)
  return taken, ok
end

--- Keep partial built-in and custom output invisible to cache readers.
local function download_file(url, cache_path, video)
  local nonce = vim.fn.sha256(vim.fn.tempname()):sub(1, 16)
  local output = cache_path:gsub("(%.[^./]+)$", "." .. nonce .. "%1")
  local ok, result, reason = pcall(function()
    local taken, arrived = custom_download(url, output)
    if not taken then
      local transfer = curl_download(url, output, video and 30 or 10, video and 104857600 or 20000000)
      arrived = transfer.code == 0
      if not arrived then return nil, tool_failure("curl", transfer, "could not download media") end
    end
    if arrived then return finalize_download(url, output, cache_path, video) end
    return nil, "custom media downloader reported failure"
  end)
  os.remove(output)
  if not ok then
    notify_failure("media download failed: " .. tostring(result), vim.log.levels.ERROR)
  elseif reason then
    notify_failure(reason)
  end
  return ok and result or nil
end

--- Download a URL to a local file asynchronously.
---@param url string
---@param callback fun(path: string?)  called with local path on success, nil on failure
function M.download_async(url, callback)
  if not M.is_url(url) or M.is_badge_url(url) then
    callback(nil)
    return
  end

  local cached = M.get_cached(url)
  if cached then
    callback(cached)
    return
  end

  local cache_path = url_to_cache_path(url)

  shared_work(cache_path, function()
    return download_file(url, cache_path, false)
  end, callback)
end

--- Check if a video URL is already cached (in-memory or on disk).
--- Unlike get_cached(), this does not validate with image_dimensions().
---@param url string
---@return string? cached_path
function M.get_video_cached(url)
  local current = _url_cache[url] and uv.fs_stat(_url_cache[url])
  if current and current.type == "file" and current.size > 0 then return _url_cache[url] end
  local cache_path = url_to_cache_path(url)
  local stat = uv.fs_stat(cache_path)
  if stat and stat.type == "file" and stat.size > 0 then
    _url_cache[url] = cache_path
    return cache_path
  end
  return nil
end

--- Download a video URL to a local file asynchronously.
--- Unlike download_async(), this uses larger limits and skips image_dimensions validation.
---@param url string
---@param callback fun(path: string?)  called with local path on success, nil on failure
function M.download_video_async(url, callback)
  if not M.is_url(url) then
    callback(nil)
    return
  end
  local cached = M.get_video_cached(url)
  if cached then
    callback(cached)
    return
  end

  local cache_path = url_to_cache_path(url)

  shared_work(cache_path, function()
    return download_file(url, cache_path, true)
  end, callback)
end

--- Resolve an image source to a local file path (cache-only for URLs).
--- For URLs: returns cached path or nil (no download).
--- For local files: resolves path immediately.
---@param src string  image source (URL or path)
---@param base_dir? string  base directory for resolving relative paths
---@return string? resolved_path
function M.resolve(src, base_dir)
  if M.is_url(src) then
    if M.is_badge_url(src) then return nil end
    return M.get_cached(src)
  end
  return M.resolve_local(src, base_dir)
end

--- Resolve a literal local path, without Vim/shell expressions or environment expansion.
--- Only ~/ expands; URI schemes and NUL bytes are not local filenames.
---@param src string
---@param base_dir? string
---@return string? resolved_path
function M.resolve_local(src, base_dir)
  if type(src) ~= "string" or src == "" or src:find "%z" then return nil end
  local absolute = src:sub(1, 1) == "/" or (IS_WINDOWS and src:match "^%a:[/\\]")
  if src:match "^%a[%w+.-]*:" and not absolute then return nil end
  local resolved = src
  if src:sub(1, 2) == "~/" then
    local user_home = uv.os_homedir()
    if not user_home then return nil end
    resolved = user_home .. src:sub(2)
  elseif not absolute then
    local base = base_dir or uv.cwd()
    if not base then return nil end
    if base:sub(1, 1) ~= "/" and not (IS_WINDOWS and base:match "^%a:[/\\]") then base = uv.cwd() .. "/" .. base end
    resolved = base .. "/" .. src
  end

  if vim.fn.filereadable(resolved) == 1 then return resolved end

  -- Fallback: try Obsidian vault resolution
  if base_dir and not absolute and src:sub(1, 2) ~= "~/" then
    local obsidian = require "md-render.obsidian"
    local vault_resolved = obsidian.resolve(src, base_dir)
    if vault_resolved then return vault_resolved end
  end

  return nil
end

-- ============================================================================
-- Image conversion tool detection
-- ============================================================================

--- Detect the best available tool for static image conversion (JPEG/WebP → PNG).
--- Priority: sips (macOS) → ffmpeg → magick
---@return string? tool  "sips", "ffmpeg", or "magick"
local function find_convert_tool()
  if _convert_checked then return _convert_cmd end
  _convert_checked = true
  if vim.fn.has "mac" == 1 and vim.fn.executable "sips" == 1 then
    _convert_cmd = "sips"
  elseif vim.fn.executable "ffmpeg" == 1 then
    _convert_cmd = "ffmpeg"
  elseif vim.fn.executable "magick" == 1 then
    _convert_cmd = "magick"
  end
  return _convert_cmd
end

--- Detect the best available tool for animated GIF frame extraction.
--- Priority: ffmpeg → magick
---@return string? tool  "ffmpeg" or "magick"
local function find_anim_tool()
  if _anim_checked then return _anim_cmd end
  _anim_checked = true
  if vim.fn.executable "ffmpeg" == 1 then
    _anim_cmd = "ffmpeg"
  elseif vim.fn.executable "magick" == 1 then
    _anim_cmd = "magick"
  end
  if not _anim_cmd then
    vim.notify_once(
      "md-render: GIF frames need ffmpeg or magick; video frames need ffmpeg; run :checkhealth md-render",
      vim.log.levels.WARN
    )
  end
  return _anim_cmd
end

--- Maximum dimension (in pixels) for converted PNG output.
--- Larger source images are downscaled to fit within this bound.
local MAX_CONVERT_DIM = 2000

--- Build a command to convert a static image to PNG with resize.
---@param tool string  "sips", "ffmpeg", or "magick"
---@param src string  input file path
---@param dst string  output PNG path
---@return string[]
local function build_convert_cmd(tool, src, dst)
  local dim = tostring(MAX_CONVERT_DIM)
  if tool == "sips" then
    -- -Z resizes only if the image is larger than the specified dimension
    return { "sips", "-s", "format", "png", "-Z", dim, src, "--out", dst }
  elseif tool == "ffmpeg" then
    -- scale filter with force_original_aspect_ratio keeps aspect ratio;
    -- -vframes 1 ensures only one frame for static images
    return {
      "ffmpeg",
      "-y",
      "-i",
      src,
      "-vframes",
      "1",
      "-vf",
      "scale='min(" .. dim .. ",iw)':'min(" .. dim .. ",ih)':force_original_aspect_ratio=decrease",
      dst,
    }
  else
    return { "magick", src, "-delete", "1--1", "-resize", dim .. "x" .. dim .. ">", dst }
  end
end

-- ============================================================================
-- Image conversion
-- ============================================================================

--- Get cache directory for converted PNGs (JPEG/WebP → PNG).
---@return string
local function get_converted_cache_dir()
  local dir = M.cache_dir() .. "/converted"
  vim.fn.mkdir(dir, "p")
  return dir
end

--- Build a stable cache path for a converted PNG.
--- Includes mtime so updates to the source invalidate the cache automatically,
--- and MAX_CONVERT_DIM so changing the resize bound creates a separate entry.
---@param src_path string  absolute path to the source image
---@return string? cache_path  nil if mtime cannot be read
local function get_converted_cache_path(src_path)
  local mtime = vim.fn.getftime(src_path)
  if mtime < 0 then return nil end
  local hash = vim.fn.sha256(src_path):sub(1, 16)
  return string.format("%s/%s_%d_%d.png", get_converted_cache_dir(), hash, mtime, MAX_CONVERT_DIM)
end

local function ensure_png(path, system)
  if M.is_native_format(path) then return path, false end
  local tool = find_convert_tool()
  if not tool then
    vim.notify_once(
      "md-render: image conversion needs ffmpeg, magick or macOS sips; run :checkhealth md-render",
      vim.log.levels.WARN
    )
    return nil, false
  end
  local cache_path = get_converted_cache_path(path)
  if not cache_path then return nil, false end
  if vim.fn.filereadable(cache_path) == 1 then return cache_path, false end
  local output = render_diagram_file(cache_path, function(tmp)
    return system(build_convert_cmd(tool, path, tmp), { text = true, timeout = 30000 })
  end, tool)
  return output, false
end

--- Ensure image is PNG (synchronous), caching conversions on disk.
---@param path string
---@return string? png_path, boolean is_temp
function M.ensure_png(path)
  return ensure_png(path, function(cmd, opts)
    return async.start_system(cmd, opts):wait()
  end)
end

--- Ensure image is in a native format (asynchronous).
---@param path string
---@param callback fun(png_path: string?, is_temp: boolean)
function M.ensure_png_async(path, callback)
  async.run(function()
    callback(ensure_png(path, async.system))
  end)
end

--- Choose the rounding direction (floor vs ceil) for the dependent dimension
--- that best preserves the original pixel aspect ratio.
---@param fixed_cells integer  the already-determined cell count (cols or rows)
---@param fixed_cell_px number  pixel size of the fixed dimension's cell
---@param dep_px number  target pixel size of the dependent dimension
---@param dep_cell_px number  pixel size of the dependent dimension's cell
---@param dep_max integer  upper bound for the dependent cell count
---@param img_w integer  original image width
---@param img_h integer  original image height
---@param fixed_is_cols boolean  true when fixed dimension is columns
---@return integer
local function best_round(fixed_cells, fixed_cell_px, dep_px, dep_cell_px, dep_max, img_w, img_h, fixed_is_cols)
  local r_floor = math.max(1, math.floor(dep_px / dep_cell_px))
  local r_ceil = math.min(dep_max, math.ceil(dep_px / dep_cell_px))
  if r_floor == r_ceil then return r_floor end
  local target = img_w / img_h
  local fl_ratio, cl_ratio
  if fixed_is_cols then
    fl_ratio = (fixed_cells * fixed_cell_px) / (r_floor * dep_cell_px)
    cl_ratio = (fixed_cells * fixed_cell_px) / (r_ceil * dep_cell_px)
  else
    fl_ratio = (r_floor * dep_cell_px) / (fixed_cells * fixed_cell_px)
    cl_ratio = (r_ceil * dep_cell_px) / (fixed_cells * fixed_cell_px)
  end
  if math.abs(fl_ratio - target) <= math.abs(cl_ratio - target) then return r_floor end
  return r_ceil
end

---@param img_w integer
---@param img_h integer
---@param max_cols integer
---@param max_rows integer
---@return integer cols, integer rows
function M.calc_display_size(img_w, img_h, max_cols, max_rows)
  local cell = M.get_cell_size()
  if not cell then return math.min(20, max_cols), math.min(10, max_rows) end

  -- Work in pixel space to minimize aspect-ratio distortion from rounding.
  local max_w = max_cols * cell.cell_w
  local max_h = max_rows * cell.cell_h

  -- Scale to fit within bounds (don't upscale)
  local scale = math.min(max_w / img_w, max_h / img_h, 1.0)

  local pixel_w = img_w * scale
  local pixel_h = img_h * scale

  -- Determine the constraining dimension and compute the other
  -- with optimal rounding to best preserve the aspect ratio.
  local cols, rows
  if max_w / img_w <= max_h / img_h then
    -- Width-constrained: fix cols, compute rows
    cols = math.min(max_cols, math.ceil(pixel_w / cell.cell_w))
    rows = best_round(cols, cell.cell_w, pixel_h, cell.cell_h, max_rows, img_w, img_h, true)
  else
    -- Height-constrained: fix rows, compute cols
    rows = math.min(max_rows, math.ceil(pixel_h / cell.cell_h))
    cols = best_round(rows, cell.cell_h, pixel_w, cell.cell_w, max_cols, img_w, img_h, false)
  end

  return math.max(1, cols), math.max(1, rows)
end

-- ============================================================================
-- Two-phase image display: transmit + put
-- ============================================================================

local _image_paths = {} -- image_id → file path (for Ghostty a=T workaround)
local _temp_image_paths = {} -- image_id → true for temp files that need cleanup

-- PNG queries and uploads share one response listener. A returned image ID
-- alone says nothing about whether the terminal accepted the bytes.
local png_pending, png_probe = {}, nil
local png_refresh_pending = false
local png_connections, png_deletes = {}, {}
local tmux_id_base

local function png_write(data)
  if vim.env.TMUX then data = require("md-render.heading_tmux").wrap(data) end
  return pcall(term_write, data)
end

local function next_png_id()
  _image_id = _image_id + 1
  if not vim.env.TMUX then return _image_id end
  -- A terminal is shared by Neovim instances in different panes. Avoid each
  -- instance starting at image 101; placeholders carry this 24-bit ID as RGB.
  tmux_id_base = tmux_id_base or tonumber(vim.fn.sha256(vim.fn.getpid() .. ":" .. uv.hrtime()):sub(1, 6), 16)
  return (tmux_id_base + _image_id) % 0xFFFFFF + 1
end

local function refresh_headings()
  if png_refresh_pending then return end
  png_refresh_pending = true
  vim.schedule(function()
    png_refresh_pending = false
    local preview = package.loaded["md-render.preview"]
    if preview then preview.rebuild_visible() end
  end)
end

local function cancel_png(id)
  local pending = png_pending[id]
  if not pending then return end
  png_pending[id] = nil
  if pending.timer and not pending.timer:is_closing() then
    pending.timer:stop()
    pending.timer:close()
  end
  return pending.callback
end

local function finish_png(id, err)
  local callback = cancel_png(id)
  if callback then vim.schedule(function()
    callback(err)
  end) end
end

local function await_png(id, callback)
  png_pending[id] = { callback = callback }
  png_pending[id].timer = vim.defer_fn(function()
    finish_png(id, "terminal PNG response timed out")
  end, 1500)
end

vim.api.nvim_create_autocmd("TermResponse", {
  callback = function(ev)
    local sequence = type(ev.data) == "table" and ev.data.sequence or ev.data
    if type(sequence) ~= "string" then return end
    local id, response = sequence:match "^\27_Gi=(%d+);(.*)"
    if not id then return end
    response = response:gsub("\27\\$", "")
    finish_png(tonumber(id), response ~= "OK" and response or nil)
  end,
})

function M.reset_png()
  if png_probe and png_probe.id then cancel_png(png_probe.id) end
  png_probe = nil
end

function M.fail_png(reason)
  M.reset_png()
  png_probe = { supported = false, reason = reason }
  refresh_headings()
end

--- Direct terminals confirm PNG support. Tmux uses inspected client capability
--- and quiet output: replies cannot be routed safely across pane/popup changes.
function M.png_status()
  if IS_WINDOWS then return { supported = false, reason = "image transport is unavailable on Windows" } end
  if #vim.api.nvim_list_uis() == 0 or type(vim.api.nvim_ui_send) ~= "function" then
    return { supported = false, reason = "no terminal UI attached" }
  end
  if not vim.env.TMUX and vim.env.TERM_PROGRAM == "tmux" then
    return { supported = false, reason = "tmux connection information is unavailable" }
  end
  if vim.env.TMUX then
    local connection = require("md-render.heading_tmux").status()
    if connection.pending then return { reason = connection.reason } end
    if not connection.key then return { supported = false, reason = connection.reason } end
    return png_probe or { supported = true, reason = "tmux quiet transport; uploads are not acknowledged" }
  end
  if vim.env.TERM_PROGRAM == "Apple_Terminal" then
    return { supported = false, reason = "terminal does not support PNG graphics" }
  end
  if png_probe then return png_probe end
  local version = tty_mod.kitty_version()
  if version and version[1] == 0 and version[2] < 28 then
    return { supported = false, reason = "image headings require Kitty 0.28 or newer" }
  end
  local probe = { id = next_png_id(), reason = "waiting for terminal PNG support" }
  png_probe = probe
  await_png(probe.id, function(err)
    if png_probe ~= probe then return end
    probe.supported, probe.reason = err == nil, err
    if not err then _kitty_supported = true end
    refresh_headings()
  end)
  -- a=q validates a real 1x1 PNG without storing or displaying it.
  local png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
  local ok, err = png_write(string.format("\27_Ga=q,t=d,f=100,i=%d;%s\27\\", probe.id, png))
  if not ok then M.fail_png(tostring(err)) end
  return png_probe
end

vim.api.nvim_create_autocmd("User", {
  pattern = "MdRenderTmuxChanged",
  callback = function()
    M.reset_png()
    local tmux = require "md-render.heading_tmux"
    local connection = tmux.status().owner
    if connection then
      for id, owner in pairs(png_deletes) do
        if owner == connection then png_write(string.format("\27_Ga=d,d=I,i=%d,q=2\27\\", id)) end
        png_deletes[id] = nil
      end
      tmux.watch_cleanup(false)
    end
    refresh_headings()
  end,
})

vim.api.nvim_create_autocmd({ "UIEnter", "UILeave" }, {
  callback = function()
    M.reset_png()
    refresh_headings()
  end,
})

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    for id in pairs(png_pending) do
      cancel_png(id)
    end
  end,
})

--- Transmit base64-encoded PNG bytes without requiring a shared filesystem.
--- Each Kitty payload is at most 4096 bytes, including on an SSH TTY.
---@param callback? fun(error?: string) after direct ACK/timeout, or queued tmux output
---@param cols? integer tmux virtual placement width (default 1)
---@param rows? integer tmux virtual placement height (default 1)
---@return integer? id
---@return string? error
function M.transmit_png(data, callback, cols, rows)
  if data == "" then return nil end
  local connection = vim.env.TMUX and require("md-render.heading_tmux").status()
  if connection then
    if not connection.key then return nil end
  else
    if not M.supports_kitty() then return nil end
    -- Resolve before uploading: the identity query can yield to a screen clear.
    tty_mod.kitty_version()
    M.clear_all()
  end
  local id = next_png_id()
  png_connections[id] = connection and connection.owner or nil
  if callback and not connection then await_png(id, callback) end
  local params =
    string.format("a=%s,f=100,t=d,i=%d,q=%d,", connection and "T" or "t", id, callback and not connection and 0 or 2)
  if connection then
    -- Upload and create an invisible virtual placement in one Kitty operation.
    -- Separate commands let an intervening tmux clear free the uploaded PNG.
    params = params .. string.format("U=1,p=1,c=%d,r=%d,", cols or 1, rows or 1)
  end
  local chunks = {}
  for start = 1, #data, 4096 do
    local more = start + 4096 <= #data and 1 or 0
    local header = start == 1 and params or (connection and "q=2," or "")
    chunks[#chunks + 1] = string.format("\x1b_G%sm=%d;%s\x1b\\", header, more, data:sub(start, start + 4095))
  end
  if connection then
    -- One DCS makes tmux forward the complete upload without interleaving its
    -- own screen clears between KGP chunks. Oversized DCS input is discarded.
    local payload = require("md-render.heading_tmux").wrap(table.concat(chunks))
    if #payload >= connection.limit then
      png_connections[id] = nil
      return nil, "heading PNG exceeds tmux input-buffer-size; using text"
    end
    chunks = { payload }
  end
  for _, chunk in ipairs(chunks) do
    local ok, err = pcall(term_write, chunk)
    if not ok then
      cancel_png(id)
      png_connections[id] = nil
      return nil, tostring(err)
    end
  end
  if connection then
    if callback then
      vim.schedule(function()
        if
          png_connections[id] == connection.owner and require("md-render.heading_tmux").status().key == connection.key
        then
          callback()
        end
      end)
    end
  else
    retain_image(id)
  end
  return id
end

--- Transmit image data to terminal (store without displaying).
--- The image can then be displayed cheaply with put_image().
---@param path string absolute path to image file
---@return integer? image_id
function M.transmit_image(path)
  if not M.supports_kitty() then return nil end

  local png_path, is_temp = M.ensure_png(path)
  if not png_path then return nil end

  tty_mod.kitty_version()
  _image_id = _image_id + 1
  local id = _image_id

  local b64_path = vim.base64.encode(png_path)
  -- Ghostty does not support t=t; always use t=f and delete temp files ourselves
  local t = (is_temp and not is_ghostty()) and "t" or "f"

  -- a=t: transmit and store, q=2: suppress all responses
  local message = string.format("\x1b_Ga=t,f=100,t=%s,i=%d,q=2;%s\x1b\\", t, id, b64_path)
  term_write(message)
  retain_image(id)

  if is_temp and is_ghostty() then
    -- Ghostty uses a=T (re-reads the file on each placement), so keep temp
    -- files alive until the image is deleted.  Mark for deferred cleanup.
    _temp_image_paths[id] = true
  end

  _image_paths[id] = png_path
  return id
end

local MAX_ANIM_FRAMES = 300 -- max frames to extract (= 60 seconds at 5 fps)

--- Build a command to extract frames from an animated GIF.
---@param tool string  "ffmpeg" or "magick"
---@param path string  GIF file path
---@param cache_dir string  output directory
---@param total_frames integer  total number of frames
---@return string[] cmd
local function build_frame_extract_cmd(tool, path, cache_dir, total_frames)
  if tool == "ffmpeg" then
    local vf_parts = {}
    -- Convert to display frame rate (5 fps matches the 200 ms animation timer)
    table.insert(vf_parts, "fps=5")
    table.insert(vf_parts, "scale='min(400,iw)':'min(400,ih)':force_original_aspect_ratio=decrease")
    -- GIFs can report an unset pixel aspect ratio; Snacks uses PNG density
    -- when sizing placements, so keep decoded frames square-pixel images.
    table.insert(vf_parts, "setsar=1")
    -- No `-vsync` / `-fps_mode`: the `fps` filter above already resamples to a
    -- constant rate, so the mode is redundant, and neither spelling works on
    -- every FFmpeg. `-vsync` was deprecated in 2022 (5.1 added `-fps_mode` as
    -- its replacement) and finally removed in 9.0; `-fps_mode` in turn does
    -- not exist before 5.1. Passing an option the local FFmpeg does not know
    -- makes it exit before decoding anything ("Unrecognized option 'vsync'"),
    -- which surfaced as videos and animated GIFs stuck on "Loading video..."
    -- forever. Omitting both is the only spelling valid across all versions.
    return {
      "ffmpeg",
      "-y",
      "-i",
      path,
      "-vf",
      table.concat(vf_parts, ","),
      "-frames:v",
      tostring(MAX_ANIM_FRAMES),
      cache_dir .. "/frame_%04d.png",
    }
  else
    local cmd = { "magick", path, "-coalesce" }
    if total_frames > MAX_ANIM_FRAMES then
      local step = math.ceil(total_frames / MAX_ANIM_FRAMES)
      local delete = {}
      for kept = 0, total_frames - 1, step do
        local first, last = kept + 1, math.min(kept + step - 1, total_frames - 1)
        if first <= last then table.insert(delete, first == last and tostring(first) or first .. "-" .. last) end
      end
      if #delete > 0 then
        table.insert(cmd, "-delete")
        table.insert(cmd, table.concat(delete, ","))
      end
    end
    table.insert(cmd, "-resize")
    table.insert(cmd, "800x800>")
    table.insert(cmd, cache_dir .. "/frame_%04d.png")
    return cmd
  end
end

M._build_frame_extract_cmd = build_frame_extract_cmd -- exposed for testing

-- Forward declarations: these helpers are defined further down but are already
-- referenced by M.transmit_animated below. Without this, the calls would resolve
-- to (nil) globals instead of the locals.
local get_frames_cache_dir
local get_cached_frames
local extract_frames

--- Extract frames from an animated GIF and transmit each as a separate image.
--- Large GIFs are resized and frames are sampled to stay under MAX_ANIM_FRAMES.
--- Extracted frames are cached on disk for fast subsequent loads.
--- Returns array of frame IDs and nil (frames are cached, not temporary).
---@param path string absolute path to animated GIF
---@return integer[]? frame_ids
---@return string? tmp_dir  always nil (frames persist in cache)
---@return integer? frame_w  actual width of transmitted frame PNGs
---@return integer? frame_h  actual height of transmitted frame PNGs
function M.transmit_animated(path)
  if not M.supports_kitty() then return nil end

  local anim_tool = find_anim_tool()
  if not anim_tool then return nil end

  local cache_dir = get_frames_cache_dir(path)
  if not cache_dir then return nil end
  local cached = extract_frames(path, cache_dir, anim_tool, function(cmd, opts)
    return async.start_system(cmd, opts):wait()
  end)
  if not cached then return nil end

  -- Read actual frame dimensions (may differ from original GIF due to resize)
  local frame_w, frame_h = M.image_dimensions(cached[1])

  tty_mod.kitty_version()
  local frame_ids = {}
  for _, frame_path in ipairs(cached) do
    _image_id = _image_id + 1
    local id = _image_id
    local b64_path = vim.base64.encode(frame_path)
    term_write(string.format("\x1b_Ga=t,f=100,t=f,i=%d,q=2;%s\x1b\\", id, b64_path))
    retain_image(id)
    _image_paths[id] = frame_path
    table.insert(frame_ids, id)
  end

  -- Frames are in persistent cache, not a tmp_dir
  return frame_ids, nil, frame_w, frame_h
end

--- Transmit image asynchronously (converts to PNG if needed, then transmits).
--- When the image is converted (e.g. JPEG→PNG with resize), the callback
--- receives the actual transmitted image dimensions so callers can update
--- their source rectangle parameters accordingly.
---@param path string absolute path to image file
---@param callback fun(image_id: integer?, tx_w: integer?, tx_h: integer?)
function M.transmit_image_async(path, callback)
  if not M.supports_kitty() then
    callback(nil)
    return
  end
  M.ensure_png_async(path, function(png_path, is_temp)
    if not png_path then
      callback(nil)
      return
    end
    tty_mod.kitty_version()
    _image_id = _image_id + 1
    local id = _image_id
    local b64_path = vim.base64.encode(png_path)
    -- Ghostty does not support t=t; always use t=f and delete temp files ourselves
    local t = (is_temp and not is_ghostty()) and "t" or "f"
    term_write(string.format("\x1b_Ga=t,f=100,t=%s,i=%d,q=2;%s\x1b\\", t, id, b64_path))
    retain_image(id)
    if is_temp and is_ghostty() then _temp_image_paths[id] = true end
    _image_paths[id] = png_path
    -- Return actual transmitted dimensions when the converted PNG differs from
    -- the source (conversion may have resized, e.g. large JPEG → 2000px PNG).
    -- Cached PNGs are not "temp" but their dimensions still differ from the
    -- source, so callers must use these to compute correct source rectangles.
    local tx_w, tx_h
    if png_path ~= path then
      tx_w, tx_h = M.image_dimensions(png_path)
    end
    callback(id, tx_w, tx_h)
  end)
end

--- Get persistent cache directory for extracted GIF frames.
--- Keep source versions immutable so an old view can finish reading its frames.
---@param gif_path string
---@return string?
function get_frames_cache_dir(gif_path)
  local signature = video_signature(gif_path)
  if not signature then return nil end
  local hash = vim.fn.sha256(gif_path .. ":" .. signature):sub(1, 16)
  -- v3 directories are published atomically, after successful extraction.
  return get_cache_dir() .. "/frames_" .. hash .. "_v3"
end

--- Only completed directories are visible at a cache path.
---@param cache_dir string
---@return string[]?  sorted list of frame PNG paths, or nil if cache miss
function get_cached_frames(cache_dir)
  local frames = vim.fn.glob(cache_dir .. "/frame_*.png", false, true)
  if #frames == 0 or #frames > MAX_ANIM_FRAMES then return nil end
  table.sort(frames)
  return frames
end

function extract_frames(path, cache_dir, tool, system)
  local cached = get_cached_frames(cache_dir)
  if cached then return cached end
  local staging = cache_dir .. "." .. vim.fn.sha256(vim.fn.tempname()):sub(1, 16)
  local ok, frames = pcall(function()
    local total = 1
    if tool == "magick" then
      local count = system({ "magick", "identify", "-format", "%n\n", path }, { text = true, timeout = 5000 })
      if get_frames_cache_dir(path) ~= cache_dir then return nil end
      if count.code ~= 0 then
        notify_failure(tool_failure(tool, count, "could not count animation frames"))
        return nil
      end
      total = tonumber((count.stdout or ""):match "%d+")
      if not total or total < 1 or total > 2147483647 then
        notify_failure(tool .. " returned an invalid animation frame count")
        return nil
      end
    end
    vim.fn.mkdir(staging, "p")
    local result = system(build_frame_extract_cmd(tool, path, staging, total), { text = true, timeout = 30000 })
    if get_frames_cache_dir(path) ~= cache_dir then return nil end
    if result.code ~= 0 then
      notify_failure(tool_failure(tool, result, "could not extract video/animation frames"))
      return nil
    end
    local produced = get_cached_frames(staging)
    if not produced then
      notify_failure(tool .. " produced no usable PNG frames (expected 1-" .. MAX_ANIM_FRAMES .. ")")
      return nil
    end
    for _, frame in ipairs(produced) do
      if not png_dimensions(frame) then
        notify_failure(tool .. " produced invalid PNG frames")
        return nil
      end
    end
    -- A peer may already have published this immutable source version. Never
    -- remove its directory on a collision or when our own process fails.
    local installed, err = uv.fs_rename(staging, cache_dir)
    if not installed and not get_cached_frames(cache_dir) then
      notify_failure("could not publish " .. tool .. " frames to the media cache: " .. tostring(err))
      return nil
    end
    return get_cached_frames(cache_dir)
  end)
  vim.fn.delete(staging, "rf")
  if not ok then
    vim.notify("md-render: " .. tostring(frames), vim.log.levels.ERROR)
    return nil
  end
  return frames
end

--- Extract animated GIF/video frames without choosing a terminal transport.
---@param path string
---@param callback fun(frames: string[]?) sorted PNG paths, or nil on failure
function M.extract_frames_async(path, callback)
  local anim_tool = find_anim_tool()
  if not anim_tool then
    callback(nil)
    return
  end

  local cache_dir = get_frames_cache_dir(path)
  if not cache_dir then
    callback(nil)
    return
  end
  shared_work(cache_dir, function()
    return extract_frames(path, cache_dir, anim_tool, async.system)
  end, callback)
end

--- Extract GIF frames and transmit asynchronously.
--- Large GIFs are sampled down to MAX_ANIM_FRAMES.
--- Extracted frames are cached on disk for fast subsequent loads.
---@param path string absolute path to animated GIF
---@param callback fun(frame_ids: integer[]?, tmp_dir: string?, frame_w: integer?, frame_h: integer?)
---@param owner? table renderer sharing these frame IDs
function M.transmit_animated_async(path, callback, owner)
  if not M.supports_kitty() then
    callback(nil)
    return
  end

  --- Transmit pre-extracted frames.
  --- Sends frames in small batches (BATCH_SIZE), yielding to the event loop
  --- between batches so Neovim stays responsive while the terminal processes
  --- the image data. Returns once the first batch is out, so the animation can
  --- start on the frames that are already there while the rest keep arriving.
  ---@async
  ---@param frames string[]
  ---@return integer[] frame_ids, nil tmp_dir, integer? frame_w, integer? frame_h
  local function transmit_frames(frames)
    local frame_w, frame_h = M.image_dimensions(frames[1])
    local total = #frames
    local BATCH_SIZE = 10

    -- Pre-allocate all frame IDs so the caller receives the full list
    local all_ids = {}
    for i = 1, total do
      _image_id = _image_id + 1
      all_ids[i] = _image_id
      _image_paths[_image_id] = frames[i]
    end

    ---@param first integer
    ---@return integer last  index of the last frame sent
    local function send_batch(first)
      local last = math.min(first + BATCH_SIZE - 1, total)
      tty_mod.kitty_version()
      M.begin_batch()
      for i = first, last do
        -- Cleanup may release these IDs before the background batch runs.
        if _image_paths[all_ids[i]] == frames[i] then
          local b64_path = vim.base64.encode(frames[i])
          term_write(string.format("\x1b_Ga=t,f=100,t=f,i=%d,q=2;%s\x1b\\", all_ids[i], b64_path))
          retain_image(all_ids[i])
        end
      end
      M.flush_batch()
      return last
    end

    local sent = send_batch(1)
    if sent < total then
      -- Detached: this is background feeding, and a child task would make the
      -- caller wait for the last frame before it could show the first.
      async
        .run(function()
          while sent < total do
            async.sleep(10)
            sent = send_batch(sent + 1)
          end
        end)
        :detach()
    end

    return all_ids, nil, frame_w, frame_h
  end

  -- Reuse IDs within one renderer; another renderer must be able to clear or
  -- delete its own frames independently. File extraction remains shared.
  shared_work("frames:" .. tostring(owner) .. ":" .. path, function()
    local frames = async.await(2, M.extract_frames_async, path)
    if not frames then return nil end
    return transmit_frames(frames)
  end, callback)
end

--- Display an image at a screen position.
--- For static images: uses a=p (lightweight, references previously transmitted data).
---@param image_id integer  Kitty image ID from transmit_image()
---@param win integer  window handle
---@param row integer  0-indexed row within window content
---@param col integer  0-indexed column within window content
---@param display_cols integer
---@param display_rows integer
---@param anim_path? string  if set, use a=T for animated GIF display
---@param img_w? integer  source image width in pixels (for cropping)
---@param img_h? integer  source image height in pixels (for cropping)
function M.put_image(image_id, win, row, col, display_cols, display_rows, anim_path, img_w, img_h)
  if not M.supports_kitty() then return end
  if not vim.api.nvim_win_is_valid(win) then return end
  if vim.api.nvim_win_get_tabpage(win) ~= vim.api.nvim_get_current_tabpage() then return end

  local win_pos = vim.api.nvim_win_get_position(win)

  -- Check if the image is within visible window area.
  -- Use wininfo.height (documented to exclude the winbar) rather than
  -- nvim_win_get_height(), which still counts the winbar row.  Without
  -- this, the winbar offset added to `screen_row` further below is not
  -- mirrored in `visible_rows`, and the bottom-crop math lets images
  -- spill `winbar_height` rows into the statusline.
  local wininfo = vim.fn.getwininfo(win)[1]
  local win_height = wininfo.height
  local topline = wininfo.topline - 1 -- 0-indexed
  local leftcol = wininfo.leftcol or 0
  -- Gutter width (signcolumn + number + foldcolumn + statuscolumn). Buffer
  -- text starts at win_pos[2] + textoff, so Kitty placements need the same
  -- offset to line up with the centered placeholder text in the buffer.
  local textoff = wininfo.textoff or 0

  -- Image entirely above or below visible area
  local img_end_row = row + display_rows - 1
  if img_end_row < topline or row >= topline + win_height then return end

  -- Adjust screen position for scroll offset
  local visual_row = row - topline
  -- Compute border dimensions from window config
  local border_left_width = 0
  local border_top_height = 0
  local ok_cfg, win_cfg = pcall(vim.api.nvim_win_get_config, win)
  if ok_cfg and win_cfg.border then
    local border = win_cfg.border
    if type(border) == "table" then
      local left = border[8] -- 8th element = left border char
      if type(left) == "table" then left = left[1] end
      if left and left ~= "" then border_left_width = vim.api.nvim_strwidth(left) end
      local top = border[2] -- 2nd element = top border char
      if type(top) == "table" then top = top[1] end
      if top and top ~= "" then border_top_height = 1 end
    elseif border ~= "none" and border ~= "" then
      border_left_width = vim.api.nvim_strwidth "│"
      border_top_height = 1
    end
  end
  -- Adjust for horizontal scroll offset
  local visual_col = col - leftcol

  -- Image entirely to the left or right of visible area. The visible buffer
  -- column span is `win_width - textoff`, since the gutter consumes screen
  -- columns but not buffer columns.
  local visible_text_cols = vim.api.nvim_win_get_width(win) - textoff
  local img_end_col = col + display_cols - 1
  if img_end_col < leftcol or col >= leftcol + visible_text_cols then return end

  local screen_col = win_pos[2] + visual_col + border_left_width + textoff + 1

  -- Crop to visible area using source rectangle (no scaling distortion).
  -- Track x/y/w/h independently; emit them all together at the end so that
  -- terminals (notably WezTerm) that require a fully-specified source rect
  -- to honor any single dimension still get correct cropping.
  local src_x, src_y, src_w, src_h

  -- Left crop: image starts to the left of visible area
  if visual_col < 0 then
    local hidden_cols = -visual_col
    if img_w then
      src_x = math.floor(img_w * hidden_cols / display_cols)
      src_w = img_w - src_x
    end
    display_cols = display_cols - hidden_cols
    visual_col = 0
    screen_col = win_pos[2] + border_left_width + textoff + 1
  end

  -- Top crop: image starts above visible area
  if visual_row < 0 then
    local hidden_rows = -visual_row
    if img_h then
      src_y = math.floor(img_h * hidden_rows / display_rows)
      src_h = img_h - src_y
    end
    display_rows = display_rows - hidden_rows
    visual_row = 0
  end

  -- Account for the winbar (1 screen row above the buffer content).
  -- `wininfo.winrow` is the topmost screen row of the window frame, which
  -- includes the winbar when one is present. Without this offset, images
  -- are placed one row too high and overlap any wrapped header lines below
  -- the image label (most visible with long alt text).
  local winbar_height = 0
  local ok_wb, wb = pcall(function()
    return vim.wo[win].winbar
  end)
  if ok_wb and wb and wb ~= "" then winbar_height = 1 end
  local screen_row = wininfo.winrow + visual_row + border_top_height + winbar_height
  -- Account for wrapped text above a visible anchor. Keep the top-crop path
  -- for anchors above the viewport. With horizontal scrolling (nowrap), column
  -- 1 can be hidden while the image is visible, so retain buffer-row arithmetic.
  if row >= topline and leftcol == 0 then
    local pos = vim.fn.screenpos(win, row + 1, 1)
    if pos.row == 0 then return end
    screen_row = pos.row
    visual_row = screen_row - wininfo.winrow - border_top_height - winbar_height
  end

  -- Bottom crop: image extends below visible area
  local visible_rows = win_height - visual_row
  if visible_rows <= 0 then return end
  if display_rows > visible_rows and img_h then
    local remaining_h = src_h or img_h
    src_h = math.floor(remaining_h * visible_rows / display_rows)
    display_rows = visible_rows
  end

  local visible_cols = visible_text_cols - visual_col
  if visible_cols <= 0 then return end
  if display_cols > visible_cols and img_w then
    local remaining_w = src_w or img_w
    src_w = math.floor(remaining_w * visible_cols / display_cols)
    display_cols = visible_cols
  end

  -- Build crop params: if any of x/y/w/h is set, emit all four (with defaults
  -- for the unset dimensions). Some terminals interpret a partial source rect
  -- as "no crop" and silently scale the entire image into the display cells.
  local crop_params = ""
  if (src_x or src_y or src_w or src_h) and img_w and img_h then
    crop_params = string.format(",x=%d,y=%d,w=%d,h=%d", src_x or 0, src_y or 0, src_w or img_w, src_h or img_h)
  end

  local message
  local img_path = anim_path or (is_ghostty() and _image_paths[image_id] or nil)
  if img_path then
    -- Transmit and display in one step (a=T).
    -- Used for animated GIFs and as a Ghostty workaround: Ghostty does not
    -- reliably place images with a=p after a=t, so we re-transmit each time.
    local b64_path = vim.base64.encode(img_path)
    message = string.format(
      "\x1b_Ga=T,f=100,t=f,i=%d,c=%d,r=%d%s,C=1,q=2;%s\x1b\\",
      image_id,
      display_cols,
      display_rows,
      crop_params,
      b64_path
    )
  else
    -- Static: put a previously transmitted image
    message =
      string.format("\x1b_Ga=p,i=%d,c=%d,r=%d%s,C=1,q=2\x1b\\", image_id, display_cols, display_rows, crop_params)
  end

  term_write "\x1b[s"
  move_cursor(screen_col, screen_row)
  term_write(message)
  term_write "\x1b[u"
end

--- Delete all placements for an image but keep the transmitted data.
---@param image_id integer
function M.clear_placements(image_id)
  if not M.supports_kitty() then return end
  term_write(string.format("\x1b_Ga=d,d=i,i=%d,q=2\x1b\\", image_id))
  retain_image(image_id)
end

--- Delete all images and placements from terminal memory.
function M.delete_all()
  if not M.supports_kitty() then return end
  -- d=A leaves virtual placements alive. Release our retained uploads by ID.
  for id in pairs(_retained_images) do
    M.delete_image(id)
  end
  term_write "\x1b_Ga=d,d=A,q=2\x1b\\"
  for id, path in pairs(_image_paths) do
    if _temp_image_paths[id] then os.remove(path) end
  end
  _image_paths = {}
  _temp_image_paths = {}
end

--- Delete a stored image from terminal memory
---@param image_id integer
function M.delete_image(image_id)
  cancel_png(image_id)
  _retained_images[image_id] = nil
  if png_connections[image_id] then
    -- A tmux copy-mode snapshot can still display our placeholders. Keep its
    -- PNG alive until the pane is active again, then release retired uploads.
    local tmux = require "md-render.heading_tmux"
    local connection = tmux.status().owner
    if connection then
      if connection == png_connections[image_id] then
        png_write(string.format("\27_Ga=d,d=I,i=%d,q=2\27\\", image_id))
      end
    else
      png_deletes[image_id] = png_connections[image_id]
      tmux.watch_cleanup(true)
    end
    png_connections[image_id] = nil
    return
  end
  if not M.supports_kitty() then return end
  term_write(string.format("\x1b_Ga=d,d=I,i=%d\x1b\\", image_id))
  if _temp_image_paths[image_id] and _image_paths[image_id] then
    os.remove(_image_paths[image_id])
    _temp_image_paths[image_id] = nil
  end
  _image_paths[image_id] = nil
end

--- Delete multiple images
---@param image_ids integer[]
function M.delete_images(image_ids)
  if not M.supports_kitty() or #image_ids == 0 then return end
  local parts = {}
  for _, id in ipairs(image_ids) do
    _retained_images[id] = nil
    table.insert(parts, string.format("\x1b_Ga=d,d=I,i=%d\x1b\\", id))
    if _temp_image_paths[id] and _image_paths[id] then
      os.remove(_image_paths[id])
      _temp_image_paths[id] = nil
    end
    _image_paths[id] = nil
  end
  term_write(table.concat(parts))
end

--- Clear all images from terminal memory (once per Neovim session).
--- Removes stale image data from previous sessions that may interfere
--- with new transmissions using the same ID range.
function M.clear_all()
  if _session_cleared then return end
  _session_cleared = true
  -- Snacks owns its stored images; never delete them or reset live heading IDs.
  if config.backend == "snacks" or not M.supports_kitty() then return end
  M.delete_all()
  -- Keep IDs monotonic: a capability query may still have a reply in flight.
  -- Ensure images are cleaned up when Neovim exits (e.g. :restart in Kitty)
  vim.api.nvim_create_autocmd("VimLeavePre", {
    once = true,
    callback = function()
      M.delete_all()
    end,
  })
end

return M
