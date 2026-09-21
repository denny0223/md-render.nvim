-- A child editor processes real mouse input while this script checks its state.
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
    vim.o.mouse, vim.o.mousescroll = "a", "ver:2,hor:4"
    vim.o.lines, vim.o.columns = 40, 120
    require("md-render.async").run = function() end
    local executable = vim.fn.executable
    vim.fn.executable = function(name) return name == "magick" and 1 or executable(name) end
    vim.system = function() return { kill = function() end } end
    require("md-render.image")._test_cell_size = { cell_w = 13, cell_h = 30 }
    _G.original_maps, _G.listeners = vim.api.nvim_get_keymap("n"), vim.on_key()
    _G.view = require("md-render.image_view").open "unused.png"
    vim.cmd "vnew"
    _G.other = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.tbl_map(tostring, vim.fn.range(1, 200)))
    _G.events, _G.mouse_keys = 0, {}
    vim.on_key(function(key)
      local name = vim.fn.keytrans(key)
      if name:find("ScrollWheel") or name:find("Left") then
        events = events + 1
        mouse_keys[name] = true
      end
    end)
    vim.cmd "redraw"
  ]]
  local function mouse(button, action, target, row, col)
    local pos = lua("return vim.api.nvim_win_get_position(" .. target .. ")")
    local events = lua "return events"
    vim.rpcrequest(child, "nvim_input_mouse", button, action, "", 0, pos[1] + (row or 3), pos[2] + (col or 3))
    assert(
      vim.wait(1000, function()
        return lua "return events" > events
      end, 5),
      "mouse input was not processed"
    )
  end
  local function center()
    lua [[
      view.x, view.y, view.zoom = 0.5, 0.5, 8
      vim.api.nvim_exec_autocmds("WinResized", {})
      vim.cmd "redraw"
    ]]
    return lua "return view.crop"
  end

  mouse("wheel", "up", "view.win")
  mouse("left", "press", "view.win")
  mouse("left", "drag", "view.win", 6, 6)
  mouse("left", "release", "view.win", 6, 6)
  assert(lua "return not view.crop", "scrolling before loading must be harmless")
  lua [[view.path, view.iw, view.ih = "unused.png", 6400, 3200]]
  center()
  for _, scroll in ipairs { { "up", 10 }, { "down", 8 } } do
    mouse("wheel", scroll[1], "view.win")
    assert(lua "return view.zoom" == scroll[2], "wheel must use the keyboard zoom step")
    assert(lua "return vim.api.nvim_get_current_win() == other", "zooming an inactive image must not steal focus")
  end
  lua [[vim.o.mousescroll = "ver:99,hor:0"]]
  mouse("wheel", "up", "view.win")
  assert(lua "return view.zoom == 10", "text scroll distance must not change the zoom step")
  lua [[vim.o.mousescroll = "ver:2,hor:4"]]
  for _, scroll in ipairs { { "up", 16 }, { "down", 1 } } do
    for _ = 1, 20 do
      mouse("wheel", scroll[1], "view.win")
    end
    assert(lua "return view.zoom" == scroll[2], "wheel zoom must stop at its limit")
  end

  center()
  lua [[_G.unchanged = vim.deepcopy(view.crop)]]
  mouse("wheel", "left", "view.win")
  mouse("wheel", "right", "view.win")
  assert(lua "return vim.deep_equal(view.crop, unchanged)", "horizontal wheel input must not pan the image")
  assert(lua "return vim.fn.getwininfo(view.win)[1].topline == 1", "wheel input scrolled image placeholders")

  center()
  lua [[_G.unchanged = vim.deepcopy(view.crop)]]
  lua [[vim.api.nvim_set_current_win(view.win); vim.cmd "redraw"]]
  local before = lua "return vim.fn.getwininfo(other)[1].topline"
  mouse("wheel", "down", "other")
  assert(
    lua "return vim.fn.getwininfo(other)[1].topline" > before,
    "wheel over another window must retain native scrolling"
  )
  assert(lua "return vim.deep_equal(view.crop, unchanged)", "wheel over another window moved the image")
  assert(lua "return vim.api.nvim_get_current_win() == view.win", "native scrolling changed focus")

  -- Grab the image: moving the pointer right/down moves the crop left/up.
  for _, delta in ipairs { { 5, 3 }, { -5, -3 }, { 5, -3 }, { -5, 3 } } do
    local crop = center()
    lua [[vim.api.nvim_set_current_win(other)]]
    mouse("left", "press", "view.win", 8, 10)
    assert(lua "return vim.api.nvim_get_current_win() == view.win", "grabbing an image must focus its window")
    mouse("left", "drag", "view.win", 8 + delta[2], 10 + delta[1])
    local after = lua "return view.crop"
    assert(math.abs(after.x - crop.x + delta[1] * crop.w / crop.cols) <= 1, "drag horizontal distance/direction")
    assert(math.abs(after.y - crop.y + delta[2] * crop.h / crop.rows) <= 1, "drag vertical distance/direction")
    mouse("left", "release", "view.win", 8 + delta[2], 10 + delta[1])
    assert(lua "return vim.fn.mode() == 'n'", "dragging must not select placeholder text")
  end

  -- A drag remains owned by its starting image when crossing another window.
  center()
  lua [[_G.unchanged = vim.deepcopy(view.crop); _G.other_view = vim.fn.getwininfo(other)[1] ]]
  mouse("left", "press", "view.win", 8, 10)
  mouse("left", "drag", "other", 8, 10)
  assert(lua "return not vim.deep_equal(view.crop, unchanged)", "drag must continue outside the image window")
  assert(lua "return vim.fn.getwininfo(other)[1].topline == other_view.topline", "image drag scrolled another window")
  mouse("left", "release", "other", 8, 10)
  lua [[_G.unchanged = vim.deepcopy(view.crop)]]
  mouse("left", "drag", "view.win", 6, 6)
  assert(lua "return vim.deep_equal(view.crop, unchanged)", "release outside the viewer must end the drag")

  -- Ordinary selection started elsewhere must never become an image drag.
  mouse("left", "press", "other", 8, 10)
  mouse("left", "drag", "view.win", 6, 6)
  mouse("left", "release", "view.win", 6, 6)
  assert(lua "return vim.deep_equal(view.crop, unchanged)", "drag started elsewhere moved the image")
  lua [[vim.cmd("normal! " .. vim.keycode "<Esc>")]]

  center()
  lua [[view.x, view.y = 0, 0; vim.api.nvim_exec_autocmds("WinResized", {})]]
  mouse("left", "press", "view.win", 4, 4)
  mouse("left", "drag", "view.win", 7, 9)
  assert(lua "return view.crop.x == 0 and view.crop.y == 0", "drag must stop at image edges")
  mouse("left", "drag", "view.win", 6, 8)
  assert(lua "return view.crop.x > 0 and view.crop.y > 0", "reversing a drag at an edge must move immediately")
  mouse("left", "release", "view.win", 6, 8)

  -- Fast repeated grabs include double/triple-click mouse keycodes.
  for _ = 1, 4 do
    center()
    mouse("left", "press", "view.win", 8, 10)
    mouse("left", "drag", "view.win", 9, 11)
    mouse("left", "release", "view.win", 9, 11)
    assert(lua "return vim.fn.mode() == 'n'", "repeated grabs selected text")
  end
  assert(lua 'return mouse_keys["<2-LeftMouse>"]', "test must exercise repeated-click keycodes")
  mouse("left", "press", "view.win", 8, 10)
  lua [[_G.unchanged = vim.deepcopy(view.crop); vim.api.nvim_set_current_win(other)]]
  mouse("left", "drag", "view.win", 9, 11)
  mouse("left", "release", "view.win", 9, 11)
  assert(lua "return vim.deep_equal(view.crop, unchanged)", "leaving the viewer must cancel its drag")

  lua [[
    assert(vim.deep_equal(original_maps, vim.api.nvim_get_keymap("n")), "image viewer changed global mappings")
    vim.api.nvim_set_current_win(other)
    vim.api.nvim_win_close(view.win, true)
    assert(view.closed and vim.on_key() == listeners + 1, "closing the viewer leaked its input listener")
  ]]
  before = lua "return vim.fn.getwininfo(other)[1].topline"
  mouse("wheel", "down", "other")
  assert(lua "return vim.fn.getwininfo(other)[1].topline" > before, "closing the viewer broke normal scrolling")
end)
vim.fn.jobstop(child)
assert(ok, err)
print "Image mouse input: wheel zoom, grab/drag, window capture, boundaries, native input and cleanup OK"
