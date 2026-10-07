local FloatWin = require "md-render.float_win"
local TabWin = require "md-render.tab_win"
local cb = require "md-render.content_builder"
local display_utils = require "md-render.display_utils"
local wrap = require "md-render.wrap"
local ContentBuilder = cb.ContentBuilder

local float_win = FloatWin.new "md_render_preview_float"
local demo_float_win = FloatWin.new "md_render_demo_float"
local tab_win = TabWin.new "md_render_preview_tab"

local MdPreview = {}
local get_or_create_session

--- Upper bound on render width when not explicitly overridden by the user.
--- Long lines hurt readability even in wide windows, so we cap auto-sized
--- render windows here while still adapting downward in narrow splits.
local DEFAULT_MAX_WIDTH = 80

local function close_timer(timer)
  if timer and not timer:is_closing() then
    timer:stop()
    timer:close()
  end
end

local function without_events(fn)
  local saved = vim.o.eventignore
  vim.o.eventignore = "all"
  local ok, err = pcall(fn)
  vim.o.eventignore = saved
  if not ok then error(err, 0) end
end

--- Usable text-area width of a window, excluding the gutter (signcolumn,
--- number column, foldcolumn, statuscolumn). `nvim_win_get_width` returns the
--- full window width including these, which would mis-size content centered
--- against the visible text area.
---@param win integer
---@return integer
local function usable_win_width(win)
  local total = vim.api.nvim_win_get_width(win)
  local wininfo = vim.fn.getwininfo(win)[1]
  local textoff = (wininfo and wininfo.textoff) or 0
  return math.max(1, total - textoff)
end

-- Preserve soft wrapping for ordinary text. Only overflowing tables and
-- expanded regions need horizontal scrolling.
local function set_preview_wrap(buf, content)
  local expanded = false
  for _, region in ipairs(content.expandable_regions or {}) do
    if region.expanded then
      expanded = true
      break
    end
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    local should_wrap = not expanded
    local width = usable_win_width(win)
    for row in pairs(content.table_lines or {}) do
      if vim.api.nvim_strwidth(content.lines[row + 1]) > width then
        should_wrap = false
        break
      end
    end
    vim.wo[win].wrap = should_wrap
  end
end

--- Parse simple YAML frontmatter lines into key-value pairs
---@param fm_lines string[]
---@return {key: string, value: string, source_line: integer}[]? entries Nil preserves unsupported YAML as raw text.
local function parse_frontmatter(fm_lines)
  local entries = {}
  local current_key = nil
  local current_list = {}
  local current_line
  local list_indent

  local function flush_list()
    if current_key and #current_list > 0 then
      table.insert(entries, {
        key = current_key,
        value = table.concat(current_list, ", "),
        source_line = current_line,
      })
      current_key = nil
      current_list = {}
      list_indent = nil
      return true
    end
    return current_key == nil
  end

  for row, line in ipairs(fm_lines) do
    if line:match "^%s*$" then goto continue end
    local indent, list_value = line:match "^(%s+)%-%s+(.+)$"
    if list_value and current_key then
      if (list_indent and list_indent ~= indent) or list_value:match "^[|>]" or list_value:match ":%s" then
        return nil
      end
      list_indent = indent
      table.insert(current_list, list_value)
    else
      if not flush_list() then return nil end
      local key, value = line:match "^([%w_%-]+):%s*(.*)$"
      if key then
        if value and value ~= "" then
          if value:match "^[|>]" then return nil end
          table.insert(entries, { key = key, value = value, source_line = row + 1 })
          current_key = nil
        else
          current_key = key
          current_list = {}
          current_line = row + 1
        end
      else
        return nil
      end
    end
    ::continue::
  end
  if not flush_list() then return nil end

  return entries
end

