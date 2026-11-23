-- Image tabs return to the specific window and reading position that opened them.
local back_label = "[Back]"
local M = { back_padding = string.rep(" ", #back_label) }

local mouse_actions = {
  ["<ScrollWheelUp>"] = "zoom_in",
  ["<ScrollWheelDown>"] = "zoom_out",
  ["<ScrollWheelLeft>"] = "ignore",
  ["<ScrollWheelRight>"] = "ignore",
  ["<LeftMouse>"] = "press",
  ["<LeftDrag>"] = "drag",
  ["<LeftRelease>"] = "release",
}
local owners = {}
-- :noautocmd close skips WinClosed, and a second split can keep the buffer alive.
vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace "md_render_image_tab_owner", {
  on_start = function()
    for view, cleanup in pairs(owners) do
      if not view.valid() then
        owners[view] = nil
        vim.schedule(function()
          if view.valid() then
            owners[view] = cleanup
          else
            cleanup()
          end
        end)
      end
    end
    return false
  end,
})

function M.open()
  local origin_win, origin_buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local origin_view = vim.fn.winsaveview()
  vim.cmd "tabnew"
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  local state = { win = win, buf = buf }
  vim.b[buf].md_render_image_view = true
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "wipe", false
  vim.bo[buf].filetype = "md-render-image"
  vim.wo[win].wrap, vim.wo[win].number, vim.wo[win].relativenumber = false, false, false
  vim.wo[win].signcolumn, vim.wo[win].foldcolumn = "no", "0"
  vim.wo[win].conceallevel, vim.wo[win].scrolloff = 2, 0
  local group = vim.api.nvim_create_augroup("md_render_image_view_" .. buf, { clear = true })
  state.group = group
  local mouse_ns = vim.api.nvim_create_namespace("md_render_image_mouse_" .. buf)
  -- The buffer can be split; only the owner receives Back gestures.
  vim.api.nvim__ns_set(mouse_ns, { wins = { win } })
  vim.api.nvim_buf_set_extmark(buf, mouse_ns, 0, 0, {
    virt_text = { { back_label } },
    virt_text_pos = "overlay",
    right_gravity = false,
  })
  local back_pressed

  -- The bookmark belongs to the image buffer, so a surviving split can still
  -- return to a document the reader revisited after the image owner closed.
  local track_origin = vim.api.nvim_create_autocmd("WinLeave", {
    buffer = origin_buf,
    callback = function()
      if not vim.api.nvim_buf_is_valid(buf) then return true end
      if vim.api.nvim_get_current_win() == origin_win then origin_view = vim.fn.winsaveview() end
    end,
  })
  -- WinClosed fires after Neovim selects its fallback and before WinEnter.
  local viewer_active = true
  vim.api.nvim_create_autocmd({ "WinEnter", "WinLeave" }, {
    group = group,
    callback = function(event)
      local current = vim.api.nvim_get_current_win()
      if event.event == "WinEnter" then
        viewer_active = current == win
      elseif current == win then
        back_pressed = nil
        if state.cancel_mouse then state.cancel_mouse() end
      end
    end,
  })
  function state.valid()
    return not state.closed
      and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_buf_is_valid(buf)
      and vim.api.nvim_win_get_buf(win) == buf
  end
  local function cleanup()
    if state.closed then return end
    state.closed = true
    vim.on_key(nil, mouse_ns)
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_clear_namespace(buf, mouse_ns, 0, -1) end
    owners[state] = nil
    if state.on_close then state.on_close() end
    pcall(vim.api.nvim_del_augroup_by_id, group)
  end
  local function origin_valid()
    return vim.api.nvim_win_is_valid(origin_win) and vim.api.nvim_win_get_buf(origin_win) == origin_buf
  end
  local function restore_view()
    if vim.api.nvim_get_current_win() ~= origin_win or vim.api.nvim_get_current_buf() ~= origin_buf then return end
    local cursor = vim.api.nvim_win_get_cursor(origin_win)
    if cursor[1] == origin_view.lnum and cursor[2] == origin_view.col then vim.fn.winrestview(origin_view) end
  end
  -- A split inherits the return keys. The last reader goes back to its source
  -- even if the window that owned the image has already gone away.
  local function go_back()
    if #vim.fn.win_findbuf(buf) > 1 then return vim.api.nvim_win_close(0, true) end
    if origin_valid() then vim.api.nvim_set_current_win(origin_win) end
    -- Entering the source can already close the image or repurpose its window.
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    restore_view()
  end
  for _, key in ipairs { "<CR>", "q", "<Esc>" } do
    vim.keymap.set("n", key, go_back, { buffer = buf, silent = true, desc = "Return from image" })
  end
  owners[state] = function()
    if state.closed then return end
    cleanup()
    if not origin_valid() or vim.api.nvim_win_get_tabpage(origin_win) ~= vim.api.nvim_get_current_tabpage() then
      return
    end
    -- The tabline can disappear when the viewer closes and scroll the source
    -- one row. A silent background close must not move the reader's view.
    local returned = viewer_active and vim.api.nvim_get_current_win() == origin_win
    if state.on_silent_return then state.on_silent_return(origin_win, returned) end
    if returned then restore_view() end
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      pcall(vim.api.nvim_del_autocmd, track_origin)
      cleanup()
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = cleanup })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    callback = function()
      cleanup()
      if not viewer_active or #vim.fn.win_findbuf(buf) > 1 then return end
      local fallback_win = vim.api.nvim_get_current_win()
      -- Finish the tab layout change before returning; background closes must
      -- leave the reader's current window alone, as must a newer navigation.
      vim.schedule(function()
        if vim.api.nvim_get_current_win() ~= fallback_win or not origin_valid() then return end
        vim.api.nvim_set_current_win(origin_win)
        restore_view()
      end)
    end,
  })
  vim.api.nvim_create_autocmd("BufLeave", {
    group = group,
    buffer = buf,
    callback = function()
      -- BufWinLeave is skipped when another split still shows this buffer.
      vim.schedule(function()
        if not state.valid() then cleanup() end
      end)
    end,
  })
  -- Native and Snacks tabs share the same press/release boundary. Image drags
  -- started by a backend keep their capture when the pointer crosses the header.
  vim.on_key(function(key)
    local action = mouse_actions[vim.fn.keytrans(key):gsub("^<[234]%-", "<")]
    if not action or not state.valid() then return end
    if vim.o.mouse == "" then
      back_pressed = nil
      if state.cancel_mouse then state.cancel_mouse() end
      return
    end
    local mouse = vim.fn.getmousepos()
    local over_back = mouse.winid == win
      and mouse.line == 1
      and mouse.column >= 1
      and mouse.column <= #back_label
      and vim.fn.screenpos(win, 1, mouse.column).row == mouse.screenrow
    if action == "press" then
      back_pressed = over_back
      if over_back then
        if state.cancel_mouse then state.cancel_mouse() end
        vim.api.nvim_set_current_win(win)
        return ""
      end
    elseif back_pressed then
      back_pressed = nil
      if action == "release" and over_back then go_back() end
      return ""
    end
    if state.on_mouse then return state.on_mouse(action, mouse) end
  end, mouse_ns)
  return state
end

return M
