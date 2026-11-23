--- Show the available image action in the preview that owns it.
local M = {}
local ns = vim.api.nvim_create_namespace "md_render_image_hint"
local active

function M.hide()
  if not active then return end
  local hint = active
  active = nil
  if vim.api.nvim_buf_is_valid(hint.buf) then vim.api.nvim_buf_del_extmark(hint.buf, ns, hint.mark) end
end

-- Search only the selected image's caption and its left margin. Empty cells
-- inside the image rectangle can contain Kitty graphics instead of text.
local function hint_position(win, buf, p, text)
  local info = vim.fn.getwininfo(win)[1]
  local left = p.cell_col or 0
  local right = p.cell_cols and left + p.cell_cols or math.huge
  local full_width = vim.api.nvim_strwidth(text) + 1
  local best
  local function consider(row, byte, limit)
    if byte < 0 then return end
    local pos = vim.fn.screenpos(win, row, byte + 1)
    if pos.row == 0 or pos.col == 0 then return end
    local room = math.min(full_width, limit, info.wincol + info.width - pos.col)
    if not best or room > best.room then best = { row = row, byte = byte, room = room } end
    return room == full_width
  end

  for row = math.min(p.line, info.botline), math.max(p.line - (p.label_rows or 1) + 1, info.topline), -1 do
    local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
    local first = p.cell_cols and vim.fn.virtcol2col(win, row, left + 1) or 1
    local last = p.cell_cols and vim.fn.virtcol2col(win, row, right + 1) - 1 or #line
    local caption = line:sub(first, last):gsub("%s+$", "")
    local byte = first - 1 + #caption
    local col = vim.fn.virtcol({ row, byte + 1 }, false, win) - 1
    if consider(row, byte, right - col) then break end
  end

  -- Single-row Snacks images can start at an inline extmark's byte column.
  -- Multiline images reserve their layout columns in both backends.
  local row = math.max(p.line + 1, info.topline)
  if p.rows > 1 and row <= math.min(p.line + p.rows, info.botline) and p.col > left then
    local byte = p.cell_cols and vim.fn.virtcol2col(win, row, left + 1) - 1 or 0
    local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
    local next_text = line:find("[^ ]", byte + 1)
    consider(row, byte, math.min(p.col - left, next_text and next_text - byte - 1 or math.huge))
  end
  if not best then return end
  local key = text:match "^%w+"
  for _, label in ipairs { text, key, key == "Enter" and "↵" or "🖱" } do
    if vim.api.nvim_strwidth(label) + 1 <= best.room then return best.row, best.byte, " " .. label end
  end
end

function M.show(win, p, text)
  local buf = vim.api.nvim_win_get_buf(win)
  local row, byte, label = hint_position(win, buf, p, text)
  if not row then return M.hide() end
  if active and active.win == win and active.buf == buf and active.text == label then
    local mark = vim.api.nvim_buf_get_extmark_by_id(buf, ns, active.mark, {})
    if mark[1] == row - 1 and mark[2] == byte then return true end
  end
  M.hide()
  vim.api.nvim__ns_set(ns, { wins = { win } })
  local mark = vim.api.nvim_buf_set_extmark(buf, ns, row - 1, byte, {
    virt_text = { { label, "Special" } },
    virt_text_pos = "overlay",
    priority = 250,
  })
  active = { win = win, buf = buf, text = label, mark = mark }
  return true
end

function M.refresh()
  local win = vim.api.nvim_get_current_win()
  local session = require("md-render.preview")._sessions[vim.api.nvim_win_get_buf(win)]
  if not session or not session._keymap_opts or vim.api.nvim_get_mode().mode ~= "n" then return M.hide() end
  local cursor = vim.api.nvim_win_get_cursor(win)
  local p, index = session:image_at(cursor[1] - 1, vim.fn.virtcol "." - 1)
  local hint = p and session:image_view_hint(p, index)
  if hint and vim.fn.maparg("<CR>", "n", false, true).callback == session._keymap_opts.image_enter then
    local url = require("md-render.links").at(session.buf, session.ns, cursor[1] - 1, cursor[2])
    if not url or url:sub(1, 1) ~= "#" then return M.show(win, p, hint) end
  end
  M.hide()
end

local scheduled = false
function M.schedule()
  if scheduled then return end
  scheduled = true
  vim.schedule(function()
    scheduled = false
    M.refresh()
  end)
end

-- :noautocmd close can remove a preview without firing any leave event.
-- Clear its buffer mark outside textlock when another split keeps the buffer alive.
vim.api.nvim_set_decoration_provider(ns, {
  on_start = function()
    if active and (not vim.api.nvim_win_is_valid(active.win) or vim.api.nvim_win_get_buf(active.win) ~= active.buf) then
      M.schedule()
    end
    return false
  end,
})

local group = vim.api.nvim_create_augroup("md_render_image_hint", { clear = true })
vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "TabLeave" }, { group = group, callback = M.hide })
vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled", "WinResized", "WinEnter", "BufEnter", "ModeChanged" }, {
  group = group,
  callback = function()
    if active or vim.b.md_render then M.schedule() end
  end,
})

return M