--- Build rendered content from markdown lines
---@param lines string[]
---@param opts? { max_width?: integer, fold_state?: table<integer, boolean>, expand_state?: table<integer, boolean>, autolinks?: MdRender.Autolink[] }
---@return MdRender.Content
MdPreview.build_content = function(lines, opts)
  opts = opts or {}
  lines = vim.tbl_map(require("md-render.character_references").normalize_nul, lines)
  local max_width = opts.max_width or DEFAULT_MAX_WIDTH
  local expand_state = opts.expand_state or {}

  local b = ContentBuilder.new()

  -- Detect and extract frontmatter.
  --
  -- Both fences tolerate trailing whitespace: editors that rewrite the
  -- frontmatter block (Obsidian's property editor among them) can leave a
  -- space behind, and requiring a bare `---` would drop the whole block back
  -- into the body. There it renders as a thematic break followed by a setext
  -- heading, because the closing fence underlines the last property line.
  local body_start = 1
  if lines[1] and lines[1]:match "^%-%-%-%s*$" then
    local frontmatter_lines = {}
    for i = 2, #lines do
      if lines[i]:match "^%-%-%-%s*$" then
        body_start = i + 1
        break
      end
      table.insert(frontmatter_lines, lines[i])
    end
    if body_start > 1 and #frontmatter_lines > 0 then
      local entries = parse_frontmatter(frontmatter_lines)
      if not entries then
        -- Preserve unsupported or mixed YAML literally; Markdown parsing would
        -- reinterpret its fences, block scalars and nested collections.
        for row = 1, body_start - 1 do
          b:set_source_line(row)
          b:add_line("  " .. lines[row], { { col = 0, end_col = -1, hl = "Comment" } })
        end
        b:add_line ""
      elseif #entries > 0 then
        b:set_source_line(1)
        b:add_line("  Properties", {
          { col = 2, end_col = 2 + #"Properties", hl = "Title" },
        })
        -- Negative source rows stay distinct from code blocks and stable when
        -- a width change makes another entry overflow.
        for _, entry in ipairs(entries) do
          b:set_source_line(entry.source_line)
          local label = "  " .. entry.key
          -- Byte/display column where the value starts, after "<label>: ".
          -- label is ASCII (key matches [%w_%-]+), so bytes == display cols.
          local value_col = #label + 2
          local full_line = label .. ": " .. entry.value
          local display_width = vim.api.nvim_strwidth(full_line)
          if display_width > max_width then
            local block_id = -entry.source_line
            local expanded = expand_state[block_id] or false
            local start_line = #b.lines
            if expanded then
              -- Wrap the value across lines, aligning continuation lines
              -- under the value's start column.
              local value_width = math.max(1, max_width - value_col)
              local wrapped = wrap.wrap_words(entry.value, value_width)
              local cont_indent = string.rep(" ", value_col)
              for idx, wline in ipairs(wrapped) do
                if idx == 1 then
                  local line = label .. ": " .. wline
                  b:add_line(line, {
                    { col = 0, end_col = #label, hl = "Comment" },
                    { col = value_col, end_col = #line, hl = "String" },
                  })
                else
                  local line = cont_indent .. wline
                  b:add_line(line, {
                    { col = value_col, end_col = #line, hl = "String" },
                  })
                end
              end
            else
              local target = max_width - vim.api.nvim_strwidth "…"
              local current_width = 0
              local byte_pos = 0
              for char in full_line:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
                local char_width = vim.api.nvim_strwidth(char)
                if current_width + char_width > target then break end
                current_width = current_width + char_width
                byte_pos = byte_pos + #char
              end
              local truncated = full_line:sub(1, byte_pos) .. "…"
              b:add_line(truncated, {
                { col = 0, end_col = math.min(#label, byte_pos), hl = "Comment" },
                { col = math.min(value_col, byte_pos), end_col = byte_pos, hl = "String" },
                { col = byte_pos, end_col = #truncated, hl = "Underlined" },
              })
            end
            -- Register the region so clicking / za / <CR> toggles expansion.
            table.insert(b.expandable_regions, {
              start_line = start_line,
              end_line = #b.lines - 1,
              block_id = block_id,
              expanded = expanded,
            })
          else
            b:add_labeled(label, entry.value, "String")
          end
        end
        b:add_line ""
      end
    end
  end

  -- Render the document body using the shared rendering loop
  local body_lines = {}
  for i = body_start, #lines do
    table.insert(body_lines, lines[i])
  end

  b:render_document(body_lines, {
    max_width = max_width,
    table_max_width = opts.table_max_width,
    indent = opts.indent,
    fold_state = opts.fold_state,
    expand_state = opts.expand_state,
    autolinks = opts.autolinks,
    source_line_offset = body_start - 1,
    buf_dir = opts.buf_dir,
    text_scale = opts.text_scale,
    heading_normal = opts.heading_normal,
    image_max_height = opts.image_max_height,
  })

  if b.native_heading_fallback then
    -- Rebuild once so unscalable native headings cannot invert the size
    -- hierarchy or leave wrapping and empty rows reserved for scaled text.
    local content = MdPreview.build_content(lines, vim.tbl_extend("force", opts, { text_scale = false }))
    content.heading_fallback = b.native_heading_fallback
    return content
  end
  return b:result()
end

-- =====================================================================
-- Session: encapsulates a render buffer's content, state, and lifecycle.
-- Toggle/split share one Session per source; each float/tab presentation
-- retains its own documents. Native window copies share their render buffer.
-- show_pager also uses Session, with its own full-screen lifecycle.
-- =====================================================================

---@class MdRender.Session
---@field source_bufnr integer        -- source markdown buffer
---@field source_lines string[]       -- snapshot of source buffer
---@field opts table                  -- options passed to build_content
---@field buf integer                 -- render buffer (scratch)
---@field ns integer                  -- highlight namespace
---@field fold_state table<integer, boolean>
---@field expand_state table<integer, boolean>
---@field content MdRender.Content    -- current rendered content
---@field win? integer                -- bound render window (if any)
---@field image_state? MdRender.ImageState
---@field text_size_state? MdRender.TextSizeState|MdRender.HeadingImageState
---@field dirty boolean               -- true when source changed while render was hidden
---@field _debounce_timer? table      -- libuv timer handle for live-update debounce
---@field _update_footer? fun()       -- redraws the float footer (set by install_footer)
---@field _syncing? boolean           -- a scroll sync is in flight (see install_scroll_sync)
---@field _sync_unlock_timer? table   -- timer that releases `_syncing`
---@field _synced_views? table<integer, integer[]> -- per window, `{ topline, cursor_line, written_at }` of the last sync write
---@field views? table<integer, table> -- last reading view per window, for close synchronization
---@field jump_views? table<integer, table<string, table>> -- viewports keyed by native jump position
---@field cache? table<integer, MdRender.Session> -- documents within this preview presentation
---@field pager? boolean             -- full-screen reading presentation
local Session = {}
Session.__index = Session

--- Every live session, keyed by render buffer. Weak values so a session that
--- nothing else references is collected normally.
MdPreview._sessions = setmetatable({}, { __mode = "v" })

local modified_sources = {}

local function sync_source_modified(source_bufnr)
  local found = false
  for buf, session in pairs(MdPreview._sessions) do
    if session.source_bufnr == source_bufnr and vim.api.nvim_buf_is_valid(buf) then
      session:sync_modified()
      found = true
    end
  end
  return found
end

-- Mirror explicit option changes; 0.13 also reports native dirty transitions here.
vim.api.nvim_create_autocmd("OptionSet", {
  pattern = "modified",
  callback = function()
    sync_source_modified(vim.api.nvim_get_current_buf())
  end,
})

local function attach_source_modified(source_bufnr)
  if modified_sources[source_bufnr] or not vim.api.nvim_buf_is_loaded(source_bufnr) then return end
  local function sync(_, buf)
    -- Returning true retires just this attachment after its last preview.
    if not sync_source_modified(buf) then
      modified_sources[buf] = nil
      return true
    end
  end
  modified_sources[source_bufnr] = vim.api.nvim_buf_attach(source_bufnr, false, {
    on_lines = sync,
    on_changedtick = sync,
    on_reload = sync,
    on_detach = function(_, buf)
      modified_sources[buf] = nil
      -- Detach precedes the final unload flags; an autocmd may also abort it.
      vim.schedule(function()
        if sync_source_modified(buf) then attach_source_modified(buf) end
      end)
    end,
  }) or nil
end

local deferred_rebuilds = {}

--- Reflow replaces buffer lines. Keep native operations on their original
--- text until they finish, including a held mouse press and its yank feedback.
local function defer_rebuild(buf, callback, text_state)
  local interacting = vim.api.nvim_get_current_buf() == buf and vim.api.nvim_get_mode().mode ~= "n"
  -- Neovim 0.13 shares yank/put feedback in nvim.hl.events.
  local namespaces = vim.api.nvim_get_namespaces()
  local feedback_ns = namespaces["nvim.hl.events"] or namespaces["nvim.hlyank"]
  local highlighting = feedback_ns and #vim.api.nvim_buf_get_extmarks(buf, feedback_ns, 0, -1, {}) > 0
  if interacting or highlighting or (text_state and text_state.gesture) then
    deferred_rebuilds[buf] = callback
    return true
  end
  deferred_rebuilds[buf] = nil
  return false
end

-- SafeState also runs when native yank feedback expires. Do not schedule from
-- this callback: scheduling would keep waking the otherwise idle editor.
vim.api.nvim_create_autocmd("SafeState", {
  callback = function()
    for buf, rebuild in pairs(deferred_rebuilds) do
      deferred_rebuilds[buf] = nil
      if vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0 then rebuild() end
    end
  end,
})

--- Rebuild and repaint every session currently shown in a window. Used by
--- settings that change how content is *built* (e.g. `:MdRender textsize`),
--- where re-applying highlights alone is not enough.
function MdPreview.rebuild_visible(layouts)
  for buf, session in pairs(MdPreview._sessions) do
    local affected = not layouts
    for _, layout in ipairs(layouts or {}) do
      if session.content.heading_layouts and session.content.heading_layouts[layout.key] then affected = true end
    end
    if affected and vim.api.nvim_buf_is_valid(buf) and #vim.fn.win_findbuf(buf) > 0 then
      session:rebuild()
      session:refresh_images()
    end
  end
  -- `show_demo` builds its own window rather than a Session; it registers a
  -- rebuild hook here so it is not left behind.
  if MdPreview._demo_rebuild then pcall(MdPreview._demo_rebuild, layouts) end
end

--- Build a fresh Session from a source buffer.
---@param source_bufnr integer
---@param ns_name string
---@param opts? table
---@return MdRender.Session
function Session.new(source_bufnr, ns_name, opts)
  local effective_opts = vim.tbl_extend("force", {}, opts or {})
  local explicit_buf_dir = effective_opts.buf_dir ~= nil
  local source_name = vim.api.nvim_buf_get_name(source_bufnr)
  -- Unnamed input keeps its entry cwd until it acquires a filename. Only an
  -- explicit buf_dir override stays fixed after :saveas.
  effective_opts.buf_dir = effective_opts.buf_dir
    or (source_name == "" and vim.fn.getcwd() or vim.fn.fnamemodify(source_name, ":h"))

  local self = setmetatable({}, Session)
  self.source_bufnr = source_bufnr
  self.source_lines = vim.api.nvim_buf_get_lines(source_bufnr, 0, -1, false)
  self.opts = effective_opts
  self._explicit_buf_dir = explicit_buf_dir
  self.fold_state = {}
  self.expand_state = {}
  self.buf = vim.api.nvim_create_buf(false, true)
  -- Marks every buffer this plugin renders into, so a configuration can tell
  -- one apart without matching on a name or a filetype. Buffer-local rather
  -- than window-local on purpose: `:MdRender toggle` swaps the buffer inside a
  -- window it keeps, and a user splitting a preview with `<C-w>s` creates a
  -- window this plugin never sees. The flag has to travel with the buffer for
  -- either to work. See |md-render-b-md-render|.
  vim.b[self.buf].md_render = true
  self.ns = vim.api.nvim_create_namespace(ns_name)
  self.dirty = false
  self._debounce_timer = nil
  self._explicit_max_width = (effective_opts.max_width ~= nil)

  -- Give the render buffer a recognisable name so statuslines, pickers,
  -- and bufferline plugins can show what's being viewed. The "[render]"
  -- suffix avoids colliding with the source name.
  --
  -- Suppress autocmds while we change the name and filetype: user-configured
  -- handlers (markdown ftplugins, treesitter, lualine, etc.) would otherwise
  -- treat this scratch buffer as a real markdown file and clobber our
  -- pre-rendered content (conceallevel, readonly, syntax overlays, ...).
  -- A non-empty filetype ("md-render") prevents external hacks that run
  -- `:edit` on filetype="" buffers from clearing the rendered content.
  if source_name ~= "" then
    without_events(function()
      local named = pcall(vim.api.nvim_buf_set_name, self.buf, source_name .. " [render]")
      if not named then vim.api.nvim_buf_set_name(self.buf, source_name .. " [render " .. self.buf .. "]") end
      vim.bo[self.buf].filetype = "md-render"
    end)
    -- nvim_buf_set_name can flip readonly when it thinks the file already
    -- exists on disk; defend so apply_content_to_buffer doesn't W10-warn.
    vim.bo[self.buf].readonly = false
    vim.bo[self.buf].modified = false
  end

  require("md-render").setup_highlights()

  self.opts.fold_state = self.fold_state
  self.opts.expand_state = self.expand_state
  self.content = MdPreview.build_content(self.source_lines, self.opts)
  -- Defensive: nvim_buf_set_name above can leave the buffer modifiable=false
  -- on some setups (third-party autocmds firing even with eventignore=all).
  vim.bo[self.buf].modifiable = true
  display_utils.apply_content_to_buffer(self.buf, self.ns, self.content)
  self:sync_modified()

  -- Initialize fold_state from default fold states (e.g. `> [!TIP]-`)
  for _, fold in ipairs(self.content.callout_folds) do
    self.fold_state[fold.source_line] = fold.collapsed
  end

  -- Weakly registered so `MdPreview.rebuild_visible()` can reach every live
  -- session regardless of how it was opened (float / tab / split / toggle).
  MdPreview._sessions[self.buf] = self

  return self
end

--- Native :update / :x / ZZ consult this flag before invoking BufWriteCmd.
function Session:sync_modified()
  if vim.api.nvim_buf_is_valid(self.buf) then
    vim.bo[self.buf].modified = vim.api.nvim_buf_is_valid(self.source_bufnr) and vim.bo[self.source_bufnr].modified
      or false
  end
end

--- Infer paths from the current source name; :saveas can move a cached source.
function Session:source_directory()
  local name = vim.api.nvim_buf_get_name(self.source_bufnr)
  if self._explicit_buf_dir or name == "" then return self.opts.buf_dir end
  return vim.fn.fnamemodify(name, ":h")
end

--- Refresh source_lines from the source buffer (call before rebuild when
--- the source may have changed).
---@return boolean changed
function Session:refresh_source()
  if vim.api.nvim_buf_is_valid(self.source_bufnr) then
    local lines = vim.api.nvim_buf_get_lines(self.source_bufnr, 0, -1, false)
    local directory = self:source_directory()
    local changed = directory ~= self.opts.buf_dir or not vim.deep_equal(lines, self.source_lines)
    self.source_lines, self.opts.buf_dir = lines, directory
    return changed
  end
  return false
end

--- Rebuild render content from the current source_lines and apply it.
--- Preserves the view (topline/cursor) of every window currently displaying
--- the render buffer, since changing lines can otherwise reset topline.
function Session:rebuild(force)
  if
    not force
    and defer_rebuild(self.buf, function()
      self:rebuild()
      self:refresh_images()
    end, self.text_size_state)
  then
    self.dirty = true
    return
  end
  self.opts.fold_state = self.fold_state
  self.opts.expand_state = self.expand_state
  local new_content = MdPreview.build_content(self.source_lines, self.opts)

  local wins = vim.fn.win_findbuf(self.buf)
  local saved_views = {}
  for _, w in ipairs(wins) do
    if vim.api.nvim_win_is_valid(w) then
      saved_views[w] = vim.api.nvim_win_call(w, function()
        return vim.fn.winsaveview()
      end)
    end
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = self.buf })
  vim.api.nvim_buf_clear_namespace(self.buf, self.ns, 0, -1)
  display_utils.apply_content_to_buffer(self.buf, self.ns, new_content)
  vim.api.nvim_set_option_value("modifiable", false, { buf = self.buf })
  -- Reflow itself is not an edit; conditional writes still need source dirtiness.
  self:sync_modified()

  for w, view in pairs(saved_views) do
    if vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_win_call(w, function()
        vim.fn.winrestview(display_utils.remap_view(view, self.content, new_content))
      end)
    end
  end

  set_preview_wrap(self.buf, new_content)
  self.content = new_content
  self.dirty = false
  -- Rendered line numbers have just moved, so "this window still shows what
  -- the last sync wrote" no longer implies the two sides agree.
  self._synced_views = nil
  -- Folding/expanding shifts the rendered line under the cursor without
  -- firing CursorMoved, so refresh the footer explicitly.
  if self._update_footer then self._update_footer() end
end

--- Lazily build sync points from `content.source_line_map`. A sync point
--- marks the first rendered line of each source-line "run" in the map,
--- plus a terminal sentinel for past-the-end interpolation.
---
--- For map = [5, 5, 5, 7, 7, 10], sync_points becomes:
---   [{src=5, render=1}, {src=7, render=4}, {src=10, render=6}, {src=11, render=7}]
---
--- The final sentinel lets `source_to_rendered_f` interpolate past the
--- last point without degenerating, matching the VS Code preview's
--- "interpolate between previous and next markers" approach.
---@return { src: integer, render: integer }[]
function Session:get_sync_points()
  local content = self.content
  if content._sync_points then return content._sync_points end
  local map = content.source_line_map
  local points = {}
  if map and #map > 0 then
    local prev = nil
    for render_idx, src in ipairs(map) do
      if src ~= prev then
        table.insert(points, { src = src, render = render_idx })
        prev = src
      end
    end
    if #points > 0 then
      local last = points[#points]
      table.insert(points, { src = last.src + 1, render = #map + 1 })
    end
  end
  content._sync_points = points
  return points
end

--- Find the largest `i` such that `pts[i][key] <= value` (binary search).
--- Returns `i = 1` if `value` is below all entries.
local function bracket_index(pts, key, value)
  local lo, hi = 1, #pts
  if value < pts[1][key] then return 1 end
  if value >= pts[hi][key] then return hi end
  while lo + 1 < hi do
    local mid = math.floor((lo + hi) / 2)
    if pts[mid][key] <= value then
      lo = mid
    else
      hi = mid
    end
  end
  return lo
end

--- Float version of `source_to_rendered`. Linearly interpolates between
--- adjacent sync points so a source line that sits "between" two known
--- markers maps to a fractional rendered line, rather than snapping to
--- the next marker.
---@param src number 1-indexed source line (may be fractional)
---@return number 1-indexed rendered line (float)
function Session:source_to_rendered_f(src)
  local pts = self:get_sync_points()
  if #pts == 0 then return 1 end
  if src <= pts[1].src then return pts[1].render end
  if src >= pts[#pts].src then return pts[#pts].render end
  local i = bracket_index(pts, "src", src)
  local p1 = pts[i]
  local p2 = pts[i + 1]
  if not p2 or p2.src == p1.src then return p1.render end
  local frac = (src - p1.src) / (p2.src - p1.src)
  return p1.render + frac * (p2.render - p1.render)
end

--- Float version of `rendered_to_source`. Symmetric counterpart of
--- `source_to_rendered_f`.
---@param r number 1-indexed rendered line (may be fractional)
---@return number 1-indexed source line (float)
function Session:rendered_to_source_f(r)
  local pts = self:get_sync_points()
  if #pts == 0 then return 1 end
  if r <= pts[1].render then return pts[1].src end
  if r >= pts[#pts].render then return pts[#pts].src end
  local i = bracket_index(pts, "render", r)
  local p1 = pts[i]
  local p2 = pts[i + 1]
  if not p2 or p2.render == p1.render then return p1.src end
  local frac = (r - p1.render) / (p2.render - p1.render)
  return p1.src + frac * (p2.src - p1.src)
end

--- Integer-rounded `source_to_rendered_f`. Used by callers that need a
--- concrete render line (cursor placement, initial scroll).
---@param src_line integer 1-indexed source line
---@return integer  1-indexed rendered line
function Session:source_to_rendered(src_line)
  return math.max(1, math.floor(self:source_to_rendered_f(src_line) + 0.5))
end

--- Recover the physical owner for a concrete row; scrolling keeps interpolation.
--- Returns nil when the underlying map is empty.
---@param rendered_line integer 1-indexed rendered line
---@return integer? 1-indexed source line, or nil if no map exists
function Session:rendered_to_source(rendered_line)
  local owner = self.content.source_line_map and self.content.source_line_map[rendered_line]
  if owner then return owner end
  local pts = self:get_sync_points()
  if #pts == 0 then return nil end
  return math.max(1, math.floor(self:rendered_to_source_f(rendered_line) + 0.5))
end

--- Place cursor on the rendered line corresponding to a source line,
--- centering it within the bound window.
---@param source_cursor_line integer 1-indexed source line
function Session:scroll_to_source_line(source_cursor_line)
  if not self.win or not vim.api.nvim_win_is_valid(self.win) then return end
  local target = self:source_to_rendered(source_cursor_line)
  local buf_lines = vim.api.nvim_buf_line_count(self.buf)
  target = math.max(1, math.min(target, buf_lines))
  local win_height = vim.api.nvim_win_get_height(self.win)
  local top = math.max(0, target - 1 - math.floor(win_height / 2))
  vim.api.nvim_win_call(self.win, function()
    vim.fn.winrestview { topline = top + 1 }
  end)
  vim.api.nvim_win_set_cursor(self.win, { target, 0 })
end

--- Update automatic layout bounds; return whether a rebuild is needed.
function Session:resize(win)
  local snacks = require("md-render.image").config().backend == "snacks"
  local width = self._explicit_max_width and self.opts.max_width
    or math.min(usable_win_width(win), snacks and math.huge or DEFAULT_MAX_WIDTH)
  local table_width = self._explicit_max_width and self.opts.max_width or usable_win_width(win)
  local height = snacks and math.max(1, vim.api.nvim_win_get_height(win) - 6) or nil
  local normal = vim.api.nvim_win_get_config(win).relative ~= "" and "NormalFloat" or "Normal"
  local changed = width ~= (self.opts.max_width or DEFAULT_MAX_WIDTH)
    or table_width ~= self.opts.table_max_width
    or height ~= self.opts.image_max_height
    or normal ~= self.opts.heading_normal
  self.opts.heading_normal = normal
  self.opts.max_width, self.opts.image_max_height = width, height
  self.opts.table_max_width = table_width
  return changed
end

--- Bind a window to this session and start displaying images in it.
---@param win integer
---@param layout? { max_width?: integer, indent?: string }
function Session:bind_window(win, layout)
  self:cleanup_images()
  self.win = win
  if layout then
    local explicit = layout.max_width ~= nil
    self.dirty = self.dirty
      or explicit ~= self._explicit_max_width
      or (explicit and layout.max_width ~= self.opts.max_width)
      or layout.indent ~= self.opts.indent
    self._explicit_max_width = explicit
    self.opts.max_width = layout.max_width or self.opts.max_width
    self.opts.indent = layout.indent
  end
  if self:resize(win) or self.dirty then self:rebuild() end
  set_preview_wrap(self.buf, self.content)
  -- Own teardown before the renderers' WinClosed handlers, so they are
  -- detached once and cannot queue work while this window is closing.
  self._win_closed = vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      self:cleanup_images()
      -- WinClosed runs before the window is removed from win_findbuf().
      vim.schedule(function()
        if not self.win then self:refresh_images() end
      end)
    end,
  })
  self.image_state = display_utils.setup_images(win, self.content, self.ns, {
    buf = self.buf,
    on_ready = function()
      self:rebuild()
      self:refresh_images()
    end,
  })
  self.text_size_state = require("md-render.text_size").attach(win, self.content)
  if self._rebind_keymaps then self._rebind_keymaps(win) end
end

--- True when the render buffer is displayed in at least one window.
---@return boolean
function Session:is_visible()
  return #vim.fn.win_findbuf(self.buf) > 0
end

--- Update renderers after a rebuild, or bind a surviving preview window.
function Session:refresh_images()
  if deferred_rebuilds[self.buf] then return end
  if not self.win or not vim.api.nvim_win_is_valid(self.win) or vim.api.nvim_win_get_buf(self.win) ~= self.buf then
    self:cleanup_images()
    if not vim.api.nvim_buf_is_valid(self.buf) then return end
    local win = vim.fn.win_findbuf(self.buf)[1]
    if win then self:bind_window(win) end
    return
  end
  self.image_state = display_utils.update_images(self.image_state, self.win, self.content, self.ns, {
    buf = self.buf,
    on_ready = function()
      self:rebuild()
      self:refresh_images()
    end,
  })
  self.text_size_state = require("md-render.text_size").refresh(self.text_size_state, self.win, self.content)
end

--- Release the bound window and its renderers (keeps the buffer).
function Session:cleanup_images()
  if self._win_closed then
    pcall(vim.api.nvim_del_autocmd, self._win_closed)
    self._win_closed = nil
  end
  if self.image_state then
    display_utils.cleanup_images(self.image_state)
    self.image_state = nil
  end
  if self.text_size_state then
    require("md-render.text_size").detach(self.text_size_state)
    self.text_size_state = nil
  end
  self.win = nil
end

--- Install the standard click/keymap handlers on a window-managed close handle
--- (FloatWin or TabWin). Used by show / show_tab. Pass `keymap_opts.close_keys = {}`
--- and a nil close_handle for toggle-mode buffers that must not self-close.
---@param close_handle MdRender.FloatWin|MdRender.TabWin|nil
---@param keymap_opts? { close_keys?: string[], close_line_idx?: integer }
function Session:install_float_keymaps(close_handle, keymap_opts)
  keymap_opts = keymap_opts or {}
  if self._rebind_keymaps then
    self._keymap_opts.close_keys = keymap_opts.close_keys
    self._keymap_opts.close_line_idx = keymap_opts.close_line_idx
    self._rebind_keymaps(self.win, close_handle, self._keymap_opts)
    return
  end
  self._keymap_opts = {
    close_keys = keymap_opts.close_keys,
    close_line_idx = keymap_opts.close_line_idx,
    get_content = function()
      return self.content
    end,
    on_fold_toggle = function(source_line, collapsed)
      self.fold_state[source_line] = collapsed
      self:rebuild()
      self:refresh_images()
    end,
    on_expand_toggle = function(block_id, expanded)
      self.expand_state[block_id] = expanded
      self:rebuild()
      self:refresh_images()
    end,
    on_image_open = function(row)
      if require("md-render.image").config().backend ~= "snacks" then return false end
      local col = vim.fn.virtcol "." - 1
      for idx, p in ipairs(self.content.image_placements or {}) do
        if
          row >= p.line - (p.label_rows or 1)
          and row < p.line + p.rows
          and (not p.cell_col or (col >= p.cell_col and col < p.cell_col + p.cell_cols))
        then
          local object = self.image_state and self.image_state.objects[idx]
          if object and object:ready() then require("md-render.image_view").open(p.path or object.img.file) end
          return true
        end
      end
      return false
    end,
  }
  self._rebind_keymaps =
    display_utils.setup_float_keymaps(self.buf, self.ns, self.win, self.content, close_handle, self._keymap_opts)
  if self.pager then
    -- Let :qa handle unsaved buffers, including showing the editor that
    -- needs saving. Do not tear down renderers before exit is accepted.
    vim.keymap.set("n", "q", function()
      vim.cmd { cmd = "quitall", mods = { keepjumps = true } }
    end, { buffer = self.buf, silent = true, desc = "Quit pager (preserve unsaved edits)" })
  end
end

--- Show status info (source file name, position in the source buffer) on the
--- float's bottom border and keep it in sync with the cursor.
---
--- The footer is used rather than a statusline because floating windows only
--- draw one when 'laststatus' is 1 or 2; see
--- |display_utils.build_footer_chunks()| for the details.  It is a no-op for
--- non-floating windows, so tab/split/pager presentations are unaffected.
function Session:install_footer()
  local win = self.win
  if not win or not vim.api.nvim_win_is_valid(win) then return end
  if vim.api.nvim_win_get_config(win).relative == "" then return end

  local source_name = vim.api.nvim_buf_get_name(self.source_bufnr)
  local name = source_name ~= "" and vim.fn.fnamemodify(source_name, ":t") or nil
  local last_text = nil

  local function update()
    local w = self.win
    if not w or not vim.api.nvim_win_is_valid(w) then return end
    local rendered_line = vim.api.nvim_win_get_cursor(w)[1]
    local chunks = display_utils.build_footer_chunks({
      name = name,
      -- Rendered lines don't line up with the source, so report the source
      -- line the cursor maps back to — that's the number the user can act on.
      line = self:rendered_to_source(rendered_line) or rendered_line,
      total = #self.source_lines,
    }, vim.api.nvim_win_get_config(w).width)

    -- Most cursor movements land on the same source line (one source line
    -- spans several rendered lines). Reconfiguring the window redraws it,
    -- which can make inline images flicker, so only do it on a real change.
    local text = ""
    for _, chunk in ipairs(chunks) do
      text = text .. chunk[1]
    end
    if text == last_text then return end
    last_text = text

    display_utils.set_float_footer(w, chunks)
  end

  self._update_footer = update
  update()

  if self._footer_autocmd then pcall(vim.api.nvim_del_autocmd, self._footer_autocmd) end
  self._footer_autocmd = vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = self.buf,
    callback = update,
  })
end

--- Restore the corresponding source position when a managed preview closes.
function Session:sync_source_cursor(win)
  local view = self.views and self.views[win]
  local line = view and view.lnum
  if vim.api.nvim_win_is_valid(win) then line = vim.api.nvim_win_get_cursor(win)[1] end
  local source_line = line and self:rendered_to_source(line)
  if not source_line or source_line < 1 or not vim.api.nvim_buf_is_valid(self.source_bufnr) then return end
  local source_win = vim.fn.win_findbuf(self.source_bufnr)[1]
  if source_win then
    vim.api.nvim_win_set_cursor(
      source_win,
      { math.min(source_line, vim.api.nvim_buf_line_count(self.source_bufnr)), 0 }
    )
    vim.api.nvim_win_call(source_win, function()
      vim.cmd "normal! zz"
    end)
  end
end

-- =====================================================================
-- Helpers shared by user-facing entry points
-- =====================================================================

--- Verify that a buffer holds Markdown content.
---@param bufnr integer
---@return boolean ok, string? warning_msg
local function check_markdown_buffer(bufnr)
  local ft = vim.bo[bufnr].filetype
  local name = vim.api.nvim_buf_get_name(bufnr)
  if ft == "markdown" or name:match "%.md$" or name:match "%.markdown$" then return true end
  return false, "md-render: current buffer is not a Markdown file"
end

-- =====================================================================
-- show: floating preview window (existing behavior)
-- =====================================================================

--- Show a floating window previewing the current buffer's markdown content
---@param opts? { max_width?: integer }
MdPreview.show = function(opts)
  if float_win:close_if_valid() then return end

  local bufnr = vim.api.nvim_get_current_buf()
  local ok, warn = check_markdown_buffer(bufnr)
  if not ok then
    vim.notify(warn, vim.log.levels.WARN)
    return
  end

  local source_win = vim.api.nvim_get_current_win()
  local source_cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local session = get_or_create_session(bufnr, opts, {})

  local win = display_utils.open_float_window(session.buf, session.content, float_win, {
    title = " Markdown Preview ",
    position = "center",
    enter = true,
  })

  if session.win ~= win then session:bind_window(win) end
  session:scroll_to_source_line(source_cursor_line)
  session:install_footer()
  session:install_float_keymaps(float_win)
  session:install_navigation(source_win, float_win)
end

-- =====================================================================
-- show_tab: tab-based preview (existing behavior)
-- =====================================================================

--- Show a tab previewing the current buffer's markdown content
---@param opts? { max_width?: integer }
MdPreview.show_tab = function(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  if tab_win.win and vim.api.nvim_win_is_valid(tab_win.win) then
    local previous = MdPreview._sessions[vim.api.nvim_win_get_buf(tab_win.win)]
    local same_document = vim.api.nvim_get_current_win() == tab_win.win or (previous and previous.source_bufnr == bufnr)
    tab_win:close_if_valid()
    if same_document then return end
  end
  local ok, warn = check_markdown_buffer(bufnr)
  if not ok then
    vim.notify(warn, vim.log.levels.WARN)
    return
  end

  local source_win = vim.api.nvim_get_current_win()
  local source_cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local session = get_or_create_session(bufnr, opts, {})

  vim.cmd "tabnew"
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, session.buf)

  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldcolumn = "0"
  vim.wo[win].statuscolumn = ""
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = true
  vim.wo[win].spell = false
  vim.wo[win].list = false
  vim.wo[win].statusline = " Markdown Preview "

  vim.bo[session.buf].modifiable = false
  vim.bo[session.buf].bufhidden = "hide"

  tab_win:setup(win)

  if session.win ~= win then session:bind_window(win) end
  session:scroll_to_source_line(source_cursor_line)
  session:install_float_keymaps(tab_win)
  session:install_navigation(source_win, tab_win)
end

-- =====================================================================
-- toggle: same-window source ↔ render swap
-- =====================================================================

-- Toggle/split share their source cache. Each float/tab starts its own cache,
-- so simultaneous presentations never rewrite one another's rendered layout.
---@type table<integer, MdRender.Session>
local _toggle_sessions = {}

-- Window-local options that get overridden while a window is showing a
-- render buffer. The originals are stashed in `md_render_state.source_wo`
-- on the source->render transition and restored on the render->source
-- transition. The BufEnter guard re-applies these to any window that
-- happens to display the render buffer (covers manual `:b` / picker
-- entries in addition to the toggle / split entry points).
local RENDER_WIN_OPTS = {
  { "number", false },
  { "relativenumber", false },
  { "list", false },
  { "signcolumn", "no" },
  { "foldcolumn", "0" },
  { "statuscolumn", "" },
}

local function save_render_win_opts(win)
  local saved = {}
  for _, entry in ipairs(RENDER_WIN_OPTS) do
    saved[entry[1]] = vim.api.nvim_get_option_value(entry[1], { win = win })
  end
  for _, name in ipairs { "cursorline", "wrap", "spell", "statusline", "winbar" } do
    saved[name] = vim.api.nvim_get_option_value(name, { win = win })
  end
  return saved
end

local function apply_render_win_opts(win)
  for _, entry in ipairs(RENDER_WIN_OPTS) do
    vim.api.nvim_set_option_value(entry[1], entry[2], { win = win })
  end
end

local function restore_render_win_opts(win, saved)
  if not saved then return end
  for name, value in pairs(saved) do
    vim.api.nvim_set_option_value(name, value, { win = win })
  end
end

local function toggle_buf_augroup(buf)
  return "md_render_toggle_buf_" .. buf
end

local function toggle_src_augroup(bufnr)
  return "md_render_toggle_src_" .. bufnr
end

local function live_update_augroup(bufnr)
  return "md_render_toggle_live_" .. bufnr
end

local function scroll_sync_augroup(bufnr)
  return "md_render_toggle_sync_" .. bufnr
end

local function win_resize_augroup(bufnr)
  return "md_render_toggle_resize_" .. bufnr
end

local function shadow_augroup(bufnr)
  return "md_render_shadow_" .. bufnr
end

-- Dedicated namespace for MdRenderSplit shadow-cursor extmarks. Kept
-- separate from session.ns so Session:rebuild's clear of session.ns does
-- not wipe the shadow. nvim_create_namespace returns the same ID for
-- the same name, so source and render buffers can safely share it.
local SHADOW_NS = vim.api.nvim_create_namespace "md_render_shadow"

-- Auto-toggle state declared up here so install_source_watcher's BufWipeout
-- callback can clean it up. The auto_on / auto_off implementations live
-- further down with the rest of the auto-toggle logic.
---@type table<integer, { in_timer?: table, leave_timer?: table }>
local _auto_state = {}

local function auto_augroup(bufnr)
  return "md_render_auto_" .. bufnr
end

--- Schedule a debounced live rebuild of the render buffer.
--- Hidden buffers update immediately: native jumps read their marks before
--- BufEnter, so deferring their repaint until entry would use stale positions.
---@param session MdRender.Session
local function schedule_live_rebuild(session)
  if not vim.api.nvim_buf_is_valid(session.source_bufnr) then return end
  if not vim.api.nvim_buf_is_valid(session.buf) then return end

  close_timer(session._debounce_timer)
  session._debounce_timer = nil
  if not session:is_visible() then
    if session:refresh_source() or session.dirty then session:rebuild() end
    return
  end

  local timer
  timer = vim.defer_fn(function()
    if session._debounce_timer ~= timer then return end
    session._debounce_timer = nil
    if not vim.api.nvim_buf_is_valid(session.source_bufnr) then return end
    if not vim.api.nvim_buf_is_valid(session.buf) then return end
    if session:refresh_source() or session.dirty then
      session:rebuild()
      if session:is_visible() then session:refresh_images() end
    end
  end, 150)
  session._debounce_timer = timer
end

--- Listen for source buffer changes and trigger debounced live rebuilds.
---@param session MdRender.Session
local function install_live_update(session)
  local source_bufnr = session.source_bufnr
  local augroup = vim.api.nvim_create_augroup(live_update_augroup(source_bufnr), { clear = true })

  vim.api.nvim_create_autocmd({
    "TextChanged",
    "TextChangedI",
    "BufWritePost",
    "BufReadPost", -- :e reload
    "BufFilePost", -- :file / :saveas can change relative image and link paths
    "FileChangedShellPost", -- external change detected via :checktime / autoread
  }, {
    group = augroup,
    buffer = source_bufnr,
    callback = function()
      sync_source_modified(source_bufnr)
      for _, current in pairs(MdPreview._sessions) do
        if current.source_bufnr == source_bufnr and current.cache then schedule_live_rebuild(current) end
      end
    end,
  })
end

--- Bidirectional cursor + scroll sync between source and render windows.
---
--- Triggers:
---   - CursorMoved / CursorMovedI on source -> sync render windows
---   - CursorMoved on render -> sync source windows
---   - WinScrolled on either -> sync the other side (covers Ctrl+E / Ctrl+Y
---     / mouse-wheel scrolling that doesn't move the cursor)
---
--- Sync target: edge-aware. When the source is anchored to the file's
--- start or end, snap the destination to its own start or end (this
--- guarantees "I scrolled to the bottom, the other side did too" even
--- when source has hidden lines like footnote/link reference defs that
--- produce no render output and would otherwise leave the mapped end
--- short of the file). Otherwise map the cursor line through
--- `source_to_rendered_f` / `rendered_to_source_f` and put it at the same
--- height in the destination window as it has in the originating one,
--- measured as a fraction of the window in screen rows.
---
--- Mapping is done in floating point so a source line that sits between
--- two sync points yields a fractional render position rather than
--- snapping to the next marker. This mirrors the way VS Code's preview
--- interpolates between `data-line` markers.
---
--- Screen rows, not buffer lines, because the two sides spend them very
--- differently. A source line full of links wraps over several rows while
--- the render shortens the links and fits it in one or two, so a source
--- window can show only a handful of buffer lines whose rendered
--- counterpart is a fraction of the render window. The previous design
--- aligned the two visible ranges in buffer lines: centered on the mapped
--- center, then clamped to keep both mapped ends in view. When the mapped
--- range was shorter than the window the two clamps contradicted each
--- other, the bottom one won, and a heading on the top row of the source
--- showed up halfway down the render. The cursor is what the user is
--- looking at, so the cursor is what has to line up.
---
--- Aligning the cursor's row was tried once before and dropped because it
--- jittered: pressing `j` on a source line whose mapped render line did not
--- advance moved the render view up by a row, and the next step moved it
--- back. `TOPLINE_HYSTERESIS` in `fan_out` now absorbs that one-row
--- back-and-forth.
---
--- Both topline and cursor are written through a single `winrestview`
--- call. Using `nvim_win_set_cursor` instead would re-apply 'scrolloff'
--- and silently override the topline we just set.
---
--- Loop prevention, in two layers.
---
--- The first is a single `_syncing` flag, released after 30 ms via
--- vim.defer_fn. Each sync action fires both CursorMoved and WinScrolled
--- on the destination windows; the timer-based unlock suppresses the
--- whole cascade without the brittleness of trying to count events.
---
--- The timer alone is not enough, because it is a guess about how long the
--- cascade takes. Under a busy configuration — treesitter, diagnostics,
--- another plugin's decoration provider — a destination window's
--- `WinScrolled` lands well after 30 ms, and what comes back is then read
--- as a fresh user scroll. So the second layer records the view each write
--- produced and ignores an event whose window still holds it: same view
--- means the two sides already agree, whoever put them there, and there is
--- nothing to sync. See `is_echo`.
---
--- What made the missed echo *visible* rather than merely wasteful is that
--- the map between the buffers is many-to-one: a collapsed `<details>`, a
--- table or a figure renders as one line for a whole run of source lines.
--- `fan_out` therefore only writes a destination cursor that is actually
--- out of sync — see the `in_sync` predicates below.
---@param session MdRender.Session
local function install_scroll_sync(session)
  local augroup = vim.api.nvim_create_augroup(scroll_sync_augroup(session.source_bufnr), { clear = true })

  local SYNC_UNLOCK_MS = 30

  local function with_sync_lock(fn)
    session._syncing = true
    local ok, err = pcall(fn)
    close_timer(session._sync_unlock_timer)
    local timer
    timer = vim.defer_fn(function()
      if session._sync_unlock_timer ~= timer then return end
      session._syncing = false
      session._sync_unlock_timer = nil
    end, SYNC_UNLOCK_MS)
    session._sync_unlock_timer = timer
    if not ok then error(err) end
  end

  --- How long a topline that has not settled yet is still attributable to our
  --- own write. See `is_echo`.
  local ECHO_SETTLE_MS = 250

  --- How far a destination window may sit from the topline the map asks for
  --- before it is scrolled there. One line: enough to absorb the rounding of
  --- the map, small enough that the two views never visibly part company.
  local TOPLINE_HYSTERESIS = 1

  --- `{ topline, cursor_line }` of a window as it stands right now.
  ---
  --- Through `winsaveview()`, not `line('w0')`: `w0` *recomputes* the topline
  --- as a side effect, and doing that anywhere near a write undoes the edge
  --- snaps — after `zb` plus a cursor placement above the last line, the
  --- recomputation scrolls the window down and leaves the file's final line
  --- off the bottom. `winsaveview` reports the stored value and changes
  --- nothing.
  ---@param win integer
  ---@return integer[]?
  local function view_of(win)
    if not vim.api.nvim_win_is_valid(win) then return nil end
    local ok, view = pcall(vim.api.nvim_win_call, win, function()
      local v = vim.fn.winsaveview()
      return { v.topline, v.lnum }
    end)
    return ok and view or nil
  end

  --- True when `win` is still showing what the last sync wrote into it, i.e.
  --- the event being handled is our own write coming back.
  ---
  --- The 30 ms lock covers the cascade that arrives promptly; this covers the
  --- one that outran it, and unlike the lock it does not have to guess how
  --- long that takes. An unchanged view cannot need syncing either way: it is
  --- the view the other side was synced *to*, so the two already agree,
  --- whether the window got there by our write or by the user landing on the
  --- same spot.
  ---
  --- The cursor line is compared exactly. The topline gets a grace period,
  --- because the value recorded at write time is the stored one and Vim
  --- recomputes it at the next redraw — so our own write reads back with a
  --- topline that is merely close. Bounding that by time is what keeps a real
  --- scroll of the unfocused side (a mouse wheel over the preview, which
  --- moves the view and not the cursor) from being swallowed as an echo: it
  --- only takes 250 ms of quiet, and while the user is holding a key there is
  --- no wheel in the other hand.
  ---@param win integer
  ---@return boolean
  local function is_echo(win)
    local written = session._synced_views and session._synced_views[win]
    if not written then return false end
    local view = view_of(win)
    if not view or view[2] ~= written[2] then return false end
    if view[1] == written[1] then return true end
    return (vim.uv.now() - written[3]) < ECHO_SETTLE_MS
  end

  --- Apply a per-window scroll + cursor under the sync lock.
  ---
  --- For interior scrolls a single `winrestview` writes both topline
  --- and lnum so 'scrolloff' cannot shift the topline as a side effect
  --- of placing the cursor.
  ---
  --- For edge scrolls (`"top"` / `"bot"`) we cannot just compute
  --- `topline = dest_lines - height + 1`: when the destination has
  --- 'wrap' on (Vim's default), buffer lines that wrap occupy more
  --- screen rows than buffer rows, so a row-arithmetic topline leaves
  --- the file's last line off the bottom of the window. We instead
  --- park the cursor at the file boundary and use `zt` / `zb` so Vim
  --- itself computes a topline that respects 'wrap'.
  ---
  --- After applying the action, position the cursor and let Vim
  --- auto-scroll for visibility — without this, a topline computed
  --- from buffer rows can leave the cursor's row outside the visible
  --- screen rows when the destination has many wrapped or
  --- image-occupied buffer lines (e.g. README with kitty image
  --- placeholders), causing the shadow highlight to disappear past
  --- the bottom of the window.
  local function fan_out(wins, from_win, compute_action, target_cursor, in_sync)
    if #wins == 0 then return end
    local mapped_cursor = math.max(1, math.floor(target_cursor + 0.5))
    session._synced_views = session._synced_views or {}
    with_sync_lock(function()
      for _, w in ipairs(wins) do
        if w ~= from_win and vim.api.nvim_win_is_valid(w) then
          pcall(function()
            -- Where this window's cursor goes. Normally the mapped position,
            -- but the map is many-to-one wherever the render collapses source
            -- lines — a folded `<details>`, a table, a figure — and rounding
            -- to a whole line throws away which line of the block the cursor
            -- was on. Mapping that back picks the *first* source line of the
            -- run, so writing it unprompted drags the cursor to the top of
            -- the block, and a held `j` never escapes it. Leave a cursor that
            -- already stands for the same place where the user put it.
            local cursor = mapped_cursor
            local before_view = view_of(w)
            local current = vim.api.nvim_win_get_cursor(w)[1]
            if in_sync and in_sync(current) then cursor = current end
            local action = compute_action(w, cursor)

            -- Hysteresis on the scroll, for the same reason as on the cursor.
            --
            -- An interior topline is derived from the *other* window through a
            -- rounded map, so it trails what this window does on its own by up
            -- to a line: placing the cursor scrolls the window forward, the
            -- next sync computes a topline one line behind, and writing it
            -- scrolls back. Held down, that is a one-line shudder on every
            -- second keystroke — measured at 11 of 59 writes on a `j` sweep
            -- through README.ja.md. The same one-row step comes from a source
            -- cursor that moves down a row while its mapped line stays put.
            --
            -- Skipping the write leaves the window where it scrolled itself,
            -- which is what an unsynced window would have done anyway. Drift
            -- cannot accumulate: every action is computed from the current
            -- view rather than from the last one, so the two sides stay within
            -- the tolerance of each other and anything larger is still
            -- corrected.
            local settled = type(action) == "number"
              and before_view
              and math.abs(action - before_view[1]) <= TOPLINE_HYSTERESIS

            vim.api.nvim_win_call(w, function()
              if action == "top" then
                vim.fn.cursor(1, 1)
                vim.cmd "normal! zt"
              elseif action == "bot" then
                local last = vim.api.nvim_buf_line_count(0)
                vim.fn.cursor(last, 1)
                vim.cmd "normal! zb"
              elseif not settled then
                vim.fn.winrestview { topline = action, col = 0 }
              end
              -- Final cursor placement: vim.fn.cursor() respects
              -- 'wrap' / image-row layout when deciding whether to
              -- scroll, unlike a row-arithmetic topline. We keep the
              -- intended topline action above, then let Vim adjust if
              -- placing the cursor would push it off-screen.
              vim.fn.cursor(cursor, 1)
            end)
            -- Read the view back rather than record what we asked for:
            -- 'scrolloff', 'wrap' and the cursor placement above all move it
            -- after the fact, and a record that does not match the window
            -- would never recognise its own echo. The timestamp is what lets
            -- `is_echo` tell a topline that has not settled yet from one
            -- somebody else changed.
            local view = view_of(w)
            if view then session._synced_views[w] = { view[1], view[2], vim.uv.now() } end
          end)
        end
      end
    end)
  end

  --- Screen rows the lines `first` .. `last` take up in `win`, counting
  --- 'wrap', folds and virtual lines the way the window draws them.
  ---@return integer
  local function rows_between(win, first, last)
    if last < first then return 0 end
    return vim.api.nvim_win_text_height(win, { start_row = first - 1, end_row = last - 1 }).all
  end

  --- The topline that puts the first row of `line` `rows` screen rows below
  --- the top of `win`, or as close above that as whole lines allow. Walks up
  --- from `line` adding the height of each line, so a line that wraps over
  --- several rows counts as that many.
  ---@return integer
  local function topline_for_row(win, line, rows)
    local top, used = line, 0
    while top > 1 do
      local h = rows_between(win, top - 1, top - 1)
      if used + h > rows then break end
      used = used + h
      top = top - 1
    end
    return top
  end

  --- Decide what to do with one destination window.
  ---
  --- Returns either:
  ---   * the literal string `"top"` — fan_out will scroll the window
  ---     to its first line via `gg` + `zt` (handles 'wrap' correctly).
  ---   * the literal string `"bot"` — fan_out will scroll the window
  ---     to its last line via `G` + `zb` (handles 'wrap' correctly).
  ---   * an integer topline for the interior (mid-scroll) case, which puts
  ---     `cursor` `frac` of the way down the window in screen rows. It is
  ---     clamped so the window does not scroll past the end of its buffer;
  ---     the end itself is the `"bot"` case.
  ---@param w integer destination window
  ---@param dest_lines integer line count of the destination buffer
  ---@param cursor integer destination cursor line
  ---@param frac number how far down the originating window its cursor is, 0 <= frac < 1
  local function pick_action(w, dest_lines, cursor, frac, src_top_at_edge, src_bot_at_edge)
    local dest_height = vim.api.nvim_win_get_height(w)
    -- Edge snap only when the mapped cursor still fits in the window
    -- from that edge. Otherwise the snap pins topline=1 / botline=last
    -- but the cursor (and shadow) sit beyond the visible rows — common
    -- when the source is short but the render is much taller (images,
    -- tables, wrap). Fall through to the cursor-anchored interior path
    -- in that case.
    if src_top_at_edge and cursor <= dest_height then return "top" end
    if src_bot_at_edge and cursor >= dest_lines - dest_height + 1 then return "bot" end

    local rows = math.floor(frac * dest_height + 0.5)
    rows = math.max(0, math.min(rows, dest_height - 1))
    local topline = topline_for_row(w, cursor, rows)
    local last_rows = rows_between(w, dest_lines, dest_lines)
    local max_top = topline_for_row(w, dest_lines, math.max(0, dest_height - last_rows))
    return math.min(topline, max_top)
  end

  --- Where a window is looking: its visible buffer-line range, its cursor
  --- line, and how far down the window the cursor is.
  ---
  --- `line('w0')` / `line('w$')` honour 'wrap', folds, and 'diff' filler
  --- lines, unlike `topline + nvim_win_get_height() - 1` which counts
  --- screen rows and would over- or under-shoot when a single buffer line
  --- spans multiple screen rows. The cursor's height is measured in
  --- screen rows for the same reason, from the top row to the first row of
  --- the cursor line, as a fraction of the window height.
  ---
  --- Returned as an array because `nvim_win_call` only preserves the
  --- first return value of its callback.
  ---@return { [1]: integer, [2]: integer, [3]: integer, [4]: number } # `{ topline, botline, cursor_line, frac }`
  local function visible_range(win)
    return vim.api.nvim_win_call(win, function()
      local top, cursor = vim.fn.line "w0", vim.fn.line "."
      local above = rows_between(win, top, cursor - 1)
      local frac = above / math.max(1, vim.api.nvim_win_get_height(win))
      return { top, vim.fn.line "w$", cursor, math.min(math.max(frac, 0), 0.999) }
    end)
  end

  local function sync_from_source(source_win)
    if not vim.api.nvim_win_is_valid(source_win) then return end
    if vim.api.nvim_win_get_buf(source_win) ~= session.source_bufnr then return end
    local render_wins = vim.fn.win_findbuf(session.buf)
    if #render_wins == 0 then return end

    local source_lines = vim.api.nvim_buf_line_count(session.source_bufnr)
    local sv = visible_range(source_win)
    local source_topline, source_botline, source_cursor_line, frac = sv[1], sv[2], sv[3], sv[4]
    local src_top_at_edge = source_topline <= 1
    local src_bot_at_edge = source_botline >= source_lines

    local render_lines = vim.api.nvim_buf_line_count(session.buf)
    local target_cursor = math.min(math.max(session:source_to_rendered_f(source_cursor_line), 1), render_lines)

    -- A render cursor that maps back to the source line the user is on is
    -- already pointing at the same place; only the rounding differs.
    local function in_sync(render_line)
      local back = session:rendered_to_source_f(render_line)
      back = math.min(math.max(back, 1), source_lines)
      return math.floor(back + 0.5) == source_cursor_line
    end

    fan_out(render_wins, source_win, function(w, cursor)
      return pick_action(w, render_lines, cursor, frac, src_top_at_edge, src_bot_at_edge)
    end, target_cursor, in_sync)
  end

  local function sync_from_render(render_win)
    if not vim.api.nvim_win_is_valid(render_win) then return end
    if vim.api.nvim_win_get_buf(render_win) ~= session.buf then return end
    local source_wins = vim.fn.win_findbuf(session.source_bufnr)
    if #source_wins == 0 then return end

    if #session:get_sync_points() == 0 then return end
    local render_lines = vim.api.nvim_buf_line_count(session.buf)
    local rv = visible_range(render_win)
    local render_topline, render_botline, render_cursor_line, frac = rv[1], rv[2], rv[3], rv[4]
    local src_top_at_edge = render_topline <= 1
    local src_bot_at_edge = render_botline >= render_lines

    local source_lines = vim.api.nvim_buf_line_count(session.source_bufnr)
    local target_cursor = math.min(math.max(session:rendered_to_source_f(render_cursor_line), 1), source_lines)

    -- The direction that used to trap the cursor. Every source line of a
    -- collapsed block maps to the one rendered line the block occupies, so
    -- the source cursor is already where it belongs whenever it maps
    -- *forward* onto the render cursor — and moving it to the block's first
    -- line, which is what the backward map returns, would be a regression
    -- rather than a correction.
    local function in_sync(source_line)
      local fwd = session:source_to_rendered_f(source_line)
      fwd = math.min(math.max(fwd, 1), render_lines)
      return math.floor(fwd + 0.5) == render_cursor_line
    end

    fan_out(source_wins, render_win, function(w, cursor)
      return pick_action(w, source_lines, cursor, frac, src_top_at_edge, src_bot_at_edge)
    end, target_cursor, in_sync)
  end

  -- `MdPreview.split` calls this once the windows are in place: the split
  -- opens with the render centred on the cursor, which is not where the
  -- cursor is in the source window.
  --
  -- The lock is released straight away rather than after 30 ms: nothing
  -- the user does right after opening the split should be dropped, and the
  -- render window's own echo of this write is recognised by `is_echo`.
  session._sync_from_source = function(win)
    sync_from_source(win)
    if session._sync_unlock_timer then
      session._sync_unlock_timer:stop()
      session._sync_unlock_timer = nil
    end
    session._syncing = false
  end

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augroup,
    buffer = session.source_bufnr,
    callback = function()
      if session._syncing then return end
      local win = vim.api.nvim_get_current_win()
      if is_echo(win) then return end
      sync_from_source(win)
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = session.buf,
    callback = function()
      if session._syncing then return end
      local win = vim.api.nvim_get_current_win()
      if is_echo(win) then return end
      sync_from_render(win)
    end,
  })

  -- WinScrolled has no `buffer = ...` filter, so we register globally and
  -- dispatch via vim.v.event which carries { [winid_str] = {...}, ... }
  -- for every window whose view changed in the current tick.
  vim.api.nvim_create_autocmd("WinScrolled", {
    group = augroup,
    callback = function()
      if session._syncing then return end
      local event = vim.v.event
      if type(event) ~= "table" then return end
      for key in pairs(event) do
        -- A window this sync just wrote to is skipped rather than returned
        -- on: one tick can carry both sides, and stopping at the echo would
        -- hide a genuine scroll reported alongside it.
        if key ~= "all" then
          local win = tonumber(key)
          if win and vim.api.nvim_win_is_valid(win) and not is_echo(win) then
            local buf = vim.api.nvim_win_get_buf(win)
            if buf == session.source_bufnr then
              sync_from_source(win)
              return
            elseif buf == session.buf then
              sync_from_render(win)
              return
            end
          end
        end
      end
    end,
  })
end

--- Shadow cursor for MdRenderSplit: highlight the matching line(s) on
--- the unfocused side so the user can see where the focused cursor maps
--- to in the counterpart buffer.
---
--- - source -> render: highlight the contiguous render-line block that
---   the source cursor's line expands into (a heading that wraps, or a
---   source line of a paragraph whose rows start in it, is shown as a
---   block).
--- - render -> source: highlight the single source line the render
---   cursor's line maps back to (the map is 1:1 in this direction).
---
--- The focused side is always cleared so the shadow never overlaps with
--- the real cursor + cursorline. When source and render are not both
--- visible at once (toggle mode, split closed), no shadow is placed.
---
--- This handler intentionally ignores `_syncing`: scroll_sync moves the
--- counterpart cursor under the lock, and we want shadow to follow the
--- focused side's cursor regardless. Flicker is suppressed by a no-op
--- early return when the new line set equals the existing one — the
--- two sides converge on a fixpoint within one tick.
---@param session MdRender.Session
local function install_shadow_cursor(session)
  local augroup = vim.api.nvim_create_augroup(shadow_augroup(session.source_bufnr), { clear = true })

  -- Map source line -> [start, end] render line range (inclusive).
  --
  -- Walks source_line_map directly instead of going through the
  -- linear-interpolation `source_to_rendered_f`. The interpolation path
  -- mis-sizes blocks whenever consecutive source lines collapse:
  --   - headings followed by blanks that map to the heading itself
  --   - <img>/<details>/callout/table whose body source lines never
  --     appear in the map (the renderer attributes the entire rendered
  --     block to the opening source line)
  -- For those cases we want the *whole rendered block* of the cursor's
  -- source line, including any orphan rows (map entry == 0) that are
  -- structurally part of it.
  --
  -- Owner fallback: if `source_line` itself isn't in the map (e.g. the
  -- cursor sits inside a callout/details body whose lines don't emit
  -- their own render rows), we fall back to the largest mapped source
  -- line `<= source_line` whose rendered block extends past the cursor
  -- — i.e. the container that swallowed the body. This makes the shadow
  -- track the visible block instead of disappearing mid-container.
  local function compute_render_range(source_line)
    local map = session.content.source_line_map
    if not map or #map == 0 then return nil end

    -- Direct hit: source_line is in the map.
    local first = nil
    for i = 1, #map do
      if map[i] == source_line then
        first = i
        break
      end
    end

    -- Owner fallback: pick the closest mapped source line <= source_line.
    if not first then
      local owner_src = nil
      local owner_first = nil
      for i = 1, #map do
        local m = map[i]
        if m > 0 and m <= source_line and (not owner_src or m > owner_src) then
          owner_src = m
          owner_first = i
        end
      end
      if not owner_src then return nil end
      -- Only use the owner's block when it actually swallows source_line:
      -- the next mapped source line must be strictly greater than
      -- source_line. Otherwise the cursor sits past the container.
      local next_src = nil
      for i = owner_first + 1, #map do
        if map[i] > owner_src then
          next_src = map[i]
          break
        end
      end
      if next_src and source_line >= next_src then return nil end
      first = owner_first
      source_line = owner_src
    end

    -- Extend forward to include consecutive rows that belong to the
    -- same block: the source line itself, smaller source lines (rare),
    -- and orphan rows (0). Stop at the first row mapped to a strictly
    -- greater source line — that's the next semantic block.
    local last = first
    for i = first + 1, #map do
      if map[i] > source_line then break end
      last = i
    end

    local render_lines = vim.api.nvim_buf_line_count(session.buf)
    if first < 1 then first = 1 end
    if last > render_lines then last = render_lines end
    if last < first then return nil end
    return first, last
  end

  -- Map render line -> single source line.
  local function compute_source_line(render_line)
    local map = session.content.source_line_map
    if not map or render_line < 1 or render_line > #map then return nil end
    local src = map[render_line]
    if not src or src < 1 then return nil end
    local source_lines = vim.api.nvim_buf_line_count(session.source_bufnr)
    if src > source_lines then src = source_lines end
    return src
  end

  -- Read existing shadow extmark line numbers (1-based, sorted) so we
  -- can no-op when nothing changed.
  local function current_shadow_lines(buf)
    if not vim.api.nvim_buf_is_valid(buf) then return {} end
    local marks = vim.api.nvim_buf_get_extmarks(buf, SHADOW_NS, 0, -1, {})
    local lines = {}
    for _, m in ipairs(marks) do
      table.insert(lines, m[2] + 1)
    end
    table.sort(lines)
    return lines
  end

  local function lines_equal(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
      if a[i] ~= b[i] then return false end
    end
    return true
  end

  local function clear_shadow(buf)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if #current_shadow_lines(buf) == 0 then return end
    vim.api.nvim_buf_clear_namespace(buf, SHADOW_NS, 0, -1)
  end

  local function set_shadow(buf, lines)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if lines_equal(current_shadow_lines(buf), lines) then return end
    vim.api.nvim_buf_clear_namespace(buf, SHADOW_NS, 0, -1)
    for _, l in ipairs(lines) do
      pcall(vim.api.nvim_buf_set_extmark, buf, SHADOW_NS, l - 1, 0, {
        line_hl_group = "MdRenderShadowCursor",
      })
    end
  end

  -- Active win drives direction. Guard with win_findbuf so we only
  -- place a shadow when both sides are simultaneously visible.
  local function recompute()
    if not vim.api.nvim_buf_is_valid(session.source_bufnr) then return end
    if not vim.api.nvim_buf_is_valid(session.buf) then return end

    local active_win = vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(active_win) then return end
    local active_buf = vim.api.nvim_win_get_buf(active_win)

    local source_visible = #vim.fn.win_findbuf(session.source_bufnr) > 0
    local render_visible = #vim.fn.win_findbuf(session.buf) > 0
    if not (source_visible and render_visible) then
      clear_shadow(session.source_bufnr)
      clear_shadow(session.buf)
      return
    end

    if active_buf == session.source_bufnr then
      clear_shadow(session.source_bufnr)
      local cursor_line = vim.api.nvim_win_get_cursor(active_win)[1]
      local s, e = compute_render_range(cursor_line)
      if not s then
        clear_shadow(session.buf)
        return
      end
      -- Skip image-overlay rows: setting line_hl_group on a line that
      -- carries a Kitty Graphics placement causes the terminal to repaint
      -- those cells with the new background, wiping the image overlay.
      -- The image redraw autocmd in display_utils only fires for
      -- CursorMoved/WinScrolled inside the render window, so source-side
      -- cursor moves leave the image gone until something else forces a
      -- redraw. image_placements use 0-indexed `line`; shadow tracks
      -- 1-indexed render lines.
      local image_rows = {}
      local placements = session.content and session.content.image_placements or {}
      for _, p in ipairs(placements) do
        for r = p.line + 1, p.line + (p.rows or 1) do
          image_rows[r] = true
        end
      end
      local lines = {}
      for l = s, e do
        if not image_rows[l] then table.insert(lines, l) end
      end
      set_shadow(session.buf, lines)
    elseif active_buf == session.buf then
      clear_shadow(session.buf)
      local cursor_line = vim.api.nvim_win_get_cursor(active_win)[1]
      local src = compute_source_line(cursor_line)
      if not src then
        clear_shadow(session.source_bufnr)
        return
      end
      set_shadow(session.source_bufnr, { src })
    end
    -- If the active window shows neither side, leave existing shadows
    -- alone — focus may return shortly without disturbing the user.
  end

  -- Stash so MdPreview.split can trigger the initial paint.
  session._shadow_recompute = recompute

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = augroup,
    buffer = session.source_bufnr,
    callback = recompute,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = augroup,
    buffer = session.buf,
    callback = recompute,
  })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = augroup,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if not vim.api.nvim_win_is_valid(win) then return end
      local buf = vim.api.nvim_win_get_buf(win)
      if buf == session.source_bufnr or buf == session.buf then recompute() end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(ev)
      local closed_win = tonumber(ev.match)
      if not closed_win then return end
      -- Re-evaluate after the close so win_findbuf reflects the new state.
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(session.source_bufnr) then return end
        if not vim.api.nvim_buf_is_valid(session.buf) then return end
        local source_visible = #vim.fn.win_findbuf(session.source_bufnr) > 0
        local render_visible = #vim.fn.win_findbuf(session.buf) > 0
        if not (source_visible and render_visible) then
          clear_shadow(session.source_bufnr)
          clear_shadow(session.buf)
        else
          recompute()
        end
      end)
    end,
  })
end

--- Rebuild render content when a render window is resized and max_width is
--- not explicitly set, so that text wrapping and image sizing adapt to the
--- new window dimensions.
---@param session MdRender.Session
local function install_win_resize_handler(session)
  local augroup = vim.api.nvim_create_augroup(win_resize_augroup(session.buf), { clear = true })

  vim.api.nvim_create_autocmd("WinResized", {
    group = augroup,
    callback = function()
      local render_wins = vim.fn.win_findbuf(session.buf)
      if #render_wins == 0 then return end
      set_preview_wrap(session.buf, session.content)

      local win = render_wins[1]
      if not vim.api.nvim_win_is_valid(win) then return end
      if session:resize(win) then
        session.dirty = true
        schedule_live_rebuild(session)
      end
    end,
  })
end

--- Apply read-only buffer options used by toggle-mode render buffers.
--- - buftype = `acwrite` so `:w` reaches the BufWriteCmd handler installed
---   in install_render_buf_guards (instead of E382 from Vim itself).
--- - modifiable = false to block editing keys.
--- - readonly is intentionally left false: Vim checks readonly *before*
---   firing BufWriteCmd, so a true readonly would short-circuit `:w` with
---   E45 and prevent us from forwarding the write to the source.
---@param session MdRender.Session
local function apply_render_buf_options(session)
  vim.bo[session.buf].buftype = "acwrite"
  vim.bo[session.buf].bufhidden = "hide"
  vim.bo[session.buf].swapfile = false
  vim.bo[session.buf].modifiable = false
  vim.bo[session.buf].readonly = false
  session:sync_modified()
end

--- Forward a complete write while preserving source errors and preview state.
function Session:write_source(file)
  if not vim.api.nvim_buf_is_valid(self.source_bufnr) then error("md-render: source buffer is gone; cannot save", 0) end
  if not vim.api.nvim_buf_is_loaded(self.source_bufnr) then
    -- A queued write can precede the deferred dirty mirror after :bunload!.
    sync_source_modified(self.source_bufnr)
    error("md-render: source buffer is unloaded; reload the source before saving", 0)
  end
  local render_name = vim.api.nvim_buf_get_name(self.buf)
  if file ~= "" and file ~= render_name then
    error(
      "md-render: writing to a different file from render mode is not supported; "
        .. "use :MdRenderToggle and save from source",
      0
    )
  end
  local bang = vim.v.cmdbang == 1 and "!" or ""
  local cmdarg = vim.v.cmdarg
  -- Use the actual window: nvim_buf_call can leave :write on the render.
  -- Suppress enter/leave events while swapping; save autocmds run normally.
  local win = vim.api.nvim_get_current_win()
  local saved_buf = vim.api.nvim_win_get_buf(win)
  local saved_ei = vim.o.eventignore
  local ok, err = pcall(function()
    without_events(function()
      vim.api.nvim_win_set_buf(win, self.source_bufnr)
    end)
    vim.api.nvim_command("write" .. bang .. " " .. cmdarg)
  end)
  local restored, restore_err = pcall(without_events, function()
    if
      vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_buf_is_valid(saved_buf)
      and vim.api.nvim_win_get_buf(win) == self.source_bufnr
    then
      vim.api.nvim_win_set_buf(win, saved_buf)
    end
  end)
  vim.o.eventignore = saved_ei
  sync_source_modified(self.source_bufnr)
  if not ok then
    -- A formatter may edit before failing. Refresh after reporting its error.
    vim.schedule(function()
      for _, current in pairs(MdPreview._sessions) do
        if current.source_bufnr == self.source_bufnr and current.cache then schedule_live_rebuild(current) end
      end
    end)
    error(err, 0)
  end
  if not restored then error(restore_err, 0) end
end

--- Re-assert read-only on entry; revert on accidental edit.
---@param session MdRender.Session
local function install_render_buf_guards(session)
  local augroup = vim.api.nvim_create_augroup(toggle_buf_augroup(session.buf), { clear = true })

  -- Ex splits copy window options, but not w: variables. Preserve their source snapshot.
  -- ponytail: Ex split ancestry only; arbitrary API targets need explicit origin tracking.
  vim.api.nvim_create_autocmd("WinNew", {
    group = augroup,
    callback = function()
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(win) ~= session.buf or vim.api.nvim_win_get_config(win).relative ~= "" then return end
      local parent = vim.fn.win_getid(vim.fn.winnr "#")
      if parent == 0 then
        local tab = vim.fn.tabpagenr "#"
        parent = vim.fn.win_getid(vim.fn.tabpagewinnr(tab), tab)
      end
      local ok, state = pcall(vim.api.nvim_win_get_var, parent, "md_render_state")
      if
        ok
        and type(state) == "table"
        and state.render_buf == session.buf
        and vim.api.nvim_win_get_buf(parent) == session.buf
      then
        vim.api.nvim_win_set_var(win, "md_render_state", state)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    buffer = session.buf,
    callback = function()
      if vim.api.nvim_buf_is_valid(session.buf) then
        vim.bo[session.buf].modifiable = false
        session:sync_modified()
        -- Don't set readonly = true here: Vim's :w checks readonly before
        -- firing BufWriteCmd, so doing so would break our :w forwarding.
      end
      local win = vim.api.nvim_get_current_win()
      if vim.api.nvim_win_get_buf(win) == session.buf then
        apply_render_win_opts(win)
        set_preview_wrap(session.buf, session.content)
      end

      -- Mirror the stale-content check from get_or_create_session
      -- so paths that swap to the render buf without going through
      -- MdPreview.toggle (jumplist Ctrl-O / Ctrl-I, :buffer, :b#, etc.)
      -- still see fresh content, including edits made without TextChanged.
      if vim.api.nvim_buf_is_valid(session.source_bufnr) then
        local current = vim.api.nvim_buf_get_lines(session.source_bufnr, 0, -1, false)
        if session.dirty or not vim.deep_equal(current, session.source_lines) then
          session:refresh_source()
          session:rebuild()
          session:refresh_images()
        end
      end
    end,
  })

  -- Restore source dirtiness after our own internal writes. The buffer is
  -- modifiable=false (re-asserted by BufEnter), so user edits are blocked
  -- at the Vim level (E21) and never reach TextChanged. Any TextChanged
  -- that fires here is from internal writes (apply_content_to_buffer in
  -- Session:rebuild, clear_placeholder_text during async image placement,
  -- the on_download rebuild in display_utils.setup_images). They must not
  -- make a clean source appear dirty or erase its unsaved state.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = augroup,
    buffer = session.buf,
    callback = function()
      session:sync_modified()
    end,
  })

  -- :saveas renames before BufWriteCmd. A native exception aborts interactive
  -- Ex too; an error from a Lua callback only interrupts API command callers.
  vim.api.nvim_create_autocmd("BufFilePre", {
    group = augroup,
    buffer = session.buf,
    command = "throw 'md-render: renaming a rendered buffer is not supported; use :MdRenderToggle and save from source'",
  })

  -- Alternate filenames, partial ranges and appends bypass BufWriteCmd.
  vim.api.nvim_create_autocmd({ "FileWriteCmd", "FileAppendCmd" }, {
    group = augroup,
    buffer = session.buf,
    command = "throw 'md-render: partial writes, appends or other filenames are not supported; use :MdRenderToggle and save from source'",
  })

  -- Forward `:w` / `:w!` on the render buffer to a `:write` on the source.
  -- :saveas / :w other-name is rejected (use :MdRenderToggle
  -- to switch to source first).
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = augroup,
    buffer = session.buf,
    nested = true,
    -- Lua callback errors do not abort interactive :wq!. Re-throw at Ex level.
    command = "try | call luaeval(\"require('md-render.preview')._sessions[_A[1]]:write_source(_A[2])\", "
      .. "[str2nr(expand('<abuf>')), expand('<afile>')]) | catch | throw 'md-render: ' . v:exception | endtry",
  })
