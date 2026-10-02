---@class MdRender.MarkdownTable.ParsedCell
---@field text string rendered text (inline markdown processed)
---@field highlights MdRender.Markdown.Highlight[] highlights from markdown.render()
---@field links MdRender.Markdown.Link[] links from markdown.render()

---@class MdRender.MarkdownTable.ParsedTable
---@field headers MdRender.MarkdownTable.ParsedCell[]
---@field alignments string[] "left"|"center"|"right" per column
---@field rows MdRender.MarkdownTable.ParsedCell[][] each row is an array of cells
---@field col_widths integer[] display width per column

local MarkdownTable = {}
local wrap_mod = require "md-render.wrap"
local fence_mod = require "md-render.fence"
local inline = require "md-render.inline"

--- Split a table row into cell strings (trim leading/trailing whitespace)
---@param line string
---@return string[]|nil cells or nil if not a valid table row
local function split_row(line)
  local inner = line:match "^%s*(.-)%s*$"
  if inner == "" then return nil end
  -- Outer pipes are optional. The scanner consumes a trailing pipe as the
  -- last cell's delimiter, while an escaped pipe remains cell content.
  if inner:sub(1, 1) == "|" then inner = inner:sub(2) end
  local cells = {}
  local pos = 1
  while pos <= #inner do
    local cell_parts = {}
    while pos <= #inner do
      local c = inner:sub(pos, pos)
      if c == "\\" and pos + 1 <= #inner and inner:sub(pos + 1, pos + 1) == "|" then
        -- Escaped pipe: keep the literal |
        table.insert(cell_parts, "|")
        pos = pos + 2
      elseif c == "|" then
        pos = pos + 1
        break
      else
        table.insert(cell_parts, c)
        pos = pos + 1
      end
    end
    local cell = table.concat(cell_parts)
    -- Trim whitespace
    cell = cell:match "^%s*(.-)%s*$"
    table.insert(cells, cell)
  end
  return cells
end

--- Check if a line is a separator row (e.g., |---|:---:|---:|)
---@param line string
---@return string[]|nil alignments array or nil if not a separator
local function parse_separator(line)
  local cells = split_row(line)
  if not cells or #cells == 0 then return nil end
  local alignments = {}
  for _, cell in ipairs(cells) do
    -- Must match pattern: optional :, one or more -, optional :
    if not cell:match "^:?%-+:?$" then return nil end
    local left = cell:sub(1, 1) == ":"
    local right = cell:sub(-1) == ":"
    if left and right then
      table.insert(alignments, "center")
    elseif right then
      table.insert(alignments, "right")
    else
      table.insert(alignments, "left")
    end
  end
  return alignments
end

--- A table ends at a blank line or another block, not an inline construct.
---@param line string
---@param in_paragraph? boolean complete type-7 HTML tags cannot interrupt an existing paragraph
---@return boolean
function MarkdownTable.is_body_row(line, in_paragraph)
  local indent, text = line:match "^([ \t]*)(.*)$"
  if fence_mod.indent_columns(indent) >= 4 or text == "" then return false end
  if text:sub(1, 1) == "|" then return true end
  if fence_mod.opening(line) then return false end
  -- Images, autolinks and inline HTML remain cell content. Complete HTML
  -- tags on their own line and block tags still end the table.
  if text:sub(1, 1) == "<" then return require("md-render.html_block").start(line, in_paragraph) == nil end
  if text:match "^!%[" or text:match "^=+%s*$" then return true end
  if text:match "^[%-%*%+]%s*$" then return false end
  local digits, tail = text:match "^(%d+)[.)](.*)$"
  if digits and (tail == "" or tail:match "^[ \t]") then return #digits > 9 end
  -- The paragraph boundary helper also recognizes Setext underlines and
  -- loose thematic-break prefixes; neither can end a table unless it is
  -- an actual thematic break or list item.
  if text:match "^[%-_*]%s*[%-_*]" then
    local compact = text:gsub("%s", "")
    if #compact >= 3 and compact == string.rep(compact:sub(1, 1), #compact) then return false end
    return not text:match "^[%-%*]%s"
  end
  return not require("md-render.markdown").is_block_start(text, false)
end

