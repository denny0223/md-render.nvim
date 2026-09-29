-- Use real Neovim input to verify native heading cursor, click and drag semantics.
local child = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-i", "NONE" }, { rpc = true })
local function lua(code, ...)
  return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
end
local ok, err = pcall(function()
  lua [[
    package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
    vim.o.mouse, vim.o.mousetime = "a", 0
    vim.o.termguicolors = true
    vim.o.lines, vim.o.columns = 45, 120
    vim.api.nvim_ui_send = function() end
    _G.size = require "md-render.text_size"
    size.supports = function() return true end
    size.setup { backend = "native" }
    vim.bo.filetype = "markdown"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "Body", "", "## [FIRST](#first) [SECOND](#second)", "", "## First", "", "## Second",
    })
    local preview = require "md-render.preview"
    preview.toggle()
    _G.session = preview._sessions[vim.api.nvim_get_current_buf()]
    _G.events = 0
    vim.on_key(function() events = events + 1 end)
    vim.cmd "redraw"
  ]]
  local function ready()
    assert(
      vim.wait(1000, function()
        return lua "return #(session.text_size_state.drawn or {}) == 3"
      end, 5),
      "native headings did not become visible"
    )
  end
  local function reset()
    lua [[
      vim.cmd("normal! " .. vim.keycode "<Esc>")
      vim.cmd "normal! gg0"
      vim.api.nvim_exec_autocmds("SafeState", {})
      vim.cmd "redraw"
    ]]
    ready()
  end
  local function mouse(action, row, col)
    local events = lua "return events"
    local pos =
      lua [[local p=session.content.text_placements[1]; return vim.fn.screenpos(session.win,p.line+1,p.col+1)]]
    vim.rpcrequest(child, "nvim_input_mouse", "left", action, "", 0, pos.row - 1 + row, pos.col - 1 + col)
    assert(
      vim.wait(1000, function()
        return lua "return events" > events
      end, 5),
      "input was not processed"
    )
  end
  ready()
  for _, cursorline in ipairs { false, true } do
    lua("vim.wo.cursorline = ...", cursorline)
    for _, target in ipairs { { "first", 2 }, { "second", 16 } } do
      for _, row in ipairs { 0, 1 } do
        mouse("press", row, target[2])
        lua [[vim.api.nvim_exec_autocmds("SafeState", {})]]
        mouse("release", row, target[2])
        assert(
          lua "return vim.api.nvim_win_get_cursor(session.win)[1]"
            == lua("return session.content.heading_anchors[...] + 1", target[1]),
          "click lost visible " .. target[1] .. " on row " .. row
        )
        reset()
      end
    end
  end
  -- FIRST occupies ten native cells, followed by a two-cell space. Its tenth
  -- cell is rounded padding and must not activate the source link underneath.
  mouse("press", 1, 9)
  mouse("release", 1, 9)
  assert(
    lua "return vim.api.nvim_win_get_cursor(session.win)[1] ~= session.content.heading_anchors.first + 1",
    "padding activated a link"
  )
  reset()
  mouse("press", 1, 2)
  assert(
    lua "return vim.api.nvim_win_get_cursor(session.win)[2] == session.content.text_placements[1].col + 1",
    "press must project the drag origin"
  )
  mouse("drag", 0, 8)
  mouse("release", 0, 8)
  assert(lua "return vim.fn.mode() == 'v'", "drag must enter Visual mode")
  lua [[vim.cmd "normal! y"]]
  assert(lua [[return vim.fn.getreg('"')]] == "IRST SEC", "drag must start at the visible native character")
  reset()
  lua [[
    local p=session.content.text_placements[1]
    local pos=vim.fn.screenpos(session.win,p.line+1,p.col+1)
    vim.api.nvim_input_mouse("left","press","",0,pos.row,pos.col+15)
    vim.api.nvim_input_mouse("left","release","",0,pos.row,pos.col+15)
  ]]
  assert(
    vim.wait(1000, function()
      return lua "return vim.api.nvim_win_get_cursor(session.win)[1] == session.content.heading_anchors.second + 1"
    end, 5),
    "batched click must retain the visible destination"
  )
  -- Keyboard navigation uses ordinary text cells. Entering SECOND must reveal
  -- that text before gf can follow it, with or without CursorLine enabled.
  lua [[
    require("md-render.preview").toggle()
    local cwd = vim.fn.getcwd()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "Body", "", "## [FIRST](" .. cwd .. "/README.md) [SECOND](" .. cwd .. "/README.zh-TW.md)",
    })
    require("md-render.preview").toggle()
    session = require("md-render.preview")._sessions[vim.api.nvim_get_current_buf()]
    session.follow_file = function(_, path) _G.followed = path end
  ]]
  for _, cursorline in ipairs { false, true } do
    lua(
      [[
      vim.wo.cursorline = ...
      _G.followed, _G.entry_frame = nil, nil
      local p = session.content.text_placements[1]
      vim.api.nvim_win_set_cursor(session.win, { p.line + 1, p.col - 1 })
      vim.cmd "redraw"
      size.paint(session.text_size_state)
      assert(#session.text_size_state.drawn == 1, "start enlarged at the margin")
      -- Registered after the renderer: observe its scheduled CursorMoved
      -- paint, without forcing redraw or waiting for the debounce timer.
      vim.api.nvim_create_autocmd("CursorMoved", { callback = function()
        if vim.api.nvim_win_get_cursor(session.win)[2] == p.col then
          vim.schedule(function() _G.entry_frame = #session.text_size_state.drawn end)
          return true
        end
      end })
    ]],
      cursorline
    )
    vim.rpcrequest(child, "nvim_input", "l")
    assert(
      vim.wait(1000, function()
        return lua "return entry_frame ~= nil"
      end, 5),
      "cursor input must be processed"
    )
    assert(lua "return entry_frame == 0", "text entry must reveal accurate cursor feedback without a debounce")
    vim.rpcrequest(child, "nvim_input", "6lgf")
    assert(
      vim.wait(1000, function()
        return lua "return followed == vim.fn.getcwd() .. '/README.zh-TW.md'"
      end, 5),
      "gf must follow the visible SECOND link"
    )
  end
  lua [[require("md-render.preview").toggle()]]
  assert(
    lua [[return require('md-render.text_size').mouse_position({winid=session.win}).column == nil]],
    "closed previews must not project stale targets"
  )
end)
pcall(vim.rpcnotify, child, "nvim_command", "qa!")
vim.fn.jobwait({ child }, 1000)
assert(ok, err)
print "Native heading mouse: upper/lower clicks, padding, CursorLine, drag/yank, keyboard gf and teardown OK"