end

--- Release one rendered document; source watchers may still serve other previews.
function Session:dispose()
  close_timer(self._debounce_timer)
  close_timer(self._sync_unlock_timer)
  self._debounce_timer, self._sync_unlock_timer = nil, nil
  deferred_rebuilds[self.buf] = nil
  self:cleanup_images()
  self.win = nil
  if self.cache and self.cache[self.source_bufnr] == self then self.cache[self.source_bufnr] = nil end
  MdPreview._sessions[self.buf] = nil
  if vim.api.nvim_buf_is_valid(self.buf) then
    local win = vim.fn.win_findbuf(self.buf)[1]
    if win then
      -- Keep the last normal window when disposal runs from a floating preview.
      pcall(vim.api.nvim_win_call, win, function()
        vim.api.nvim_buf_delete(self.buf, { force = true })
      end)
    else
      pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
    end
  end
  pcall(vim.api.nvim_del_augroup_by_name, toggle_buf_augroup(self.buf))
  pcall(vim.api.nvim_del_augroup_by_name, win_resize_augroup(self.buf))
end

--- When the source buffer is wiped, drop the cached session and its render buf.
---@param session MdRender.Session
local function install_source_watcher(session)
  local source_bufnr = session.source_bufnr
  local augroup = vim.api.nvim_create_augroup(toggle_src_augroup(source_bufnr), { clear = true })

  attach_source_modified(source_bufnr)
  -- Neovim 0.13 reports modified changes through OptionSet instead.
  local events = { "BufReadPost" }
  if vim.fn.exists "##BufModifiedSet" == 1 then table.insert(events, "BufModifiedSet") end
  vim.api.nvim_create_autocmd(events, {
    group = augroup,
    buffer = source_bufnr,
    callback = function()
      attach_source_modified(source_bufnr)
      sync_source_modified(source_bufnr)
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = source_bufnr,
    once = true,
    callback = function()
      modified_sources[source_bufnr] = nil
      local astate = _auto_state[source_bufnr]
      if astate then
        close_timer(astate.in_timer)
        close_timer(astate.leave_timer)
        _auto_state[source_bufnr] = nil
      end
      for _, current in pairs(MdPreview._sessions) do
        if current.source_bufnr == source_bufnr and current.cache then current:dispose() end
      end
      pcall(vim.api.nvim_del_augroup_by_name, toggle_src_augroup(source_bufnr))
      pcall(vim.api.nvim_del_augroup_by_name, live_update_augroup(source_bufnr))
      pcall(vim.api.nvim_del_augroup_by_name, scroll_sync_augroup(source_bufnr))
      pcall(vim.api.nvim_del_augroup_by_name, shadow_augroup(source_bufnr))
      pcall(vim.api.nvim_del_augroup_by_name, auto_augroup(source_bufnr))
    end,
  })