--- Validate the header and delimiter together before collecting table rows.
---@param header string
---@param separator? string
---@return string[]? cells
---@return string[]? alignments
function MarkdownTable.parse_header(header, separator)
  -- Plain dashes retain Setext-heading precedence, even after a piped header.
  if not separator or separator:match "^%s*%-+%s*$" then return nil end
  if not MarkdownTable.is_body_row(separator) then return nil end
  local alignments = parse_separator(separator)
  if not alignments or not MarkdownTable.is_body_row(header) then return nil end
  local cells = split_row(header)
  if not cells or #cells ~= #alignments then return nil end
  return cells, alignments
end

--- Process a cell's text through markdown.render() for inline formatting
---@param text string
---@param repo_base_url? string
---@param autolinks? MdRender.Autolink[]
---@param ref_links? table<string, string> normalized document labels to URLs
---@return MdRender.MarkdownTable.ParsedCell
local function process_cell(text, repo_base_url, autolinks, ref_links, raw_html)
  local markdown = require "md-render.markdown"
  local rendered, highlights, links =
    markdown.render(text, repo_base_url, autolinks, ref_links, nil, true, { raw_html = raw_html })
  return {
    text = rendered,
    highlights = highlights,
    links = links,
  }
end

--- Wrap at ordinary word boundaries, then at complete glyphs for long tokens.
--- Kinsoku groups may exceed the target width; layout reserves space for them.
---@param text string
---@param max_display_width integer
---@return {text: string, byte_start: integer}[]
local function wrap_cell_text(text, max_display_width)
  if vim.api.nvim_strwidth(text) <= max_display_width then return { { text = text, byte_start = 0 } } end
  local lines, starts = wrap_mod.wrap_words(text, max_display_width)
  local result = {}
  for i, line in ipairs(lines) do
    if vim.api.nvim_strwidth(line) <= max_display_width then
      table.insert(result, { text = line, byte_start = starts[i] })
    else
      local groups, pending_open = {}, ""
      -- Neovim groups combining marks, emoji modifiers and ZWJ sequences.
      for _, char in ipairs(vim.fn.split(line, "\\zs")) do
        if wrap_mod.NO_BREAK_END[char] then
          pending_open = pending_open .. char
        elseif wrap_mod.NO_BREAK_START[char] and #groups > 0 and pending_open == "" then
          groups[#groups] = groups[#groups] .. char
        else
          groups[#groups + 1] = pending_open .. char
          pending_open = ""
        end
      end
      if pending_open ~= "" then groups[#groups > 0 and #groups or 1] = (groups[#groups] or "") .. pending_open end
      local current, offset, current_start = "", 0, 0
      for _, group in ipairs(groups) do
        if current ~= "" and vim.api.nvim_strwidth(current .. group) > max_display_width then
          table.insert(result, { text = current, byte_start = starts[i] + current_start })
          current, current_start = "", offset
        end
        current = current .. group
        offset = offset + #group
      end
      if current ~= "" then table.insert(result, { text = current, byte_start = starts[i] + current_start }) end
    end
  end
  return result
end

--- Pad text to a given display width according to alignment
---@param text string
---@param width integer target display width
---@param align string "left"|"center"|"right"
---@return string padded text
---@return integer left_pad number of spaces added on the left
local function pad_cell(text, width, align)
  local text_width = vim.api.nvim_strwidth(text)
  local total_pad = width - text_width
  if total_pad <= 0 then return text, 0 end
  if align == "right" then
    return string.rep(" ", total_pad) .. text, total_pad
  elseif align == "center" then
    local left = math.floor(total_pad / 2)
    local right = total_pad - left
    return string.rep(" ", left) .. text .. string.rep(" ", right), left
  else
    return text .. string.rep(" ", total_pad), 0
  end
end

--- Parse consecutive lines as a Markdown table
---@param lines string[]
---@param repo_base_url? string
---@param autolinks? MdRender.Autolink[]
---@param ref_links? table<string, string> normalized document labels to URLs
---@return MdRender.MarkdownTable.ParsedTable|nil
function MarkdownTable.parse(lines, repo_base_url, autolinks, ref_links, raw_html)
  if #lines < 2 then return nil end

  local header_cells, alignments = MarkdownTable.parse_header(lines[1], lines[2])
  if not header_cells then return nil end

  -- Process header cells
  local headers = {}
  for _, cell_text in ipairs(header_cells) do
    table.insert(headers, process_cell(cell_text, repo_base_url, autolinks, ref_links, raw_html))
  end

  -- Process data rows (line 3+)
  local rows = {}
  for i = 3, #lines do
    if not MarkdownTable.is_body_row(lines[i]) then break end
    local cells = split_row(lines[i])
    if not cells then break end
    local row = {}
    for col = 1, #alignments do
      local cell_text = cells[col] or ""
      table.insert(row, process_cell(cell_text, repo_base_url, autolinks, ref_links, raw_html))
    end
    table.insert(rows, row)
  end

  -- Calculate column widths (display width)
  local col_widths = {}
  for col = 1, #alignments do
    local w = vim.api.nvim_strwidth(headers[col].text)
    for _, row in ipairs(rows) do
      if row[col] then w = math.max(w, vim.api.nvim_strwidth(row[col].text)) end
    end
    col_widths[col] = w
  end

  -- Detect empty header (all cells are blank) — used by HTML table conversion
  local empty_header = true
  for _, h in ipairs(headers) do
    if h.text:match "%S" then
      empty_header = false
      break
    end
  end

  return {
    headers = headers,
    alignments = alignments,
    rows = rows,
    col_widths = col_widths,
    _raw_lines = vim.list_slice(lines, 1, #rows + 2),
    empty_header = empty_header,
  }
end

--- Render a parsed table into lines with highlights and links
---@param parsed_table MdRender.MarkdownTable.ParsedTable
---@param indent string
---@param max_width? integer Maximum display width (default: no limit)
---@param buf_dir? string Directory for resolving relative images
---@return string[] lines
---@return MdRender.Highlight.Group[][] per_line_highlights
---@return {line: integer, col_start: integer, col_end: integer, url: string}[][] per_line_links
---@return table[] image_placements
---@return integer[] per_line_source_offsets 0-based offset into the original table source rows for each output line: 0=header, 1=separator, 2+N=Nth data row
function MarkdownTable.render(parsed_table, indent, max_width, buf_dir)
  local out_lines = {}
  local out_highlights = {}
  local out_links = {}
  -- Parallel array: source-row offset (0-based) within the table for each
  -- output line. Lets callers stamp source_line_map per row instead of
  -- attributing the whole rendered table to a single source line.
  local out_source_offsets = {}
  local num_cols = #parsed_table.col_widths
  local col_widths = vim.deepcopy(parsed_table.col_widths)
  local sep_width = vim.api.nvim_strwidth "│" -- border char display width (varies with ambiwidth)

  --- Strip leading HTML comments from text
  ---@param text string
  ---@return string
  local function strip_html_comments(text)
    return inline.hide_html_comments(text):match "^%s*(.-)%s*$"
  end

  --- Check if a cell contains only an image reference ![alt](url), <img>, or <video> tag
  --- Also handles cells with leading HTML comments like <!-- ... -->![alt](url)
  ---@param _cell MdRender.MarkdownTable.ParsedCell
  ---@param raw_text string original cell text before markdown rendering
  ---@return string? alt, string? url, boolean? is_video
  local function cell_image(_cell, raw_text)
    local stripped = strip_html_comments(raw_text)
    local alt, url = stripped:match "^!%[(.-)%]%((.-)%)$"
    if alt and url then
      local image_mod = require "md-render.image"
      return alt, url, image_mod.is_video_file(url)
    end
    -- Try <img src="..." alt="..."> tag
    local img_end = stripped:lower():match "^<img%s" and inline.html_end(stripped, 1)
    local img_tag = img_end and stripped:sub(img_end + 1):match "^%s*$" and stripped:sub(1, img_end)
    if img_tag then
      local src = inline.html_target(img_tag)
      if src then
        local quoted
        alt, quoted = inline.html_attribute(img_tag, "alt")
        if not quoted then alt = "" end
        local image_mod = require "md-render.image"
        return alt, src, image_mod.is_video_file(src)
      end
    end
    -- Try <video src="...">...</video> or <video><source src="...">...</video>
    local video_start = stripped:lower():match "^<video[%s>]" and inline.html_end(stripped, 1)
    local video_end = video_start and select(2, inline.html_closing(stripped, "video", video_start + 1))
    local video_tag = video_end and stripped:sub(video_end + 1):match "^%s*$" and stripped:sub(1, video_end)
    if video_tag then
      local src = inline.html_target(video_tag)
      if src then
        alt = src:match "([^/]+)$" or src
        return alt, src, true
      end
    end
    return nil, nil, nil
  end

  -- Collect raw cell texts for image detection
  local raw_rows = {}
  for i = 3, #(parsed_table._raw_lines or {}) do
    local cells = split_row(parsed_table._raw_lines[i])
    if cells then
      local row = {}
      for col = 1, #parsed_table.alignments do
        local cell_text = cells[col] or ""
        cell_text = cell_text:match "^%s*(.-)%s*$"
        table.insert(row, cell_text)
      end
      table.insert(raw_rows, row)
    end
  end

  -- Pre-detect images and calculate display sizes for column width fitting
  local row_images_cache = {} -- row_idx -> col -> {alt, url, resolved, src_url, img_w, img_h}
  local col_image_widths = {} -- col -> max display_cols across all image rows
  do
    local image_mod = require "md-render.image"
    if image_mod.supports_kitty() then
      buf_dir = buf_dir or vim.fn.expand "%:p:h"
      local indent_width = vim.api.nvim_strwidth(indent)
      local overhead = indent_width + num_cols * (sep_width + 2) + sep_width
      local effective_max = max_width and max_width < 1e6 and max_width or 1e6
      local total_budget = effective_max - overhead
      local initial_max_per_col = math.max(1, math.floor(total_budget / num_cols))

      for row_idx, row in ipairs(parsed_table.rows) do
        if #raw_rows >= row_idx then
          for col = 1, num_cols do
            local raw = raw_rows[row_idx][col]
            if raw then
              local alt, url, is_video = cell_image(row[col], raw)
              if alt and url and not image_mod.is_badge_url(url) then
                local resolved, src_url, img_w, img_h
                if is_video then
                  src_url = image_mod.is_url(url) and url or nil
                  if src_url then
                    resolved = image_mod.get_video_cached(src_url)
                  else
                    resolved = image_mod.resolve_local(url, buf_dir)
                  end
                  if resolved then
                    img_w, img_h = image_mod.video_dimensions(resolved)
                  end
                else
                  resolved = image_mod.resolve(url, buf_dir)
                  src_url = image_mod.is_url(url) and url or nil
                  if resolved then
                    img_w, img_h = image_mod.image_dimensions(resolved)
                    if not img_w and image_mod.is_video_content(resolved) then
                      is_video = true
                      img_w, img_h = image_mod.video_dimensions(resolved)
                    end
                  end
                end
                if resolved and img_w and img_h then
                  local display_cols = image_mod.calc_display_size(img_w, img_h, initial_max_per_col, 15)
                  if not row_images_cache[row_idx] then row_images_cache[row_idx] = {} end
                  row_images_cache[row_idx][col] = {
                    alt = alt,
                    url = url,
                    resolved = resolved,
                    img_w = img_w,
                    img_h = img_h,
                    video = is_video,
                  }
                  col_image_widths[col] = math.max(col_image_widths[col] or 0, display_cols)
                elseif resolved and is_video then
                  -- Auto-detected video with resolved path but no dimensions yet
                  if not row_images_cache[row_idx] then row_images_cache[row_idx] = {} end
                  row_images_cache[row_idx][col] = {
                    alt = alt,
                    url = url,
                    resolved = resolved,
                    video = true,
                  }
                  col_image_widths[col] = math.max(col_image_widths[col] or 0, initial_max_per_col)
                elseif src_url then
                  if not row_images_cache[row_idx] then row_images_cache[row_idx] = {} end
                  row_images_cache[row_idx][col] = {
                    alt = alt,
                    url = url,
                    resolved = nil,
                    src_url = src_url,
                    video = is_video,
                  }
                  col_image_widths[col] = math.max(col_image_widths[col] or 0, initial_max_per_col)
                end
              end
            end
          end
        end
      end
    end
  end

  -- Reserve up to four cells (two wide glyphs), plus any wider kinsoku
  -- groups, even when the window is narrower than the table's minimum width.
  local min_widths = {}
  for col = 1, num_cols do
    local minimum = math.min(4, math.max(1, col_widths[col]))
    local function measure(cell)
      for _, part in ipairs(wrap_cell_text(cell.text, 2)) do
        minimum = math.max(minimum, vim.api.nvim_strwidth(part.text))
      end
    end
    measure(parsed_table.headers[col])
    for _, row in ipairs(parsed_table.rows) do
      measure(row[col])
    end
    min_widths[col] = minimum
    col_widths[col] = math.max(col_widths[col], minimum, col_image_widths[col] or 0)
  end

  -- Cap the widest columns first: short numeric/status columns keep their
  -- natural widths, and long prose shares the remaining space.
  if max_width then
    local overhead = vim.api.nvim_strwidth(indent) + num_cols * (sep_width + 2) + sep_width
    local minimum, total, upper = 0, 0, 0
    for col, width in ipairs(col_widths) do
      minimum = minimum + min_widths[col]
      total = total + width
      upper = math.max(upper, width)
    end
    local budget = math.max(minimum, max_width - overhead)
    if total > budget then
      local lower = 0
      while lower < upper do
        local cap = math.ceil((lower + upper) / 2)
        local sum = 0
        for col, width in ipairs(col_widths) do
          sum = sum + math.max(min_widths[col], math.min(width, cap))
        end
        if sum <= budget then
          lower = cap
        else
          upper = cap - 1
        end
      end
      local remaining = budget
      local natural = col_widths
      col_widths = {}
      for col, width in ipairs(natural) do
        col_widths[col] = math.max(min_widths[col], math.min(width, lower))
        remaining = remaining - col_widths[col]
      end
      for col, width in ipairs(natural) do
        if remaining > 0 and col_widths[col] < width then
          col_widths[col] = col_widths[col] + 1
          remaining = remaining - 1
        end
      end
    end
  end

  --- Build a multi-line data row by wrapping cell content instead of truncating
  ---@param cells MdRender.MarkdownTable.ParsedCell[]
  ---@param is_header boolean
  ---@param col_align_overrides? table<integer, string> per-column alignment overrides
  ---@return string[] lines
  ---@return MdRender.Highlight.Group[][] per_line_highlights
  ---@return {col_start: integer, col_end: integer, url: string}[][] per_line_links
  local function build_wrapped_row(cells, is_header, col_align_overrides)
    -- Wrap each cell's text into multiple lines
    local wrapped_cells = {}
    local max_wrap_lines = 1
    for col = 1, num_cols do
      local cell = cells[col]
      local wraps = wrap_cell_text(cell.text, col_widths[col])
      wrapped_cells[col] = wraps
      max_wrap_lines = math.max(max_wrap_lines, #wraps)
    end

    local all_lines = {}
    local all_hls = {}
    local all_lnks = {}

    for wrap_idx = 1, max_wrap_lines do
      local parts = {}
      local hls = {}
      local lnks = {}
      local byte_pos = #indent

      for col = 1, num_cols do
        local cell = cells[col]
        local wrap = wrapped_cells[col][wrap_idx]
        local display_text = wrap and wrap.text or ""
        local wrap_byte_start = wrap and wrap.byte_start or 0

        local col_align = (col_align_overrides and col_align_overrides[col]) or parsed_table.alignments[col]
        local padded, left_pad = pad_cell(display_text, col_widths[col], col_align)

        -- "│ " before cell
        local sep = "│ "
        table.insert(hls, { col = byte_pos, end_col = byte_pos + #sep, hl = "FloatBorder" })
        byte_pos = byte_pos + #sep

        local cell_start = byte_pos + left_pad

        local kept_byte_len = #display_text

        -- Distribute highlights for this wrapped line
        if wrap then
          local wrap_byte_end = wrap_byte_start + kept_byte_len
          for _, hl in ipairs(cell.highlights) do
            if hl.end_col > wrap_byte_start and hl.col < wrap_byte_end then
              local local_start = math.max(0, hl.col - wrap_byte_start)
              local local_end = math.min(kept_byte_len, hl.end_col - wrap_byte_start)
              table.insert(hls, {
                col = cell_start + local_start,
                end_col = cell_start + local_end,
                hl = hl.hl,
              })
            end
          end

          -- Distribute links
          for _, link in ipairs(cell.links) do
            if link.col_end > wrap_byte_start and link.col_start < wrap_byte_end then
              local local_start = math.max(0, link.col_start - wrap_byte_start)
              local local_end = math.min(kept_byte_len, link.col_end - wrap_byte_start)
              table.insert(lnks, {
                col_start = cell_start + local_start,
                col_end = cell_start + local_end,
                url = link.url,
              })
            end
          end
        end

        -- Add header Bold highlight
        if is_header and wrap then
          table.insert(hls, {
            col = cell_start,
            end_col = cell_start + #display_text,
            hl = "Bold",
          })
        end

        byte_pos = byte_pos + #padded
        table.insert(parts, sep .. padded)

        -- " " after cell (before next separator)
        byte_pos = byte_pos + 1
        table.insert(parts, " ")
      end

      -- Trailing "│"
      local trailing = "│"
      table.insert(hls, { col = byte_pos, end_col = byte_pos + #trailing, hl = "FloatBorder" })
      table.insert(parts, trailing)

      table.insert(all_lines, indent .. table.concat(parts))
      table.insert(all_hls, hls)
      table.insert(all_lnks, lnks)
    end

    return all_lines, all_hls, all_lnks
  end

  --- Build a separator line
  ---@return string line
  ---@return MdRender.Highlight.Group[] highlights
  local function build_separator()
    local parts = {}
    local byte_pos = #indent
    local rule_width = vim.api.nvim_strwidth "─"

    for col = 1, num_cols do
      local width = col_widths[col] + 2
      local sep_str = "│" .. string.rep("─", math.floor(width / rule_width)) .. string.rep(" ", width % rule_width)
      table.insert(parts, sep_str)
      byte_pos = byte_pos + #sep_str
    end
    table.insert(parts, "│")

    local line = indent .. table.concat(parts)
    local hls = { { col = #indent, end_col = #line, hl = "FloatBorder" } }
    return line, hls
  end

  -- Header row and separator (skip when header is empty, e.g. HTML tables without <th>)
  if not parsed_table.empty_header then
    local h_lines, h_hls_list, h_links_list = build_wrapped_row(parsed_table.headers, true)
    for i, line in ipairs(h_lines) do
      table.insert(out_lines, line)
      table.insert(out_highlights, h_hls_list[i])
      table.insert(out_links, h_links_list[i])
      table.insert(out_source_offsets, 0) -- header row
    end

    local s_line, s_hls = build_separator()
    table.insert(out_lines, s_line)
    table.insert(out_highlights, s_hls)
    table.insert(out_links, {})
    table.insert(out_source_offsets, 1) -- separator row
  end

  --- Build an empty row line with borders only (for image placeholder rows)
  ---@return string line
  ---@return MdRender.Highlight.Group[] highlights
  local function build_empty_row()
    local parts = {}
    local hls = {}
    local byte_pos = #indent

    for col = 1, num_cols do
      local sep = "│ "
      table.insert(hls, { col = byte_pos, end_col = byte_pos + #sep, hl = "FloatBorder" })
      byte_pos = byte_pos + #sep

      local padding = string.rep(" ", col_widths[col])
      byte_pos = byte_pos + #padding + 1
      table.insert(parts, sep .. padding .. " ")
    end

    local trailing = "│"
    table.insert(hls, { col = byte_pos, end_col = byte_pos + #trailing, hl = "FloatBorder" })
    table.insert(parts, trailing)

    return indent .. table.concat(parts), hls
  end

  -- Image placements to return
  local out_image_placements = {}

  -- Data rows
  for row_idx, row in ipairs(parsed_table.rows) do
    -- Use pre-detected image info from cache
    local cached = row_images_cache[row_idx]
    local row_has_images = cached ~= nil
    local row_images = {}
    if cached then
      local image_mod = require "md-render.image"
      for col, img in pairs(cached) do
        if img.img_w and img.img_h then
          local display_cols, display_rows = image_mod.calc_display_size(img.img_w, img.img_h, col_widths[col], 15)
          row_images[col] = {
            alt = img.alt,
            url = img.url,
            resolved = img.resolved,
            display_cols = display_cols,
            display_rows = display_rows,
            video = img.video,
          }
        elseif img.resolved and img.video then
          -- Auto-detected video: resolved path but no dimensions yet
          row_images[col] = {
            alt = img.alt,
            url = img.url,
            resolved = img.resolved,
            display_cols = col_widths[col],
            display_rows = 10,
            video = true,
          }
        elseif img.src_url then
          row_images[col] = {
            alt = img.alt,
            url = img.url,
            resolved = nil,
            src_url = img.src_url,
            display_cols = col_widths[col],
            display_rows = 10,
            video = img.video,
          }
        end
      end
      row_has_images = next(row_images) ~= nil
    end

    if row_has_images then
      -- Calculate max image height across all cells in this row
      local max_img_rows = 0
      for _, img in pairs(row_images) do
        max_img_rows = math.max(max_img_rows, img.display_rows)
      end

      -- Build wrapped labels and adjacent text before the images.
      local label_cells = {}
      for col = 1, num_cols do
        if row_images[col] then
          local icons_mod = require "md-render.icons"
          local raw_icon, icon_hl = icons_mod.get_image_icon(row_images[col].url or "")
          local img_icon = icons_mod.pad_icon(raw_icon)
          local caption = row_images[col].alt:gsub("\r\n", "\n"):gsub("[\r\n]", " ")
          local label = img_icon .. " " .. caption
          local lbl_hls = {
            { col = #img_icon + 1, end_col = #label, hl = "Comment" },
          }
          if icon_hl then table.insert(lbl_hls, 1, { col = 0, end_col = #img_icon, hl = icon_hl }) end
          label_cells[col] = {
            text = label,
            highlights = lbl_hls,
            links = {},
          }
        else
          label_cells[col] = row[col]
        end
      end
      -- Center-align image label cells
      local img_align_overrides = {}
      for col = 1, num_cols do
        if row_images[col] then img_align_overrides[col] = "center" end
      end
      local label_lines, label_hls, label_links = build_wrapped_row(label_cells, false, img_align_overrides)
      for i, line in ipairs(label_lines) do
        table.insert(out_lines, line)
        table.insert(out_highlights, label_hls[i])
        table.insert(out_links, label_links[i])
        table.insert(out_source_offsets, 1 + row_idx)
      end

      -- Add placeholder rows for images
      local img_start_line_idx = #out_lines -- 0-indexed line where images start
      for _ = 1, max_img_rows do
        local empty_line, empty_hls = build_empty_row()
        table.insert(out_lines, empty_line)
        table.insert(out_highlights, empty_hls)
        table.insert(out_links, {})
        table.insert(out_source_offsets, 1 + row_idx)
      end

      -- Record image placements (positions relative to table start)
      for col, img in pairs(row_images) do
        -- Calculate the display column offset of this column's content area
        -- (put_image uses display columns, not byte offsets)
        local col_display_offset = vim.api.nvim_strwidth(indent)
        for c = 1, col - 1 do
          col_display_offset = col_display_offset + sep_width + 2 + col_widths[c] -- "│" + " " + width + " "
        end
        col_display_offset = col_display_offset + sep_width + 1 -- "│ " for this column

        -- Center image horizontally within the cell.
        -- When the gap is odd, expand the image by 1 cell so centering is symmetric.
        local img_cols = img.display_cols
        local diff = col_widths[col] - img_cols
        if diff > 0 and diff % 2 == 1 then img_cols = img_cols + 1 end
        local center_pad = math.max(0, math.floor((col_widths[col] - img_cols) / 2))

        -- Pass pre-computed img_w/img_h so process_placement skips recalculation
        -- (which would undo the +1 expansion above).
        local cached_img = cached[col]
        table.insert(out_image_placements, {
          resolved = img.resolved,
          src_url = img.src_url,
          line_offset = img_start_line_idx,
          label_rows = #label_lines,
          col = col_display_offset + center_pad,
          rows = img.display_rows,
          cols = img_cols,
          cell_col = col_display_offset - 1,
          cell_cols = col_widths[col] + 2,
          img_w = cached_img and cached_img.img_w or nil,
          img_h = cached_img and cached_img.img_h or nil,
          video = img.video,
        })
      end

      -- Add separator after image row (but not after the last row)
      if row_idx < #parsed_table.rows then
        local sep_line, sep_hls = build_separator()
        table.insert(out_lines, sep_line)
        table.insert(out_highlights, sep_hls)
        table.insert(out_links, {})
        -- Inter-row separator stays attributed to the row above so a
        -- cursor on row N highlights row N's content + its trailing
        -- separator (instead of leaving a thin gap).
        table.insert(out_source_offsets, 1 + row_idx)
      end
    else
      local r_lines, r_hls_list, r_links_list = build_wrapped_row(row, false)
      for i, line in ipairs(r_lines) do
        table.insert(out_lines, line)
        table.insert(out_highlights, r_hls_list[i])
        table.insert(out_links, r_links_list[i])
        table.insert(out_source_offsets, 1 + row_idx)
      end
      if row_idx < #parsed_table.rows and #r_lines > 1 then
        local sep_line, sep_hls = build_separator()
        table.insert(out_lines, sep_line)
        table.insert(out_highlights, sep_hls)
        table.insert(out_links, {})
        table.insert(out_source_offsets, 1 + row_idx)
      end
    end
  end

  return out_lines, out_highlights, out_links, out_image_placements, out_source_offsets
end

return MarkdownTable
