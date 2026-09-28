--- Preserve a visible heading target across native mouse press/drag/release.
local M = {}

function M.attach(state, project, repaint, erase)
  state.key_ns = state.key_ns or vim.api.nvim_create_namespace("md_render_heading_keys_" .. state.win)
  vim.on_key(function(key, typed)
    local event = typed ~= "" and typed or key
    if event == vim.keycode "<C-l>" then state.last_layout = nil end
    if event == vim.keycode "<LeftMouse>" and vim.o.mouse ~= "" then
      state.gesture, state.press, state.dragged = nil, nil, nil
      local raw = vim.fn.getmousepos()
      local mouse, projected, entry = project(raw)
      if projected and mouse.winid == state.win then
        state.gesture = entry
        if mouse.line > 0 then state.press = mouse end
        local gesture = state.gesture
        -- Let Neovim focus the window and process the press before correcting
        -- the drag origin. Replaying mouse input here corrupts TUI redraws.
        vim.schedule(function()
          if
            not state.closed
            and mouse.line > 0
            and state.gesture == gesture
            and vim.api.nvim_get_current_win() == state.win
            and vim.api.nvim_win_get_buf(state.win) == state.buf
            and vim.api.nvim_get_mode().mode == "n"
          then
            vim.api.nvim_win_set_cursor(state.win, { mouse.line, mouse.column - 1 })
          end
          repaint(state)
        end)
      end
    elseif event == vim.keycode "<LeftRelease>" then
      -- The release mapping clears the gesture after resolving the visible
      -- target. Scheduling here can run before a mapped release is dispatched.
      return
    elseif event == vim.keycode "<LeftDrag>" then
      if state.gesture then state.dragged = true end
      -- Press and drag can arrive in the same input batch, before scheduled
      -- cursor correction. The native press has completed by this point.
      if
        state.gesture
        and state.press
        and vim.api.nvim_get_current_win() == state.win
        and vim.api.nvim_win_get_buf(state.win) == state.buf
        and vim.api.nvim_get_mode().mode == "n"
      then
        vim.api.nvim_win_set_cursor(state.win, { state.press.line, state.press.column - 1 })
      end
      state.gesture, state.press = nil, nil
      erase(state)
    elseif event ~= vim.keycode "<MouseMove>" and typed and typed ~= "" then
      state.gesture, state.press, state.dragged = nil, nil, nil
      repaint(state)
    end
  end, state.key_ns)
end

return M