end

---@param source_bufnr integer
---@param opts? table
---@param cache? table<integer, MdRender.Session>
---@return MdRender.Session
get_or_create_session = function(source_bufnr, opts, cache)
  cache = cache or _toggle_sessions
  local session = cache[source_bufnr]
  if session and not vim.api.nvim_buf_is_valid(session.buf) then
    -- Render buf was wiped externally; drop and rebuild.
    session:dispose()
    session = nil
  end

  if session then
    -- Keep render content in sync with the latest source state.
    -- Live-update normally clears `dirty`, but fall back to a content
    -- comparison so that direct `nvim_buf_set_lines` (which may not fire
    -- TextChanged in headless contexts) is still picked up here.
    local current = vim.api.nvim_buf_get_lines(session.source_bufnr, 0, -1, false)
    if session.dirty or not vim.deep_equal(current, session.source_lines) then
      session:refresh_source()
      session:rebuild()
    end
    return session
  end

  session = Session.new(source_bufnr, "md_render_toggle_" .. source_bufnr, opts)
  session.cache = cache
  apply_render_buf_options(session)
  install_render_buf_guards(session)
  install_source_watcher(session)
  install_live_update(session)
  -- Source editing and scroll/shadow synchronization belong to toggle/split.
  -- Floating/tab presentations retain independent layout and reading state.
  if cache == _toggle_sessions then
    install_scroll_sync(session)
    install_shadow_cursor(session)
  end
  install_win_resize_handler(session)
  cache[source_bufnr] = session
  return session
