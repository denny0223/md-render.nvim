-- Process real Neovim mouse events; only the optional rasterizer is mocked.
local child = vim.fn.jobstart(
  { vim.v.progpath, "--embed", "--headless", "-n", "-u", "NONE", "--noplugin", "-i", "NONE" },
  { rpc = true }
)
local function lua(code, ...)
  return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
end
local ok, err = pcall(function()
  lua [[
    package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
    vim.o.mouse, vim.o.mousetime = "a", 0
    vim.o.termguicolors = true
    vim.o.lines, vim.o.columns = 40, 120
    vim.api.nvim_ui_send = function() end
    local image = require "md-render.image"
    image.supports_kitty = function() return true end
    image.get_cell_size = function() return { cell_w = 19, cell_h = 44 } end
    local id = 0
    image.png_status = function() return { supported = true } end
    image.transmit_png = function(_, callback) callback(); id = id + 1; return id end
    vim.system = function(_, opts, callback)
      local outputs = {}
      for index, request in ipairs(vim.json.decode(opts.stdin).requests) do
        local entry = request.entries[1]
        outputs[index] = { lines = {{ start = 0, ["end"] = #entry.text, text = entry.text,
          data = "png", cols = 19, width = 361, height = 88,
          columns = { 0, 0, 1, 1, 2, 2, 3, 4, 4, 5, 6, 6, 7, 8, 8, 9, 10, 10, 11 } }} }
        for col, byte in ipairs(outputs[index].lines[1].columns) do
          if byte >= #entry.text then outputs[index].lines[1].columns[col] = false end
        end
      end
      vim.schedule(function() callback { code = 0, stdout = vim.json.encode(outputs) } end)
      return { kill = function() end }
    end
    local size = require "md-render.text_size"
    size.supports = function() return true end
    size.setup { backend = "image" }
    vim.bo.filetype = "markdown"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, {
      "Body", "", "## [FIRST](#first) [SECOND](#second)", "", "## First", "", "## Second",
    })
    _G.source = vim.api.nvim_get_current_buf()
    _G.preview = require "md-render.preview"
    preview.toggle()
    _G.session = preview._sessions[vim.api.nvim_get_current_buf()]
    _G.events = 0
    vim.on_key(function() events = events + 1 end)
    vim.cmd "redraw"
  ]]
  local function ready()
    assert(
      vim.wait(1000, function()
        return lua "return session.text_size_state and session.text_size_state.drawn == 3"
      end, 5),
      "heading images did not become visible"
    )
  end
  local function mouse(button, action, lower, offset)
    local events = lua "return events"
    local pos = lua [[
      local p = session.text_size_state.entries[1].placement
      return vim.fn.screenpos(session.win, p.line + 1, p.col + 1)
    ]]
    vim.rpcrequest(child, "nvim_input_mouse", button, action, "", 0, pos.row - 1 + lower, pos.col - 1 + offset)
    assert(
      vim.wait(1000, function()
        return lua "return events" > events
      end, 5),
      "mouse input was not processed"
    )
  end
  local function reset()
    lua [[
      vim.cmd("normal! " .. vim.keycode "<Esc>")
      vim.api.nvim_set_current_win(session.win)
      vim.cmd "normal! gg"
      vim.api.nvim_exec_autocmds("SafeState", {})
      vim.cmd "redraw"
    ]]
    ready()
  end
  ready()
  for _, row in ipairs { 0, 1 } do
    mouse("move", "", row, 7)
    assert(
      lua "return require('md-render.display_utils').getmousepos().column == session.text_size_state.entries[1].placement.col + 5",
      "hover must keep the visible image target"
    )
    assert(
      lua "return session.text_size_state.entries[1].visible",
      "hover must not move a different link under the pointer"
    )
    mouse("left", "press", row, 7)
    mouse("left", "release", row, 7)
    assert(
      lua "return vim.api.nvim_win_get_cursor(session.win)[1] == session.content.heading_anchors.first + 1",
      "image click activated SECOND instead of FIRST"
    )
    reset()
  end

  -- A complete click can arrive in one batch, before cursor correction paints.
  lua [[
    local p = session.text_size_state.entries[1].placement
    local pos = vim.fn.screenpos(session.win, p.line + 1, p.col + 1)
    vim.api.nvim_input_mouse("left", "press", "", 0, pos.row, pos.col + 6)
    vim.api.nvim_input_mouse("left", "release", "", 0, pos.row, pos.col + 6)
  ]]
  assert(
    vim.wait(1000, function()
      return lua "return vim.api.nvim_win_get_cursor(session.win)[1] == session.content.heading_anchors.first + 1"
    end, 5),
    "batched image click lost its visible link"
  )
  reset()

  mouse("left", "press", 1, 7)
  assert(
    lua "return vim.api.nvim_win_get_cursor(session.win)[2] == session.text_size_state.entries[1].placement.col + 4",
    "a direct press must move to the image glyph before the drag"
  )
  mouse("left", "drag", 0, 9)
  mouse("left", "release", 0, 9)
  assert(lua "return vim.fn.mode() == 'v'", "drag must retain native Visual selection")
  lua [[vim.cmd "normal! y"]]
  assert(lua [[return vim.fn.getreg('"')]] == "T SECO", "drag started from the hidden native column")

  reset()
  lua [[
    local p = session.text_size_state.entries[1].placement
    local pos = vim.fn.screenpos(session.win, p.line + 1, p.col + 1)
    vim.api.nvim_input_mouse("left", "press", "", 0, pos.row, pos.col + 6)
    vim.api.nvim_input_mouse("left", "drag", "", 0, pos.row - 1, pos.col + 8)
    vim.api.nvim_input_mouse("left", "release", "", 0, pos.row - 1, pos.col + 8)
  ]]
  vim.wait(30)
  assert(
    lua "return vim.api.nvim_win_get_cursor(session.win)[1] == session.text_size_state.entries[1].placement.line + 1",
    "coalesced drag coordinates must not activate a link"
  )

  reset()
  lua [[
    vim.cmd "vnew"
    _G.other = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Other buffer" })
    vim.cmd "redraw"
  ]]
  ready()
  mouse("left", "press", 1, 7)
  assert(lua "return vim.api.nvim_get_current_win() == session.win", "click must focus an inactive preview")
  assert(
    lua "return vim.api.nvim_win_get_cursor(session.win)[2] == session.text_size_state.entries[1].placement.col + 4",
    "entering an inactive split lost the projected cursor"
  )
  mouse("left", "release", 1, 7)

  reset()
  lua [[
    _G.previous = session.text_size_state
    local original = session.win
    vim.cmd "split"
    _G.survivor = vim.api.nvim_get_current_win()
    vim.api.nvim_win_close(original, true)
  ]]
  assert(
    vim.wait(1000, function()
      return lua "return session.win == survivor"
    end, 5),
    "owner handoff did not complete"
  )
  ready()
  assert(lua "return previous.closed", "owner handoff left the old renderer active")
  mouse("left", "press", 1, 7)
  mouse("left", "release", 1, 7)
  assert(
    lua "return vim.api.nvim_win_get_cursor(survivor)[1] == session.content.heading_anchors.first + 1",
    "the surviving preview did not inherit image link input"
  )
  lua [[
    local current = session.text_size_state
    vim.api.nvim_win_close(survivor, true)
    assert(current.closed, "closing the last preview left its image input listener active")
  ]]

  -- Auto images must use the same local-file navigation and return history.
  lua [[
    _G.link_root = vim.fn.tempname()
    vim.fn.mkdir(link_root, "p")
    link_root = vim.uv.fs_realpath(link_root)
    vim.fn.writefile({"Body", "", "## Destination"}, link_root .. "/target.md")
    vim.api.nvim_win_set_buf(0, source)
    vim.api.nvim_buf_set_lines(source, 2, 3, false, {
      "## [FIRST](" .. link_root .. "/target.md) [SECOND](#second)",
    })
    require("md-render.text_size").setup { backend = "auto" }
    preview.toggle()
    _G.session = preview._sessions[vim.api.nvim_get_current_buf()]
    _G.link_origin = session.buf
    vim.cmd "normal! gg"
    vim.cmd "redraw"
  ]]
  ready()
  mouse("left", "press", 1, 7)
  mouse("left", "release", 1, 7)
  vim.rpcrequest(child, "nvim_input", "gf")
  assert(
    vim.wait(1000, function()
      return lua [[
      local target = preview._sessions[vim.api.nvim_get_current_buf()]
      return target and target.buf ~= link_origin
        and vim.api.nvim_buf_get_name(target.source_bufnr) == link_root .. "/target.md"
    ]]
    end, 5),
    "gf did not follow the projected image-heading link"
  )
  vim.rpcrequest(child, "nvim_input", "<C-o>")
  assert(
    vim.wait(1000, function()
      return lua "return vim.api.nvim_get_current_buf() == link_origin"
    end, 5),
    "native jump history did not return to the image-heading preview"
  )
  lua [[vim.fn.delete(link_root, "rf")]]
end)
vim.fn.jobstop(child)
assert(ok, err)
print "Heading mouse: image hover, links, native drag, inactive split and owner handoff OK"
