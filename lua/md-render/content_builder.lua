---@class MdRender.Highlight.Group
---@field col integer 0-indexed start column
---@field end_col integer 0-indexed end column (-1 means end of line)
---@field hl string highlight group name
---@field hl_eol? boolean extend highlight to end of line

---@class MdRender.LineHighlight
---@field line integer 0-indexed line number
---@field groups MdRender.Highlight.Group[]

---@class MdRender.LinkMetadata
---@field line integer 0-indexed line number
---@field col_start integer 0-indexed start column
---@field col_end integer 0-indexed end column
---@field url string

---@class MdRender.CodeBlock
---@field language string
---@field start_line integer 0-indexed, first code line
---@field end_line integer   0-indexed, last code line
---@field prefix_len integer byte length of line prefix to strip for treesitter (default 2)
---@field source_lines? string[] original (non-truncated) code lines for accurate treesitter parsing

---@class MdRender.CalloutFold
---@field header_line integer 0-indexed rendered line of the callout header
---@field source_line integer 1-indexed source line index
---@field collapsed boolean current fold state

---@class MdRender.ExpandableRegion
---@field start_line integer 0-indexed first rendered line of the region
---@field end_line integer 0-indexed last rendered line of the region
---@field block_id integer unique identifier for expand_state lookup
---@field expanded boolean current state

---@class MdRender.ImagePlacement
---@field path string? absolute path to image file (nil if not yet downloaded)
---@field line integer 0-indexed rendered line where image starts
---@field col integer 0-indexed display column offset
---@field rows integer display height in cells
---@field cols integer display width in cells
---@field cell_col? integer 0-indexed display column of the table cell interior
---@field cell_cols? integer table cell width including padding, excluding borders
---@field img_w? integer source image width in pixels
---@field img_h? integer source image height in pixels
---@field animated? boolean true if animated GIF
---@field src_url? string original URL for async download
---@field mermaid_source? string mermaid source for async rendering
---@field plantuml_source? string PlantUML source for async rendering

---@class MdRender.Content
---@field lines string[]
---@field highlights MdRender.LineHighlight[]
---@field highlight_ns? integer namespace containing the rendered Markdown styles
---@field link_metadata MdRender.LinkMetadata[]
---@field code_blocks MdRender.CodeBlock[]
---@field callout_folds MdRender.CalloutFold[]
---@field expandable_regions MdRender.ExpandableRegion[]
---@field image_placements MdRender.ImagePlacement[]
---@field text_placements MdRender.TextPlacement[]
---@field heading_layouts table<string, table> shared image layouts
---@field heading_highlights table<string, table> resolved groups used by image layouts
---@field heading_backend? "image"|"native"|"plain" renderer used to build this content
---@field heading_fallback? string document-level reason for ordinary headings
---@field heading_lines table<integer, boolean> heading rows with ordered styles (0-indexed)
---@field heading_positions table<integer, {byte: integer, col: integer, length: integer}> heading byte ranges (1-indexed rows)
---@field footnote_anchors table<string, integer> anchor name → 0-indexed line number
---@field heading_anchors table<string, integer> heading slug → 0-indexed line number
---@field source_line_map integer[] rendered line index (1-based) → source line number (1-based)
---@field title_line? integer
---@field title_text? string
---@field close_line_idx? integer

---@class MdRender.ContentBuilder
---@field lines string[]
---@field highlights MdRender.LineHighlight[]
---@field link_metadata MdRender.LinkMetadata[]
---@field code_blocks MdRender.CodeBlock[]
---@field callout_folds MdRender.CalloutFold[]
---@field expandable_regions MdRender.ExpandableRegion[]
---@field image_placements MdRender.ImagePlacement[]
---@field text_placements MdRender.TextPlacement[]
---@field footnote_anchors table<string, integer>
---@field source_line_map integer[]
---@field private _current_source_line integer
local ContentBuilder = {}

---@return MdRender.ContentBuilder
function ContentBuilder.new()
  return setmetatable({
    lines = {},
    highlights = {},
    link_metadata = {},
    code_blocks = {},
    callout_folds = {},
    expandable_regions = {},
    image_placements = {},
    text_placements = {},
    heading_layouts = {},
    heading_highlights = {},
    heading_lines = {},
    heading_positions = {},
    footnote_anchors = {},
    heading_anchors = {},
    heading_duplicates = {},
    source_line_map = {},
    text_scale = true,
    _current_source_line = 0,
  }, { __index = ContentBuilder })
end

---@param source_line integer 1-indexed source line number
function ContentBuilder:set_source_line(source_line)
  self._current_source_line = source_line
end