end

--- Resolve toggle state for this window's current buffer.
---@param win integer
---@return { source_buf: integer, render_buf: integer, mode: "source"|"render", source_view?: vim.fn.winsaveview.ret }?
local function get_win_state(win)
  local ok, state = pcall(vim.api.nvim_win_get_var, win, "md_render_state")
  if not ok or type(state) ~= "table" then state = nil end
  local buf = vim.api.nvim_win_get_buf(win)
  -- A render buffer can also be entered without toggle/split (e.g. :buffer).
  local session = MdPreview._sessions[buf]
  if session and _toggle_sessions[session.source_bufnr] == session then
    if not state or state.render_buf ~= session.buf then
      state = {
        source_buf = session.source_bufnr,
        render_buf = session.buf,
        mode = "render",
        source_wo = session._source_wo,
      }
      vim.api.nvim_win_set_var(win, "md_render_state", state)
    end
  end
  if not state then return nil end
  if not state.source_buf or not vim.api.nvim_buf_is_valid(state.source_buf) then return nil end
  -- :new / :split {file} can replace the buffer after WinNew copied state.
  if buf ~= state.source_buf and buf ~= state.render_buf then return nil end
  state.mode = buf == state.render_buf and "render" or "source"
  return state
end

local function set_win_state(win, state)
  vim.api.nvim_win_set_var(win, "md_render_state", state)
  -- Fallback for render-buffer entries without a saved window state.
  local session = _toggle_sessions[state.source_buf]
  if session and state.mode == "render" then session._source_wo = state.source_wo end
end

-- Native jumps keep the document history. This table only owns the resources
-- and presentation of each window; hidden Sessions retain folds and views.
local navigation_windows = {}
local pending_views = {}
local enter_navigation

local pager_options = { showtabline = 0, laststatus = 0, cmdheight = 0, ruler = false, showcmd = false }
local saved_pager_options

