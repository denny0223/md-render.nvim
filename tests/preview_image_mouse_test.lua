-- Exercise screen coordinates, real press/drag/release ordering and link precedence.
local child = vim.fn.jobstart(
  { vim.v.progpath, "--embed", "--headless", "-n", "-u", "NONE", "-i", "NONE" },
  { rpc = true }
)
local function lua(source, ...)
  return vim.rpcrequest(child, "nvim_exec_lua", source, { ... })
end
local function until_true(source, reason)
  assert(
    vim.wait(1500, function()
      return lua(source)
    end, 5),
    reason
  )
end
local ok, err = pcall(function()
  vim.rpcrequest(child, "nvim_ui_attach", 110, 40, { rgb = true })
  lua [[
    vim.opt.rtp:prepend(vim.fn.getcwd())
    vim.o.messagesopt = "wait:0,history:50"
    -- Host tmux detection can rebuild headings while the stub image state is installed.
    require("md-render.text_size").setup {enabled=false}
    vim.o.lines, vim.o.columns = 40, 110
    vim.o.mouse, vim.o.mousetime = "a", 0
    local image = require "md-render.image"
    image.setup {backend="snacks"}
    image._set_kitty_supported(true)
    image._test_cell_size = {cell_w=1,cell_h=1}
    local disp = require "md-render.display_utils"
    disp.setup_images = function() end
    disp.supports_osc8 = function() return false end
    vim.ui.open = function(url) _G.followed = url end
    local has = vim.fn.executable
    vim.fn.executable = function(name) return name == "magick" and 1 or has(name) end
    local root = vim.fn.getcwd()
    _G.paths = {root.."/tests/fixtures/test_4x4.png",root.."/assets/demo/test.png"}
    vim.bo.filetype = "markdown"
    vim.api.nvim_buf_set_lines(0,0,-1,false,{
      "# Example", "", "| Left image | Right image |", "| --- | --- |",
      ("| [![左圖](%s)](https://example.invalid/left) | [![右圖](%s)](#end) |"):format(unpack(paths)),
      "", "# End",
    })
    local preview = require "md-render.preview"
    preview.show_tab { max_width=55, text_scale=false }
    _G.session = preview._sessions[vim.api.nvim_get_current_buf()]
    _G.p = session.content.image_placements
    _G.ready = {true,true}
    local ns = vim.api.nvim_create_namespace("snacks.image")
    _G.Snacks = {image = {placement = {ns = ns}}}
    session.image_state = {snacks=true, buf=session.buf, objects={}, placements=p}
    local glyph = vim.fn.nr2char(0x10EEEE)
    for n,a in ipairs(p) do
      local bytecol = n == 1 and 0 or a.col
      local opts = n == 1 and {virt_text_win_col=a.col} or {virt_text_pos="inline"}
      opts.virt_text = {{glyph:rep(n == 1 and a.cols or 3)}}
      local eid = vim.api.nvim_buf_set_extmark(session.buf,ns,a.line,bytecol,opts)
      session.image_state.objects[n] = {eids={eid},ready=function() return ready[n] end,close=function() end}
    end
    _G.opened = {}
    local viewer = require "md-render.image_view"
    local open = viewer.open
    require("md-render.async").run = function() end
    viewer.open = function(path, ...)
      table.insert(opened, path)
      _G.view = open(path, ...)
    end
    _G.hover = require("md-render.url_hover")._internal().state
    _G.imagepos = function(n, win)
      win = win or session.win
      local a = p[n]
      local pos = vim.fn.screenpos(win,a.line+1,1)
      if n == 1 then pos.col = pos.col + a.col
      else pos.col = vim.fn.screenpos(win,a.line+1,a.col+1).col + 1 end
      assert(vim.fn.screenchar(pos.row,pos.col) == 0x10EEEE)
      return pos
    end
    _G.linkpos = function(url)
      for _, l in ipairs(session.content.link_metadata) do
        if l.url == url then return vim.fn.screenpos(session.win,l.line+1,l.col_start+1) end
      end
    end
    _G.events = 0
    vim.on_key(function() events = events + 1 end)
    vim.cmd "redraw"
  ]]
  local function mouse(button, action, pos)
    local n = lua "return events"
    vim.rpcrequest(child, "nvim_input_mouse", button, action, "", 0, pos.row - 1, pos.col - 1)
    until_true("return events > " .. n, action .. " dispatched")
  end
  local function click(pos)
    mouse("left", "press", pos)
    mouse("left", "release", pos)
  end
  local function back()
    local pos = lua [[vim.cmd "redraw"; return vim.fn.screenpos(view.win,1,2)]]
    click(pos)
    until_true("return view.closed and vim.api.nvim_get_current_win() == session.win", "click Back returns to preview")
  end
  -- Pointer B must leave the keyboard target at A until B is clicked.
  lua [[
    vim.api.nvim_win_set_cursor(session.win,{p[1].line+1,vim.fn.virtcol2col(session.win,p[1].line+1,p[1].col+1)-1})
    vim.cmd "redraw"
  ]]
  mouse("move", "", lua "return imagepos(2)")
  vim.rpcrequest(child, "nvim_input", vim.keycode "<CR>")
  until_true("return opened[1] == paths[1]", "Enter opens A while pointer is over B")
  back()
  click(lua "return imagepos(2)")
  until_true("return opened[2] == paths[2]", "click opens B")
  back()
  local padding = lua [[
    local a=p[2]; local pos=vim.fn.screenpos(session.win,a.line+1,a.col+1)
    pos.col=pos.endcol
    assert(vim.fn.screenchar(pos.row,pos.col) ~= 0x10EEEE, "fixture must hit the text cell after the inline grid")
    return pos
  ]]
  click(padding)
  assert(lua "return #opened == 2", "the space after the inline grid must not open the image")
  local url = "https://example.invalid/left"
  local linked = lua("return linkpos(...)", url)
  mouse("move", "", linked)
  until_true("return hover.current_url == '" .. url .. "'", "linked caption shows URL")
  click(linked)
  until_true("return followed ~= nil and #opened == 2", "click preserves caption link")
  local right = lua "return imagepos(2)"
  lua [[ready[2] = false]]
  click(right)
  assert(lua "return #opened == 2", "not-ready image cannot open")
  lua [[ready[2] = true]]
  local outside = lua [[
    local first = p[1]
    return vim.fn.screenpos(session.win, first.line+1,vim.fn.virtcol2col(session.win,first.line+1,first.col+first.cols+1))
  ]]
  click(outside)
  assert(lua "return #opened == 2", "table padding must not open an image")
  local left = lua "return imagepos(1)"
  mouse("left", "press", left)
  mouse("left", "drag", right)
  mouse("left", "release", right)
  assert(lua "return #opened == 2", "drag selection does not open either image")
  vim.rpcrequest(child, "nvim_input", vim.keycode "<Esc>")
  click(lua [[return linkpos("#end")]])
  until_true(
    "return vim.api.nvim_win_get_cursor(session.win)[1] == session.content.heading_anchors['end']+1",
    "click follows section link"
  )
  lua [[
    vim.cmd "normal! gg"
    vim.cmd "aboveleft vnew"
    _G.other = vim.api.nvim_get_current_win()
    vim.cmd "redraw"
  ]]
  lua [[
    ready[1] = false
    _G.has_click_hint = function()
    local ns = vim.api.nvim_get_namespaces().md_render_image_hint
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(session.buf,ns,0,-1,{details=true})) do
      local label=vim.trim(m[4].virt_text[1][1])
      if label:match("^Click") or label=="🖱" then return true end
    end
    return false
    end
  ]]
  mouse("move", "", lua "return imagepos(1)")
  lua [[require("md-render.image_hint").refresh()]]
  assert(lua "return not has_click_hint()", "no hint before image delivery")
  lua [[ready[1] = true; require("md-render.image_hint").schedule()]]
  until_true("return has_click_hint()", "stationary pointer sees newly ready image in unfocused preview")
  assert(lua "return vim.api.nvim_get_current_win() == other", "hover preserves keyboard focus")
  lua [[
    _G.on_press = function() _G.custom_presses = (custom_presses or 0) + 1 end
    vim.keymap.set("n","<LeftMouse>",on_press,{buffer=0})
    require("md-render.image_hint").refresh()
  ]]
  assert(lua "return not has_click_hint()", "the focused buffer owns the press in the inactive preview")
  click(lua "return imagepos(1)")
  assert(lua "return custom_presses == 1 and #opened == 2 and vim.api.nvim_get_current_win() == other")
  vim.rpcrequest(child, "nvim_input", vim.keycode "<Esc>")
  lua [[
    vim.keymap.del("n","<LeftMouse>",{buffer=0})
    vim.keymap.set("n","<LeftMouse>",on_press,{buffer=session.buf})
  ]]
  click(lua "return imagepos(1)")
  until_true("return opened[3] == paths[1] and custom_presses == 1", "default press focuses the preview before release")
  back()
  mouse("move", "", lua "return imagepos(2)")
  lua [[require("md-render.image_hint").refresh()]]
  assert(lua "return not has_click_hint()", "custom preview press disables the click hint")
  click(lua "return imagepos(2)")
  assert(lua "return custom_presses == 2 and #opened == 3", "mapped press cannot also open the image on release")
  lua [[
    vim.keymap.del("n","<LeftMouse>",{buffer=session.buf})
    vim.keymap.set("n","<LeftDrag>",function() _G.custom_drag = true end,{buffer=session.buf})
  ]]
  local image_pos = lua "return imagepos(2)"
  mouse("left", "press", image_pos)
  mouse("left", "drag", image_pos)
  mouse("left", "release", image_pos)
  assert(lua "return custom_drag and #opened == 3", "a mapped drag back to the pressed cell cancels the click")
  lua [[
    vim.keymap.set('n','<LeftRelease>',function() _G.custom_click = true end,{buffer=session.buf})
  ]]
  mouse("move", "", lua "return imagepos(1)")
  lua [[require("md-render.image_hint").refresh()]]
  assert(lua "return not has_click_hint()", "user replacement disables the open hint")
  click(lua "return imagepos(1)")
  until_true("return custom_click and #opened == 3", "custom click mapping wins")
  -- The previous window keeps its painted Snacks buffer while the copy has yet
  -- to bind any renderer. Focusing the copy will retire the pressed placement.
  lua [[
    vim.keymap.set("n","<LeftRelease>",session._keymap_opts.image_click,{buffer=session.buf})
    vim.cmd "belowright split"
    duplicate = vim.api.nvim_get_current_win()
    vim.cmd "wincmd p"
    vim.cmd "redraw"
  ]]
  local copy_image = lua "return imagepos(2, duplicate)"
  mouse("move", "", copy_image)
  until_true("return has_click_hint()", "image painted in the inactive copy offers a click")
  mouse("left", "press", copy_image)
  -- Changing to a different render width can lay out a link under the pressed cell.
  lua [[
    local m=vim.fn.getmousepos()
    vim.api.nvim_buf_set_extmark(session.buf,session.ns,m.line-1,m.column-1,{
      end_col=m.column, url="https://example.invalid/reflowed"
    })
  ]]
  mouse("left", "release", copy_image)
  until_true("return opened[4] == paths[2]", "first click opens the painted image across the focus change")
  assert(lua "return followed ~= 'https://example.invalid/reflowed'", "focus reflow did not replace the pressed image")
  back()
  assert(lua "return vim.api.nvim_get_current_win() == duplicate", "the clicked copy is the reading window")
  lua [[assert(vim.v.errmsg == "", vim.v.errmsg)]]
end)
vim.fn.jobstop(child)
assert(ok, err)
print "Preview image mouse: focused/inactive windows, keyboard target, click-back, drag, readiness and links OK"