---@param text string
---@param hl_groups? MdRender.Highlight.Group[]
function ContentBuilder:add_line(text, hl_groups)
  table.insert(self.lines, text)
  table.insert(self.source_line_map, self._current_source_line)
  if hl_groups then table.insert(self.highlights, { line = #self.lines - 1, groups = hl_groups }) end
end

---@param label string
---@param value string
---@param value_hl? string
function ContentBuilder:add_labeled(label, value, value_hl)
  local line = label .. ": " .. value
  self:add_line(line, {
    { col = 0, end_col = #label, hl = "Comment" },
    { col = #label + 2, end_col = #line, hl = value_hl or "Normal" },
  })
end

---@return MdRender.Content
function ContentBuilder:result()
  -- Natural heading names take precedence over aliases for repeated headings.
  local heading_anchors = vim.tbl_extend("force", {}, self.heading_anchors)
  for _, heading in ipairs(self.heading_duplicates) do
    local slug
    local suffix = 0
    repeat
      suffix = suffix + 1
      slug = heading.slug .. "-" .. suffix
    until heading_anchors[slug] == nil
    heading_anchors[slug] = heading.line
  end
  return {
    lines = self.lines,
    highlights = self.highlights,
    link_metadata = self.link_metadata,
    code_blocks = self.code_blocks,
    callout_folds = self.callout_folds,
    expandable_regions = self.expandable_regions,
    image_placements = self.image_placements,
    text_placements = self.text_placements,
    heading_layouts = self.heading_layouts,
    heading_highlights = self.heading_highlights,
    heading_backend = self.heading_backend,
    heading_lines = self.heading_lines,
    heading_positions = self.heading_positions,
    footnote_anchors = self.footnote_anchors,
    heading_anchors = heading_anchors,
    source_line_map = self.source_line_map,
  }
end

--- Detect bare URLs in a code block line and add link metadata for clickability.
--- This ensures that URLs inside code blocks are clickable even when the line is
--- visually truncated (the full URL is stored in the extmark).
---@param self MdRender.ContentBuilder
---@param raw_line string Raw code line content (without indent/prefix)
---@param prefix_len integer Byte length of the displayed prefix
---@param content_byte_end integer Byte position in displayed line where content ends (before "…" if truncated)
local function detect_urls_in_code_line(self, raw_line, prefix_len, content_byte_end)
  local pos = 1
  while true do
    local ms, me = raw_line:find('https?://[^%s%)<>"]+', pos)
    if not ms then break end
    local url = raw_line:sub(ms, me):gsub("[.,;:!?*~]+$", "")
    -- Strip trailing non-ASCII symbols (e.g. ⏎, →) that are not valid in URLs.
    -- charclass returns 1 for punctuation/symbols, >=2 for letters/digits.
    while #url > 0 do
      local last_char = vim.fn.strcharpart(url, vim.fn.strchars(url) - 1, 1)
      if #last_char > 1 and vim.fn.charclass(last_char) <= 1 then
        url = url:sub(1, #url - #last_char)
      else
        break
      end
    end
    local col_start = prefix_len + ms - 1
    local col_end = prefix_len + ms - 1 + #url
    if col_start < content_byte_end then
      table.insert(self.link_metadata, {
        line = #self.lines - 1,
        col_start = col_start,
        col_end = math.min(col_end, content_byte_end),
        url = url,
      })
    end
    pos = me + 1
  end
end

--- Unicode superscript digit characters for footnote numbering
local SUPERSCRIPT_DIGITS = { "⁰", "¹", "²", "³", "⁴", "⁵", "⁶", "⁷", "⁸", "⁹" }

--- Convert a number to superscript Unicode string
---@param n integer
---@return string
local function to_superscript(n)
  local s = tostring(n)
  local result = {}
  for i = 1, #s do
    local d = tonumber(s:sub(i, i))
    table.insert(result, SUPERSCRIPT_DIGITS[d + 1])
  end
  return table.concat(result)
end

local wrap_mod = require "md-render.wrap"
local icons = require "md-render.icons"
local fence_mod = require "md-render.fence"
local html_block = require "md-render.html_block"

local wrap_words = wrap_mod.wrap_words

--- Distribute markdown highlights across wrapped lines
---@param md_highlights MdRender.Markdown.Highlight[]
---@param wrapped_lines string[] The wrapped line texts
---@param line_starts integer[] Start positions of each wrapped line
---@param indent string Indentation prefix
---@param quote_prefix string Blockquote prefix (may be empty)
---@param content_offset integer Byte offset of content within the original rendered text
---@param list_prefix_len? integer Byte length of list marker prefix (0 if none)
---@param list_cont_len? integer Display width of list marker for continuation indent (0 if none)
---@return MdRender.Highlight.Group[][] per_line_highlights Array of highlight lists, one per wrapped line
local function distribute_highlights(
  md_highlights,
  wrapped_lines,
  line_starts,
  indent,
  quote_prefix,
  content_offset,
  list_prefix_len,
  list_cont_len
)
  list_prefix_len = list_prefix_len or 0
  list_cont_len = list_cont_len or list_prefix_len
  local per_line = {}
  for idx, wline in ipairs(wrapped_lines) do
    local line_start_pos = line_starts[idx]
    local lm_len = idx == 1 and list_prefix_len or list_cont_len
    local line_prefix = (quote_prefix ~= "" and (indent .. quote_prefix) or indent) .. string.rep(" ", lm_len)
    local line_hls = {}

    -- Add FloatBorder highlight for blockquote prefix on continuation lines
    if quote_prefix ~= "" and idx > 1 then
      table.insert(line_hls, {
        col = #indent,
        end_col = #indent + #quote_prefix,
        hl = "FloatBorder",
      })
    end

    for _, hl in ipairs(md_highlights) do
      local hl_start = hl.col - content_offset
      local hl_end = hl.end_col - content_offset

      -- Marker-area highlights (list markers, checkbox icons) that end at or before
      -- the content start should only appear on line 1 with their original positions
      if hl.end_col <= content_offset and hl.hl ~= "FloatBorder" then
        if idx == 1 then
          table.insert(line_hls, {
            col = #indent + hl.col,
            end_col = #indent + hl.end_col,
            hl = hl.hl,
          })
        end
      elseif hl.hl == "FloatBorder" and hl.col == 0 then
        if idx == 1 then
          table.insert(line_hls, {
            col = #indent + hl.col,
            end_col = #indent + hl.end_col,
            hl = hl.hl,
          })
        end
      else
        local wline_end = line_start_pos + #wline
        if #wline > 0 and hl_end > line_start_pos and hl_start < wline_end then
          local local_start = math.max(0, hl_start - line_start_pos)
          local local_end = math.min(#wline, hl_end - line_start_pos)
          table.insert(line_hls, {
            col = local_start + #line_prefix,
            end_col = local_end + #line_prefix,
            hl = hl.hl,
          })
        end
      end
    end

    per_line[idx] = line_hls
  end
  return per_line
end

--- Distribute link metadata across wrapped lines
---@param md_links MdRender.Markdown.Link[]
---@param wrapped_lines string[] The wrapped line texts
---@param line_starts integer[] Start positions of each wrapped line
---@param indent string Indentation prefix
---@param quote_prefix string Blockquote prefix (may be empty)
---@param content_offset integer Byte offset of content within the original rendered text
---@param base_line integer Current line count in the builder (0-indexed, before adding wrapped lines)
---@param list_prefix_len? integer Byte length of list marker prefix (0 if none)
---@param list_cont_len? integer Display width of list marker for continuation indent (0 if none)
---@return MdRender.LinkMetadata[] link_entries
local function distribute_links(
  md_links,
  wrapped_lines,
  line_starts,
  indent,
  quote_prefix,
  content_offset,
  base_line,
  list_prefix_len,
  list_cont_len
)
  list_prefix_len = list_prefix_len or 0
  list_cont_len = list_cont_len or list_prefix_len
  local entries = {}
  for idx, wline in ipairs(wrapped_lines) do
    local line_start_pos = line_starts[idx]
    local lm_len = idx == 1 and list_prefix_len or list_cont_len
    local line_prefix = (quote_prefix ~= "" and (indent .. quote_prefix) or indent) .. string.rep(" ", lm_len)

    for _, link in ipairs(md_links) do
      local link_start = link.col_start - content_offset
      local link_end = link.col_end - content_offset
      local wline_end = line_start_pos + #wline

      if #wline > 0 and link_end > line_start_pos and link_start < wline_end then
        local local_start = math.max(0, link_start - line_start_pos)
        local local_end = math.min(#wline, link_end - line_start_pos)
        table.insert(entries, {
          line = base_line + idx - 1,
          col_start = local_start + #line_prefix,
          col_end = local_end + #line_prefix,
          url = link.url,
        })
      end
    end
  end
  return entries
end

--- Add a wrapped markdown line with highlights and links distributed across wrapped lines
---@param self MdRender.ContentBuilder
---@param rendered_text string
---@param md_highlights MdRender.Markdown.Highlight[]
---@param md_links MdRender.Markdown.Link[]
---@param indent string
---@param max_width integer Display width excluding indent, including quote/list prefixes
---@param quote_prefix string
---@param list_marker? string
---@param line_gap? integer blank lines to insert after each wrapped line
---@param hard_breaks? MdRender.Markdown.Break[] mandatory paragraph row boundaries
---@param source_lines? integer[] original source rows of the paragraph
function ContentBuilder:add_wrapped_markdown(
  rendered_text,
  md_highlights,
  md_links,
  indent,
  max_width,
  quote_prefix,
  list_marker,
  line_gap,
  hard_breaks,
  source_lines
)
  local wrap_text = rendered_text
  local content_offset = 0
  if quote_prefix ~= "" then
    wrap_text = rendered_text:sub(#quote_prefix + 1)
    content_offset = #quote_prefix
  end

  -- Strip list marker from wrap_text so wrapping is based on content only
  local list_prefix_len = 0
  local list_cont_len = 0
  if list_marker and list_marker ~= "" then
    wrap_text = wrap_text:sub(#list_marker + 1)
    content_offset = content_offset + #list_marker
    list_prefix_len = #list_marker
    list_cont_len = vim.api.nvim_strwidth(list_marker)
  end

  local content_max_width = max_width
  if quote_prefix ~= "" then content_max_width = max_width - vim.api.nvim_strwidth(quote_prefix) end
  if list_cont_len > 0 then content_max_width = content_max_width - list_cont_len end

  local wrapped_lines, line_starts, row_sources = {}, {}, {}
  local first, source_line = 0, self._current_source_line
  hard_breaks = hard_breaks or {}
  for i = 1, #hard_breaks + 1 do
    local boundary = hard_breaks[i]
    local last = boundary and boundary.col - content_offset or #wrap_text
    local segment = wrap_text:sub(first + 1, last)
    local rows, starts = wrap_words(segment, content_max_width)
    if segment == "" then
      rows, starts = { "" }, { 0 }
    end
    for row, value in ipairs(rows) do
      wrapped_lines[#wrapped_lines + 1] = value
      line_starts[#line_starts + 1] = first + starts[row]
      row_sources[#row_sources + 1] = source_line
    end
    first = last + 1
    if boundary then
      local offset = source_lines and source_lines[boundary.source_line] - source_lines[1] or boundary.source_line - 1
      source_line = self._current_source_line + offset
    end
  end
  local per_line_hls = distribute_highlights(
    md_highlights,
    wrapped_lines,
    line_starts,
    indent,
    quote_prefix,
    content_offset,
    list_prefix_len,
    list_cont_len
  )
  local base_line = #self.lines
  local link_entries = distribute_links(
    md_links,
    wrapped_lines,
    line_starts,
    indent,
    quote_prefix,
    content_offset,
    base_line,
    list_prefix_len,
    list_cont_len
  )

  local list_prefix = list_marker or ""
  local list_continuation = string.rep(" ", list_cont_len)

  line_gap = line_gap or 0
  local saved_source = self._current_source_line
  for idx, wline in ipairs(wrapped_lines) do
    local line_prefix = quote_prefix ~= "" and (indent .. quote_prefix) or indent
    local lm = idx == 1 and list_prefix or list_continuation
    local line_hls = per_line_hls[idx]
    self:set_source_line(row_sources[idx])
    self:add_line(line_prefix .. lm .. wline, #line_hls > 0 and line_hls or nil)
    for _ = 1, line_gap do
      self:add_line ""
    end
  end
  self:set_source_line(saved_source)

  for _, entry in ipairs(link_entries) do
    -- distribute_links assumed the wrapped lines were consecutive; spread the
    -- entries back out over the gaps we just inserted.
    if line_gap > 0 then entry.line = base_line + (entry.line - base_line) * (line_gap + 1) end
    table.insert(self.link_metadata, entry)
  end
end

--- Add a simple (non-wrapped) markdown line with highlights and links
---@param self MdRender.ContentBuilder
---@param rendered_text string
---@param md_highlights MdRender.Markdown.Highlight[]
---@param md_links MdRender.Markdown.Link[]
---@param indent string
function ContentBuilder:add_simple_markdown(rendered_text, md_highlights, md_links, indent)
  local line_hls = {}
  for _, hl in ipairs(md_highlights) do
    table.insert(line_hls, {
      col = hl.col + #indent,
      end_col = hl.end_col + #indent,
      hl = hl.hl,
    })
  end

  self:add_line(indent .. rendered_text, #line_hls > 0 and line_hls or nil)

  for _, link in ipairs(md_links) do
    table.insert(self.link_metadata, {
      line = #self.lines - 1,
      col_start = link.col_start + #indent,
      col_end = link.col_end + #indent,
      url = link.url,
    })
  end
end

--- Add a table block with highlights and links
---@param self MdRender.ContentBuilder
---@param table_lines string[]
---@param indent string
---@param max_width integer
---@param repo_base_url? string
---@param autolinks? MdRender.Autolink[]
---@param ref_links? table<string, string> normalized document labels to URLs
--- @param per_row_source? boolean When true (markdown pipe tables), each
---   rendered line gets its source attribution from the corresponding
---   source row offset. When false/nil (HTML tables, where the source
---   isn't a per-row enumeration), all rows inherit the caller's
---   _current_source_line as-is.
function ContentBuilder:add_table(
  table_lines,
  indent,
  max_width,
  repo_base_url,
  autolinks,
  expanded,
  buf_dir,
  per_row_source,
  ref_links,
  raw_html
)
  local markdown_table = require "md-render.markdown_table"
  local parsed = markdown_table.parse(table_lines, repo_base_url, autolinks, ref_links, raw_html)
  if not parsed then
    -- Fallback: render each line as markdown
    for _, line in ipairs(table_lines) do
      self:add_markdown_line(
        line,
        indent,
        max_width,
        repo_base_url,
        autolinks,
        ref_links,
        nil,
        nil,
        { raw_html = raw_html }
      )
    end
    return
  end
  local lines, per_line_hls, per_line_links, tbl_image_placements, src_offsets =
    markdown_table.render(parsed, indent, max_width, expanded, buf_dir)
  local base_line = #self.lines
  -- For pipe tables, table_lines[i] corresponds to source line
  -- (caller's _current_source_line + i - 1). Use the offset returned by
  -- render to stamp each emitted line at the right source row.
  local saved_src_line = self._current_source_line
  for i, line in ipairs(lines) do
    if per_row_source and src_offsets and src_offsets[i] then
      self._current_source_line = saved_src_line + src_offsets[i]
    end
    self:add_line(line, #per_line_hls[i] > 0 and per_line_hls[i] or nil)
    for _, link in ipairs(per_line_links[i] or {}) do
      table.insert(self.link_metadata, {
        line = base_line + i - 1,
        col_start = link.col_start,
        col_end = link.col_end,
        url = link.url,
      })
    end
  end
  self._current_source_line = saved_src_line

  -- Register image placements from table cells (inline within table borders)
  if tbl_image_placements then
    for _, p in ipairs(tbl_image_placements) do
      table.insert(self.image_placements, {
        path = p.resolved,
        line = base_line + p.line_offset,
        col = p.col,
        rows = p.rows,
        cols = p.cols,
        cell_col = p.cell_col,
        cell_cols = p.cell_cols,
        src_url = p.src_url,
        img_w = p.img_w,
        img_h = p.img_h,
        video = p.video,
      })
    end
  end
end

--- Emit an image/video header line (icon + display name) with wrapping.
---@param self MdRender.ContentBuilder
---@param indent string
---@param img_icon string Padded icon string
---@param icon_hl? string Highlight group for the icon
---@param display_name string Alt text or filename
---@param max_width integer
---@param name_hl string Highlight group for the display name text
---@return integer lines_added Number of lines emitted
function ContentBuilder:_emit_image_header(indent, img_icon, icon_hl, display_name, max_width, name_hl)
  local icon_start = #indent
  local icon_end = icon_start + #img_icon
  local icon_display_width = vim.api.nvim_strwidth(img_icon)
  local cont_width = icon_display_width + 1
  local available = math.max(1, max_width - vim.api.nvim_strwidth(indent) - cont_width)

  local wrapped, _ = wrap_words(display_name, available)

  for idx, segment in ipairs(wrapped) do
    if idx == 1 then
      local header = indent .. img_icon .. " " .. segment
      local hls = {
        { col = icon_end, end_col = #header, hl = name_hl },
      }
      if icon_hl then table.insert(hls, 1, { col = icon_start, end_col = icon_end, hl = icon_hl }) end
      self:add_line(header, hls)
    else
      local cont_pad = string.rep(" ", cont_width)
      local line = indent .. cont_pad .. segment
      self:add_line(line, {
        { col = #indent + #cont_pad, end_col = #line, hl = name_hl },
      })
    end
  end
  return #wrapped
end

--- Narrowest scaled heading worth drawing, in pre-scale cells. Below this a
--- heading would wrap into a column of two-word fragments, which reads worse
--- than leaving it at plain size.
local MIN_SCALED_HEADING_WIDTH = 12

local parse_atx_heading = require("md-render.markdown").parse_atx_heading

--- How to draw a source line's heading, and the width its text has to wrap to
--- in order to fit once scaled. Returns nil when the heading must stay plain.
---@param level integer parsed heading level
---@param indent string
---@param max_width integer
---@return MdRender.TextSize.Spec? spec
local function heading_scale_plan(level, indent, max_width)
  local spec = require("md-render.text_size").spec_for(level, "native")
  if not spec then return nil end

  -- Scaling multiplies the width as well as the height, so the text has to wrap
  -- at 1/ratio of the space it would normally get. The indent is not scaled
  -- (the block starts after it), so take it off the top before dividing. One
  -- `s`-worth of cells comes off as well: `split_run` rounds each run's `w` up,
  -- so a line can land a fraction of a cell wider than `width * ratio`.
  local avail = math.floor((max_width - vim.api.nvim_strwidth(indent) - spec.s) / spec.ratio)
  if avail < MIN_SCALED_HEADING_WIDTH then return nil end

  return spec
end

--- Wrap using the same styled runs that will be painted in the terminal.
function ContentBuilder:add_native_heading(text, highlights, links, indent, spec, level, max_width)
  local native = require "md-render.heading_native"
  local budget = max_width - vim.fn.strdisplaywidth(indent)
  local function measure(fragment, offset)
    local _, width = native.runs(fragment, offset, highlights, links, spec, budget)
    return width
  end
  local lines, starts = wrap_words(text, budget, measure)
  local styles = distribute_highlights(highlights, lines, starts, indent, "", 0)
  local first_line = #self.lines
  local metadata = distribute_links(links, lines, starts, indent, "", 0, first_line)
  for index, line in ipairs(lines) do
    local runs, width = native.runs(line, starts[index], highlights, links, spec, budget)
    local placement = {
      line = #self.lines,
      col = #indent,
      text = line,
      runs = runs,
      width = width,
      scale = spec.s,
      num = spec.n,
      den = spec.d,
      hl = "MdRenderH" .. level,
      normal = self.heading_normal or "Normal",
    }
    placement.columns = native.columns(placement)
    self.text_placements[#self.text_placements + 1] = placement
    self:add_line(indent .. line, styles[index])
    for _ = 1, spec.s - 1 do
      self:add_line ""
    end
  end
  for _, link in ipairs(metadata) do
    link.line = first_line + (link.line - first_line) * spec.s
    self.link_metadata[#self.link_metadata + 1] = link
  end
end

function ContentBuilder:heading_renderer()
  if not self.heading_backend then
    self.heading_backend = self.text_scale and require("md-render.text_size").resolve_backend() or "plain"
  end
  return self.heading_backend
end

--- Image headings wrap at Pango's measured byte boundaries. The same ranges
--- populate the native buffer, highlights, links and image hit targets.
function ContentBuilder:add_image_heading(text, highlights, links, indent, max_width, level)
  -- Indexed terminal colors cannot be recovered from the RGB highlight values.
  if not vim.o.termguicolors then return false end
  local text_size = require "md-render.text_size"
  local spec = text_size.spec_for(level, "image")
  local cell = require("md-render.image").get_cell_size(true)
  if not spec or not cell then return false end
  local prefix = require("md-render.markdown").heading_icon_prefix(level)
  local offset = #prefix
  local width = max_width - vim.fn.strdisplaywidth(indent .. prefix)
  if width < 2 then return false end
  local function highlight(name)
    local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
    self.heading_highlights[name] = vim.deepcopy(hl)
    return hl
  end
  local normal = highlight(self.heading_normal or "Normal")
  local base = highlight "Normal"
  local styles = {}
  local supported =
    { fg = true, bg = true, sp = true, bold = true, italic = true, underline = true, strikethrough = true }
  local spans = highlights
  -- Float attributes combine with heading styles; Normal supplies only the
  -- default colors in an ordinary window.
  if self.heading_normal == "NormalFloat" then
    spans = vim.list_extend({ { col = offset, end_col = #text, hl = "NormalFloat" } }, highlights)
  end
  for _, span in ipairs(spans) do
    local style = highlight(span.hl)
    style.default, style.cterm, style.ctermfg, style.ctermbg = nil, nil, nil, nil
    if style.blend == 0 then style.blend = nil end
    for key, value in pairs(style) do
      if value and not supported[key] then return false end
    end
    style.start, style["end"] = math.max(0, span.col - offset), math.min(#text, span.end_col) - offset
    if style.start < style["end"] then styles[#styles + 1] = style end
  end
  local opts = text_size.config().image
  local request = {
    font = opts.font,
    font_pixels = opts.font_size,
    cell_width = math.floor(cell.cell_w),
    cell_height = math.floor(cell.cell_h),
    entries = {
      {
        text = text:sub(offset + 1),
        ratio = spec.ratio,
        rows = spec.s,
        -- Keep the native fallback within the same window when shrinking text.
        max_cols = math.max(1, math.floor(width * math.min(1, spec.ratio))),
        fg = normal.fg or base.fg or 0xffffff,
        bg = normal.bg or base.bg,
        bold = false,
        styles = styles,
      },
    },
  }
  local entry
  while true do
    entry = require("md-render.heading_layout").request(request, opts.python)
    self.heading_layouts[entry.key] = entry
    if not entry.output then return false end
    local limit = request.entries[1].max_cols
    for _, line in ipairs(entry.output.lines) do
      if line.fallback then return false end
      local native_width = vim.fn.strdisplaywidth(line.text)
      if native_width > width then
        limit = math.min(limit, request.entries[1].max_cols - 1, math.floor(line.cols * width / native_width))
      end
    end
    if limit == request.entries[1].max_cols then break end
    if limit < 1 then return false end
    -- Font fallback can pack more CJK text than the native buffer can hold.
    -- Tighten the measured wrap without mutating a cached layout request.
    request = vim.deepcopy(request)
    request.entries[1].max_cols = limit
  end
  -- Direct opaque images must cover the native text. Tmux already masks it
  -- with placeholder cells and a blank tail, so it needs no padding pass.
  local cover_native = not vim.env.TMUX
  local native_cols, needs_padding = {}, false
  for index, line in ipairs(entry.output.lines) do
    native_cols[index] = vim.fn.strdisplaywidth(line.text)
    needs_padding = needs_padding or (cover_native and not line.transparent and line.cols < native_cols[index])
  end
  if needs_padding then
    request = vim.deepcopy(request)
    request.entries[1].native_cols = native_cols
    entry = require("md-render.heading_layout").request(request, opts.python)
    self.heading_layouts[entry.key] = entry
    if not entry.output then return false end
  end
  for _, line in ipairs(entry.output.lines) do
    if line.fallback or (cover_native and not line.transparent and line.cols < vim.fn.strdisplaywidth(line.text)) then
      return false
    end
    -- A narrow linked glyph can fall between terminal cell centers. Keep text
    -- when any visible link fragment would have no projected mouse target.
    for _, link in ipairs(links) do
      local first = math.max(line.start, link.col_start - offset) - line.start
      local last = math.min(line["end"], link.col_end - offset) - line.start
      if first < last then
        local clickable = false
        for _, byte in ipairs(line.columns or {}) do
          if byte and byte >= first and byte < last then
            clickable = true
            break
          end
        end
        if not clickable then return false end
      end
    end
  end
  for index, line in ipairs(entry.output.lines) do
    local pad = index == 1 and prefix or string.rep(" ", vim.fn.strdisplaywidth(prefix))
    local line_indent = indent .. pad
    local first, last = offset + line.start, offset + line["end"]
    local row = #self.lines
    local line_hls = {}
    for _, span in ipairs(highlights) do
      local a, b = math.max(first, span.col), math.min(last, span.end_col)
      if a < b then
        line_hls[#line_hls + 1] = {
          col = index == 1 and span.col == 0 and #indent or #line_indent + a - first,
          end_col = #line_indent + b - first,
          hl = span.hl,
        }
      end
    end
    self:add_line(line_indent .. line.text, line_hls)
    for _, link in ipairs(links) do
      local a, b = math.max(first, link.col_start), math.min(last, link.col_end)
      if a < b then
        self.link_metadata[#self.link_metadata + 1] =
          { line = row, col_start = #line_indent + a - first, col_end = #line_indent + b - first, url = link.url }
      end
    end
    self.text_placements[#self.text_placements + 1] = {
      line = row,
      col = #line_indent,
      text = line.text,
      scale = spec.s,
      num = spec.n,
      den = spec.d,
      hl = "MdRenderH" .. level,
      normal = self.heading_normal or "Normal",
      raster = line,
    }
    for _ = 1, spec.s - 1 do
      self:add_line ""
    end
  end
  return true
end

--- Add a markdown-rendered line with wrapping support
---@param self MdRender.ContentBuilder
---@param text string
---@param indent string
---@param max_width integer Maximum display width including indent
---@param repo_base_url? string
---@param autolinks? MdRender.Autolink[]
---@param ref_links? table<string, string>
---@param source_lines? integer[] original source rows of the paragraph
---@param block_context? {heading_level?: integer, list_marker?: boolean, raw_html?: boolean, quote_prefix?: string} accepted document block syntax
---@return string? alert_type Alert type if this line is an alert header
---@return string? fold_mod Fold modifier ("+" or "-") if this is a foldable callout
function ContentBuilder:add_markdown_line(
  text,
  indent,
  max_width,
  repo_base_url,
  autolinks,
  ref_links,
  footnote_map,
  source_lines,
  block_context
)
  local markdown = require "md-render.markdown"
  local rendered_text, md_highlights, md_links, special_type, list_marker, alert_type, fold_mod, heading_content, hard_breaks =
    markdown.render(text, repo_base_url, autolinks, ref_links, footnote_map, nil, block_context)

  local quote_prefix = ""
  if special_type == "blockquote" then
    if block_context and block_context.quote_prefix then
      quote_prefix = block_context.quote_prefix
    else
      local bar_space = "│ " -- U+2502 + space (4 bytes)
      local pos = 1
      while rendered_text:sub(pos, pos + #bar_space - 1) == bar_space do
        pos = pos + #bar_space
      end
      quote_prefix = rendered_text:sub(1, pos - 1)
    end
  end

  local heading_quote = ""
  if heading_content and quote_prefix ~= "" then
    heading_quote = quote_prefix
    indent = indent .. heading_quote
    rendered_text = rendered_text:sub(#heading_quote + 1)
    md_highlights = vim.tbl_filter(function(hl)
      return hl.hl ~= "FloatBorder"
    end, md_highlights)
    for _, hl in ipairs(md_highlights) do
      hl.col, hl.end_col = hl.col - #heading_quote, hl.end_col - #heading_quote
    end
    for _, link in ipairs(md_links) do
      link.col_start, link.col_end = link.col_start - #heading_quote, link.col_end - #heading_quote
    end
    for _, boundary in ipairs(hard_breaks) do
      boundary.col = boundary.col - #heading_quote
    end
    quote_prefix = ""
  end

  -- A scaled heading wraps at 1/ratio of the usual width and reserves
  -- `s - 1` rows under each of its lines for the taller glyphs.
  local spec, level
  local heading_text, plain_prefix = rendered_text, ""
  local backend = heading_content and self:heading_renderer() or "plain"
  if heading_content and #hard_breaks > 0 then
    if self.text_scale and backend ~= "plain" then
      self.native_heading_fallback = "heading contains hard line breaks"
    end
    backend = "plain"
  end
  local image_heading = backend == "image"
  local plain_heading = backend == "plain" or not self.text_scale
  if heading_content then
    level = tonumber(md_highlights[1].hl:match "^MdRenderH(%d)$")
    if self.text_scale and backend == "native" and rendered_text ~= "" then
      -- OSC 66 cannot preserve Neovim's tab/control-character display.
      if rendered_text:find "%c" then
        self.native_heading_fallback = "native heading text contains control characters"
      else
        spec = heading_scale_plan(level, indent, max_width)
        if not spec then
          self.native_heading_fallback = self.native_heading_fallback or "insufficient width for native heading scaling"
        end
      end
    end
    -- A stable plain layout keeps Markdown's rank markers. Paint-time image
    -- or native feedback retains its existing layout instead of inserting text.
    if plain_heading then
      plain_prefix = string.rep("#", level) .. " "
      rendered_text = plain_prefix .. rendered_text
      for _, hl in ipairs(md_highlights) do
        hl.col, hl.end_col = hl.col + #plain_prefix, hl.end_col + #plain_prefix
      end
      md_highlights[1].col = 0
      for _, link in ipairs(md_links) do
        link.col_start, link.col_end = link.col_start + #plain_prefix, link.col_end + #plain_prefix
      end
      for _, boundary in ipairs(hard_breaks) do
        boundary.col = boundary.col + #plain_prefix
      end
    end
  end
  local indent_w = vim.api.nvim_strwidth(indent)
  local wrap_max = math.max(1, max_width - indent_w)

  local lines_before_fn = #self.lines
  local image_added = level
    and rendered_text ~= ""
    and self.text_scale
    and image_heading
    and self:add_image_heading(rendered_text, md_highlights, md_links, indent, max_width, level)
  if spec then
    self:add_native_heading(rendered_text, md_highlights, md_links, indent, spec, level, max_width)
  elseif not image_added then
    if #hard_breaks > 0 or indent_w + vim.api.nvim_strwidth(rendered_text) > max_width then
      self:add_wrapped_markdown(
        rendered_text,
        md_highlights,
        md_links,
        indent,
        wrap_max,
        quote_prefix,
        list_marker,
        nil,
        hard_breaks,
        source_lines
      )
    else
      self:add_simple_markdown(rendered_text, md_highlights, md_links, indent)
    end
  end

  -- Register heading anchor (slug → rendered line)
  if heading_content then
    local slug = markdown.heading_slug(heading_content)
    if slug ~= "" then
      if self.heading_anchors[slug] ~= nil then
        table.insert(self.heading_duplicates, { slug = slug, line = lines_before_fn })
      else
        self.heading_anchors[slug] = lines_before_fn
      end
    end
    local offset = 0
    for row = lines_before_fn, #self.lines - 1 do
      local line = self.lines[row + 1]
      if row == lines_before_fn or line ~= "" then
        self.heading_lines[row] = true
        local prefix = row == lines_before_fn and (indent .. plain_prefix .. markdown.heading_icon_prefix(level))
          or (indent .. (line:sub(#indent + 1):match "^%s*" or ""))
        local fragment = line:sub(#prefix + 1)
        local first = heading_text:find(fragment, offset + 1, true)
        if first and fragment ~= "" then
          self.heading_positions[row + 1] = { byte = first - 1, col = #prefix, length = #fragment }
          offset = first - 1 + #fragment
        end
      end
    end
    if level <= 2 then
      local char = plain_heading and level == 1 and "═" or "─"
      local rule = indent
        .. string.rep(char, math.max(0, math.floor((max_width - indent_w) / vim.fn.strdisplaywidth(char))))
      self:add_line(rule, { { col = #indent, end_col = #rule, hl = "FloatBorder" } })
    end
  end

  if heading_quote ~= "" then
    for row = lines_before_fn + 1, #self.lines do
      if self.lines[row] ~= "" then
        table.insert(self.highlights, {
          line = row - 1,
          groups = { { col = #indent - #heading_quote, end_col = #indent, hl = "FloatBorder" } },
        })
      end
    end
  end

  -- Register footnote ref anchors (first occurrence per label)
  for _, link in ipairs(self.link_metadata) do
    if link.line >= lines_before_fn then
      local label = link.url and link.url:match "^#footnote%-def%-(.+)$"
      if label and not self.footnote_anchors["footnote-ref-" .. label] then
        self.footnote_anchors["footnote-ref-" .. label] = link.line
      end
    end
  end

  return alert_type, fold_mod
end

--- Apply alert styling to lines added between lines_before and current line count
---@param self MdRender.ContentBuilder
---@param lines_before integer Line count before adding the alert line(s)
---@param lines_after integer Line count after adding the alert line(s)
---@param alert_type string Alert type key (e.g. "NOTE", "WARNING")
---@param is_header boolean Whether this is the alert header line (with icon+label)
function ContentBuilder:apply_alert_styling(lines_before, lines_after, alert_type, is_header)
  local alert_hl = "MdRenderAlert" .. alert_type:sub(1, 1) .. alert_type:sub(2):lower()
  local alert_bg_hl = alert_hl .. "Bg"

  for _, hl_info in ipairs(self.highlights) do
    if hl_info.line >= lines_before and hl_info.line < lines_after then
      -- Replace FloatBorder highlights with alert-colored border
      for _, group in ipairs(hl_info.groups) do
        if group.hl == "FloatBorder" then group.hl = alert_hl end
      end

      -- On header line, add alert highlight for content after the bar
      if is_header and hl_info.line == lines_before then
        local line_text = self.lines[hl_info.line + 1]
        if line_text then
          -- Find end of blockquote prefix (after "│ ")
          local bar_end = 0
          for _, group in ipairs(hl_info.groups) do
            if group.hl == alert_hl then
              bar_end = group.end_col
              break
            end
          end
          if bar_end > 0 then table.insert(hl_info.groups, { col = bar_end, end_col = #line_text, hl = alert_hl }) end
        end
      end

      -- Add background highlight for the entire line
      table.insert(hl_info.groups, { col = 0, end_col = -1, hl = alert_bg_hl, hl_eol = true })
    end
  end

  -- Also handle lines that have no existing highlights
  for line_idx = lines_before, lines_after - 1 do
    local has_hl = false
    for _, hl_info in ipairs(self.highlights) do
      if hl_info.line == line_idx then
        has_hl = true
        break
      end
    end
    if not has_hl then
      table.insert(self.highlights, {
        line = line_idx,
        groups = { { col = 0, end_col = -1, hl = alert_bg_hl, hl_eol = true } },
      })
    end
  end
end

--- Pad a Nerd Font icon glyph so it always occupies 2 display cells.
--- When setcellwidths makes the glyph width 1, an extra space is appended.
---@param icon string single icon character
---@return string
local function pad_icon(icon)
  if vim.api.nvim_strwidth(icon) == 1 then return icon .. " " end
  return icon
end

local get_file_icon = icons.get_file_icon

--- Append a fold indicator (›/∨) to the end of a callout header line
---@param self MdRender.ContentBuilder
---@param line_idx integer 0-indexed rendered line
---@param is_collapsed boolean
function ContentBuilder:add_fold_indicator(line_idx, is_collapsed)
  local indicator = is_collapsed and (" " .. pad_icon "󰅂") or (" " .. pad_icon "󰅀")
  local line = self.lines[line_idx + 1]
  if not line then return end

  -- Append indicator at the end of the line (no highlight shifts needed)
  self.lines[line_idx + 1] = line .. indicator
end

--- Render a markdown document into the builder.
--- This is the shared rendering loop used by both PR body rendering and markdown preview.
---@param self MdRender.ContentBuilder
---@param lines string[] Pre-processed lines (already renumbered and cleaned)
---@param opts? MdRender.RenderDocumentOpts
--- Check if a line is a Markdown thematic break (---, ***, ___, etc.)
---@param line string
---@return boolean
local function is_thematic_break(line)
  local stripped = line:gsub("%s", "")
  if #stripped < 3 then return false end
  local ch = stripped:sub(1, 1)
  if ch ~= "-" and ch ~= "*" and ch ~= "_" then return false end
  return stripped == string.rep(ch, #stripped)
end

--- Strip the display wrapper tags supported by the renderer.
--- A nil result means a wrapper-only line with no display content.
---@param line string
---@return string?
local function unwrap_html_wrapper(line)
  -- Closing </div> or </span> on its own line
  if line:match "^%s*</div>%s*$" or line:match "^%s*</span>%s*$" then return nil end
  -- Opening <div>/<span> with no content on the same line
  if
    (line:match "^%s*<div>%s*$" or line:match "^%s*<div%s[^>]*>%s*$")
    or (line:match "^%s*<span>%s*$" or line:match "^%s*<span%s[^>]*>%s*$")
  then
    return nil
  end
  -- Single-line <div>...</div>: extract inner content
  local div_inner = line:match "^%s*<div[^>]*>%s*(.-)%s*</div>%s*$"
  if div_inner and div_inner:match "%S" then
    line = div_inner -- Fall through with extracted content
  end
  -- Single-line <span>...</span>: extract inner content
  local span_inner = line:match "^%s*<span[^>]*>%s*(.-)%s*</span>%s*$"
  if span_inner and span_inner:match "%S" then
    line = span_inner -- Fall through with extracted content
  end
  -- Opening <div>/<span> with content after the tag (no closing on same line)
  local div_rest = line:match "^%s*<div[^>]*>%s*(.+)$"
  if div_rest and not line:match "</div>" then
    line = div_rest -- Fall through with extracted content
  end
  local span_rest = line:match "^%s*<span[^>]*>%s*(.+)$"
  if span_rest and not line:match "</span>" then
    line = span_rest -- Fall through with extracted content
  end
  return line
end

--- Both comment syntaxes are opaque to every preprocessing pass. A type-2
--- HTML block also owns the entire closing line, whose suffix remains literal.
--- A nil suffix means this line is outside a comment; an empty one is hidden.
---@param state? 'html'|'obsidian'
---@param line string
---@return 'html'|'obsidian'|nil state, string? suffix
local function block_comment_step(state, line)
  if state == "obsidian" then
    local content = unwrap_html_wrapper(line)
    if content and content:match "^%s*%%%%%s*$" then return nil, "" end
    return state, ""
  end
  if not state then
    line = unwrap_html_wrapper(line)
    if not line then return nil, nil end
    if line:match "^%s*%%%%%s*$" then return "obsidian", "" end
    if not line:match "^%s*<!%-%-" then return nil, nil end
  end
  local _, close_end = line:find("-->", 1, true)
  if not close_end then return "html", "" end
  -- Other complete comments on the closing line are hidden too. The remaining
  -- text is still HTML-block content, so callers must not parse it as Markdown.
  local suffix = line:sub(close_end + 1):gsub("<!%-%-.-%-%->", "")
  return nil, suffix
end

--- Convert accumulated HTML table lines into pipe-table format lines.
--- Parses <tr>, <th>, <td> structure and extracts align attributes.
---@param html_lines string[] lines between <table> and </table> (inclusive)
---@return string[] pipe-table lines suitable for MarkdownTable.parse
local function html_table_to_pipe(html_lines)
  -- Inline rendering owns whitespace normalization inside each cell.
  local html = table.concat(html_lines, "\n")

  -- Extract rows from <tr>...</tr>
  local rows = {}
  for tr_content in html:gmatch "<tr[^>]*>(.-)</tr>" do
    local cells = {}
    local aligns = {}
    -- Match <th> or <td> with optional attributes
    for tag, attrs, content in tr_content:gmatch "<(t[hd])([^>]*)>(.-)</%1>" do
      -- Extract align attribute
      local align = attrs:match 'align%s*=%s*"([^"]*)"' or attrs:match "align%s*=%s*'([^']*)'"
      table.insert(aligns, align or "")
      -- Preserve the cell content as-is (inline HTML like <img>, <em> will be
      -- processed later by markdown.render / process_html_tags)
      local cell = content:gsub("^%s+", ""):gsub("%s+$", "")
      table.insert(cells, { text = cell, is_header = tag == "th" })
    end
    if #cells > 0 then table.insert(rows, { cells = cells, aligns = aligns }) end
  end

  if #rows == 0 then return {} end

  -- Determine column count
  local num_cols = 0
  for _, row in ipairs(rows) do
    num_cols = math.max(num_cols, #row.cells)
  end

  -- Determine if first row is a header row
  local has_header = false
  if rows[1] then has_header = rows[1].cells[1] and rows[1].cells[1].is_header end

  -- Build alignment from header or first data row
  local col_aligns = {}
  for col = 1, num_cols do
    local align = ""
    for _, row in ipairs(rows) do
      if row.aligns[col] and row.aligns[col] ~= "" then
        align = row.aligns[col]
        break
      end
    end
    col_aligns[col] = align
  end

  -- Build pipe-table lines
  local result = {}

  -- Header row
  local header_parts = {}
  if has_header then
    for col = 1, num_cols do
      local cell = rows[1].cells[col]
      header_parts[col] = cell and cell.text or ""
    end
  else
    -- No <th> found — use empty header
    for col = 1, num_cols do
      header_parts[col] = " "
    end
  end
  table.insert(result, "| " .. table.concat(header_parts, " | ") .. " |")

  -- Separator row with alignment
  local sep_parts = {}
  for col = 1, num_cols do
    local a = col_aligns[col]:lower()
    if a == "center" then
      sep_parts[col] = ":---:"
    elseif a == "right" then
      sep_parts[col] = "---:"
    else
      sep_parts[col] = "---"
    end
  end
  table.insert(result, "| " .. table.concat(sep_parts, " | ") .. " |")

  -- Data rows (skip first row if it was the header)
  local start = has_header and 2 or 1
  for i = start, #rows do
    local parts = {}
    for col = 1, num_cols do
      local cell = rows[i].cells[col]
      parts[col] = cell and cell.text or ""
    end
    table.insert(result, "| " .. table.concat(parts, " | ") .. " |")
  end

  return result
end

local Markdown = require "md-render.markdown"
local is_block_start = Markdown.is_block_start

--- Check if a line opens a list item (bullet or ordered).
--- A thematic break (`- - -`) shares the bullet's leading characters, so it
--- is excluded here.
---@param line string
---@return boolean
local function is_list_item(line, in_paragraph)
  return Markdown.list_marker_type(line, in_paragraph) ~= nil and not is_thematic_break(line)
end

local markdown_table = require "md-render.markdown_table"

--- Remove up to `n` leading spaces from a line (CommonMark dedents fenced
--- code content by the opening fence's indent, no further).
---@param line string
---@param n integer
---@return string
local function strip_indent(line, n)
  if n <= 0 then return line end
  local ws = line:match "^ *"
  return line:sub(math.min(#ws, n) + 1)
end

--- Split one blockquote marker level (`>` plus an optional space) off a line.
--- Only column 0 counts as a quote here, matching the rest of the renderer.
--- strip_quote_indent() has already moved indented quotes to column 0.
---@param line string
---@param column? integer original column before the quote marker
---@return string marker, string content, integer column
local function split_quote_marker(line, column, after_column)
  local marker, content = line:match "^(>[ \t]?)(.*)$"
  column = column or 0
  if marker:sub(-1) == "\t" then
    -- The optional space after > consumes only one column of a tab.
    content = string.rep(" ", 3 - (column + 1) % 4) .. content
    marker = "> "
  end
  return marker, content, after_column or column + #marker
end

-- Physical columns never come from the length of a generated quote prefix.
local function source_column(origins, src, depth)
  local origin = origins and origins[src]
  if not origin then return 0 end
  return depth and depth > 0 and origin.quote_columns[depth] or origin.column
end

--- Content column of a list item line: the column its text starts at, and
--- therefore the one its continuation lines and nested blocks are indented
--- to.
---@param line string
---@param column? integer original column before the list marker
---@return integer? column nil when the line does not open a list item
---@return string? content marker-free content at that column
local function list_content_column(line, column, in_paragraph)
  if not is_list_item(line, in_paragraph) then return nil end
  local _, _, prefix, content = Markdown.list_marker_type(line)
  local ws = prefix:match "^ *"
  local marker = prefix:sub(#ws + 1):match "^[^ \t]+"
  local gap = prefix:sub(#ws + #marker + 1)
  local start = (column or 0) + #ws + #marker
  local gap_width = fence_mod.indent_columns(gap, start)
  if content:match "^[ \t]*$" then
    gap_width, content = 1, ""
  end
  -- Five or more columns after the marker start indented code inside the item.
  if gap_width > 4 then content = string.rep(" ", gap_width - 1) .. content end
  return #ws + #marker + (gap_width > 0 and gap_width <= 4 and gap_width or 1), content
end

--- Track the real content columns of open list items, before inspecting fences.
local function list_container_column(line, item_cols, column, paragraph_column, accepted_item)
  local ws = #line:match "^ *"
  while #item_cols > 0 and ws < item_cols[#item_cols] do
    table.remove(item_cols)
  end
  local base = item_cols[#item_cols] or 0
  local col, content
  if accepted_item ~= false then
    col, content = list_content_column(line, column, paragraph_column == base)
  end
  -- Four columns beyond the parent content belong to indented code.
  if ws - base >= 4 then col = nil end
  if col then table.insert(item_cols, col) end
  return base, col, ws, content
end

--- Expand structural indentation; never call this on literal code content.
local function expand_leading_tabs(line, column)
  local ws = line:match "^[ \t]*"
  if not ws:find("\t", 1, true) then return line end
  return string.rep(" ", fence_mod.indent_columns(ws, column)) .. line:sub(#ws + 1)
end

--- Remove a container prefix in columns, retaining the unconsumed part of a tab.
local function strip_container_prefix(line, width, column)
  local pos, col = 1, column or 0
  local finish = col + width
  while col < finish do
    local c = line:sub(pos, pos)
    if c == " " then
      col = col + 1
    elseif c == "\t" then
      col = col + 4 - col % 4
    else
      break
    end
    pos = pos + 1
  end
  return string.rep(" ", math.max(0, col - finish)) .. line:sub(pos)
end

-- Canonical quote markers are parser scaffolding; literal content stays intact.
-- A wider gap is permitted only for the exact scaffold of an already-accepted
-- interleaved list owner. Callers discard those columns on an owner exit.
local function quote_content(line, column, limit, owner_columns)
  local columns = {}
  local prefix = ""
  while not limit or #columns < limit do
    local structural = expand_leading_tabs(line, column)
    local ws = #structural:match "^ *"
    local owner_gap = owner_columns
      and #columns > 0
      and owner_columns[#columns + 1]
      and owner_columns[#columns + 1] - owner_columns[#columns] - 2
    if (ws > 3 and ws ~= owner_gap) or structural:sub(ws + 1, ws + 1) ~= ">" then break end
    local _
    _, line, column = split_quote_marker(structural:sub(ws + 1), column + ws)
    -- Canonical markers preserve quote identity; intervening indent stays physical.
    prefix = prefix .. string.rep(" ", ws) .. "> "
    columns[#columns + 1] = column
  end
  return line, columns, column, prefix
end

-- Only accepted list scaffolding changes quote geometry. Physical gaps keep
-- list margins between borders; ordinary quotes retain the established layout.
local function quote_display_prefix(origin, list_column)
  if origin.list_column == nil then return nil end
  local prefix, previous = "", nil
  for _, column in ipairs(origin.quote_columns) do
    if previous then prefix = prefix .. string.rep(" ", math.max(0, column - previous - 2)) end
    prefix, previous = prefix .. "│ ", column
  end
  return prefix .. string.rep(" ", list_column or origin.list_column)
end

-- Peel only accepted same-row containers. Ordinary item paragraphs and tasks
-- retain their hanging-marker layout; block children use the existing renderers.
local function list_child_block(content, column)
  local structural = expand_leading_tabs(content, column)
  local ws = #structural:match "^ *"
  local _, columns = quote_content(content, column)
  return ws >= 4
    or parse_atx_heading(content) ~= nil
    or #columns > 0
    or fence_mod.opening(content, column) ~= nil
    or is_thematic_break(content)
    or (ws <= 3 and is_list_item(structural))
end

local function list_prefix_entry(line, base, origin, scaffold)
  local _, _, prefix = Markdown.list_marker_type(line)
  return {
    text = scaffold .. prefix,
    base = base,
    quote_columns = vim.deepcopy(origin.quote_columns),
    list_column = #origin.quote_columns > 0 and base or nil,
  }
end

local function peel_list_children(line, column, base, col, content, items, origin, scaffold)
  while col and list_child_block(content, column + col) do
    origin.list_prefixes = origin.list_prefixes or {}
    origin.list_prefixes[#origin.list_prefixes + 1] = list_prefix_entry(line, base, origin, scaffold)
    line = string.rep(" ", col) .. content
    local _
    base, col, _, content = list_container_column(line, items, column)
  end
  return line, base, col, content
end

local function quote_paragraph_line(line, column, missing_marker, container)
  line = expand_leading_tabs(line, column)
  container = container or 0
  if #line:match "^ *" >= container then
    line, column = line:sub(container + 1), column + container
  end
  if line:match "^%s*$" then return false end
  if line:match "^    " then return true end -- indented code cannot interrupt a paragraph
  -- A new unmarked list belongs outside the quote, even when its starting
  -- number could not interrupt the paragraph with every marker present.
  if missing_marker and is_list_item(line) then return false end
  local empty_number = line:match "^ *(%d+)[%.)]%s*$"
  if fence_mod.opening(line, column) or line:match "^ *[%-%*%+]%s*$" or (empty_number and #empty_number <= 9) then
    return false
  end
  -- Reuse the table leaf recognizer for inline HTML, images and autolinks.
  if line:match "^ *[<!]" then return markdown_table.is_body_row(line, true) end
  -- An omitted quote marker makes a possible underline paragraph text, never a heading.
  if missing_marker and Markdown.parse_setext_underline(line) and not is_thematic_break(line) then return true end
  return not is_block_start(line, true)
end

--- Move the content of a block container to column 0 and report the indent
--- that was taken off each line.
---
--- Two containers put their content past column 0.  A blockquote may carry up
--- to three spaces of indentation in front of its `>` (four is an indented
--- code block), and a list item puts everything that belongs to it at its
--- content column — the column its own text starts at.  The rest of the
--- renderer works on blocks that begin at column 0, so the indent is stripped
--- here and handed back to render_document, which puts it back as display
--- indent.  Indices are into the original `lines`, before any pass merges
--- lines together.
---
--- Without this a list item's second paragraph came out flush left: nothing
--- downstream knew the three spaces in front of it meant "inside item 2", and
--- wrap_words drops leading whitespace, so the indent survived only on a
--- paragraph short enough not to wrap.
---
--- What comes back is the *container's* content column, not the whitespace
--- that was taken off: the up-to-three spaces in front of a marker are not
--- content, so `   > a` at the top level renders flush left, while a quote
--- in a list item renders under the item.  Two quote lines belong to the
--- same blockquote only if they report the same column.
---
--- A list item's marker line keeps its indentation for hanging-indent layout.
--- Fences and their content lose only the container prefix, which the renderer
--- restores. Their remaining indentation is relative to that container.
---@param lines string[]
---@return string[] result, table<integer, string> indents, table origins, table<integer, integer> list_bases
local function strip_container_indent(lines)
  local result, indents, origins = {}, {}, {}
  local list_bases = {}
  local item_cols = {}
  local open_fence, fence_container = nil, 0
  local html
  local comment_state
  local comment_start
  local quote
  local empty_item
  local paragraph_column, table_column
  local paragraph_item
  local in_root_code, in_math = false, false
  local code_blanks = {}
  local code_container = 0

  local function own_indented_code(row, line, base)
    local origin = origins[row]
    origin.code, origin.column = true, base
    if base > 0 then indents[row] = string.rep(" ", base) end
    result[row] = strip_container_prefix(line, base)
    if code_container == base then
      for _, blank in ipairs(code_blanks) do
        origins[blank].code, origins[blank].column = true, base
        if base > 0 then indents[blank] = string.rep(" ", base) end
        result[blank] = strip_container_prefix(result[blank], base)
      end
    end
    in_root_code, code_container, code_blanks = true, base, {}
    paragraph_column, table_column, quote, paragraph_item = nil, nil, nil, nil
    if base == 0 then item_cols = {} end
  end

  local function expose_setext_item(item, last, quoted)
    local origin = origins[item.row]
    origin.list_prefixes = origin.list_prefixes or {}
    origin.list_prefixes[#origin.list_prefixes + 1] = item.prefix
    list_bases[item.row] = nil
    if quoted then
      result[item.row] = string.rep("> ", #origin.quote_columns) .. string.rep(" ", item.column) .. item.content
      for row = item.row, last do
        origins[row].list_column = item.column
        origins[row].ancestor_prefix = item.scaffold .. string.rep(" ", item.column)
      end
      quoted.child_base = item.column
      quoted.ancestor_prefix = item.scaffold .. string.rep(" ", item.column)
    else
      result[item.row], origin.column = item.content, item.column
      indents[item.row] = string.rep(" ", item.column)
    end
  end

  for i, line in ipairs(lines) do
    local origin = { column = 0, quote_columns = {} }
    origins[i] = origin
    if html then
      in_root_code, code_blanks = false, {}
      local blank = line:match "^[ \t]*$"
      local ws = fence_mod.indent_columns(line:match "^[ \t]*")
      if (html.kind >= 6 and blank) or (not blank and ws < html.container) then
        html = nil
      else
        origin.html, origin.column = html.src, html.container
        result[i] = strip_container_prefix(line, html.container)
        if html.container > 0 then indents[i] = string.rep(" ", html.container) end
        paragraph_column, table_column, quote, paragraph_item = nil, nil, nil, nil
        if html_block.ends(html.kind, result[i]) then html = nil end
        goto next_source
      end
    end
    if not open_fence and not comment_state and line:match "^%$%$$" then
      in_math = not in_math
      in_root_code, code_blanks = false, {}
      result[i] = line
      paragraph_column, table_column, quote, paragraph_item = nil, nil, nil, nil
      goto next_source
    end
    if in_math then
      result[i] = line
      goto next_source
    end
    -- End the previous item before the new row can establish literal ownership.
    if
      open_fence
      and fence_container > 0
      and not line:match "^[ \t]*$"
      and fence_mod.indent_columns(line:match "^[ \t]*") < fence_container
    then
      open_fence = nil
      origin.code = false
    end
    -- Settle root literal ownership before comments, quotes or list markers
    -- can claim the line. Keep tabs beyond the four structural columns intact.
    if not open_fence and not comment_state then
      local ws = fence_mod.indent_columns(line:match "^[ \t]*")
      local base = 0
      for _, col in ipairs(item_cols) do
        if col <= ws then base = col end
      end
      if in_root_code and line:match "^[ \t]*$" then
        code_blanks[#code_blanks + 1] = i
        result[i] = line
        goto next_source
      elseif
        not in_math
        and not paragraph_column
        and not (quote and quote.paragraph)
        and not (quote and #quote.items > 0)
        and ws - base >= 4
        and not line:match "^[ \t]*$"
      then
        own_indented_code(i, line, base)
        goto next_source
      end
    end
    in_root_code, code_blanks = false, {}
    -- Resolve missing quote markers before an unindented lazy row can pop
    -- its enclosing list. A real quote at another list column ends that owner.
    if quote and quote.paragraph and not open_fence and not comment_state then
      local structural = expand_leading_tabs(line)
      local ws = #structural:match "^ *"
      local base = 0
      for _, col in ipairs(item_cols) do
        if col <= ws then base = col end
      end
      local content, columns, column = structural, {}, 0
      local marked = structural:sub(ws + 1, ws + 1) == ">" and ws - base <= 3
      if marked then
        content, columns, column = quote_content(structural:sub(ws + 1), ws, nil, quote.columns)
      elseif ws >= quote.base then
        content, column = strip_container_prefix(line, quote.base), quote.base
      end
      if
        (not marked or base == quote.base)
        and #columns < quote.depth
        and quote_paragraph_line(content, column, true)
      then
        origin.column = marked and ws or column
        origin.quote_columns = columns
        for depth = #columns + 1, quote.depth do
          columns[depth] = column -- the virtual marker consumes no source columns
        end
        origin.continuation_depth = quote.depth
        origin.ancestor_prefix = quote.ancestor_prefix
        origin.list_column = quote.child_base
        result[i] = string.rep("> ", quote.depth) .. content
        if quote.base > 0 then indents[i] = string.rep(" ", quote.base) end
        goto next_source
      end
    end
    local was_in_comment = comment_state ~= nil
    local comment_suffix
    if not open_fence then
      comment_state, comment_suffix = block_comment_step(comment_state, line)
    end
    if comment_suffix ~= nil then
      paragraph_column, table_column, paragraph_item = nil, nil, nil
      quote = nil
      result[i] = line
      local structural_line = expand_leading_tabs(line)
      local ws = #structural_line:match "^ *"
      -- The opening line can leave an item; hidden body lines cannot change it.
      if not was_in_comment then list_container_column(structural_line, item_cols) end
      local base = item_cols[#item_cols] or 0
      if base > 0 and ws >= base then indents[i] = string.rep(" ", base) end
      if not was_in_comment then comment_start = i end
      if comment_state == "html" or (was_in_comment and comment_start) or line:find("<!--", 1, true) then
        origin.html = comment_start
      end
      local kind = not was_in_comment and html_block.start(strip_container_prefix(line, base), false, base)
      if kind then
        origin.html = i
        if not html_block.ends(kind, line) then html = { kind = kind, src = i, container = base } end
        comment_state = nil
      end
      if not comment_state then comment_start = nil end
    elseif open_fence then
      paragraph_column, table_column, paragraph_item = nil, nil, nil
      quote = nil
      local is_fence
      open_fence, is_fence, result[i] =
        fence_mod.step(open_fence, strip_container_prefix(line, fence_container), fence_container)
      origin.column = fence_container
      if fence_container > 0 then indents[i] = string.rep(" ", fence_container) end
      if fence_container > 0 then
        origin.code, origin.code_closer = true, is_fence
      end
      goto next_source
    else
      line = expand_leading_tabs(line)
      result[i] = line
      if not line:match "^%s*$" then
        local base, col, item_content = 0, nil, nil
        local lazy_item = paragraph_column
          and #item_cols > 0
          and #line:match "^ *" < paragraph_column
          and not is_list_item(line)
          and quote_paragraph_line(line, 0, true)
        if not lazy_item then
          local _
          base, col, _, item_content = list_container_column(line, item_cols, nil, paragraph_column)
        end
        local next_line = lines[i + 1] and expand_leading_tabs(lines[i + 1])
        line, base, col, item_content = peel_list_children(line, 0, base, col, item_content, item_cols, origin, "")
        local ws = #line:match "^ *"
        result[i] = line
        if col then list_bases[i] = base end
        empty_item = col and item_content == "" and col or nil
        local opens_item = col ~= nil
        if origin.list_prefixes and not col and ws - base >= 4 then
          own_indented_code(i, line, base)
          goto next_source
        end
        local is_fence, normalized
        open_fence, is_fence, normalized = fence_mod.step(nil, line:sub(base + 1), base)
        if is_fence then
          fence_container = base
          result[i], origin.column = normalized, base
          if base > 0 then indents[i] = string.rep(" ", base) end
          if base > 0 then
            origin.code, origin.code_opener = true, open_fence ~= nil
          end
        elseif line:match "^ *>" and ws >= base and ws - base <= 3 then
          if base > 0 then indents[i] = string.rep(" ", base) end
          result[i], origin.column = line:sub(ws + 1), ws
        elseif not col and base > 0 then
          indents[i] = string.rep(" ", base)
          result[i], origin.column = line:sub(base + 1), base
        end
        local leaf, leaf_column = line:sub(base + 1), base
        if opens_item then
          leaf, leaf_column = item_content, col
        end
        local html_kind = not is_fence
          and html_block.start(leaf, paragraph_column == leaf_column and not opens_item, leaf_column)
        if html_kind then
          origin.html = i
          paragraph_column, table_column, quote, paragraph_item = nil, nil, nil, nil
          if not html_block.ends(html_kind, leaf) then html = { kind = html_kind, src = i, container = leaf_column } end
          goto next_source
        end
        if next_line then
          next_line = #next_line:match "^ *" >= leaf_column and next_line:sub(leaf_column + 1) or nil
        end
        if
          (table_column == leaf_column and markdown_table.is_body_row(leaf))
          or markdown_table.parse_header(leaf, next_line)
        then
          table_column, paragraph_column, paragraph_item = leaf_column, nil, nil
        else
          table_column = nil
          if is_fence or result[i]:match "^>" then
            paragraph_column, paragraph_item = nil, nil
          elseif paragraph_column == leaf_column and Markdown.parse_setext_underline(leaf) then
            if paragraph_item then expose_setext_item(paragraph_item, i) end
            paragraph_column, paragraph_item = nil, nil
          elseif opens_item or not paragraph_column or is_block_start(leaf, true) then
            paragraph_column = not is_block_start(leaf, false) and leaf_column or nil
            paragraph_item = opens_item
                and paragraph_column
                and item_content ~= ""
                and {
                  row = i,
                  column = col,
                  content = item_content,
                  prefix = list_prefix_entry(line, base, origin, ""),
                }
              or nil
          end
        end
      else
        paragraph_column, table_column, paragraph_item = nil, nil, nil
        if empty_item and item_cols[#item_cols] == empty_item then table.remove(item_cols) end
        empty_item = nil
      end
    end

    if not result[i]:match "^>" then
      quote = nil
      goto next_source
    end
    local base = #(indents[i] or "")
    local limit = quote and quote.base == base and (quote.fence or quote.comment or quote.html) and quote.depth or nil
    local content, quote_columns, column, ancestor_prefix =
      quote_content(result[i], origin.column, limit, quote and quote.columns)
    -- A blank quote row may omit list indentation while keeping its quote ancestors.
    if
      quote
      and (quote.fence or quote.html)
      and quote.ancestor_prefix
      and not (content:match "^[ \t]*$" and vim.startswith(quote.ancestor_prefix, ancestor_prefix))
      and not vim.startswith(
        ancestor_prefix .. string.rep(" ", fence_mod.indent_columns(content:match "^[ \t]*", column)),
        quote.ancestor_prefix
      )
    then
      -- A quote outside the item can have more markers than the old code owner.
      quote, limit = nil, nil
      origin.code = false
      content, quote_columns, column, ancestor_prefix = quote_content(result[i], origin.column)
    end
    if not limit and fence_mod.indent_columns(content:match "^[ \t]*", column) <= 3 then
      content = expand_leading_tabs(content, column)
    end
    origin.quote_columns = quote_columns
    origin.ancestor_prefix = ancestor_prefix
      .. string.rep(" ", fence_mod.indent_columns(content:match "^[ \t]*", column))
    local depth = #quote_columns
    result[i] = string.rep("> ", depth) .. content
    if not quote or quote.base ~= base or quote.depth ~= depth then
      quote = { base = base, depth = depth, items = {}, paragraph = false }
    end
    if quote.html then
      local leaf = strip_container_prefix(content, quote.html.container, column)
      if quote.html.kind >= 6 and leaf:match "^[ \t]*$" then
        quote.html = nil
      else
        origin.html = quote.html.src
        origin.list_column = quote.child_base
        quote.paragraph, quote.paragraph_item = false, nil
        if html_block.ends(quote.html.kind, leaf) then quote.html = nil end
        goto next_source
      end
    end
    if quote.columns and not quote.fence then
      for level = 2, depth do
        if quote_columns[level] - quote_columns[level - 1] < quote.columns[level] - quote.columns[level - 1] then
          quote.paragraph, quote.child_base, quote.columns = false, nil, nil
          break
        end
      end
    end
    local next_content, next_columns
    local next_line = lines[i + 1]
    if next_line then
      next_line = expand_leading_tabs(next_line)
      local ws = #next_line:match "^ *"
      if ws >= base and ws - base <= 3 then
        next_content, next_columns = quote_content(next_line:sub(ws + 1), ws, nil, quote.columns)
      end
    end
    if
      not quote.fence
      and (
        (quote.table and markdown_table.is_body_row(content))
        or (next_columns and #next_columns == depth and markdown_table.parse_header(content, next_content))
      )
    then
      quote.table, quote.paragraph, quote.paragraph_item = true, false, nil
      goto next_source
    end
    quote.table = nil
    local was_paragraph = quote.paragraph
    if content:match "^%s*$" and quote.empty_item and quote.items[#quote.items] == quote.empty_item then
      table.remove(quote.items)
    end
    local sibling = is_list_item(content)
      and #quote.items > 0
      and #expand_leading_tabs(content, column):match "^ *" < quote.items[#quote.items]
    if quote.paragraph and not sibling and quote_paragraph_line(content, column, nil, quote.items[#quote.items]) then
      origin.continuation_depth = depth
      origin.ancestor_prefix = quote.ancestor_prefix
      origin.list_column = quote.child_base
      goto next_source
    end
    local quote_suffix
    local literal_child = quote.child_base ~= nil
      and not quote.paragraph
      and fence_mod.indent_columns(content:match "^[ \t]*", column) - quote.child_base >= 4
    if not quote.fence and not literal_child then
      quote.comment, quote_suffix = block_comment_step(quote.comment, content)
    end
    if quote_suffix ~= nil then
      quote.paragraph, quote.paragraph_item = false, nil
      goto next_source
    end
    local local_base, col, item_content = quote.items[#quote.items] or 0, nil, nil
    if not quote.fence and not content:match "^%s*$" then
      local _
      local_base, col, _, item_content = list_container_column(
        expand_leading_tabs(content, column),
        quote.items,
        column,
        quote.paragraph and (quote.items[#quote.items] or 0) or nil
      )
      local prefixes_before = #(origin.list_prefixes or {})
      content, local_base, col, item_content = peel_list_children(
        content,
        column,
        local_base,
        col,
        item_content,
        quote.items,
        origin,
        string.rep(" ", base) .. ancestor_prefix
      )
      if #(origin.list_prefixes or {}) > prefixes_before then quote.child_base = local_base end
      if quote.child_base and local_base < quote.child_base then quote.child_base = quote.columns and 0 or nil end
      if col then list_bases[i] = local_base end
    end
    origin.list_column = quote.child_base and local_base or nil
    -- Each accepted prefix consumes source bytes. Reuse the same marker
    -- decision after a quote exposes another item, retaining physical columns.
    while origin.list_column ~= nil do
      local inner = strip_container_prefix(content, local_base, column)
      local leaf, columns, leaf_column, scaffold = quote_content(inner, column + local_base)
      if #columns == 0 then break end
      ancestor_prefix = ancestor_prefix .. string.rep(" ", local_base) .. scaffold
      for _, next_column in ipairs(columns) do
        origin.quote_columns[#origin.quote_columns + 1] = next_column
      end
      content, column, depth = leaf, leaf_column, #origin.quote_columns
      origin.ancestor_prefix = ancestor_prefix
      quote = {
        base = base,
        depth = depth,
        items = {},
        paragraph = false,
        child_base = 0,
        columns = vim.deepcopy(origin.quote_columns),
      }
      local _
      local_base, col, _, item_content =
        list_container_column(expand_leading_tabs(content, column), quote.items, column)
      content, local_base, col, item_content = peel_list_children(
        content,
        column,
        local_base,
        col,
        item_content,
        quote.items,
        origin,
        string.rep(" ", base) .. ancestor_prefix
      )
      origin.list_column, quote.child_base = local_base, local_base
      list_bases[i] = col and local_base or nil
    end
    if origin.list_prefixes and not col then origin.ancestor_prefix = ancestor_prefix .. string.rep(" ", local_base) end
    result[i] = string.rep("> ", depth) .. content
    local leaf = content
    if col then leaf = item_content end
    quote.empty_item = col and leaf:match "^[ \t]*$" and col or nil
    local paragraph_leaf = col and leaf or strip_container_prefix(leaf, local_base, column)
    local html_kind = not quote.fence
      and html_block.start(paragraph_leaf, quote.paragraph and not col, column + (col or local_base))
    if html_kind then
      origin.html = i
      quote.paragraph = false
      quote.ancestor_prefix = ancestor_prefix .. string.rep(" ", col or local_base)
      if not html_block.ends(html_kind, paragraph_leaf) then
        quote.html = { kind = html_kind, src = i, container = col or local_base }
      end
      goto next_source
    end
    local is_fence
    quote.fence, is_fence = fence_mod.step(quote.fence, leaf, column, col and 0 or local_base)
    -- Later passes must not reopen fence-looking text inside literal code.
    origin.code_opener = is_fence and quote.fence ~= nil
    origin.code_closer = is_fence and quote.fence == nil
    origin.code = quote.fence ~= nil
      or is_fence
      or (not col and fence_mod.indent_columns(paragraph_leaf:match "^[ \t]*", column + local_base) >= 4)
    if quote.child_base ~= nil and not quote.fence and not is_fence then
      if content:match "^[ \t]*$" and quote.indented then
        quote.code_blanks = quote.code_blanks or {}
        quote.code_blanks[#quote.code_blanks + 1] = i
      elseif origin.code then
        for _, blank in ipairs(quote.code_blanks or {}) do
          origins[blank].code = true
        end
        quote.indented, quote.code_blanks = true, nil
      else
        quote.indented, quote.code_blanks = false, nil
      end
    end
    if was_paragraph and Markdown.parse_setext_underline(paragraph_leaf) and quote.paragraph_item then
      expose_setext_item(quote.paragraph_item, i, quote)
    end
    quote.paragraph = not origin.code
      and not (was_paragraph and Markdown.parse_setext_underline(paragraph_leaf))
      and not is_block_start(
        expand_leading_tabs(paragraph_leaf, column + (col or local_base)),
        not col and was_paragraph
      )
    if col and quote.paragraph then
      quote.paragraph_item = {
        row = i,
        column = col,
        content = item_content,
        scaffold = ancestor_prefix,
        prefix = list_prefix_entry(content, local_base, origin, string.rep(" ", base) .. ancestor_prefix),
      }
    elseif not quote.paragraph then
      quote.paragraph_item = nil
    end
    if quote.paragraph or origin.code_opener then
      quote.ancestor_prefix = ancestor_prefix .. string.rep(" ", col or local_base)
    end
    ::next_source::
  end

  return result, indents, origins, list_bases
end

-- Return the first row after a validated table, preserving source/container
-- boundaries before any pass can join cells or reinterpret their contents.
local function table_end(lines, idx, src_indices, container_indents)
  local src = src_indices[idx]
  local container = container_indents and container_indents[src] or ""
  if
    not markdown_table.parse_header(lines[idx], lines[idx + 1])
    or src_indices[idx + 1] ~= src + 1
    or (container_indents and container_indents[src_indices[idx + 1]] or "") ~= container
  then
    return nil
  end
  local last = idx + 2
  while
    last <= #lines
    and src_indices[last] == src + last - idx
    and (container_indents and container_indents[src_indices[last]] or "") == container
    and markdown_table.is_body_row(lines[last])
  do
    last = last + 1
  end
  return last
end

--- Join paragraph continuation rows into source strings, retaining soft breaks.
--- In CommonMark, consecutive lines that don't start block-level constructs
--- form a single paragraph. This is needed for inline constructs (like links)
--- that span multiple source lines, including mandatory display breaks.
---
--- `src_indices` is a parallel array giving the original buffer line
--- number for each input line. The returned `result_indices` carries the
--- original line number of the *first* line of each joined paragraph,
--- so `source_line_map` can point back to the real buffer position.
---@param lines string[]
---@param src_indices integer[]
---@param container_indents? table<integer, string> per original line, from
---   strip_container_indent(); quote lines in different containers must not be
---   collected into the same blockquote.
---@param ref_links? table<string, string>
---@param source_origins? table original columns and accepted quote paragraph rows
---@param fence_containers table<integer, integer> quote-local list columns at fence openings
---@param comments table<integer, {suffix: string, prefix: string}> comment-owned source rows
---@param quote_prefix? string display prefix of the current quote container
---@param reference_defs? table<integer, boolean> consumed original source rows
---@param paragraph_sources table<integer, integer[]> original rows by paragraph start
---@return string[] result, integer[] result_indices
local function join_paragraph_continuations(
  lines,
  src_indices,
  container_indents,
  ref_links,
  source_origins,
  fence_containers,
  comments,
  quote_prefix,
  reference_defs,
  paragraph_sources,
  list_bases,
  quote_depth
)
  quote_depth = quote_depth or 0
  --- Container a quote line belongs to, as its display indent.
  local function quote_container(idx)
    return container_indents and container_indents[src_indices[idx]] or ""
  end

  local result = {}
  local result_indices = {}
  local para = {}
  local para_indices = {}
  local item_cols = {}
  local open_fence = nil
  local in_math = false
  local comment_state
  local comment_indent = 0

  local function flush_para()
    if #para == 0 then return end
    paragraph_sources[para_indices[1]] = para_indices
    result[#result + 1] = wrap_mod.join_source_lines(para, ref_links)
    result_indices[#result_indices + 1] = para_indices[1]
    para, para_indices = {}, {}
  end

  local idx = 1
  while idx <= #lines do
    local line = lines[idx]
    local src = src_indices[idx]
    local line_origin = source_origins[src]
    if line_origin.list_prefixes then flush_para() end
    if
      #para > 0
      and quote_depth == #line_origin.quote_columns
      and line_origin.list_column ~= source_origins[para_indices[1]].list_column
    then
      flush_para()
    end
    local literal_code = line_origin.code and quote_depth == #line_origin.quote_columns
    -- A source boundary ends older local fence state at every quote depth.
    if line_origin.code == false or line_origin.code_opener then open_fence = nil end
    -- How many input lines this iteration consumed (a blockquote eats its
    -- whole run at once).
    local consumed = 1

    do
      local column = source_column(source_origins, src, quote_depth)
      local math_boundary = not line_origin.html
        and not quote_prefix
        and not open_fence
        and not comment_state
        and line:match "^%$%$$"
      if math_boundary then in_math = not in_math end
      if in_math or math_boundary then
        flush_para()
        table.insert(result, line)
        table.insert(result_indices, src)
        goto next_line
      end
      if line_origin.continuation_depth == quote_depth and not (reference_defs and reference_defs[src]) then
        table.insert(para, line)
        table.insert(para_indices, src)
        goto next_line
      end
      local was_in_comment = comment_state ~= nil
      local comment_suffix
      if not open_fence and not literal_code then
        comment_state, comment_suffix = block_comment_step(comment_state, line)
      end
      if comment_suffix ~= nil then
        if not was_in_comment then
          comment_indent = list_container_column(expand_leading_tabs(line, column), item_cols, column)
        end
        comments[src] = {
          suffix = comment_suffix,
          prefix = quote_prefix and (quote_prefix .. string.rep(" ", comment_indent)) or "",
        }
        flush_para()
        table.insert(result, line)
        table.insert(result_indices, src)
        goto next_line
      end

      if line_origin.html and quote_depth == #line_origin.quote_columns then
        flush_para()
        table.insert(result, line)
        table.insert(result_indices, src)
        goto next_line
      end

      -- Quote contents can still carry a list prefix; retain its real column
      -- for the renderer rather than guessing from the opening fence's indent.
      local base = 0
      if not open_fence and (not literal_code or line_origin.code_opener) and not line:match "^%s*$" then
        base = list_container_column(expand_leading_tabs(line, column), item_cols, column, nil, list_bases[src] ~= nil)
      end
      if quote_depth == #line_origin.quote_columns then base = line_origin.list_column or base end
      local is_fence
      if not literal_code or line_origin.code_opener then
        open_fence, is_fence, line = fence_mod.step(open_fence, line, column, base)
      elseif line_origin.code_closer then
        open_fence = nil
      end
      if is_fence and open_fence then fence_containers[src] = open_fence.container end
      local in_code = open_fence ~= nil or literal_code
      if not in_code and reference_defs and reference_defs[src] then
        flush_para()
        -- Keep the opaque block boundary until list numbering is complete.
        table.insert(result, line)
        table.insert(result_indices, src)
        goto next_line
      end

      -- A blockquote is a container of block content: strip one marker level
      -- off the whole run and recurse, so paragraphs (and list items) inside
      -- the quote join exactly as they do at the top level. Each output line
      -- gets back the marker of the line that started it.
      if not in_code and line:match "^>" then
        flush_para()
        local container = quote_container(idx)
        local inner, inner_src, markers = {}, {}, {}
        local last = idx
        while last <= #lines and lines[last]:match "^>" and quote_container(last) == container do
          local origin = source_origins[src_indices[last]]
          local marker, content = split_quote_marker(
            lines[last],
            source_column(source_origins, src_indices[last], quote_depth),
            origin.quote_columns[quote_depth + 1]
          )
          table.insert(inner, content)
          table.insert(inner_src, src_indices[last])
          markers[src_indices[last]] = marker
          last = last + 1
        end
        consumed = last - idx
        local joined, joined_src = join_paragraph_continuations(
          inner,
          inner_src,
          container_indents,
          ref_links,
          source_origins,
          fence_containers,
          comments,
          (quote_prefix or "") .. "│ ",
          reference_defs,
          paragraph_sources,
          list_bases,
          quote_depth + 1
        )
        for k, joined_line in ipairs(joined) do
          local marker = markers[joined_src[k]] or "> "
          -- A quote line with no content must not keep the marker's space.
          if joined_line == "" then marker = (marker:gsub("%s+$", "")) end
          table.insert(result, marker .. joined_line)
          table.insert(result_indices, joined_src[k])
        end
        goto next_line
      end

      -- Decide table ownership before paragraph joining can merge the header
      -- or an unpiped body row. Keep each row's original source boundary.
      local last_table_row = not in_code and not is_fence and table_end(lines, idx, src_indices, container_indents)
      if last_table_row then
        flush_para()
        for row = idx, last_table_row - 1 do
          table.insert(result, lines[row])
          table.insert(result_indices, src_indices[row])
        end
        consumed = last_table_row - idx
        goto next_line
      end

      -- A list item opens a paragraph of its own: the lines that follow it
      -- (indented to its content, or lazily unindented) belong to that same
      -- paragraph, so they must be joined onto the marker line.
      local starts_list_item = not in_code and list_bases[src] ~= nil and is_list_item(line)
      local empty_list_item = starts_list_item and select(4, Markdown.list_marker_type(line)):match "^[ \t]*$"
      local in_paragraph = #para > 0 or (is_list_item(line) and list_bases[src] == nil and not line:match "^    ")
      local block_line = quote_prefix and strip_container_prefix(line, base, column) or line

      if
        in_code
        or is_fence
        or empty_list_item
        or (is_block_start(block_line, in_paragraph) and not starts_list_item)
      then
        -- Flush accumulated paragraph
        flush_para()
        -- These lines always end their own output line, so a trailing hard
        -- break marker is redundant: drop it so it does not leave a stray
        -- trailing space (visible on highlighted lines such as blockquotes).
        -- Code/HTML keep literal whitespace; ATX owns its space/tab boundary.
        if not in_code and not line:match "^    %S" and not line:match "^%s*<" and not parse_atx_heading(line) then
          line = (line:gsub("%s+$", ""))
        end
        table.insert(result, line)
        table.insert(result_indices, src)
      else
        -- A new list item ends the previous paragraph rather than continuing it.
        if starts_list_item then flush_para() end
        table.insert(para, line)
        table.insert(para_indices, src)
      end

      ::next_line::
    end

    idx = idx + consumed
  end

  flush_para()

  return result, result_indices
end

--- Preserve physical boundaries while masking comments and validated tables.
local function preprocess_multiline_html(lines, src_indices, container_indents, source_origins)
  local comments, table_rows = {}, {}
  local open_fence, comment_state, comment_owner
  local in_math = false
  local masked = {}
  for index, line in ipairs(lines) do
    local origin = source_origins[src_indices[index]]
    masked[index] = (origin.code or origin.html) and "" or line
  end
  local _, _, definition_ends = Markdown.parse_reference_links(masked, source_origins, src_indices)
  local reference_end = 0
  for idx, line in ipairs(lines) do
    local src = src_indices[idx]
    local origin = source_origins[src]
    if origin.code then goto next_row end
    if idx <= reference_end then goto next_row end
    if comment_state == "html" and comment_owner ~= origin.html then comment_state = nil end
    local math_boundary = not origin.html and not open_fence and not comment_state and line:match "^%$%$$"
    if math_boundary then in_math = not in_math end
    if in_math or math_boundary or table_rows[src] then goto next_row end
    if not origin.html and not open_fence and not comment_state then
      local last = table_end(lines, idx, src_indices, container_indents)
      if last then
        for row = idx, last - 1 do
          table_rows[src_indices[row]] = true
        end
        goto next_row
      end
      reference_end = definition_ends[idx] or 0
      if reference_end >= idx then goto next_row end
    end
    if not open_fence then
      local suffix
      comment_state, suffix = block_comment_step(comment_state, line)
      if suffix ~= nil then
        comments[src] = { suffix = suffix, prefix = "" }
        comment_owner = origin.html
        goto next_row
      end
    end
    if not origin.html then open_fence = fence_mod.step(open_fence, line) end
    ::next_row::
  end
  return lines, src_indices, comments, table_rows
end

-- Collect literal ownership before references can affect paragraph code-span
-- scanning, including comments inside quotes. Keep original source rows so
-- later joins cannot move the boundary.
local function fenced_code_lines(
  lines,
  src_indices,
  container_indents,
  source_origins,
  comments,
  code_lines,
  quote_prefix,
  list_bases,
  quote_depth
)
  quote_depth = quote_depth or 0
  code_lines = code_lines or {}
  local open_fence, comment_state
  local in_math_block = false
  local comment_indent = 0
  local item_cols = {}
  local idx = 1
  while idx <= #lines do
    local line, src = lines[idx], src_indices[idx]
    local origin = source_origins[src]
    if origin.code == false then open_fence = nil end
    local column = source_column(source_origins, src, quote_depth)
    local was_in_comment = comment_state ~= nil
    local comment_suffix
    local math_delimiter = not origin.html
      and not quote_prefix
      and not open_fence
      and not comment_state
      and line:match "^%$%$$"
    if origin.code then
      code_lines[src] = true
      goto next_line
    end
    if origin.continuation_depth == quote_depth then goto next_line end
    if math_delimiter then in_math_block = not in_math_block end
    if in_math_block or math_delimiter then
      code_lines[src] = true
      goto next_line
    end
    if not open_fence then
      comment_state, comment_suffix = block_comment_step(comment_state, line)
    end
    if comment_suffix ~= nil then
      if not was_in_comment then
        comment_indent = list_container_column(expand_leading_tabs(line, column), item_cols, column)
      end
      comments[src] = {
        suffix = comment_suffix,
        prefix = quote_prefix and (quote_prefix .. string.rep(" ", comment_indent)) or "",
      }
    elseif origin.html and quote_depth == #origin.quote_columns then
      goto next_line
    else
      local base = 0
      if not open_fence and not line:match "^%s*$" then
        base = list_container_column(
          expand_leading_tabs(line, column),
          item_cols,
          column,
          nil,
          not list_bases or list_bases[src] ~= nil
        )
      end
      local is_fence
      open_fence, is_fence = fence_mod.step(open_fence, line, column, base)
      if open_fence or is_fence then
        code_lines[src] = true
      elseif line:match "^>" then
        local container = container_indents[src] or ""
        local inner, inner_src = {}, {}
        local last = idx
        while last <= #lines and lines[last]:match "^>" and (container_indents[src_indices[last]] or "") == container do
          local row_origin = source_origins[src_indices[last]]
          local _, content = split_quote_marker(
            lines[last],
            source_column(source_origins, src_indices[last], quote_depth),
            row_origin.quote_columns[quote_depth + 1]
          )
          table.insert(inner, content)
          table.insert(inner_src, src_indices[last])
          last = last + 1
        end
        fenced_code_lines(
          inner,
          inner_src,
          container_indents,
          source_origins,
          comments,
          code_lines,
          (quote_prefix or "") .. "│ ",
          list_bases,
          quote_depth + 1
        )
        idx = last - 1
      end
    end
    ::next_line::
    idx = idx + 1
  end
  return code_lines
end

-- Keep literal boundaries as blank rows so definitions cannot continue across
-- them. Code, comments and already-owned rows cannot define document references.
local function definition_lines(lines, src_indices, comments, code_lines, opaque_rows, source_origins)
  local result = {}
  for i, line in ipairs(lines) do
    local src = src_indices[i]
    result[i] = (comments[src] or code_lines[src] or opaque_rows[src] or source_origins[src].html) and "" or line
  end
  return result
end

function ContentBuilder:render_document(lines, opts)
  opts = opts or {}
  local markdown = require "md-render.markdown"

  -- Track each transformed line back to its original buffer line so
  -- source_line_map records real buffer positions, not post-transform
  -- array indices.
  local src_indices = {}
  for i = 1, #lines do
    src_indices[i] = i
  end
  -- The content of a blockquote or list item is moved to column 0 here;
  -- container_indents keeps the indent per *original* line so the loop below
  -- can restore it on output.
  local container_indents, source_origins, list_bases
  local fence_containers = {}
  local comments, table_rows
  lines, container_indents, source_origins, list_bases = strip_container_indent(lines)
  lines, src_indices, comments, table_rows =
    preprocess_multiline_html(lines, src_indices, container_indents, source_origins)
  local code_lines =
    fenced_code_lines(lines, src_indices, container_indents, source_origins, comments, nil, nil, list_bases)
  local ref_links, consumed_refs = markdown.parse_reference_links(
    definition_lines(lines, src_indices, comments, code_lines, table_rows, source_origins),
    source_origins,
    src_indices
  )
  local reference_defs = {}
  for index in pairs(consumed_refs) do
    reference_defs[src_indices[index]] = true
  end
  local paragraph_sources = {}
  lines, src_indices = join_paragraph_continuations(
    lines,
    src_indices,
    container_indents,
    ref_links,
    source_origins,
    fence_containers,
    comments,
    nil,
    reference_defs,
    paragraph_sources,
    list_bases
  )
  -- Display numbering can grow beyond the nine-digit source marker limit.
  local source_list_lines = lines
  local html_lines = {}
  for src, origin in pairs(source_origins) do
    if origin.html then html_lines[src] = true end
  end
  lines = markdown.renumber_ordered_lists(
    lines,
    vim.tbl_extend("force", code_lines, comments, table_rows, reference_defs, html_lines),
    src_indices,
    container_indents,
    list_bases,
    source_origins
  )
  -- renumber_ordered_lists rewrites text but keeps line count, so
  -- src_indices stays valid.
  local footnote_defs, footnote_map = markdown.parse_footnotes(
    definition_lines(
      lines,
      src_indices,
      comments,
      code_lines,
      vim.tbl_extend("force", table_rows, reference_defs),
      source_origins
    )
  )

  -- Only display semantics may span raw rows. Their physical boundaries have
  -- already survived definition extraction, paragraph joining and numbering.
  local html_groups, html_rows, html_headings, html_heading_rows = {}, {}, {}, {}
  for index, line in ipairs(lines) do
    local src = src_indices[index]
    local origin = source_origins[src]
    if origin.html then
      local group = html_groups[origin.html] or { lines = {}, sources = {}, blanks = {} }
      html_groups[origin.html] = group
      local column = origin.column
      for depth = 1, #origin.quote_columns do
        local _
        _, line, column = split_quote_marker(line, column, origin.quote_columns[depth])
      end
      local marker = ""
      if src == origin.html and list_bases[src] ~= nil then
        local source_marker = line:match "^( *[-*+][ \t]+)" or line:match "^( *%d+[.)][ \t]+)"
        if source_marker then
          marker = markdown.render(source_marker)
          line = line:sub(#source_marker + 1)
        end
      end
      group.blanks[#group.lines + 1] = line:match "^[ \t]*$" ~= nil
      line = unwrap_html_wrapper(line) or ""
      local p_content = line:match "^%s*<p[^>]*>%s*(.-)%s*</p>%s*$"
      group.lines[#group.lines + 1] = marker .. (p_content or line)
      group.sources[#group.sources + 1] = src
    end
  end
  for _, group in pairs(html_groups) do
    local index = 1
    while index <= #group.lines do
      local level, first = group.lines[index]:match "^%s*<h([1-6])[^>]*>(.*)$"
      if level then
        local parts, last = {}, index
        while last <= #group.lines do
          local part = last == index and first or group.lines[last]
          local before = part:match("^(.-)</h" .. level .. ">%s*$")
          parts[#parts + 1] = before or part
          if before then
            html_headings[group.sources[index]] =
              { level = tonumber(level), content = wrap_mod.join_source_lines(parts) }
            for row = index + 1, last do
              html_heading_rows[group.sources[row]] = true
            end
            index = last
            break
          end
          last = last + 1
        end
      end
      index = index + 1
    end
    local text, highlights, links = markdown.render_html(table.concat(group.lines, "\n"))
    local rows = vim.split(text, "\n", { plain = true })
    local starts, offset = {}, 0
    for row_index, row in ipairs(rows) do
      starts[row_index], offset = offset, offset + #row + 1
    end
    local row_highlights = distribute_highlights(highlights, rows, starts, "", "", 0)
    for row_index, src in ipairs(group.sources) do
      html_rows[src] =
        { text = rows[row_index], highlights = row_highlights[row_index], links = {}, blank = group.blanks[row_index] }
    end
    for _, link in ipairs(distribute_links(links, rows, starts, "", "", 0, 0)) do
      local row = html_rows[group.sources[link.line + 1]]
      link.line = nil
      row.links[#row.links + 1] = link
    end
  end

  local base_max_width = opts.max_width or 80
  local base_indent = opts.indent or "  "
  local max_lines = opts.max_lines or math.huge
  local repo_base_url = opts.repo_base_url
  local autolinks = opts.autolinks
  local fold_state = opts.fold_state or {}
  local expand_state = opts.expand_state or {}
  local source_line_offset = opts.source_line_offset or 0
  local buf_dir = opts.buf_dir or vim.fn.expand "%:p:h"
  -- Scaled headings reserve rendered rows, so a caller that will never paint
  -- them (a picker preview, say) has to say so before the content is built or
  -- it gets a stray blank line under every heading.
  self.text_scale = opts.text_scale ~= false
  self.heading_normal = opts.heading_normal

  local in_code_block = false
  local code_block_lang = nil
  local code_block_start = nil
  local code_source_lines = nil
  local code_block_id = nil
  local code_block_has_truncation = false
  -- Leading whitespace of the opening fence, e.g. a fence nested under a
  -- list item. Content lines are dedented by it and re-indented on output,
  -- so the block lines up with the item it belongs to.
  local code_fence_indent = ""
  local code_container_indent = ""
  -- The opening fence, which decides what may close the block.
  local code_fence = nil
  local prev_was_heading = false
  local prev_was_hr = false
  local prev_rendered_blank = false
  local prev_list_marker_type = nil
  local lines_shown = 0
  local table_buf = {}
  local table_buf_start_idx = nil
  -- Display indent of the container the table sits in, taken from its first
  -- line: the rows are accumulated and rendered together, so the indent of
  -- whichever line happens to flush the buffer is not the table's own.
  local table_buf_indent = ""
  local truncated = false
  local current_alert_type = nil
  local alert_container, alert_depth
  local skip_callout_body = false
  local in_callout_code_block = false
  local callout_code_lang = nil
  local callout_code_fence = nil
  local callout_code_start = nil
  local callout_code_prefix = nil
  local callout_code_depth, callout_code_container
  local callout_code_source_lines = nil
  local callout_code_block_id = nil
  local callout_code_has_truncation = false
  local in_math_block = false
  local skip_next_line = false
  local in_details = false
  local details_src_idx = nil
  local details_default_open = false
  local details_summary_rendered = false
  local details_depth = 0
  local in_details_summary = false
  local details_summary_parts = {}
  local details_summary_owner, details_summary_src
  local in_figure = false
  local figure_owner, figure_indent, figure_width
  local figure_caption = nil
  -- Original buffer line of the <figcaption> tag, captured at parse
  -- time so we can stamp source_line_map under it when the caption is
  -- actually rendered at </figure>.
  local figure_caption_src = nil
  local in_p_tag = false
  local skip_details_body = false
  local in_qiita_note = false
  local qiita_note_type = nil
  local in_dl = false
  local dl_owner
  local in_html_table = false
  local html_table_lines = {}
  local html_table_src_idx = nil
  local html_table_depth = 0
  local html_table_owner
  local html_table_sources = {}

  local function finish_quote_code()
    if callout_code_lang and callout_code_start < #self.lines then
      table.insert(self.code_blocks, {
        language = callout_code_lang,
        start_line = callout_code_start,
        end_line = #self.lines - 1,
        prefix_len = #callout_code_prefix,
        source_lines = callout_code_source_lines,
      })
    end
    if callout_code_has_truncation or expand_state[callout_code_block_id] then
      table.insert(self.expandable_regions, {
        start_line = callout_code_start,
        end_line = #self.lines - 1,
        block_id = callout_code_block_id,
        expanded = expand_state[callout_code_block_id] or false,
      })
    end
    in_callout_code_block, callout_code_fence, callout_code_lang = false, nil, nil
    callout_code_source_lines, callout_code_block_id = nil, nil
  end

  --- Flush accumulated table lines
  local function flush_table()
    if #table_buf > 0 then
      local lines_before_tbl = #self.lines
      local tbl_expanded = table_buf_start_idx and expand_state[table_buf_start_idx]
      -- The trigger line (e.g. the blank after the table) has already
      -- advanced _current_source_line. Stamp the table's first source
      -- line so add_table's emissions land in source_line_map under the
      -- table itself, then restore for the caller.
      local saved_src_line = self._current_source_line
      if table_buf_start_idx then self._current_source_line = table_buf_start_idx + source_line_offset end
      self:add_table(
        table_buf,
        base_indent .. table_buf_indent,
        math.max(1, base_max_width - #table_buf_indent),
        repo_base_url,
        autolinks,
        tbl_expanded or false,
        buf_dir,
        true,
        ref_links
      )
      self._current_source_line = saved_src_line
      local lines_added = #self.lines - lines_before_tbl
      lines_shown = lines_shown + lines_added
      local has_truncation = false
      if not tbl_expanded then
        for li = lines_before_tbl + 1, #self.lines do
          if self.lines[li] and self.lines[li]:match "…" then
            has_truncation = true
            break
          end
        end
      end
      if has_truncation or tbl_expanded then
        table.insert(self.expandable_regions, {
          start_line = lines_before_tbl,
          end_line = #self.lines - 1,
          block_id = table_buf_start_idx,
          expanded = tbl_expanded or false,
        })
      end
      table_buf = {}
      table_buf_start_idx = nil
      table_buf_indent = ""
    end
  end

  --- Render a <details> summary header with fold indicator
  local function render_details_summary(summary_text, raw_html)
    local is_collapsed
    if fold_state[details_src_idx] ~= nil then
      is_collapsed = fold_state[details_src_idx]
    else
      is_collapsed = not details_default_open
    end

    local det_lines_before = #self.lines
    local det_icon = is_collapsed and "▶ " or "▼ "
    local det_rendered, det_hls, det_links =
      markdown.render(summary_text, repo_base_url, autolinks, ref_links, nil, true, { raw_html = raw_html })

    local det_icon_len = #det_icon
    for _, hl in ipairs(det_hls) do
      hl.col = hl.col + det_icon_len
      hl.end_col = hl.end_col + det_icon_len
    end
    for _, link in ipairs(det_links) do
      link.col_start = link.col_start + det_icon_len
      link.col_end = link.col_end + det_icon_len
    end

    local det_full = det_icon .. det_rendered
    table.insert(det_hls, 1, { col = 0, end_col = #det_full, hl = "Title" })

    self:add_simple_markdown(det_full, det_hls, det_links, base_indent)

    table.insert(self.callout_folds, {
      header_line = det_lines_before,
      source_line = details_src_idx,
      collapsed = is_collapsed,
    })

    if is_collapsed then skip_details_body = true end

    details_summary_rendered = true
    lines_shown = lines_shown + (#self.lines - det_lines_before)
  end

  local function finish_details_summary(src)
    local saved_source = self._current_source_line
    self:set_source_line((src or details_summary_src) + source_line_offset)
    local joined = wrap_mod.join_source_lines(details_summary_parts)
    render_details_summary(joined ~= "" and joined or "Details", details_summary_owner ~= nil)
    self._current_source_line = saved_source
    in_details_summary, details_summary_parts = false, {}
    details_summary_owner, details_summary_src = nil, nil
  end

  --- Apply │ prefix and FloatBorder highlight to lines rendered within a <details> body
  local function apply_details_body_prefix(from_line, to_line)
    local prefix = "│ "
    local prefix_len = #prefix
    local indent_len = #base_indent

    for i = from_line + 1, to_line do
      local line_text = self.lines[i]
      self.lines[i] = line_text:sub(1, indent_len) .. prefix .. line_text:sub(indent_len + 1)
      local position = self.heading_positions[i]
      if position then position.col = position.col + prefix_len end
    end

    for _, hl_info in ipairs(self.highlights) do
      if hl_info.line >= from_line and hl_info.line < to_line then
        for _, group in ipairs(hl_info.groups) do
          group.col = group.col + prefix_len
          if group.end_col >= 0 then group.end_col = group.end_col + prefix_len end
        end
        table.insert(hl_info.groups, 1, {
          col = indent_len,
          end_col = indent_len + prefix_len,
          hl = "MdRenderDetailsBar",
        })
        table.insert(hl_info.groups, { col = 0, end_col = -1, hl = "MdRenderDetailsBg", hl_eol = true })
      end
    end

    for line_idx = from_line, to_line - 1 do
      local has_hl = false
      for _, hl_info in ipairs(self.highlights) do
        if hl_info.line == line_idx then
          has_hl = true
          break
        end
      end
      if not has_hl then
        table.insert(self.highlights, {
          line = line_idx,
          groups = {
            { col = indent_len, end_col = indent_len + prefix_len, hl = "MdRenderDetailsBar" },
            { col = 0, end_col = -1, hl = "MdRenderDetailsBg", hl_eol = true },
          },
        })
      end
    end

    -- Text placements use byte columns, including the separately painted icon.
    for _, placement in ipairs(self.text_placements) do
      if placement.line >= from_line and placement.line < to_line then
        placement.col = placement.col + prefix_len
        if placement.icon_col then placement.icon_col = placement.icon_col + prefix_len end
      end
    end

    for _, link in ipairs(self.link_metadata) do
      if link.line >= from_line and link.line < to_line then
        link.col_start = link.col_start + prefix_len
        link.col_end = link.col_end + prefix_len
      end
    end

    local prefix_cols = vim.api.nvim_strwidth(prefix)
    for _, placement in ipairs(self.image_placements) do
      if placement.line >= from_line and placement.line < to_line then
        placement.col = placement.col + prefix_cols
        if placement.cell_col then placement.cell_col = placement.cell_col + prefix_cols end
      end
    end

    for _, cb in ipairs(self.code_blocks) do
      if cb.start_line >= from_line and cb.end_line < to_line then
        cb.prefix_len = (cb.prefix_len or indent_len) + prefix_len
      end
    end
  end

  -- Only an accepted paragraph can own an underline in the same physical container.
  local function setext_level(idx, content, depth)
    local src, next_src = src_indices[idx], src_indices[idx + 1]
    local sources, origin, next_origin = paragraph_sources[src], source_origins[src], source_origins[next_src]
    if
      not sources
      or not next_origin
      or next_src ~= sources[#sources] + 1
      or origin.code
      or origin.html
      or next_origin.code
      or next_origin.html
      or is_list_item(content)
      or (container_indents[src] or "") ~= (container_indents[next_src] or "")
      or #origin.quote_columns ~= #next_origin.quote_columns
      or origin.list_column ~= next_origin.list_column
      or (depth > 0 and next_origin.continuation_depth == depth)
    then
      return nil
    end
    local underline = lines[idx + 1]
    for _ = 1, depth do
      if not underline:match "^>" then return nil end
      underline = underline:gsub("^>[ \t]?", "", 1)
    end
    if origin.list_column then
      underline = strip_container_prefix(underline, origin.list_column, next_origin.quote_columns[depth])
    end
    return markdown.parse_setext_underline(underline)
  end

  local function render_html_row(src, display_indent, quote_prefix)
    local row = html_rows[src]
    if not row or (row.text == "" and not row.blank) then return end
    local saved_source = self._current_source_line
    self:set_source_line(src + source_line_offset)
    local before = #self.lines
    local text = quote_prefix .. row.text
    local highlights, links = vim.deepcopy(row.highlights), vim.deepcopy(row.links)
    for _, hl in ipairs(highlights) do
      hl.col, hl.end_col = hl.col + #quote_prefix, hl.end_col + #quote_prefix
    end
    for _, link in ipairs(links) do
      link.col_start, link.col_end = link.col_start + #quote_prefix, link.col_end + #quote_prefix
    end
    if quote_prefix ~= "" then table.insert(highlights, 1, { col = 0, end_col = #quote_prefix, hl = "FloatBorder" }) end
    local width = base_max_width - vim.api.nvim_strwidth(display_indent)
    if in_details and details_summary_rendered then width = width - vim.fn.strdisplaywidth "│ " end
    if vim.api.nvim_strwidth(text) > width then
      self:add_wrapped_markdown(text, highlights, links, display_indent, math.max(1, width), quote_prefix)
    else
      self:add_simple_markdown(text, highlights, links, display_indent)
    end
    if in_details and details_summary_rendered and not skip_details_body then
      apply_details_body_prefix(before, #self.lines)
    end
    lines_shown = lines_shown + #self.lines - before
    self._current_source_line = saved_source
  end

  local function release_html_table()
    for _, src in ipairs(html_table_sources) do
      render_html_row(
        src,
        base_indent .. (container_indents[src] or ""),
        string.rep("│ ", #source_origins[src].quote_columns)
      )
    end
    in_html_table, html_table_lines, html_table_sources, html_table_owner = false, {}, {}, nil
    html_table_src_idx = nil
  end

  local function render_figure_caption(indent, max_width)
    -- Render figcaption centered (captured during figure body processing).
    -- Keep supported tags such as <em>/<strong> while preserving raw text,
    -- and wrap long captions instead of overflowing the window.
    if figure_caption then
      -- Trigger line is </figure>; restore the figcaption's own
      -- source line so its render rows are attributed to it.
      local saved_src_line = self._current_source_line
      if figure_caption_src then self._current_source_line = figure_caption_src + source_line_offset end
      local rendered_text, md_highlights, md_links = markdown.render(
        figure_caption,
        repo_base_url,
        autolinks,
        ref_links,
        footnote_map,
        true,
        { raw_html = source_origins[figure_caption_src].html ~= nil }
      )
      -- Apply Comment as the base highlight covering the whole caption
      table.insert(md_highlights, 1, {
        col = 0,
        end_col = #rendered_text,
        hl = "Comment",
      })

      local indent_width = vim.api.nvim_strwidth(indent)
      local available = math.max(1, max_width - indent_width)
      local wrapped_lines, line_starts
      if vim.api.nvim_strwidth(rendered_text) > available then
        wrapped_lines, line_starts = wrap_words(rendered_text, available)
      else
        wrapped_lines, line_starts = { rendered_text }, { 0 }
      end

      local base_line = #self.lines
      for idx, wline in ipairs(wrapped_lines) do
        local line_width = vim.api.nvim_strwidth(wline)
        local pad = math.max(0, math.floor((max_width - line_width) / 2) - indent_width)
        local prefix_len = #indent + pad
        local padded = indent .. string.rep(" ", pad) .. wline
        local line_start = line_starts[idx] or 0
        local line_end_pos = line_start + #wline

        local line_hls = {}
        for _, hl in ipairs(md_highlights) do
          if hl.end_col > line_start and hl.col < line_end_pos then
            local local_start = math.max(0, hl.col - line_start)
            local local_end = math.min(#wline, hl.end_col - line_start)
            table.insert(line_hls, {
              col = prefix_len + local_start,
              end_col = prefix_len + local_end,
              hl = hl.hl,
            })
          end
        end
        self:add_line(padded, #line_hls > 0 and line_hls or nil)

        for _, link in ipairs(md_links) do
          if link.col_end > line_start and link.col_start < line_end_pos then
            local local_start = math.max(0, link.col_start - line_start)
            local local_end = math.min(#wline, link.col_end - line_start)
            table.insert(self.link_metadata, {
              line = base_line + idx - 1,
              col_start = prefix_len + local_start,
              col_end = prefix_len + local_end,
              url = link.url,
            })
          end
        end

        lines_shown = lines_shown + 1
      end
      figure_caption = nil
      figure_caption_src = nil
      self._current_source_line = saved_src_line
    end
  end

  local function finish_code_block(indent, max_width)
    -- Mermaid code blocks: render as image if possible
    local mermaid_handled = false
    if code_block_lang and code_block_lang:lower() == "mermaid" and code_source_lines and #code_source_lines > 0 then
      local image = require "md-render.image"
      if image.supports_kitty() and image.has_mmdc() then
        local mermaid_source = table.concat(code_source_lines, "\n")
        -- Remove the code lines that were already added as text
        local lines_to_remove = #self.lines - code_block_start
        for _ = 1, lines_to_remove do
          table.remove(self.lines)
          table.remove(self.highlights)
        end

        -- Only use cached result synchronously; otherwise render async
        local cached = image.get_mermaid_cached(mermaid_source)
        local display_cols, display_rows
        local orig_img_w, orig_img_h
        local img_max_cols = max_width - 2

        if cached then
          orig_img_w, orig_img_h = image.image_dimensions(cached)
          if orig_img_w and orig_img_h then
            display_cols, display_rows =
              image.calc_display_size(orig_img_w, orig_img_h, img_max_cols, opts.image_max_height or 25)
          end
        end

        if not display_cols then
          display_cols = math.floor(img_max_cols * 0.8)
          display_rows = 15
        end

        local header = indent .. "Mermaid"
        self:add_line(header, {
          { col = 0, end_col = #header, hl = "Comment" },
        })
        local img_start_line = #self.lines
        local img_col = math.max(0, math.floor((max_width - display_cols) / 2))
        if not cached then
          local placeholder_msg = "Rendering mermaid diagram..."
          local placeholder_row = math.floor(display_rows / 2)
          for r = 1, display_rows do
            if r == placeholder_row + 1 then
              local pad = math.max(0, math.floor((display_cols - vim.api.nvim_strwidth(placeholder_msg)) / 2))
              local placeholder_line = indent .. string.rep(" ", img_col) .. string.rep(" ", pad) .. placeholder_msg
              self:add_line(placeholder_line, {
                { col = 0, end_col = #placeholder_line, hl = "Comment" },
              })
            else
              self:add_line(indent)
            end
          end
        else
          for _ = 1, display_rows do
            self:add_line(indent)
          end
        end
        table.insert(self.image_placements, {
          path = cached,
          line = img_start_line,
          col = img_col,
          rows = display_rows,
          cols = display_cols,
          img_w = orig_img_w,
          img_h = orig_img_h,
          mermaid_source = not cached and mermaid_source or nil,
        })
        lines_shown = lines_shown + 1 + display_rows
        mermaid_handled = true
      end
    end

    -- PlantUML code blocks: render as image if possible
    local plantuml_handled = false
    if
      not mermaid_handled
      and code_block_lang
      and (code_block_lang:lower() == "plantuml" or code_block_lang:lower() == "puml")
      and code_source_lines
      and #code_source_lines > 0
    then
      local image = require "md-render.image"
      if image.supports_kitty() and image.has_plantuml() then
        local plantuml_source = table.concat(code_source_lines, "\n")
        -- Remove the code lines that were already added as text
        local lines_to_remove = #self.lines - code_block_start
        for _ = 1, lines_to_remove do
          table.remove(self.lines)
          table.remove(self.highlights)
        end

        -- Only use cached result synchronously; otherwise render async
        local cached = image.get_plantuml_cached(plantuml_source)
        local display_cols, display_rows
        local orig_img_w, orig_img_h
        local img_max_cols = max_width - 2

        if cached then
          orig_img_w, orig_img_h = image.image_dimensions(cached)
          if orig_img_w and orig_img_h then
            display_cols, display_rows =
              image.calc_display_size(orig_img_w, orig_img_h, img_max_cols, opts.image_max_height or 25)
          end
        end

        if not display_cols then
          display_cols = math.floor(img_max_cols * 0.8)
          display_rows = 15
        end

        local header = indent .. "PlantUML"
        self:add_line(header, {
          { col = 0, end_col = #header, hl = "Comment" },
        })
        local img_start_line = #self.lines
        local img_col = math.max(0, math.floor((max_width - display_cols) / 2))
        if not cached then
          local placeholder_msg = "Rendering PlantUML diagram..."
          local placeholder_row = math.floor(display_rows / 2)
          for r = 1, display_rows do
            if r == placeholder_row + 1 then
              local pad = math.max(0, math.floor((display_cols - vim.api.nvim_strwidth(placeholder_msg)) / 2))
              local placeholder_line = indent .. string.rep(" ", img_col) .. string.rep(" ", pad) .. placeholder_msg
              self:add_line(placeholder_line, {
                { col = 0, end_col = #placeholder_line, hl = "Comment" },
              })
            else
              self:add_line(indent)
            end
          end
        else
          for _ = 1, display_rows do
            self:add_line(indent)
          end
        end
        table.insert(self.image_placements, {
          path = cached,
          line = img_start_line,
          col = img_col,
          rows = display_rows,
          cols = display_cols,
          img_w = orig_img_w,
          img_h = orig_img_h,
          plantuml_source = not cached and plantuml_source or nil,
        })
        lines_shown = lines_shown + 1 + display_rows
        plantuml_handled = true
      end
    end

    if not mermaid_handled and not plantuml_handled then
      if code_block_lang and code_block_start < #self.lines then
        local cb_prefix = #indent + #code_fence_indent
        if in_details and details_summary_rendered then cb_prefix = cb_prefix + #"│ " end
        table.insert(self.code_blocks, {
          language = code_block_lang,
          start_line = code_block_start,
          end_line = #self.lines - 1,
          prefix_len = cb_prefix,
          source_lines = code_source_lines,
        })
      end
      if code_block_has_truncation or expand_state[code_block_id] then
        table.insert(self.expandable_regions, {
          start_line = code_block_start,
          end_line = #self.lines - 1,
          block_id = code_block_id,
          expanded = expand_state[code_block_id] or false,
        })
      end
    end
    in_code_block = false
    code_fence = nil
    code_block_lang = nil
    code_source_lines = nil
    code_block_id = nil
    code_fence_indent = ""
  end

  for src_idx, line in ipairs(lines) do
    -- src_idx is the post-transform array index; src_indices[src_idx]
    -- is the original buffer line, which is what consumers (cursor sync,
    -- shadow cursor, link/anchor extraction) actually expect.
    self:set_source_line(src_indices[src_idx] + source_line_offset)

    -- Content of a blockquote or a list item was moved to column 0 by
    -- strip_container_indent(); its indent comes back as display indent for
    -- this line only, and the width it takes up is off the budget. Both are
    -- the plain base for every other line, which is what the rest of the loop
    -- reads. Text wrapping receives base_max_width instead: it accounts for
    -- the complete display indent itself.
    local container_indent = container_indents[src_indices[src_idx]] or ""
    local indent = base_indent .. container_indent
    local max_width = math.max(1, base_max_width - #container_indent)
    local origin = source_origins[src_indices[src_idx]]
    if in_html_table and origin.html ~= html_table_owner then release_html_table() end
    if in_details_summary and origin.html ~= details_summary_owner then finish_details_summary() end
    if in_dl and origin.html ~= dl_owner then
      in_dl, dl_owner = false, nil
    end
    if in_figure and origin.html ~= figure_owner then
      render_figure_caption(figure_indent, figure_width)
      in_figure, figure_owner = false, nil
    end
    if html_heading_rows[src_indices[src_idx]] then goto continue end
    local quoted_content, quote_column = line, origin.column
    local quote_depth = 0
    while quoted_content:match "^>" and quote_depth < #origin.quote_columns do
      quote_depth = quote_depth + 1
      local _
      _, quoted_content, quote_column =
        split_quote_marker(quoted_content, quote_column, origin.quote_columns[quote_depth])
    end
    local leaf_marker = list_bases[src_indices[src_idx]] ~= nil
    local quote_prefix = quote_display_prefix(origin, leaf_marker and 0 or nil)
    if origin.list_column and not origin.code and not leaf_marker then
      quoted_content = strip_container_prefix(quoted_content, origin.list_column, quote_column)
      line = string.rep("> ", quote_depth) .. quoted_content
    end
    if
      in_code_block
      and (origin.code == false or origin.code_opener or container_indent ~= code_container_indent)
      and not origin.code_closer
    then
      local before = #self.lines
      finish_code_block(base_indent .. code_container_indent, math.max(1, base_max_width - #code_container_indent))
      if in_details and details_summary_rendered and not skip_details_body and #self.lines > before then
        apply_details_body_prefix(before, #self.lines)
      end
    end
    if
      in_callout_code_block
      and not in_qiita_note
      and (
        origin.code == false
        or origin.code_opener
        or quote_depth ~= callout_code_depth
        or container_indent ~= callout_code_container
      )
    then
      finish_quote_code()
    end
    -- Quote-local code and folds end when their container ends, even when the
    -- next line is hidden. Qiita note markers are added later in this loop.
    if
      not in_qiita_note
      and (not line:match "^>" or (alert_depth and (quote_depth < alert_depth or container_indent ~= alert_container)))
    then
      in_callout_code_block = false
      callout_code_fence = nil
      callout_code_lang = nil
      skip_callout_body = false
      current_alert_type = nil
      alert_depth = nil
    end
    if origin.list_prefixes and not skip_callout_body and not skip_details_body then
      flush_table()
      for _, prefix in ipairs(origin.list_prefixes) do
        if lines_shown >= max_lines then break end
        local text, prefix_indent = prefix.text, base_indent
        if #prefix.quote_columns > 0 then
          local ws = text:match "^ *"
          text = quote_content(text:sub(#ws + 1), #ws, #prefix.quote_columns, prefix.quote_columns)
          text = string.rep("> ", #prefix.quote_columns) .. text
          prefix_indent = prefix_indent .. ws
        end
        local before = #self.lines
        self:add_markdown_line(text, prefix_indent, base_max_width, repo_base_url, autolinks, ref_links, nil, nil, {
          list_marker = true,
          quote_prefix = quote_display_prefix(prefix, 0),
        })
        lines_shown = lines_shown + #self.lines - before
      end
      if lines_shown >= max_lines then
        self:add_line(indent .. "... (truncated)", { { col = 0, end_col = -1, hl = "Comment" } })
        truncated = true
        break
      end
    end
    -- A consumed definition may also mark the end of the previous code owner.
    if reference_defs[src_indices[src_idx]] then goto continue end

    -- An established table owns its delimiter and ordinary body rows before
    -- HTML, images or Setext detection can reinterpret inline cell content.
    if #table_buf > 0 then
      if
        src_indices[src_idx] == table_buf_start_idx + #table_buf
        and container_indent == table_buf_indent
        and (#table_buf == 1 or markdown_table.is_body_row(line))
      then
        table.insert(table_buf, line)
        goto continue
      end
      flush_table()
      if lines_shown >= max_lines then
        self:add_line(indent .. "... (truncated)", { { col = 0, end_col = -1, hl = "Comment" } })
        truncated = true
        break
      end
      self:add_line(indent)
      lines_shown = lines_shown + 1
      prev_rendered_blank = true
    end

    -- Skip setext heading underline
    if skip_next_line then
      skip_next_line = false
      goto continue
    end

    if skip_callout_body then goto continue end

    if in_math_block and not line:match "^%$%$$" then
      self:add_line(indent .. line, { { col = 0, end_col = -1, hl = "MdRenderMath" } })
      lines_shown = lines_shown + 1
      goto continue
    end

    -- Consume comment-owned lines before definitions, tags, and Setext headings
    -- can reinterpret them. Only the closing line may contain visible text.
    local comment = comments[src_indices[src_idx]]
    if comment and not in_code_block and not in_callout_code_block then
      local comment_suffix = comment.suffix
      if not skip_details_body and comment_suffix:match "%S" then
        flush_table()
        if lines_shown >= max_lines then
          self:add_line(indent .. "... (truncated)", { { col = 0, end_col = -1, hl = "Comment" } })
          truncated = true
          break
        end
        local comment_lines_before = #self.lines
        local comment_text = comment.prefix .. comment_suffix
        local comment_highlights = {}
        if comment.prefix ~= "" then
          comment_highlights[1] = { col = 0, end_col = #comment.prefix, hl = "FloatBorder" }
        end
        local comment_width = base_max_width - vim.api.nvim_strwidth(indent)
        if in_details and details_summary_rendered then
          comment_width = comment_width - vim.fn.strdisplaywidth "│ "
        end
        comment_width = math.max(1, comment_width)
        if vim.api.nvim_strwidth(comment_text) > comment_width then
          self:add_wrapped_markdown(comment_text, comment_highlights, {}, indent, comment_width, comment.prefix)
        else
          self:add_simple_markdown(comment_text, comment_highlights, {}, indent)
        end
        if current_alert_type and comment.prefix ~= "" then
          self:apply_alert_styling(comment_lines_before, #self.lines, current_alert_type, false)
        end
        if in_details and details_summary_rendered then apply_details_body_prefix(comment_lines_before, #self.lines) end
        lines_shown = lines_shown + #self.lines - comment_lines_before
        prev_was_heading = false
        prev_was_hr = false
        prev_rendered_blank = false
        prev_list_marker_type = nil
        if lines_shown >= max_lines then
          self:add_line(indent .. "... (truncated)", { { col = 0, end_col = -1, hl = "Comment" } })
          truncated = true
          break
        end
      end
      goto continue
    end

    -- Literal source ownership precedes HTML, headings and display blank-line
    -- policy. Fence delimiters and their active payload use the fence renderer.
    if
      origin.code
      and quote_depth == 0
      and not origin.code_opener
      and not origin.code_closer
      and not in_code_block
      and not in_math_block
    then
      if skip_details_body then goto continue end
      if prev_was_hr then
        self:add_line(indent)
        lines_shown = lines_shown + 1
      end
      local code_content = strip_container_prefix(line, 4, origin.column)
      local indented_line = indent .. code_content
      local display_width = vim.api.nvim_strwidth(indented_line)
      local content_byte_end = #indented_line
      local ib_lines_before = #self.lines
      if display_width > max_width then
        local target = max_width - vim.api.nvim_strwidth "…"
        local current_width = 0
        local byte_pos = 0
        for char in indented_line:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
          local char_width = vim.api.nvim_strwidth(char)
          if current_width + char_width > target then break end
          current_width = current_width + char_width
          byte_pos = byte_pos + #char
        end
        local truncated_line = indented_line:sub(1, byte_pos) .. "…"
        self:add_line(truncated_line, { { col = 0, end_col = -1, hl = "String" } })
        content_byte_end = byte_pos
      else
        self:add_line(indented_line, { { col = 0, end_col = -1, hl = "String" } })
      end
      detect_urls_in_code_line(self, code_content, #indent, content_byte_end)
      if in_details and details_summary_rendered and not skip_details_body then
        apply_details_body_prefix(ib_lines_before, #self.lines)
      end
      lines_shown = lines_shown + 1
      prev_was_heading, prev_was_hr, prev_list_marker_type = false, false, nil
      prev_rendered_blank = code_content:match "^[ \t]*$" ~= nil
      if lines_shown >= max_lines then
        self:add_line(indent .. "... (truncated)", { { col = 0, end_col = -1, hl = "Comment" } })
        truncated = true
        break
      end
      goto continue
    end

    -- Skip footnote definition lines (rendered in footnote section at end)
    if not origin.html and not in_code_block and markdown.is_footnote_def(line) then goto continue end

    -- Strip wrapper tags before ordinary block processing.
    if not in_code_block and not in_callout_code_block then
      line = unwrap_html_wrapper(line)
      if not line then goto continue end
    end

    local setext_rank = not in_code_block
        and not in_callout_code_block
        and setext_level(src_idx, quote_depth > 0 and quoted_content or line, quote_depth)
      or nil
    if setext_rank then skip_next_line = true end

    -- Convert HTML headings <h1>-<h6> to markdown format
    -- If heading contains an <img>, split it into separate image + heading lines
    local html_heading_level
    if not in_code_block then
      local heading = line:match "^%s*<h[1-6]" and html_headings[src_indices[src_idx]]
      local h_level, h_content = line:match "^%s*<h([1-6])[^>]*>(.-)</h%1>%s*$"
      if heading then
        h_level, h_content = heading.level, heading.content
      end
      if h_level then
        html_heading_level = tonumber(h_level)
        local img_tag = h_content:match "(<img%s[^>]*>)"
        if img_tag then
          -- Extract the img tag as a standalone line, render it before the heading
          local remaining = h_content:gsub("<img%s[^>]*>", ""):gsub("^%s+", ""):gsub("%s+$", "")
          -- The synthetic image shares the heading's physical source row.
          -- Keep source classification and row indices aligned with it.
          table.insert(lines, src_idx + 1, img_tag)
          table.insert(source_list_lines, src_idx + 1, img_tag)
          table.insert(src_indices, src_idx + 1, src_indices[src_idx])
          if remaining ~= "" then
            line = remaining
          else
            goto continue
          end
        else
          line = h_content
        end
      end
    end

    local is_blank = line:match "^%s*$" ~= nil
    local atx_level, atx_content = parse_atx_heading(quote_depth > 0 and quoted_content or line)
    local is_heading = not in_code_block
      and not in_callout_code_block
      and not origin.code
      and (html_heading_level ~= nil or (not origin.html and (setext_rank ~= nil or atx_level ~= nil)))

    -- Handle <details>/<summary> HTML blocks (outside code blocks)
    if not in_code_block and not in_callout_code_block then
      -- Handle </details> end tag
      if line:match "^%s*</details>%s*$" then
        if in_details_summary then finish_details_summary(src_indices[src_idx]) end
        if in_details then
          if details_depth > 0 then
            details_depth = details_depth - 1
          else
            in_details = false
            skip_details_body = false
            details_src_idx = nil
            details_summary_rendered = false
          end
        end
        goto continue
      end

      -- Skip body of collapsed <details>
      if skip_details_body then
        if line:match "^%s*<details" then details_depth = details_depth + 1 end
        goto continue
      end

      -- Handle <details> opening tag
      if line:match "^%s*<details" then
        if in_details then
          details_depth = details_depth + 1
          goto continue
        end
        local attrs = line:match "^%s*<details(.-)>" or ""
        in_details = true
        details_src_idx = src_idx
        details_default_open = attrs:match "open" ~= nil
        details_summary_rendered = false
        details_depth = 0
        in_details_summary = false
        details_summary_parts = {}

        -- Check for inline <summary>...</summary>
        local rest = line:match "^%s*<details.->(.+)$"
        if rest then
          local s = rest:match "<summary>(.-)</summary>"
          if s then render_details_summary(s ~= "" and s or "Details", origin.html ~= nil) end
        end
        goto continue
      end

      -- Handle <summary> within <details>
      if in_details and not details_summary_rendered then
        if in_details_summary then
          -- Accumulating multi-line summary
          local before = line:match "^(.-)</summary>%s*$"
          if before then
            if before ~= "" then table.insert(details_summary_parts, before) end
            finish_details_summary(src_indices[src_idx])
            goto continue
          end
          table.insert(details_summary_parts, line)
          goto continue
        end

        -- Single-line <summary>text</summary>
        local s = line:match "^%s*<summary>(.-)</summary>%s*$"
        if s then
          render_details_summary(s ~= "" and s or "Details", origin.html ~= nil)
          goto continue
        end

        -- Multi-line <summary> start
        local start_text = line:match "^%s*<summary>(.*)$"
        if start_text then
          in_details_summary = true
          details_summary_parts = {}
          details_summary_owner, details_summary_src = origin.html, src_indices[src_idx]
          if start_text ~= "" then table.insert(details_summary_parts, start_text) end
          goto continue
        end

        -- No <summary> found and this is content - render default header
        if not is_blank then
          render_details_summary "Details"
          -- Fall through to render this line as body content
        end
      end
    end

    -- Handle <figure> blocks (outside code blocks)
    -- Lines inside <figure> pass through normally (e.g. <img> lines are rendered
    -- by the standalone image detector below). Only the <figure>, </figure>, and
    -- <figcaption> wrapper tags are consumed here.
    if not in_code_block and not in_callout_code_block then
      if in_figure then
        if line:match "^%s*</figure>%s*$" then
          in_figure = false
          figure_owner = nil
          render_figure_caption(indent, max_width)
          goto continue
        end
        -- Extract <figcaption> content for rendering when </figure> is reached
        local cap = line:match "^%s*<figcaption>(.-)</figcaption>%s*$"
        if cap and cap:match "%S" then
          figure_caption = cap
          figure_caption_src = src_indices[src_idx]
          goto continue
        end
        -- Other lines inside <figure> (e.g. <img>) fall through to normal processing
      end

      if line:match "^%s*<figure[^>]*>%s*$" then
        in_figure = true
        figure_owner, figure_indent, figure_width = origin.html, indent, max_width
        goto continue
      end
    end

    -- Handle <p> blocks (outside code blocks)
    -- Strip <p>/<p align="..."> wrapper tags and let inner content (e.g. <img>,
    -- <em>) fall through to normal processing, similar to <figure>.
    if not in_code_block and not in_callout_code_block then
      if in_p_tag then
        if line:match "^%s*</p>%s*$" then
          in_p_tag = false
          goto continue
        end
        -- Inner content falls through to normal processing
      end

      if line:match "^%s*<p[%s>]" and not line:match "</p>" then
        in_p_tag = true
        goto continue
      end
      -- Single-line <p>...</p>: extract inner content and process it
      local p_inner = line:match "^%s*<p[^>]*>%s*(.-)%s*</p>%s*$"
      if p_inner and p_inner:match "%S" then
        line = p_inner -- Fall through with extracted content
      end
    end

    -- Handle <dl> definition lists (outside code blocks)
    if not in_code_block and not in_callout_code_block then
      if in_dl then
        if line:match "^%s*</dl>%s*$" then
          in_dl = false
          dl_owner = nil
          -- Ensure blank line after </dl> block
          self:add_line(indent)
          lines_shown = lines_shown + 1
          prev_rendered_blank = true
          goto continue
        end
        -- Parse <dt> and <dd> elements from the line
        -- A line may contain <dt>term</dt><dd>description patterns
        flush_table()
        local rest = line
        -- Strip standalone <dl> opening if present
        rest = rest:gsub("^%s*<dl>%s*", "")
        if rest:match "^%s*$" then goto continue end
        while rest and rest ~= "" do
          -- Try to match <dt>...</dt> or <dt>...
          local dt_content = rest:match "^%s*<dt>(.-)</dt>"
          if dt_content then
            rest = rest:match "^%s*<dt>.-</dt>%s*(.*)" or ""
            -- Split on <br> / <br/> / <br /> and render each segment
            local dt_lines_before = #self.lines
            for _, seg in ipairs(vim.split(dt_content, "<br%s*/?>", { plain = false, trimempty = true })) do
              seg = seg:gsub("^%s+", ""):gsub("%s+$", "")
              if seg ~= "" then
                local dt_rendered, dt_hls, dt_links = markdown.render(
                  seg,
                  repo_base_url,
                  autolinks,
                  ref_links,
                  nil,
                  true,
                  { raw_html = origin.html ~= nil }
                )
                table.insert(dt_hls, { col = 0, end_col = #dt_rendered, hl = "Bold" })
                self:add_simple_markdown(dt_rendered, dt_hls, dt_links, indent)
              end
            end
            if in_details and details_summary_rendered and not skip_details_body then
              apply_details_body_prefix(dt_lines_before, #self.lines)
            end
            lines_shown = lines_shown + (#self.lines - dt_lines_before)
          end
          -- Try to match <dd>...</dd> or <dd>... (may not have closing tag)
          local dd_content = rest:match "^%s*<dd>(.-)</dd>"
          if dd_content then
            rest = rest:match "^%s*<dd>.-</dd>%s*(.*)" or ""
          else
            dd_content = rest:match "^%s*<dd>(.*)"
            if dd_content then rest = "" end
          end
          if dd_content and dd_content ~= "" then
            local dd_indent = indent .. "  "
            local dd_width = math.max(1, base_max_width - vim.api.nvim_strwidth(dd_indent))
            local dd_lines_before = #self.lines
            -- Split on <br> / <br/> / <br /> and render each segment
            for _, seg in ipairs(vim.split(dd_content, "<br%s*/?>", { plain = false, trimempty = true })) do
              seg = seg:gsub("^%s+", ""):gsub("%s+$", "")
              if seg ~= "" then
                local dd_rendered, dd_hls, dd_links = markdown.render(
                  seg,
                  repo_base_url,
                  autolinks,
                  ref_links,
                  nil,
                  true,
                  { raw_html = origin.html ~= nil }
                )
                if vim.api.nvim_strwidth(dd_rendered) > dd_width then
                  self:add_wrapped_markdown(dd_rendered, dd_hls, dd_links, dd_indent, dd_width, "")
                else
                  self:add_simple_markdown(dd_rendered, dd_hls, dd_links, dd_indent)
                end
              end
            end
            if in_details and details_summary_rendered and not skip_details_body then
              apply_details_body_prefix(dd_lines_before, #self.lines)
            end
            lines_shown = lines_shown + (#self.lines - dd_lines_before)
          end
          -- Unrecognized text remains readable inside this raw owner.
          if not dt_content and not dd_content then
            local before = #self.lines
            self:add_markdown_line(rest, indent, base_max_width, repo_base_url, autolinks, ref_links, nil, nil, {
              raw_html = origin.html ~= nil,
            })
            if in_details and details_summary_rendered then apply_details_body_prefix(before, #self.lines) end
            lines_shown = lines_shown + #self.lines - before
            break
          end
        end
        goto continue
      end

      if line:match "^%s*<dl[^>]*>" then
        flush_table()
        -- Ensure blank line before <dl> block
        if lines_shown > 0 and not prev_rendered_blank then
          self:add_line(indent)
          lines_shown = lines_shown + 1
        end
        in_dl = true
        dl_owner = origin.html
        goto continue
      end
    end

    -- Handle HTML <table> blocks (outside code blocks)
    if not in_code_block and not in_callout_code_block then
      if in_html_table then
        table.insert(html_table_lines, line)
        table.insert(html_table_sources, src_indices[src_idx])
        -- Track nested <table> depth
        local ll = line:lower()
        for _ in ll:gmatch "<table[%s>]" do
          html_table_depth = html_table_depth + 1
        end
        for _ in ll:gmatch "</table" do
          html_table_depth = html_table_depth - 1
        end
        if html_table_depth <= 0 then
          in_html_table = false
          -- Convert HTML table to pipe-table lines and render
          local pipe_lines = html_table_to_pipe(html_table_lines)
          if #pipe_lines >= 2 then
            flush_table()
            if lines_shown > 0 and not prev_rendered_blank then
              self:add_line(indent)
              lines_shown = lines_shown + 1
            end
            local tbl_lines_before = #self.lines
            local tbl_expanded = html_table_src_idx and expand_state[html_table_src_idx]
            -- Same source-line stamping rationale as flush_table above.
            local saved_src_line = self._current_source_line
            if html_table_src_idx then self._current_source_line = html_table_src_idx + source_line_offset end
            self:add_table(
              pipe_lines,
              indent,
              max_width,
              repo_base_url,
              autolinks,
              tbl_expanded or false,
              nil,
              nil,
              ref_links,
              true
            )
            self._current_source_line = saved_src_line
            local tbl_lines_added = #self.lines - tbl_lines_before
            lines_shown = lines_shown + tbl_lines_added
            local has_truncation = false
            if not tbl_expanded then
              for li = tbl_lines_before + 1, #self.lines do
                if self.lines[li] and self.lines[li]:match "…" then
                  has_truncation = true
                  break
                end
              end
            end
            if has_truncation or tbl_expanded then
              table.insert(self.expandable_regions, {
                start_line = tbl_lines_before,
                end_line = #self.lines - 1,
                block_id = html_table_src_idx,
                expanded = tbl_expanded or false,
              })
            end
            if in_details and details_summary_rendered and not skip_details_body then
              apply_details_body_prefix(tbl_lines_before, #self.lines)
            end
            prev_rendered_blank = false
          end
          if #pipe_lines < 2 then release_html_table() end
          html_table_lines = {}
          html_table_sources = {}
          html_table_src_idx = nil
        end
        goto continue
      end

      if line:match "^%s*<table[^>]*>" then
        flush_table()
        in_html_table = true
        html_table_depth = 1
        html_table_lines = { line }
        html_table_sources = { src_indices[src_idx] }
        html_table_owner = origin.html
        html_table_src_idx = src_indices[src_idx]
        -- Check if </table> is on the same line
        if line:lower():match "</table" then
          html_table_depth = 0
          -- will be handled on next iteration; re-process
          in_html_table = false
          local pipe_lines = html_table_to_pipe(html_table_lines)
          if #pipe_lines >= 2 then
            if lines_shown > 0 and not prev_rendered_blank then
              self:add_line(indent)
              lines_shown = lines_shown + 1
            end
            local tbl_lines_before = #self.lines
            self:add_table(pipe_lines, indent, max_width, repo_base_url, autolinks, nil, buf_dir, nil, ref_links, true)
            lines_shown = lines_shown + (#self.lines - tbl_lines_before)
            if in_details and details_summary_rendered and not skip_details_body then
              apply_details_body_prefix(tbl_lines_before, #self.lines)
            end
          end
          if #pipe_lines < 2 then release_html_table() end
          html_table_lines = {}
          html_table_sources = {}
          html_table_src_idx = nil
        end
        goto continue
      end
    end

    -- Handle <hr> as horizontal rule
    if not in_code_block and line:match "^%s*<hr[^>]*>%s*$" then
      flush_table()
      if lines_shown > 0 and not prev_was_hr then
        self:add_line(indent)
        lines_shown = lines_shown + 1
      end
      local hr_lines_before = #self.lines
      local rule = indent .. string.rep("─", max_width)
      self:add_line(rule, { { col = 0, end_col = #rule, hl = "FloatBorder" } })
      if in_details and details_summary_rendered and not skip_details_body then
        apply_details_body_prefix(hr_lines_before, #self.lines)
      end
      lines_shown = lines_shown + 1
      prev_was_heading = false
      prev_was_hr = true
      prev_list_marker_type = nil
      goto continue
    end

    -- Handle markdown thematic breaks (---, ***, ___, etc.)
    if origin.html and not line:match "^%s*<img%s[^>]*>%s*$" and not line:match "^%s*<video[%s>].-</video>%s*$" then
      if prev_was_hr and not is_blank then
        self:add_line(indent)
        lines_shown = lines_shown + 1
      end
      if html_heading_level then
        local before = #self.lines
        if lines_shown > 0 and not prev_rendered_blank and not prev_was_hr then self:add_line(indent) end
        local text_scale = self.text_scale
        if in_details and self:heading_renderer() == "image" then self.text_scale = false end
        self:add_markdown_line(line, indent, base_max_width, repo_base_url, autolinks, ref_links, nil, nil, {
          raw_html = true,
          heading_level = html_heading_level,
        })
        self.text_scale = text_scale
        if in_details and details_summary_rendered then apply_details_body_prefix(before, #self.lines) end
        lines_shown = lines_shown + #self.lines - before
      elseif not skip_details_body then
        render_html_row(src_indices[src_idx], indent, string.rep("│ ", quote_depth))
      end
      prev_was_heading, prev_was_hr, prev_rendered_blank, prev_list_marker_type =
        html_heading_level ~= nil, false, false, nil
      if lines_shown >= max_lines then
        self:add_line(indent .. "... (truncated)", { { col = 0, end_col = -1, hl = "Comment" } })
        truncated = true
        break
      end
      goto continue
    end
    if not in_code_block and is_thematic_break(line) then
      flush_table()
      if lines_shown > 0 and not prev_was_hr then
        self:add_line(indent)
        lines_shown = lines_shown + 1
      end
      local hr_lines_before = #self.lines
      local rule = indent .. string.rep("─", max_width)
      self:add_line(rule, { { col = 0, end_col = #rule, hl = "FloatBorder" } })
      if in_details and details_summary_rendered and not skip_details_body then
        apply_details_body_prefix(hr_lines_before, #self.lines)
      end
      lines_shown = lines_shown + 1
      prev_was_heading = false
      prev_was_hr = true
      prev_list_marker_type = nil
      goto continue
    end

    -- Add blank line after HR for regular content (not heading, not HR)
    -- Headings already add their own blank line before them.
    if prev_was_hr and not is_blank and not is_heading then
      self:add_line(indent)
      lines_shown = lines_shown + 1
    end
    if prev_was_hr and not is_blank then prev_was_hr = false end

    -- Start collecting only after a matching header and delimiter are known.
    if
      not in_code_block
      and not in_callout_code_block
      and not in_math_block
      and markdown_table.parse_header(line, lines[src_idx + 1])
      and src_indices[src_idx + 1] == src_indices[src_idx] + 1
    then
      table_buf_start_idx = src_indices[src_idx]
      table_buf_indent = container_indent
      if lines_shown > 0 and not prev_rendered_blank then
        self:add_line(indent)
        lines_shown = lines_shown + 1
      end
      table.insert(table_buf, line)
      goto continue
    end

    -- Collapse consecutive rendered blank lines (outside regular code blocks)
    if not in_code_block and not in_callout_code_block and is_blank and prev_rendered_blank then goto continue end

    -- Skip blank lines adjacent to headings (outside code blocks)
    if not in_code_block and not in_callout_code_block and is_blank then
      local skip = prev_was_heading or prev_was_hr
      if not skip then
        for k = src_idx + 1, #lines do
          -- References were consumed before joining; skip blanks and footnotes.
          if not lines[k]:match "^%s*$" and not markdown.is_footnote_def(lines[k]) then
            -- Check ATX heading or setext heading (text followed by === or ---)
            skip = parse_atx_heading(lines[k]) ~= nil
            if not skip then skip = is_thematic_break(lines[k]) end
            if not skip then skip = lines[k]:match "^:::$" ~= nil end
            if not skip then skip = setext_level(k, lines[k], #source_origins[src_indices[k]].quote_columns) ~= nil end
            break
          end
        end
      end
      if skip then goto continue end

      -- Skip blank lines between list items of the same marker type (loose list → tight)
      if not skip and prev_list_marker_type then
        local next_marker_type
        for k = src_idx + 1, #lines do
          if not lines[k]:match "^%s*$" then
            next_marker_type = list_bases[src_indices[k]] ~= nil and markdown.list_marker_type(source_list_lines[k])
            break
          end
        end
        if next_marker_type and next_marker_type == prev_list_marker_type then goto continue end
      end
    end

    -- Ensure exactly one blank line before headings (except the first content)
    if not in_code_block and is_heading and lines_shown > 0 then
      self:add_line(indent)
      lines_shown = lines_shown + 1
      if lines_shown >= max_lines then
        self:add_line(indent .. "... (truncated)", { { col = 0, end_col = -1, hl = "Comment" } })
        truncated = true
        break
      end
    end

    local lines_before = #self.lines

    -- Handle Qiita :::note / :::message blocks (outside code blocks)
    if not in_code_block and not in_math_block then
      -- Closing :::
      if in_qiita_note and line:match "^:::$" then
        in_qiita_note = false
        qiita_note_type = nil
        current_alert_type = nil
        prev_rendered_blank = false
        goto continue
      end

      -- Opening :::note or :::message
      local note_type = line:match "^:::note%s+(%a+)%s*$"
        or (line:match "^:::note%s*$" and "info")
        or line:match "^:::message%s+(%a+)%s*$"
        or (line:match "^:::message%s*$" and "info")
      if note_type then
        in_qiita_note = true
        -- Map Qiita note types to existing alert style keys
        local qiita_map = {
          info = { style = "NOTE", icon = "󰋽", label = "Note" },
          warn = { style = "WARNING", icon = "󰀪", label = "Warning" },
          alert = { style = "CAUTION", icon = "󰳦", label = "Caution" },
        }
        local qm = qiita_map[note_type] or qiita_map.info
        qiita_note_type = qm.style

        local icon = pad_icon(qm.icon)
        local header_text = indent .. "│ " .. icon .. " " .. qm.label
        self:add_line(header_text, {
          { col = #indent, end_col = #indent + #"│ ", hl = "FloatBorder" },
          {
            col = #indent + #"│ ",
            end_col = #header_text,
            hl = "MdRenderAlert" .. (qiita_note_type:sub(1, 1) .. qiita_note_type:sub(2):lower()),
          },
        })
        self:apply_alert_styling(lines_before, #self.lines, qiita_note_type, true)
        lines_shown = lines_shown + 1
        prev_rendered_blank = false
        prev_was_heading = true -- suppress blank line after header (like heading)
        prev_list_marker_type = nil
        goto continue
      end

      -- Body lines inside :::note block
      if in_qiita_note then
        -- Code blocks inside Qiita notes: transform to callout format
        -- and fall through to the callout code block handler below
        if in_callout_code_block or fence_mod.opening(line) then
          line = "> " .. line
          current_alert_type = qiita_note_type
        else
          -- Render as blockquote-style content with alert styling
          local qn_line = "> " .. line
          local alert_type_ret = self:add_markdown_line(
            qn_line,
            indent,
            base_max_width,
            repo_base_url,
            autolinks,
            ref_links,
            footnote_map,
            paragraph_sources[src_indices[src_idx]],
            {
              raw_html = origin.html ~= nil,
              heading_level = html_heading_level or setext_rank,
              list_marker = list_bases[src_indices[src_idx]] ~= nil,
            }
          )
          local lines_after = #self.lines
          if not alert_type_ret then self:apply_alert_styling(lines_before, lines_after, qiita_note_type, false) end
          lines_shown = lines_shown + (lines_after - lines_before)
          prev_rendered_blank = is_blank
          prev_was_heading = false
          prev_list_marker_type = nil
          goto continue
        end
      end
    end

    if not in_code_block and line:match "^%$%$$" then
      if not in_math_block then
        in_math_block = true
      else
        in_math_block = false
      end
    elseif in_math_block then
      local indented = indent .. line
      self:add_line(indented, { { col = 0, end_col = -1, hl = "MdRenderMath" } })
    elseif
      (in_code_block and fence_mod.closes(line, code_fence)) or (not in_code_block and fence_mod.opening(line))
    then
      if not in_code_block then
        in_code_block = true
        code_fence = fence_mod.opening(line)
        code_container_indent = container_indent
        code_fence_indent = code_fence.indent
        local info_string = code_fence.lang
        code_block_lang = info_string
        -- Split lang:filename (Qiita-style code block filename)
        local code_block_filename = nil
        if info_string and info_string:find(":", 1, true) then
          local lang_part, file_part = info_string:match "^([^:]*):(.+)$"
          if file_part then
            code_block_filename = file_part
            code_block_lang = (lang_part ~= "") and lang_part or nil
          end
        end
        -- Render filename header above code block
        if code_block_filename then
          local file_icon, icon_hl = get_file_icon(code_block_filename)
          file_icon = pad_icon(file_icon)
          local icon_start = #indent + #code_fence_indent
          local icon_end = icon_start + #file_icon
          local fname_line = indent .. code_fence_indent .. file_icon .. " " .. code_block_filename
          local hls = {
            { col = icon_end, end_col = #fname_line, hl = "Comment" },
          }
          if icon_hl then
            table.insert(hls, 1, { col = icon_start, end_col = icon_end, hl = icon_hl })
          else
            hls[1].col = icon_start
          end
          self:add_line(fname_line, hls)
          lines_shown = lines_shown + 1
        end
        code_block_start = #self.lines
        code_source_lines = {}
        code_block_id = src_idx
        code_block_has_truncation = false
      else
        finish_code_block(indent, max_width)
      end
    elseif in_code_block then
      -- Dedent by the opening fence's indent, then put it back on output:
      -- the code keeps its own indentation but not the container's.
      local content = strip_indent(line, #code_fence_indent)
      table.insert(code_source_lines, content)
      local indented = indent .. code_fence_indent .. content
      local display_width = vim.api.nvim_strwidth(indented)
      if not expand_state[code_block_id] and display_width > max_width then
        code_block_has_truncation = true
        local target = max_width - vim.api.nvim_strwidth "…"
        local current_width = 0
        local byte_pos = 0
        for char in indented:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
          local char_width = vim.api.nvim_strwidth(char)
          if current_width + char_width > target then break end
          current_width = current_width + char_width
          byte_pos = byte_pos + #char
        end
        local truncated_line = indented:sub(1, byte_pos) .. "…"
        self:add_line(truncated_line, {
          { col = 0, end_col = byte_pos, hl = "String" },
          { col = byte_pos, end_col = #truncated_line, hl = "Underlined" },
        })
        detect_urls_in_code_line(self, content, #indent + #code_fence_indent, byte_pos)
      else
        self:add_line(indented, { { col = 0, end_col = -1, hl = "String" } })
        detect_urls_in_code_line(self, content, #indent + #code_fence_indent, #indented)
      end
    else
      local handled = false

      -- Handle code blocks inside blockquotes (both plain blockquotes and callouts)
      if line:match "^>" then
        local stripped = in_qiita_note and line:gsub("^>[ \t]?", "", 1) or quoted_content
        local code_column = in_qiita_note and origin.column or quote_column
        local code_quote_prefix = in_qiita_note and "│ "
          or quote_display_prefix(origin, 0)
          or string.rep("│ ", quote_depth)
        if origin.code_closer and not in_callout_code_block then
          handled = true
        elseif
          (in_callout_code_block and fence_mod.closes(stripped, callout_code_fence, code_column))
          or (
            not in_callout_code_block
            and (not origin.code or origin.code_opener)
            and fence_mod.opening(stripped, code_column, fence_containers[src_indices[src_idx]])
          )
        then
          if not in_callout_code_block then
            in_callout_code_block = true
            callout_code_fence = fence_mod.opening(stripped, code_column, fence_containers[src_indices[src_idx]])
            callout_code_prefix = indent .. code_quote_prefix .. string.rep(" ", callout_code_fence.container)
            local callout_info = callout_code_fence.lang
            callout_code_lang = callout_info
            -- Split lang:filename (Qiita-style)
            if callout_info and callout_info:find(":", 1, true) then
              local lang_part, file_part = callout_info:match "^([^:]*):(.+)$"
              if file_part then
                callout_code_lang = (lang_part ~= "") and lang_part or nil
                local cb_file_icon, cb_icon_hl = get_file_icon(file_part)
                cb_file_icon = pad_icon(cb_file_icon)
                local cb_icon_start = #callout_code_prefix
                local cb_icon_end = cb_icon_start + #cb_file_icon
                local fname_line = callout_code_prefix .. cb_file_icon .. " " .. file_part
                local cb_hls = {
                  { col = #indent, end_col = cb_icon_start, hl = "FloatBorder" },
                  { col = cb_icon_end, end_col = #fname_line, hl = "Comment" },
                }
                if cb_icon_hl then
                  table.insert(cb_hls, 2, { col = cb_icon_start, end_col = cb_icon_end, hl = cb_icon_hl })
                else
                  cb_hls[2].col = cb_icon_start
                end
                self:add_line(fname_line, cb_hls)
                if current_alert_type then
                  self:apply_alert_styling(lines_before, #self.lines, current_alert_type, false)
                end
                lines_shown = lines_shown + 1
              end
            end
            callout_code_depth, callout_code_container = quote_depth, container_indent
            callout_code_start = #self.lines
            callout_code_source_lines = {}
            callout_code_block_id = src_idx
            callout_code_has_truncation = false
          else
            finish_quote_code()
          end
          handled = true
        elseif in_callout_code_block then
          stripped = strip_container_prefix(stripped, #callout_code_fence.indent, code_column)
          table.insert(callout_code_source_lines, stripped)
          local code_line = callout_code_prefix .. stripped
          local display_width = vim.api.nvim_strwidth(code_line)
          if not expand_state[callout_code_block_id] and display_width > max_width then
            callout_code_has_truncation = true
            local target = max_width - vim.api.nvim_strwidth "…"
            local current_width = 0
            local byte_pos = 0
            for char in code_line:gmatch "[%z\1-\127\194-\253][\128-\191]*" do
              local char_width = vim.api.nvim_strwidth(char)
              if current_width + char_width > target then break end
              current_width = current_width + char_width
              byte_pos = byte_pos + #char
            end
            local truncated_code = code_line:sub(1, byte_pos) .. "…"
            self:add_line(truncated_code, {
              { col = #indent, end_col = #callout_code_prefix, hl = "FloatBorder" },
              { col = #callout_code_prefix, end_col = byte_pos, hl = "String" },
              { col = byte_pos, end_col = #truncated_code, hl = "Underlined" },
            })
            detect_urls_in_code_line(self, stripped, #callout_code_prefix, byte_pos)
          else
            self:add_line(code_line, {
              { col = #indent, end_col = #callout_code_prefix, hl = "FloatBorder" },
              { col = #callout_code_prefix, end_col = -1, hl = "String" },
            })
            detect_urls_in_code_line(self, stripped, #callout_code_prefix, #code_line)
          end
          if current_alert_type then self:apply_alert_styling(lines_before, #self.lines, current_alert_type, false) end
          handled = true
        elseif origin.code and quote_depth > 0 then
          local prefix = indent .. code_quote_prefix
          if origin.list_column then
            prefix = prefix .. string.rep(" ", origin.list_column)
            stripped = strip_container_prefix(stripped, origin.list_column + 4, code_column)
          end
          self:add_line(prefix .. stripped, {
            { col = #indent, end_col = #prefix, hl = "FloatBorder" },
            { col = #prefix, end_col = -1, hl = "String" },
          })
          detect_urls_in_code_line(self, stripped, #prefix, #prefix + #stripped)
          handled = true
        end
      end

      if not handled then
        -- Detect image lines: ![alt](path), <img src="path">, ![[image]]
        local img_path, img_alt
        if not current_alert_type then
          -- Markdown image: ![alt](path) (standalone on line)
          -- Headings containing only an image retain the same media presentation.
          local image_text = quote_depth == 0 and atx_content or line
          img_alt, img_path = image_text:match "^%s*!%[([^%]]-)%]%(([^)]-)%)%s*$"
          -- Linked image: [![alt](img-path)](link-url) (standalone on line)
          if not img_path then
            img_alt, img_path = line:match "^%s*%[!%[(.-)%]%((.-)%)%]%(.-%)%s*$"
          end
          -- HTML img: <img src="path" alt="alt"> as sole content on line
          -- Also matches inside headings: # <img ...> or ## <img ...>
          if not img_path then
            local img_tag = image_text:match "^%s*(<img%s[^>]*>)%s*$"
            if img_tag then
              img_path = img_tag:match 'src="([^"]*)"' or img_tag:match "src='([^']*)'"
              img_alt = img_tag:match 'alt="([^"]*)"' or img_tag:match "alt='([^']*)'"
            end
          end
          -- HTML video: <video src="url">...</video> or <video><source src="url">...</video>
          if not img_path then
            local video_tag = line:match "^%s*(<video[%s>].-</video>)%s*$"
            if video_tag then
              img_path = video_tag:match 'src="([^"]*)"' or video_tag:match "src='([^']*)'"
              -- If no src on <video>, check for <source src="...">
              if not img_path then
                img_path = video_tag:match '<source[^>]*src="([^"]*)"' or video_tag:match "<source[^>]*src='([^']*)'>"
              end
              if img_path then img_alt = img_path:match "([^/]+)$" or img_path end
            end
          end
          -- CommonMark autolink to GitHub user-attachments CDN: <https://github.com/user-attachments/assets/...>
          -- These URLs have no extension; GitHub's web UI inlines them as <video>/<img>
          -- based on Content-Type. Restrict to this CDN so non-media URLs do not get
          -- stuck on a "Loading..." placeholder.
          if not img_path then
            local autolink_url = line:match "^%s*<(https?://github%.com/user%-attachments/[%w%-/%.]+)>%s*$"
            if autolink_url then
              img_path = autolink_url
              img_alt = autolink_url:match "([^/]+)$" or autolink_url
            end
          end
          -- Obsidian embed: ![[file]] or ![[file|caption]]
          if not img_path then
            local first, embed, last = line:match "^%s*()!%[%[(.-)%]%]()%s*$"
            local inline = require "md-render.inline"
            local pipe = embed and embed:find("|", 1, true)
            local target_end = embed and (pipe and first + 2 + pipe or last - 1)
            if
              embed and not inline.extension_owned(inline.standard_ranges(line, ref_links), first, last - 1, target_end)
            then
              local target = embed:match "^([^|#]+)" or embed
              local ext = target:match "%.(%w+)$"
              local img_exts = { png = true, jpg = true, jpeg = true, gif = true, webp = true, bmp = true, svg = true }
              local vid_exts = { mp4 = true, webm = true, mov = true, avi = true, mkv = true, m4v = true }
              if ext and (img_exts[ext:lower()] or vid_exts[ext:lower()]) then
                img_path = target
                local caption = embed:match "|(.+)$"
                img_alt = caption or target:match "([^/]+)$"
              end
            end
          end
        end

        -- Collect images: single image or multiple images on one line
        local img_entries = {}
        if img_path and img_path ~= "" then
          table.insert(img_entries, { alt = img_alt, path = img_path })
        elseif not current_alert_type then
          -- Multiple images on one line: ![alt](url) ![alt](url) ...
          -- Also supports linked images: [![alt](img)](url) mixed in
          local remainder = line:gsub("^%s+", ""):gsub("%s+$", "")
          if remainder:match "!%[" then
            local tmp = remainder
            -- Strip linked images [![alt](img)](url)
            tmp = tmp:gsub("%[!%[.-%]%(.-%)]%(.-%)", "")
            -- Strip plain images ![alt](url)
            tmp = tmp:gsub("!%[.-%]%(.-%)", "")
            -- If only whitespace remains, the line is composed entirely of images
            if tmp:match "^%s*$" then
              for linked_alt, linked_path in remainder:gmatch "%[!%[(.-)%]%((.-)%)%]%(.-%)%s*" do
                table.insert(img_entries, { alt = linked_alt, path = linked_path })
              end
              for plain_alt, plain_path in remainder:gmatch "!%[(.-)%]%((.-)%)" do
                -- Skip images already captured as part of linked images
                local is_linked = false
                for _, entry in ipairs(img_entries) do
                  if entry.path == plain_path then
                    is_linked = true
                    break
                  end
                end
                if not is_linked then table.insert(img_entries, { alt = plain_alt, path = plain_path }) end
              end
            end
          end
        end

        for _, img_entry in ipairs(img_entries) do
          local image = require "md-render.image"

          -- Skip badge/shield URLs entirely — they are too small to render
          -- as block images and SVG badges cannot be displayed via Kitty protocol.
          if image.is_url(img_entry.path) and image.is_badge_url(img_entry.path) then goto continue_img end

          local is_video = image.is_video_file(img_entry.path)

          local resolved, src_url, display_cols, display_rows, is_animated
          local orig_img_w, orig_img_h

          if is_video then
            -- Video files: skip image_dimensions validation
            src_url = image.is_url(img_entry.path) and img_entry.path or nil
            if src_url then
              resolved = image.get_video_cached(src_url)
            else
              local video_path = vim.fn.expand(img_entry.path)
              if video_path:sub(1, 1) ~= "/" and buf_dir then video_path = buf_dir .. "/" .. video_path end
              if vim.fn.filereadable(video_path) == 1 then resolved = video_path end
              -- Fallback: try Obsidian vault resolution for local video files
              if not resolved and buf_dir then
                local obsidian = require "md-render.obsidian"
                resolved = obsidian.resolve(img_entry.path, buf_dir)
              end
            end
            is_animated = true
            local img_max_cols = max_width - 2
            if resolved then
              orig_img_w, orig_img_h = image.video_dimensions(resolved)
              if orig_img_w and orig_img_h then
                display_cols, display_rows =
                  image.calc_display_size(orig_img_w, orig_img_h, img_max_cols, opts.image_max_height or 25)
              end
            end
            if not display_cols then
              -- Video not yet cached or ffprobe unavailable: use placeholder size
              display_cols = math.floor(img_max_cols * 0.8)
              display_rows = 15
            end
          else
            resolved = image.resolve(img_entry.path, buf_dir)
            src_url = image.is_url(img_entry.path) and img_entry.path or nil
            local img_max_cols = max_width - 2
            if resolved then
              orig_img_w, orig_img_h = image.image_dimensions(resolved)
              if orig_img_w and orig_img_h then
                display_cols, display_rows =
                  image.calc_display_size(orig_img_w, orig_img_h, img_max_cols, opts.image_max_height or 25)
                is_animated = image.is_animated_gif(resolved)
              elseif image.is_video_content(resolved) then
                -- URL without video extension resolved to a video file
                is_video = true
                is_animated = true
                orig_img_w, orig_img_h = image.video_dimensions(resolved)
                if orig_img_w and orig_img_h then
                  display_cols, display_rows =
                    image.calc_display_size(orig_img_w, orig_img_h, img_max_cols, opts.image_max_height or 25)
                end
              end
            end
            if not display_cols then
              if src_url or is_video then
                display_cols = math.floor(img_max_cols * 0.8)
                display_rows = 15
              end
            end
          end

          local display_name = (img_entry.alt and img_entry.alt ~= "") and img_entry.alt
            or (img_entry.path:match "([^/]+)$" or img_entry.path)
          if image.supports_kitty() then
            if display_cols and display_rows then
              local raw_icon, icon_hl = icons.get_image_icon(img_entry.path)
              local img_icon = pad_icon(raw_icon)
              local header_lines_added =
                self:_emit_image_header(indent, img_icon, icon_hl, display_name, max_width, "Comment")
              local img_start_line = #self.lines
              -- Center the image horizontally
              local img_col = math.max(0, math.floor((max_width - display_cols) / 2))
              -- Show placeholder with background highlight while the image is loading.
              -- The image overlay (Kitty graphics) will cover this once loaded.
              local indent_width = vim.api.nvim_strwidth(indent)
              local placeholder_msg
              if is_video then
                placeholder_msg = "Loading video..."
              elseif is_animated then
                placeholder_msg = "Loading animation..."
              else
                placeholder_msg = "Loading image..."
              end
              local msg_width = vim.api.nvim_strwidth(placeholder_msg)
              local mid_row = math.floor(display_rows / 2) + 1
              for r = 1, display_rows do
                local spaces_to_img = math.max(0, img_col - indent_width)
                if r == mid_row and msg_width <= display_cols then
                  -- Center a short message within the image area
                  local pad = math.floor((display_cols - msg_width) / 2)
                  local right_pad = display_cols - pad - msg_width
                  local placeholder_line = indent
                    .. string.rep(" ", spaces_to_img)
                    .. string.rep(" ", pad)
                    .. placeholder_msg
                    .. string.rep(" ", right_pad)
                  local hl_start = #indent + spaces_to_img
                  self:add_line(placeholder_line, {
                    { col = hl_start, end_col = #placeholder_line, hl = "MdRenderImagePlaceholder" },
                  })
                else
                  local fill = indent .. string.rep(" ", spaces_to_img) .. string.rep(" ", display_cols)
                  local hl_start = #indent + spaces_to_img
                  self:add_line(fill, {
                    { col = hl_start, end_col = #fill, hl = "MdRenderImagePlaceholder" },
                  })
                end
              end
              table.insert(self.image_placements, {
                path = resolved,
                line = img_start_line,
                col = img_col,
                rows = display_rows,
                cols = display_cols,
                img_w = orig_img_w,
                img_h = orig_img_h,
                animated = is_animated,
                src_url = src_url,
                video = is_video,
              })
              lines_shown = lines_shown + header_lines_added + display_rows
              handled = true
            end
          end

          if not handled then
            -- Fallback: text-only display
            local raw_icon, icon_hl = icons.get_image_icon(img_entry.path)
            local img_icon = pad_icon(raw_icon)
            local fb_lines = self:_emit_image_header(indent, img_icon, icon_hl, display_name, max_width, "Underlined")
            lines_shown = lines_shown + fb_lines
            handled = true
          end
          ::continue_img::
        end

        -- Skip blank blockquote lines at callout boundaries (after header, before end)
        if not handled and current_alert_type and line:match "^>%s*$" then
          local should_skip = prev_was_heading
          if not should_skip then
            local found_next = false
            for k = src_idx + 1, #lines do
              local kl = lines[k]
              if not kl:match "^%s*$" then
                should_skip = not kl:match "^>"
                found_next = true
                break
              end
            end
            if not found_next then
              should_skip = true -- end of document = callout ends
            end
          end
          if should_skip then handled = true end
        end

        if not handled then
          -- Details add their prefix and background after rendering. Leave
          -- image headings as text until those transforms carry image geometry.
          local text_scale = self.text_scale
          if (in_details or current_alert_type) and is_heading and self:heading_renderer() == "image" then
            self.text_scale = false
          end
          -- Reserve the prefix that apply_details_body_prefix() adds later.
          local text_width = base_max_width
          if in_details and details_summary_rendered and not skip_details_body then
            text_width = math.max(1, text_width - vim.fn.strdisplaywidth "│ ")
          end
          local alert_type, fold_mod = self:add_markdown_line(
            line,
            indent,
            text_width,
            repo_base_url,
            autolinks,
            ref_links,
            footnote_map,
            paragraph_sources[src_indices[src_idx]],
            { heading_level = setext_rank, list_marker = leaf_marker, quote_prefix = quote_prefix }
          )
          self.text_scale = text_scale
          local lines_after = #self.lines
          if alert_type then
            current_alert_type = alert_type
            alert_container, alert_depth = container_indent, quote_depth
            is_heading = true -- suppress blank line after header (like heading)

            if fold_mod then
              local is_collapsed
              if fold_state[src_indices[src_idx]] ~= nil then
                is_collapsed = fold_state[src_indices[src_idx]]
              else
                is_collapsed = (fold_mod == "-")
              end
              self:add_fold_indicator(lines_before, is_collapsed)
              table.insert(self.callout_folds, {
                header_line = lines_before,
                source_line = src_indices[src_idx],
                collapsed = is_collapsed,
              })
              if is_collapsed then skip_callout_body = true end
            end

            self:apply_alert_styling(lines_before, #self.lines, current_alert_type, true)
          elseif current_alert_type and line:match "^>" then
            self:apply_alert_styling(lines_before, lines_after, current_alert_type, false)
          else
            current_alert_type = nil
          end
        end
      end
    end

    -- Apply │ prefix to lines rendered within <details> body
    if in_details and details_summary_rendered and not skip_details_body then
      local lines_after_render = #self.lines
      if lines_after_render > lines_before then apply_details_body_prefix(lines_before, lines_after_render) end
    end

    local lines_added = #self.lines - lines_before
    lines_shown = lines_shown + lines_added

    -- Only update rendered-state tracking when lines were actually added;
    -- code fence open/close inside callout code blocks produce no output
    -- and must not reset prev_rendered_blank.
    if lines_added > 0 then
      prev_was_heading = is_heading
      prev_rendered_blank = is_blank
      if not is_blank then
        prev_list_marker_type = list_bases[src_indices[src_idx]] ~= nil
          and markdown.list_marker_type(source_list_lines[src_idx])
      end
    end

    if lines_shown >= max_lines then
      self:add_line(indent .. "... (truncated)", { { col = 0, end_col = -1, hl = "Comment" } })
      truncated = true
      break
    end

    ::continue::
  end

  if in_callout_code_block then finish_quote_code() end
  if in_html_table and not truncated then release_html_table() end
  if in_details_summary and not truncated then finish_details_summary() end
  if in_figure and not truncated then render_figure_caption(figure_indent, figure_width) end
  if in_code_block then
    local before = #self.lines
    finish_code_block(base_indent .. code_container_indent, math.max(1, base_max_width - #code_container_indent))
    if in_details and details_summary_rendered and not skip_details_body and #self.lines > before then
      apply_details_body_prefix(before, #self.lines)
    end
  end

  -- Flush any remaining table lines at end of document
  if not truncated then
    flush_table()
    if lines_shown >= max_lines then
      self:add_line(base_indent .. "... (truncated)", { { col = 0, end_col = -1, hl = "Comment" } })
    end
  end

  -- Render footnote section at end of document
  if not truncated and #footnote_defs > 0 then
    -- Separator
    self:add_line(base_indent)
    local rule = base_indent .. string.rep("─", base_max_width)
    self:add_line(rule, { { col = 0, end_col = #rule, hl = "FloatBorder" } })

    for _, def in ipairs(footnote_defs) do
      local num = footnote_map[def.label]
      local prefix = base_indent .. to_superscript(num) .. " "
      local prefix_display_width = vim.api.nvim_strwidth(prefix)
      local rendered_text, md_highlights, md_links =
        markdown.render(def.text, repo_base_url, autolinks, ref_links, footnote_map, true)

      local full_text = prefix .. rendered_text
      local def_first_line = #self.lines -- 0-indexed line where this def starts
      if vim.api.nvim_strwidth(full_text) > base_max_width then
        -- Wrap: use prefix on first line, spaces on continuation lines
        local content_max_width = base_max_width - prefix_display_width
        local wrapped_lines, line_starts = wrap_words(rendered_text, content_max_width)
        local continuation = string.rep(" ", prefix_display_width)

        -- Distribute highlights/links across wrapped lines (content_offset=0, no quote/list)
        local per_line_hls = distribute_highlights(md_highlights, wrapped_lines, line_starts, "", "", 0, 0, 0)
        local base_line = #self.lines
        local link_entries = distribute_links(md_links, wrapped_lines, line_starts, "", "", 0, base_line, 0, 0)

        for idx, wline in ipairs(wrapped_lines) do
          local line_prefix = idx == 1 and prefix or (base_indent .. continuation:sub(#base_indent + 1))
          local actual_prefix = idx == 1 and prefix or continuation
          local line_hls = {}
          -- Shift highlights by prefix length
          for _, hl in ipairs(per_line_hls[idx]) do
            table.insert(line_hls, {
              col = hl.col + #actual_prefix,
              end_col = hl.end_col + #actual_prefix,
              hl = hl.hl,
            })
          end
          if idx == 1 then table.insert(line_hls, { col = #base_indent, end_col = #prefix, hl = "Special" }) end
          table.insert(line_hls, { col = 0, end_col = -1, hl = "Comment" })
          self:add_line(line_prefix .. wline, line_hls)
        end

        -- Shift link entries by prefix length
        for _, entry in ipairs(link_entries) do
          local line_idx = entry.line - base_line
          local actual_prefix = line_idx == 0 and prefix or continuation
          entry.col_start = entry.col_start + #actual_prefix
          entry.col_end = entry.col_end + #actual_prefix
          table.insert(self.link_metadata, entry)
        end
      else
        -- No wrapping needed
        local prefix_len = #prefix
        for _, hl in ipairs(md_highlights) do
          hl.col = hl.col + prefix_len
          hl.end_col = hl.end_col + prefix_len
        end
        for _, link in ipairs(md_links) do
          link.col_start = link.col_start + prefix_len
          link.col_end = link.col_end + prefix_len
        end

        local line_hls = {}
        table.insert(line_hls, { col = #base_indent, end_col = #prefix, hl = "Special" })
        for _, hl in ipairs(md_highlights) do
          table.insert(line_hls, hl)
        end
        table.insert(line_hls, { col = 0, end_col = -1, hl = "Comment" })

        self:add_line(full_text, line_hls)

        local base_line = #self.lines - 1
        for _, link in ipairs(md_links) do
          table.insert(self.link_metadata, {
            line = base_line,
            col_start = link.col_start,
            col_end = link.col_end,
            url = link.url,
          })
        end
      end

      -- Register footnote definition anchor and back-link on the superscript number
      self.footnote_anchors["footnote-def-" .. def.label] = def_first_line
      table.insert(self.link_metadata, {
        line = def_first_line,
        col_start = #base_indent,
        col_end = #prefix - 1, -- superscript number (exclude trailing space)
        url = "#footnote-ref-" .. def.label,
      })
    end
  end
end

---@class MdRender.RenderDocumentOpts
---@field max_width? integer Maximum display width (default: 80)
---@field indent? string Indentation prefix (default: "  ")
---@field max_lines? integer Maximum number of rendered lines (default: unlimited)
---@field repo_base_url? string Repository base URL for issue/PR references
---@field autolinks? MdRender.Autolink[] Autolink definitions
---@field fold_state? table<integer, boolean> Callout fold state by source line
---@field expand_state? table<integer, boolean> Expandable region state by block id
---@field source_line_offset? integer Offset added to src_idx for source_line_map (default: 0)
---@field buf_dir? string Directory of the source buffer for resolving relative paths (default: vim.fn.expand("%:p:h"))

local M = {}
M.ContentBuilder = ContentBuilder
return M