-- Global chrome belongs to the focused presentation, including native window
-- and tab switches. Capture editor changes again on each new pager entry.
local function update_pager_ui(session)
  if session and session.pager then
    if not saved_pager_options then
      saved_pager_options = {}
      for name in pairs(pager_options) do
        saved_pager_options[name] = vim.o[name]
      end
    end
    if saved_pager_options.cmdheight == nil then saved_pager_options.cmdheight = vim.o.cmdheight end
    for name, value in pairs(pager_options) do
      vim.o[name] = value
    end
  elseif saved_pager_options then
    for name, value in pairs(saved_pager_options) do
      vim.o[name] = value
    end
    saved_pager_options = nil
  end
end

local function view_key(line, col)
  return line .. ":" .. col
end

local function remember_view(session, win, view)
  session.views[win] = view
  session.jump_views = session.jump_views or {}
  local views = session.jump_views[win] or {}
  views[view_key(view.lnum, view.col)] = view
  session.jump_views[win] = views
  -- getjumplist() normalizes pending entries: calling it inside BufLeave
  -- would remove the jump currently being recorded. Prune after it settles.
  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(win) then return end
    local latest = session.views[win]
    local saved = session.jump_views[win]
    if not (latest and saved) then return end
    local retained = { [view_key(latest.lnum, latest.col)] = true }
    local tab = vim.fn.win_id2tabwin(win)[1]
    for _, jump in ipairs(vim.fn.getjumplist(win, tab)[1]) do
      if jump.bufnr == session.buf then retained[view_key(jump.lnum, jump.col)] = true end
    end
    for key in pairs(saved) do
      if not retained[key] then saved[key] = nil end
    end
  end)
end

local function restore_view(session, win)
  if pending_views[win] ~= session then return end
  pending_views[win] = nil
  if not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= session.buf then return end
  local saved = session.jump_views and session.jump_views[win]
  local cursor = vim.api.nvim_win_get_cursor(win)
  local view = saved and saved[view_key(cursor[1], cursor[2])]
  if view then vim.api.nvim_win_call(win, function()
    vim.fn.winrestview(view)
  end) end
end

local function detach_session(session, win)
  if session.win ~= win then return end
  session:cleanup_images()
  session.win = nil
  -- Session images have one owner. Hand them back to a retained split when
  -- a jump or window close removes the most recently bound view.
  for _, other in ipairs(vim.fn.win_findbuf(session.buf)) do
    if other ~= win and vim.api.nvim_win_is_valid(other) then
      local context = navigation_windows[other]
      session:bind_window(other, context and context.layout)
      break
    end
  end
end

local function leave_navigation(win, context)
  if not context.session then return end
  detach_session(context.session, win)
  if context.close_handle and context.close_handle.win == win then context.close_handle:detach() end
  if vim.api.nvim_win_get_config(win).relative == "" then restore_render_win_opts(win, context.source_wo) end
  pcall(vim.api.nvim_win_del_var, win, "md_render_state")
  context.session = nil
end

local function navigation_origin(session)
  -- Native splits do not copy window variables. The alternate window (or
  -- previous tab's active window for :tab split) still identifies the parent.
  local previous = vim.fn.winnr "#"
  local win = previous > 0 and vim.fn.win_getid(previous) or nil
  if not win then
    local tab = vim.fn.tabpagenr "#"
    if tab > 0 then win = vim.fn.win_getid(vim.fn.tabpagewinnr(tab), tab) end
  end
  local context = win and navigation_windows[win]
  return context and context.session == session and context or nil
end

local function navigation_context(win, session)
  local origin = navigation_origin(session)
  local context = {
    source_win = origin and origin.source_win or win,
    source_wo = origin and origin.source_wo or save_render_win_opts(win),
    layout = origin and origin.layout,
    session = session,
  }
  navigation_windows[win] = context
  return context
end

local active_link_tag
local link_tag_prefix = "md-render:"

local function enable_render_tags(session)
  if session._tag_readcmd then return end
  if vim.api.nvim_buf_get_name(session.buf) == "" then
    without_events(function()
      vim.api.nvim_buf_set_name(session.buf, "md-render://render/" .. session.buf)
      vim.bo[session.buf].filetype = "md-render"
    end)
  end
  -- The native tag reader accepts loaded virtual filenames when BufReadCmd
  -- owns that literal filename. It does not invoke this handler on a jump.
  session._tag_readcmd = vim.api.nvim_create_autocmd("BufReadCmd", {
    group = vim.api.nvim_create_augroup(toggle_buf_augroup(session.buf), { clear = false }),
    pattern = vim.fn.escape(vim.api.nvim_buf_get_name(session.buf), "[]*?\\{},"),
    -- :edit! clears the buffer before BufReadCmd. Restore the render before
    -- throwing a native exception, which also aborts interactive Ex commands.
    command = [[call luaeval("require('md-render.preview')._sessions[_A]:rebuild(true)", str2nr(expand('<abuf>'))) | throw "md-render: reload the source buffer instead of the rendered buffer"]],
  })
end

-- Prepare the exact href before creating a window or touching native history.
function Session:link_target(url)
  local links = require "md-render.links"
  if url:match "^#" then
    local row = links.anchor_row(url, self.content)
    if row == nil then error("anchor not found: " .. url) end
    return { source = self.source_bufnr, session = self, row = row, url = url }
  end
  local path = links.file_path(url, self:source_directory())
  if not path then return nil end
  return self:file_target(path, url)
end

-- Concrete paths have already been decoded; do not interpret their # or %.
function Session:file_target(path, url)
  local links = require "md-render.links"
  local stat = vim.uv.fs_stat(path)
  if
    not stat
    or (stat.type ~= "file" and stat.type ~= "directory")
    or not vim.uv.fs_access(path, stat.type == "directory" and "RX" or "R")
  then
    error("not a readable file or directory: " .. path)
  end
  local source = vim.fn.bufadd(path)
  local target = {
    source = source,
    path = path,
    url = url or path,
    anchor = url and url:match "#.*$",
    directory = stat.type == "directory",
  }
  if not target.directory then
    vim.fn.bufload(source)
    if not vim.api.nvim_buf_is_loaded(source) then error "could not read file" end
    if check_markdown_buffer(source) then
      local opts = vim.tbl_extend("force", {}, self.opts)
      opts.buf_dir = nil
      opts.max_width = self._explicit_max_width and self.opts.max_width or nil
      local session = get_or_create_session(source, opts, self.cache)
      session.pager, session.views = self.pager, session.views or {}
      enable_render_tags(session)
      target.session = session
      if target.anchor then target.row = links.anchor_row(target.anchor, session.content) end
    end
  end
  return target
end

function MdPreview._link_tagfunc(pattern, flags, info)
  local session = MdPreview._sessions[vim.api.nvim_get_current_buf()]
  local request = active_link_tag
  if
    not request
    and session
    and type(info.user_data) == "string"
    and info.user_data:sub(1, #link_tag_prefix) == link_tag_prefix
  then
    local ok, url = pcall(vim.json.decode, info.user_data:sub(#link_tag_prefix + 1))
    if ok and type(url) == "string" then
      local prepared, target = pcall(session.link_target, session, url)
      if prepared and target then request = { target = target } end
    end
  end
  -- Native selectors may re-query the tag after their async picker returns.
  if not request and session and pattern:sub(1, #link_tag_prefix) == link_tag_prefix then
    local url = vim.uri_decode(pattern:sub(#link_tag_prefix + 1))
    local prepared, target = pcall(session.link_target, session, url)
    if prepared and target then request = { target = target } end
  end
  if not request then
    local original = session and session._navigation_tagfunc
    if not original or original == "" then return vim.NIL end
    if original:match "^v:lua%." then
      return vim.api.nvim_eval(
        original .. "(" .. vim.fn.string(pattern) .. "," .. vim.fn.string(flags) .. "," .. vim.fn.string(info) .. ")"
      )
    end
    return vim.fn[original](pattern, flags, info)
  end
  local target = request.target
  local destination = target.session and target.session.buf or target.source
  local filename = vim.api.nvim_buf_get_name(destination):gsub("\\", "\\\\")
  local command = tostring((target.row or 0) + 1)
  local anchor = target.session and target.row ~= nil and target.url:match "#(.*)$"
  if anchor then
    -- Binding can reflow a cached render. Native tag commands resolve the
    -- current anchor after entry, including cached :tfirst/:trewind matches.
    -- Keep the native tag-field marker |;" out of quoted anchor keys.
    local key = vim.fn.string(vim.uri_decode(anchor)):gsub('"', "' . nr2char(34) . '")
    command = "call cursor(get(b:md_render_anchors," .. key .. ",0)+1,1)|"
  end
  return {
    {
      name = target.url,
      filename = filename,
      cmd = command,
      user_data = link_tag_prefix .. vim.json.encode(target.url),
    },
  }
end

local function file_line_number()
  local line, col = vim.api.nvim_get_current_line(), vim.api.nvim_win_get_cursor(0)[2]
  local start = 0
  while true do
    local token = vim.fn.matchstrpos(line, [[\f\+]], start)
    if token[2] < 0 then return nil end
    if token[3] > col then
      local tail = line:sub(token[3] + 1)
      local match = vim.fn.matchlist(tail, [[^\s*\%(line\s\+\|\%(\f\|\d\)\@!.\s*\)\?\(\d\+\)]])
      return tonumber(match[2])
    end
    start = token[3]
  end
end

local function native_link_key(key, count)
  vim.api.nvim_feedkeys((count > 0 and tostring(count) or "") .. vim.keycode(key), "in", false)
end

local link_tag_commands = {
  ["<C-]>"] = "tag",
  ["g]"] = "tselect",
  ["g<C-]>"] = "tjump",
  ["<C-w>]"] = "stag",
  ["<C-w><C-]>"] = "stag",
  ["<C-w>g]"] = "stselect",
  ["<C-w>g<C-]>"] = "stjump",
  ["<C-LeftMouse>"] = "tag",
  ["g<LeftMouse>"] = "tag",
}

function Session:install_navigation(source_win, close_handle, source_wo)
  local win = self.win
  self.views = self.views or {}
  vim.bo[self.buf].bufhidden = "hide"
  navigation_windows[win] = {
    source_win = source_win,
    close_handle = close_handle,
    source_wo = source_wo or save_render_win_opts(source_win),
    render_wo = save_render_win_opts(win),
    layout = { max_width = self._explicit_max_width and self.opts.max_width or nil, indent = self.opts.indent },
    session = self,
  }
  -- The callback follows the current window; rebinding must preserve user maps.
  if self._navigation_installed then return end
  enable_render_tags(self)
  self._navigation_tagfunc = vim.bo[self.buf].tagfunc
  if self._navigation_tagfunc == "" then self._navigation_tagfunc = vim.bo[self.source_bufnr].tagfunc end
  vim.bo[self.buf].tagfunc = "v:lua.require'md-render.preview'._link_tagfunc"
  local function follow_link(key, tag, split, tab, line_number, mouse)
    local count = vim.v.count
    local reader = self
    if mouse then
      local pos = display_utils.getmousepos()
      if pos.winid == 0 or pos.line == 0 or pos.column == 0 then
        native_link_key(key, count)
        return
      end
      vim.api.nvim_set_current_win(pos.winid)
      vim.api.nvim_win_set_cursor(0, { pos.line, pos.column - 1 })
      reader = MdPreview._sessions[vim.api.nvim_get_current_buf()]
      if not reader then
        native_link_key(key, count)
        return
      end
    end
    local cursor = vim.api.nvim_win_get_cursor(0)
    local links = require "md-render.links"
    local url = links.at(reader.buf, reader.ns, cursor[1] - 1, cursor[2])
    if not url then
      native_link_key(key, count)
      return
    end
    if key == "g<LeftMouse>" then vim.w.md_render_tag_mouse_release = true end
    local ok, err = pcall(function()
      local target = reader:link_target(url)
      if not target then
        if tag then
          vim.ui.open(url)
        else
          vim.notify("md-render: not a local file link: " .. url, vim.log.levels.WARN)
        end
        return
      end
      local origin_win = vim.api.nvim_get_current_win()
      if tag then
        local stack = vim.fn.gettagstack(origin_win)
        local tagfunc = vim.bo[reader.buf].tagfunc
        vim.bo[reader.buf].tagfunc = "v:lua.require'md-render.preview'._link_tagfunc"
        local request = { target = target }
        local previous_active = active_link_tag
        active_link_tag = request
        local success, message = pcall(function()
          -- Labels can have no keyword at all. Ex commands also retain queued
          -- input for g]'s selector, which nested :normal would discard.
          local command = {
            cmd = link_tag_commands[key],
            args = { link_tag_prefix .. vim.uri_encode(url, "rfc3986") },
          }
          if command.cmd == "tag" and count > 0 then command.range = { count } end
          vim.cmd(command)
          if split and count > 0 and vim.api.nvim_get_current_win() ~= origin_win then
            vim.api.nvim_win_set_height(0, count)
          end
        end)
        local destination = target.session and target.session.buf or target.source
        local selector = key == "g]" or key == "<C-w>g]"
        local current_stack = vim.fn.gettagstack(origin_win)
        -- tselect writes at the old index before prompting. Only a completed
        -- selection adds user_data there; cancellation can stay in this buffer.
        local current_tag = current_stack.items[math.min(stack.curidx, current_stack.length)]
        local completed = request.completed
          or (
            vim.api.nvim_get_current_buf() == destination
            and (
              not selector
              or not vim.o.tagstack
              or current_tag and current_tag.user_data == link_tag_prefix .. vim.json.encode(target.url)
            )
          )
        active_link_tag = previous_active
        if vim.api.nvim_buf_is_valid(reader.buf) then vim.bo[reader.buf].tagfunc = tagfunc end
        if not success or not completed then
          vim.fn.settagstack(origin_win, { items = stack.items }, "r")
          vim.fn.settagstack(origin_win, { curidx = stack.curidx })
        end
        if not success then error(message) end
        return
      end
      local row = target.row
      local source_line
      if line_number and row == nil then source_line = file_line_number() end
      if split then
        vim.cmd.split()
      elseif tab then
        vim.cmd "tab split"
      end
      if url:match "^#" then
        links.follow_anchor(url, reader.content)
      else
        reader:follow_file(
          target.path,
          { target = target, row = row, source_line = source_line, same_window = split or tab }
        )
      end
    end)
    if not ok then vim.notify("md-render: cannot follow " .. url .. ": " .. tostring(err), vim.log.levels.WARN) end
  end
  for _, entry in ipairs {
    { "gf" },
    { "gF", false, false, false, true },
    { "<C-w>f", false, true },
    { "<C-w><C-f>", false, true },
    { "<C-w>F", false, true, false, true },
    { "<C-w>gf", false, false, true },
    { "<C-w>gF", false, false, true, true },
    { "<C-]>", true },
    { "g]", true },
    { "g<C-]>", true },
    { "<C-w>]", true, true },
    { "<C-w><C-]>", true, true },
    { "<C-w>g]", true, true },
    { "<C-w>g<C-]>", true, true },
    { "<C-LeftMouse>", true, false, false, false, true },
    { "g<LeftMouse>", true, false, false, false, true },
  } do
    local key = entry[1]
    vim.keymap.set("n", key, function()
      follow_link(unpack(entry))
    end, { buffer = self.buf, desc = "Follow rendered link" })
  end
  local original_gx = vim.api.nvim_buf_call(self.buf, function()
    return vim.fn.maparg("gx", "n", false, true)
  end)
  vim.keymap.set("n", "gx", function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local links = require "md-render.links"
    local url = links.at(self.buf, self.ns, cursor[1] - 1, cursor[2])
    if not url then
      local rhs
      if original_gx.callback then
        local result = original_gx.callback()
        if original_gx.expr == 1 then rhs = result end
      elseif original_gx.rhs and original_gx.rhs ~= "" then
        rhs = original_gx.expr == 1 and vim.api.nvim_eval(original_gx.rhs) or original_gx.rhs
      else
        native_link_key("gx", vim.v.count)
      end
      if type(rhs) == "string" and rhs ~= "" then
        local count = vim.v.count > 0 and tostring(vim.v.count) or ""
        vim.api.nvim_feedkeys(count .. vim.keycode(rhs), original_gx.noremap == 1 and "n" or "m", false)
      end
      return
    end
    if links.follow_anchor(url, self.content) then return end
    vim.ui.open(links.file_path(url, self:source_directory()) or url)
  end, { buffer = self.buf, desc = "Open rendered link with system handler" })
  self._navigation_installed = true
end

function Session:follow_file(path, opts)
  opts = opts or {}
  local win = vim.api.nvim_get_current_win()
  -- Adopt render windows exposed without the usual enter events.
  if not navigation_windows[win] then enter_navigation() end
  local context = navigation_windows[win]
  local view = vim.fn.winsaveview()
  local destination = opts.target or self:file_target(path)
  local target = destination.source
  -- Enter directories only in the destination window, where the user's
  -- directory browser can handle BufEnter/BufReadCmd normally.
  if destination.session then
    vim.cmd.buffer(destination.session.buf)
    local row = opts.row
    if destination.anchor then
      row = require("md-render.links").anchor_row(destination.anchor, destination.session.content)
    end
    if row == nil and opts.source_line then row = destination.session:source_to_rendered(opts.source_line) - 1 end
    if row then vim.api.nvim_win_set_cursor(0, { math.min(row + 1, vim.api.nvim_buf_line_count(0)), 0 }) end
    return
  end

  local source_win = (opts.same_window or self.pager) and win or context.source_win
  if not vim.api.nvim_win_is_valid(source_win) then error "source editing window was closed" end
  if source_win ~= win then
    -- A jumplist belongs to a window. Seed the source window with the current
    -- render before opening the editor, without attaching preview resources.
    -- :buffer (without !) preserves Neovim's modified-buffer protection.
    local previous = navigation_windows[source_win]
    local previous_session = previous and previous.session
    local source_wo = previous_session and previous.source_wo or save_render_win_opts(source_win)
    local previous_view
    vim.api.nvim_win_call(source_win, function()
      if previous_session then restore_view(previous_session, source_win) end
      previous_view = vim.fn.winsaveview()
      vim.cmd { cmd = "buffer", args = { tostring(self.buf) }, mods = { noautocmd = true } }
      vim.fn.winrestview(view)
    end)
    -- Only detach after :buffer succeeds, so E37 leaves the old view intact.
    if previous then
      if previous_session then remember_view(previous_session, source_win, previous_view) end
      leave_navigation(source_win, previous)
    end
    remember_view(self, source_win, view)
    navigation_windows[source_win] = {
      source_win = source_win,
      source_wo = source_wo,
      layout = context.layout,
      session = self,
    }
    if context.close_handle then context.close_handle:close_if_valid() end
    vim.api.nvim_set_current_win(source_win)
  end
  vim.cmd.buffer(target)
  local row = opts.row or (opts.source_line and opts.source_line - 1)
  if row then vim.api.nvim_win_set_cursor(0, { math.min(row + 1, vim.api.nvim_buf_line_count(0)), 0 }) end
end

local navigation_group = vim.api.nvim_create_augroup("md_render_navigation", { clear = true })
vim.api.nvim_create_autocmd("BufEnter", {
  group = navigation_group,
  callback = function(ev)
    local request = active_link_tag
    if request and ev.buf == (request.target.session and request.target.session.buf or request.target.source) then
      request.completed = true
    end
  end,
})
vim.api.nvim_create_autocmd("TabLeave", {
  group = navigation_group,
  callback = function()
    -- cmdheight is tab-local: restore the departing tab before switching,
    -- without writing its value into the next tab's editor.
    if saved_pager_options and saved_pager_options.cmdheight ~= nil then
      vim.o.cmdheight = saved_pager_options.cmdheight
      saved_pager_options.cmdheight = nil
    end
  end,
})
vim.on_key(function(key, typed)
  local event = typed ~= "" and typed or key
  if event == vim.keycode "<LeftRelease>" or event == vim.keycode "<C-LeftRelease>" then
    local mouse = vim.fn.getmousepos()
    if
      mouse.winid > 0
      and vim.api.nvim_win_is_valid(mouse.winid)
      and vim.w[mouse.winid].md_render_tag_mouse_release
    then
      vim.w[mouse.winid].md_render_tag_mouse_release = nil
      display_utils.getmousepos(true)
      return ""
    end
  end
  -- Finish a native return before the next key, including scroll commands in
  -- a macro. Scheduling alone would restore over that subsequent command.
  local win = vim.api.nvim_get_current_win()
  local session = pending_views[win]
  if session then restore_view(session, win) end
end, vim.api.nvim_create_namespace "md_render_navigation")
vim.api.nvim_create_autocmd("BufLeave", {
  group = navigation_group,
  callback = function()
    local win = vim.api.nvim_get_current_win()
    local context = navigation_windows[win]
    if context and not context.session then context.source_wo = save_render_win_opts(win) end
    local session = MdPreview._sessions[vim.api.nvim_get_current_buf()]
    if session and session.views then
      -- A macro can leave again before the scheduled return-view restoration.
      restore_view(session, win)
      remember_view(session, win, vim.fn.winsaveview())
    end
  end,
})

enter_navigation = function()
  local win = vim.api.nvim_get_current_win()
  -- bufload()/buf_call() can enter a temporary autocmd window. It does not
  -- change the reader's focus and must not resize the real pager's chrome.
  if vim.fn.win_gettype(win) == "autocmd" then return end
  local buf = vim.api.nvim_get_current_buf()
  local context = navigation_windows[win]
  local session = MdPreview._sessions[buf]
  if session and not session.views then session = nil end
  update_pager_ui(session)
  if session and context and context.session == session and session.win == win then
    if context.close_handle and context.close_handle.win ~= win then
      context.close_handle:setup(win, { auto_close = false })
    end
    session:install_float_keymaps(context.close_handle, not context.close_handle and { close_keys = {} } or nil)
    return
  end
  if context and context.session ~= session then leave_navigation(win, context) end
  if not session then return end
  context = context or navigation_context(win, session)
  restore_render_win_opts(win, context.render_wo)
  apply_render_win_opts(win)
  if session.win ~= win or not session.image_state then session:bind_window(win, context.layout) end
  if context.close_handle then context.close_handle:setup(win, { auto_close = false }) end
  session:install_float_keymaps(context.close_handle, not context.close_handle and { close_keys = {} } or nil)
  session:install_navigation(context.source_win, context.close_handle, context.source_wo)
  if context.close_handle == float_win then session:install_footer() end
  set_win_state(win, {
    source_buf = session.source_bufnr,
    render_buf = session.buf,
    mode = "render",
    source_wo = context.source_wo,
  })
  if session.jump_views and session.jump_views[win] then
    -- Ctrl-O places the cursor after BufEnter. Restore only the viewport
    -- belonging to that native position, including earlier visits here.
    pending_views[win] = session
    vim.schedule(function()
      restore_view(session, win)
    end)
  end
end

vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
  group = navigation_group,
  callback = function(ev)
    local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
    if ev.event == "WinEnter" and not navigation_windows[win] then
      -- :tabnew/:new briefly inherit the old buffer; a native :split keeps it.
      local session = MdPreview._sessions[buf]
      if not (session and session.views) then return end
      -- Register editor options before a following :edit or native gf can
      -- leave the inherited render. Only resource binding must be deferred.
      navigation_context(win, session)
      vim.schedule(function()
        if vim.api.nvim_get_current_win() == win and vim.api.nvim_win_get_buf(win) == buf then enter_navigation() end
      end)
    else
      enter_navigation()
    end
  end,
})

vim.api.nvim_create_autocmd("BufWipeout", {
  group = navigation_group,
  callback = function()
    -- Source disposal can replace the focused render from an autocmd window,
    -- without a real BufEnter. Recheck focus after the deletion finishes.
    if saved_pager_options then vim.schedule(enter_navigation) end
  end,
})

vim.api.nvim_create_autocmd("WinClosed", {
  group = navigation_group,
  callback = function(ev)
    local win = tonumber(ev.match)
    local context = navigation_windows[win]
    if context and context.session then
      if context.close_handle then context.session:sync_source_cursor(win) end
      detach_session(context.session, win)
    end
    navigation_windows[win] = nil
    pending_views[win] = nil
    for _, session in pairs(MdPreview._sessions) do
      if session.views then session.views[win] = nil end
      if session.jump_views then session.jump_views[win] = nil end
    end
    -- Wait until the close and any gf handoff have finished recording native jumps.
    vim.schedule(function()
      local referenced = {}
      for _, remaining in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(remaining)
        referenced[buf] = true
        local state = get_win_state(remaining)
        if state and state.mode == "source" and state.source_buf == buf then referenced[state.render_buf] = true end
        local tab = vim.fn.win_id2tabwin(remaining)[1]
        for _, jump in ipairs(vim.fn.getjumplist(remaining, tab)[1]) do
          referenced[jump.bufnr] = true
        end
        for _, tag in ipairs(vim.fn.gettagstack(remaining).items) do
          referenced[tag.bufnr] = true
          referenced[tag.from[1]] = true
        end
      end
      local caches = {}
      for buf, session in pairs(MdPreview._sessions) do
        local cache = session.cache
        if cache and cache ~= _toggle_sessions then caches[cache] = caches[cache] or referenced[buf] or false end
      end
      for cache, retained in pairs(caches) do
        if not retained then
          for _, session in pairs(cache) do
            session:dispose()
          end
        end
      end
    end)
  end,
})

--- Show Markdown in a full-screen pager, retaining native navigation history.
---@param opts? { max_width?: integer, buf_dir?: string }
MdPreview.show_pager = function(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  local ok, warn = check_markdown_buffer(bufnr)
  if not ok then
    vim.notify(warn, vim.log.levels.WARN)
    return
  end

  opts = vim.tbl_extend("force", {}, opts or {})
  if opts.buf_dir then opts.buf_dir = vim.fn.fnamemodify(opts.buf_dir, ":p") end
  local win = vim.api.nvim_get_current_win()
  local source_wo = save_render_win_opts(win)
  local session = get_or_create_session(bufnr, opts, {})
  session.pager = true
  -- Respect normal modified-buffer protections, including on initial entry.
  local switched, err = pcall(vim.cmd.buffer, session.buf)
  if not switched then
    session:dispose()
    error(err)
  end
  update_pager_ui(session)
  apply_render_win_opts(win)
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = true
  vim.wo[win].spell = false
  vim.wo[win].winbar = ""
  session:bind_window(win)
  session:install_navigation(win, nil, source_wo)
  set_win_state(win, { source_buf = bufnr, render_buf = session.buf, mode = "render", source_wo = source_wo })
  enter_navigation()
end

--- Toggle between source and render mode in the current window.
---@param opts? { max_width?: integer }
MdPreview.toggle = function(opts)
  local win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_win_get_buf(win)
  local state = get_win_state(win)

  -- ---- render → source ----
  if state and state.mode == "render" and cur_buf == state.render_buf then
    local session = MdPreview._sessions[state.render_buf]
    local rendered_line = vim.api.nvim_win_get_cursor(win)[1]
    local source_line = session and session:rendered_to_source(rendered_line) or nil

    if not vim.api.nvim_buf_is_valid(state.source_buf) then
      vim.notify("md-render: source buffer is no longer valid", vim.log.levels.WARN)
      return
    end

    vim.api.nvim_win_set_buf(win, state.source_buf)
    restore_render_win_opts(win, state.source_wo)

    if state.source_view then
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(state.source_view)
      end)
    end
    if source_line and source_line > 0 then
      local total = vim.api.nvim_buf_line_count(state.source_buf)
      source_line = math.min(source_line, total)
      vim.api.nvim_win_set_cursor(win, { source_line, 0 })
    end

    set_win_state(win, vim.tbl_extend("force", state, { mode = "source" }))
    return
  end

  -- ---- source → render ----
  local source_bufnr = cur_buf
  local ok, warn = check_markdown_buffer(source_bufnr)
  if not ok then
    vim.notify(warn, vim.log.levels.WARN)
    return
  end

  local source_cursor_line = vim.api.nvim_win_get_cursor(win)[1]
  local source_view = vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview()
  end)
  local source_wo = save_render_win_opts(win)

  local previous = state and state.source_buf == source_bufnr and MdPreview._sessions[state.render_buf]
  local session = get_or_create_session(source_bufnr, opts, previous and previous.cache)

  -- Restore content indent when toggling into a full-width window (may have
  -- been cleared by a prior MdRenderSplit).
  local default_indent = "  "
  if (session.opts.indent or default_indent) ~= default_indent then
    session.opts.indent = default_indent
    session:rebuild()
  end

  vim.api.nvim_win_set_buf(win, session.buf)
  if session.win ~= win then session:bind_window(win) end
  session:scroll_to_source_line(source_cursor_line)

  -- Click handlers on the render buf — no close keys (toggle owns lifecycle).
  session:install_float_keymaps(nil, { close_keys = {} })

  set_win_state(win, {
    source_buf = source_bufnr,
    render_buf = session.buf,
    mode = "render",
    source_view = source_view,
    source_wo = source_wo,
  })
  session:install_navigation(win, nil, source_wo)
end

-- =====================================================================
-- split: open a side-by-side split with source on one side, render on
-- the other. From source -> new split shows render. From a render
-- window (created by toggle) -> new split shows source. Direction is
-- driven by the user's command modifiers (:vert, :topleft, :tab, ...).
-- =====================================================================

--- Open a split showing the counterpart of the current window's mode.
---@param opts? { mods?: table, max_width?: integer }
MdPreview.split = function(opts)
  opts = opts or {}
  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_win_get_buf(cur_win)
  local state = get_win_state(cur_win)

  -- ---- render-mode window -> split shows the SOURCE ----
  if state and state.mode == "render" and cur_buf == state.render_buf then
    if not vim.api.nvim_buf_is_valid(state.source_buf) then
      vim.notify("md-render: source buffer is no longer valid", vim.log.levels.WARN)
      return
    end
    vim.cmd { cmd = "split", mods = opts.mods or {} }
    local new_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(new_win, state.source_buf)
    -- This window shows the source, so discard its inherited preview state.
    pcall(vim.api.nvim_win_del_var, new_win, "md_render_state")
    -- The new split inherited render-mode window options from cur_win;
    -- restore the source view's options from the originals stashed on
    -- cur_win when it first went source -> render.
    restore_render_win_opts(new_win, state.source_wo)
    local context = navigation_windows[cur_win]
    if context then context.source_win = new_win end
    -- New split now shows the source while cur_win still shows render;
    -- both sides are visible, so paint the shadow immediately.
    local session = MdPreview._sessions[state.render_buf]
    if session and session._shadow_recompute then session._shadow_recompute() end
    return
  end

  -- ---- source-mode window -> split shows the RENDER ----
  local source_bufnr = cur_buf
  local ok, warn = check_markdown_buffer(source_bufnr)
  if not ok then
    vim.notify(warn, vim.log.levels.WARN)
    return
  end

  local source_cursor_line = vim.api.nvim_win_get_cursor(cur_win)[1]
  -- Snapshot source-window options BEFORE :split, since the new split
  -- inherits them. Stashed on the new split's md_render_state so a later
  -- :MdRenderToggle on the split restores them on the render -> source
  -- transition.
  local source_wo = save_render_win_opts(cur_win)
  local session = get_or_create_session(source_bufnr, opts)

  -- Split windows have no border — remove content indent for space efficiency.
  if (session.opts.indent or "  ") ~= "" then
    session.opts.indent = ""
    session:rebuild()
  end

  vim.cmd { cmd = "split", mods = opts.mods or {} }
  local new_win = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(new_win, session.buf)
  if session.win ~= new_win then session:bind_window(new_win) end
  session:scroll_to_source_line(source_cursor_line)
  session:install_float_keymaps(nil, { close_keys = {} })
  vim.wo[new_win].winbar = " Markdown Preview"

  set_win_state(new_win, {
    source_buf = source_bufnr,
    render_buf = session.buf,
    mode = "render",
    source_wo = source_wo,
  })
  session:install_navigation(cur_win, nil, source_wo)

  -- Return focus to the source window — the render split is a preview,
  -- not an editing target.
  vim.cmd.wincmd "p"

  -- Line the render up with where the cursor sits in the source window.
  if session._sync_from_source then session._sync_from_source(vim.api.nvim_get_current_win()) end

  -- Initial shadow paint. Neither WinEnter nor CursorMoved fires
  -- reliably from the :split + wincmd p sequence, so call directly.
  if session._shadow_recompute then session._shadow_recompute() end
end

-- =====================================================================
-- Auto-toggle: render outside Insert mode, source while editing.
-- (`_auto_state` and `auto_augroup` are declared earlier so install_source_watcher
--  can reference them in its BufWipeout cleanup.)
-- =====================================================================

-- Insert-entry keys that, when pressed on a render buffer in auto mode,
-- toggle to source and then re-fire so the user lands in Insert mode at
-- the corresponding spot. (Visual-mode and operator-pending keys are
-- intentionally left alone.)
local AUTO_INSERT_KEYS = { "i", "I", "a", "A", "o", "O" }

local function install_auto_insert_keymaps(render_buf)
  for _, key in ipairs(AUTO_INSERT_KEYS) do
    vim.keymap.set("n", key, function()
      MdPreview.toggle()
      vim.schedule(function()
        vim.api.nvim_feedkeys(key, "n", false)
      end)
    end, {
      buffer = render_buf,
      noremap = true,
      silent = true,
      desc = "md-render auto: switch to source then " .. key,
    })
  end
end

local function uninstall_auto_insert_keymaps(render_buf)
  if not vim.api.nvim_buf_is_valid(render_buf) then return end
  for _, key in ipairs(AUTO_INSERT_KEYS) do
    pcall(vim.keymap.del, "n", key, { buffer = render_buf })
  end
end

--- Resolve the source buffer that auto_on/off/toggle should act on.
--- When the current window is showing a render buffer, follow back to its
--- source so the user can call auto_off / auto_toggle without first
--- swapping back to source mode.
---@return integer
local function get_auto_target_buf()
  local win = vim.api.nvim_get_current_win()
  local win_state = get_win_state(win)
  if win_state and win_state.mode == "render" and vim.api.nvim_buf_is_valid(win_state.source_buf) then
    return win_state.source_buf
  end
  return vim.api.nvim_get_current_buf()
end

--- Schedule a debounced auto-transition for `bufnr` toward `target_mode`.
--- 50ms debounce coalesces rapid Insert-mode boundary events
--- (e.g. `i<Esc>i<Esc>` or `<C-o>` round-trips).
---@param bufnr integer
---@param target_mode "source"|"render"
local function schedule_auto_transition(bufnr, target_mode)
  local state = _auto_state[bufnr]
  if not state then return end
  local win, tab = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
  local owner_buf = vim.api.nvim_win_get_buf(win)
  local key = (target_mode == "source") and "in_timer" or "leave_timer"
  close_timer(state[key])
  local timer
  timer = vim.defer_fn(function()
    if _auto_state[bufnr] ~= state or state[key] ~= timer then return end
    state[key] = nil
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not vim.b[bufnr].md_render_auto then return end
    if
      not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_get_current_win() ~= win
      or vim.api.nvim_get_current_tabpage() ~= tab
      or vim.api.nvim_win_get_buf(win) ~= owner_buf
    then
      return
    end

    local cur_buf = vim.api.nvim_win_get_buf(win)
    local win_state = get_win_state(win)

    if target_mode == "source" then
      if win_state and win_state.mode == "render" and win_state.source_buf == bufnr then MdPreview.toggle() end
    else -- "render"
      if vim.api.nvim_get_mode().mode == "n" and cur_buf == bufnr and (not win_state or win_state.mode ~= "render") then
        MdPreview.toggle()
      end
    end
  end, 50)
  state[key] = timer
end

--- Enable auto-toggle for the current buffer and immediately swap to render.
---@param opts? { max_width?: integer }
function MdPreview.auto_on(opts)
  local bufnr = get_auto_target_buf()
  local ok, warn = check_markdown_buffer(bufnr)
  if not ok then
    vim.notify(warn, vim.log.levels.WARN)
    return
  end
  if vim.b[bufnr].md_render_auto then return end

  vim.b[bufnr].md_render_auto = true
  _auto_state[bufnr] = { in_timer = nil, leave_timer = nil }

  -- Only InsertLeave is needed: the InsertEnter side is driven by buffer-local
  -- keymaps on the render buffer (see install_auto_insert_keymaps), since the
  -- render buffer is nomodifiable and would never fire InsertEnter on its own.
  local augroup = vim.api.nvim_create_augroup(auto_augroup(bufnr), { clear = true })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = augroup,
    buffer = bufnr,
    callback = function()
      schedule_auto_transition(bufnr, "render")
    end,
  })

  local win = vim.api.nvim_get_current_win()
  local win_state = get_win_state(win)
  if not win_state or win_state.mode ~= "render" then MdPreview.toggle(opts) end

  -- Install Insert-entry keymaps on the render buffer (now created by toggle).
  local session = MdPreview._sessions[vim.api.nvim_get_current_buf()]
  if session then install_auto_insert_keymaps(session.buf) end
end

--- Disable auto-toggle for the current buffer and, if the current window is
--- showing this buffer's render view, swap back to source so a single
--- `auto_off` (or a second `auto_toggle`) returns to the pre-`auto_on` state.
function MdPreview.auto_off()
  local bufnr = get_auto_target_buf()
  if not vim.b[bufnr].md_render_auto then return end

  vim.b[bufnr].md_render_auto = nil
  local state = _auto_state[bufnr]
  if state then
    close_timer(state.in_timer)
    close_timer(state.leave_timer)
    _auto_state[bufnr] = nil
  end
  pcall(vim.api.nvim_del_augroup_by_name, auto_augroup(bufnr))

  for _, session in pairs(MdPreview._sessions) do
    if session.source_bufnr == bufnr then uninstall_auto_insert_keymaps(session.buf) end
  end

  local win = vim.api.nvim_get_current_win()
  local win_state = get_win_state(win)
  if win_state and win_state.mode == "render" and win_state.source_buf == bufnr then MdPreview.toggle() end
end

--- Flip auto-toggle state for the current buffer.
---@param opts? { max_width?: integer }
function MdPreview.auto_toggle(opts)
  local bufnr = get_auto_target_buf()
  if vim.b[bufnr].md_render_auto then
    MdPreview.auto_off()
  else
    MdPreview.auto_on(opts)
  end
end

-- Expose for tests
MdPreview._toggle_sessions = _toggle_sessions
MdPreview._schedule_live_rebuild = schedule_live_rebuild
MdPreview._live_update_augroup = live_update_augroup
MdPreview._auto_state = _auto_state
MdPreview._auto_augroup = auto_augroup
MdPreview._schedule_auto_transition = schedule_auto_transition

-- =====================================================================
-- show_demo: demo floating window (existing behavior)
-- =====================================================================

--- Show a demo floating window with all supported Markdown notations
MdPreview.show_demo = function()
  -- Resolve plugin root for demo image paths
  local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")
  local demo_img_dir = plugin_root .. "/assets/demo"

  local demo_lines = vim.split(
    table.concat({
      "## Markdown Rendering Features",
      "",
      "**Bold**, ~~strikethrough~~, `inline code`, and [links](https://neovim.io) — all rendered inline. Bare URLs like https://neovim.io stay clickable. Long ones like https://github.com/neovim/neovim/blob/master/src/nvim/api/buffer.c#L123-L456 are truncated. Obsidian ==highlight== and `%%comments%%` also work.",
      "",
      -- All six levels in one place, so the ladder can be compared at a
      -- glance. Nothing else in the demo goes past `###`, which left `#`,
      -- `####`, `#####` and `######` — four of the six sizes — never drawn.
      "### Heading Levels",
      "",
      "Compare all six heading levels with body text between them. Use :MdRender textsize to switch the display mode.",
      "",
      -- Body text under every one of them, not just the headings back to back:
      -- what the extra row costs, and how a heading sits against the text it
      -- introduces, is only visible with something underneath it.
      "# Level 1",
      "",
      "A paragraph follows each heading, so the spacing between the two is visible.",
      "",
      "## Level 2",
      "",
      "This section groups related topics under the document title.",
      "",
      "### Level 3",
      "",
      "This subsection introduces one topic within the section above.",
      "",
      "#### Level 4",
      "",
      "Use this level to organize details within that topic.",
      "",
      "##### Level 5",
      "",
      "More specific instructions belong under their parent heading.",
      "",
      "###### Level 6",
      "",
      "A final detail completes this example of the six heading levels.",
      "",
      "### Line Breaks",
      "",
      -- The two trailing spaces below are the hard line break marker itself.
      -- Do not trim them.
      "A line ending in two spaces is a hard line break, so this line  ",
      "and this one stay apart.",
      "",
      "Without the two spaces the lines are soft-wrapped, so this line",
      "joins the previous one into a single paragraph.",
      "",
      "> The same goes inside a blockquote: this line and",
      "> the next one are one paragraph.",
      "",
      "### Code & Tables",
      "",
      "```lua",
      'local function greet(name) return "Hello, " .. name end',
      "-- This line is intentionally long to demonstrate that code lines exceeding the max width are truncated with an ellipsis indicator",
      "```",
      "",
      "| Feature | Description | Syntax |",
      "|---------|-------------|--------|",
      "| **Bold** / ~~strike~~ | Inline formatting is rendered inside table cells | `**text**` / `~~text~~` |",
      "| Wrapping | Long cells wrap to the available column width | Headers and image captions also wrap |",
      "",
      "### Lists",
      "",
      "- First item",
      "- Second item with **bold** and `code`",
      "  - Nested item",
      "  - Another nested",
      "    - Deeply nested",
      "      - Back to level 0 style",
      "- Back to top level",
      "",
      "1. Ordered first",
      "2. Ordered second",
      "  1. Nested ordered",
      "  2. Nested second",
      "3. Back to top",
      "",
      "- [ ] Unchecked task",
      "- [x] Completed task",
      "- [-] In-progress task",
      "",
      "- An item whose text is split across source lines,",
      "  indented to line up with the item, is one paragraph.",
      "- An item can hold a code block of its own:",
      "",
      "  ```lua",
      '  vim.keymap.set("n", "<Leader>md", "<Cmd>MdRender<CR>")',
      "  ```",
      "",
      "- …or a blockquote, indented to the item's content:",
      "",
      "  > [!TIP] Callouts work here too",
      "  > Anything indented to the item's content column is part of it.",
      "",
      "### Callouts & Folds",
      "",
      "> [!NOTE]",
      "> Standard callout. Five types: `NOTE`, `TIP`, `IMPORTANT`, `WARNING`, `CAUTION`.",
      "",
      "> [!TIP]- Foldable (collapsed)",
      "> Hidden until you click the header. Supports **multiple lines**.",
      "> Click the fold indicator to toggle.",
      "",
      "> [!WARNING]+ Foldable (expanded)",
      "> Visible by default, click to collapse.",
      "> ```lua",
      "> local msg = 'Code blocks inside callouts get treesitter highlighting!'",
      "> ```",
      "",
      "> [!custom] Custom types work too",
      "> Any `[!type]` is rendered as a callout.",
      "> - Lists inside callouts",
      "> - Also get bullet symbols",
      ">   - Including nested ones",
      "> 1. Ordered lists too",
      "> 2. Work just fine",
      "",
      "### Expandable Content",
      "",
      "```bash",
      "# This line is intentionally very long to demonstrate the expandable code block feature — click the underlined … to see the full content and scroll horizontally",
      "echo 'Click the … on truncated lines to expand, click again to collapse'",
      "```",
      "",
      "### Collapsible Details",
      "",
      "<details>",
      "<summary>Click to expand this section</summary>",
      "",
      "This content is hidden by default. It supports **bold**, `code`, and [links](https://neovim.io).",
      "",
      "</details>",
      "",
      "<details open>",
      "<summary>Open by default</summary>",
      "",
      "The `open` attribute makes it expanded initially. Click to collapse.",
      "",
      "</details>",
      "",
      "### 日本語テキストの折り返し",
      "",
      "budoux.luaがインストールされていれば、BudouXによる自然な分節処理で日本語テキストを文節の区切りで改行します。未インストールの場合は1文字ずつ分割して折り返します。",
      "",
      "句読点「、」や閉じ括弧「)」が行頭に来ないよう禁則処理(JIS X 4051)を適用。開き括弧「(」は行末に残さず次の行へ送ります。",
      "",
      -- The two trailing spaces below are the hard line break marker itself.
      -- Do not trim them.
      "行末に半角スペースを2つ置くと、ここで改行されます。  ",
      "スペースが無ければ次の行と連結され、和字同士の連結では",
      "余分な半角スペースを入れません。",
      "",
      "- 箇条書きの項目も、インデントを揃えて改行すれば",
      "  ひとつの段落として連結されます。",
      "",
      "> [!NOTE] 日本語コールアウト",
      "> コールアウト内でも禁則処理は有効。budoux.luaがあればBudouXの分節処理も適用され、長い文章を自然な位置で折り返します。",
      "",
      "### Qiita Extensions",
      "",
      "```ruby:app/models/user.rb",
      "class User < ApplicationRecord",
      "  validates :name, presence: true",
      "end",
      "```",
      "",
      ":::note info",
      "Qiitaのノート記法(info)です。`:::note info` で始まり `:::` で閉じます。",
      ":::",
      "",
      ":::note warn",
      "警告メッセージを表示できます。",
      ":::",
      "",
      ":::note alert",
      "重要な注意事項を強調できます。",
      ":::",
      "",
      "### Images",
      "",
      "| PNG | JPEG | WebP | GIF | Animated GIF |",
      "|-----|------|------|-----|--------------|",
      "| ![PNG]("
        .. demo_img_dir
        .. "/test.png) | ![JPEG]("
        .. demo_img_dir
        .. "/test.jpg) | ![WebP]("
        .. demo_img_dir
        .. "/test.webp) | ![GIF]("
        .. demo_img_dir
        .. "/test.gif) | ![Animated GIF]("
        .. demo_img_dir
        .. "/test_animated.gif) |",
      "",
      "### Web Images",
      "",
      "| Static (http.cat) | Animated GIF (Nyan Cat) |",
      "|--------------------|-----------------------|",
      "| ![HTTP 200](https://http.cat/200.jpg) | ![Nyan Cat](https://media.giphy.com/media/sIIhZliB2McAo/giphy.gif) |",
      "",
      "### Video",
      "",
      '<video src="' .. demo_img_dir .. '/test.mp4" controls></video>',
      "",
      "### Mermaid Diagram",
      "",
      "```mermaid",
      "graph LR",
      "    A[Markdown] --> B[Parser]",
      "    B --> C[ContentBuilder]",
      "    C --> D[FloatWin]",
      "    D --> E[Display]",
      "```",
    }, "\n"),
    "\n"
  )

  if demo_float_win:close_if_valid() then return end

  local fold_state = {}
  local expand_state = {}
  local opts = { buf_dir = plugin_root }
  local image_state = nil
  local text_size = require "md-render.text_size"
  ---@type MdRender.TextSizeState|MdRender.HeadingImageState|nil
  local text_size_state = nil

  local buf = vim.api.nvim_create_buf(false, true)
  -- The demo builds its own window rather than a Session, so it has to set
  -- this itself. See |md-render-b-md-render|.
  vim.b[buf].md_render = true
  local ns = vim.api.nvim_create_namespace "md_render_demo"

  require("md-render").setup_highlights()

  local content
  local win

  opts.heading_normal = "NormalFloat"
  local function rebuild()
    if not win or not vim.api.nvim_win_is_valid(win) or vim.api.nvim_win_get_buf(win) ~= buf then return end
    if defer_rebuild(buf, rebuild, text_size_state) then return end
    local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
    opts.fold_state = fold_state
    opts.expand_state = expand_state
    opts.autolinks = {
      { key_prefix = "JIRA-", url_template = "https://jira.example.com/browse/JIRA-<num>" },
    }
    local new_content = MdPreview.build_content(demo_lines, opts)
    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    display_utils.apply_content_to_buffer(buf, ns, new_content)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
    set_preview_wrap(buf, new_content)
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview(display_utils.remap_view(view, content, new_content))
    end)
    content = new_content
    image_state = display_utils.update_images(image_state, win, content, ns, { buf = buf, on_ready = rebuild })
    text_size_state = text_size.refresh(text_size_state, win, content)
  end

  opts.autolinks = {
    { key_prefix = "JIRA-", url_template = "https://jira.example.com/browse/JIRA-<num>" },
  }
  content = MdPreview.build_content(demo_lines, opts)
  display_utils.apply_content_to_buffer(buf, ns, content)
  win = display_utils.open_float_window(buf, content, demo_float_win, {
    title = " Markdown Rendering Demo ",
    position = "center",
    enter = true,
  })
  set_preview_wrap(buf, content)

  for _, fold in ipairs(content.callout_folds) do
    fold_state[fold.source_line] = fold.collapsed
  end

  image_state = display_utils.setup_images(win, content, ns, {
    buf = buf,
    on_ready = rebuild,
  })
  text_size_state = text_size.attach(win, content)

  -- The demo is not a Session, so `rebuild_visible` cannot find it the way it
  -- finds previews. Hand it a way in, or `:MdRender textsize` would leave the
  -- demo showing rows reserved for a scale it no longer uses.
  MdPreview._demo_rebuild = function(layouts)
    local affected = not layouts
    for _, layout in ipairs(layouts or {}) do
      if content.heading_layouts and content.heading_layouts[layout.key] then affected = true end
    end
    if affected and win and vim.api.nvim_win_is_valid(win) then rebuild() end
  end

  display_utils.setup_float_keymaps(buf, ns, win, content, demo_float_win, {
    get_content = function()
      return content
    end,
    on_fold_toggle = function(source_line, collapsed)
      fold_state[source_line] = collapsed
      rebuild()
    end,
    on_expand_toggle = function(block_id, expanded)
      expand_state[block_id] = expanded
      rebuild()
    end,
  })
end

-- Expose Session for tests and toggle implementation
MdPreview._Session = Session

return MdPreview
