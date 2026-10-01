-- Run: nvim --headless -u NONE --noplugin -l tests/preview_window_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local preview = require "md-render.preview"
local text_size = require "md-render.text_size"
text_size.setup { backend = "native" }
text_size.supports = function()
  return true
end
vim.api.nvim_ui_send = function() end
local image = require "md-render.image"
image.supports_kitty = function()
  return true
end
local image_path = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"
local detach_count = {}
local detach = text_size.detach
text_size.detach = function(state)
  if state then detach_count[state] = (detach_count[state] or 0) + 1 end
  detach(state)
end

local failures = 0
local function test(name, run)
  local source_win = vim.api.nvim_get_current_win()
  local source = vim.api.nvim_create_buf(false, false)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, {
    "![Fixture](" .. image_path .. ")",
    "",
    "[Jump](#target)",
    "",
    "## 日本中文共同文字",
    "",
    "Body",
    "",
    "## Target",
    "",
    "End",
  })
  vim.api.nvim_win_set_buf(source_win, source)
  vim.wo[source_win].number = true
  preview.split { mods = { vertical = true } }
  local session = preview._toggle_sessions[source]
  local original = session.win
  vim.api.nvim_set_current_win(original)
  vim.cmd.vsplit()
  local survivor = vim.api.nvim_get_current_win()

  local ok, err = pcall(run, session, original, survivor, source_win)
  if not ok then
    failures = failures + 1
    print("FAIL: " .. name .. ": " .. err)
  end
  local keep = vim.api.nvim_win_is_valid(source_win) and source_win or vim.api.nvim_get_current_win()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= keep then vim.api.nvim_win_close(win, true) end
  end
  if vim.api.nvim_buf_is_valid(source) then vim.api.nvim_buf_delete(source, { force = true }) end
  vim.wait(20, function()
    return false
  end)
end

local function close_owner(session, original, survivor)
  local old_images = assert(session.image_state, "fixture image renderer missing")
  vim.api.nvim_win_close(original, true)
  assert(
    vim.wait(100, function()
      return session.win == survivor
    end),
    "surviving preview did not take ownership"
  )
  assert(session.text_size_state.win == survivor, "headings still target the closed window")
  assert(session.text_size_state.keepalive_timer, "headings were not reattached")
  assert(old_images.closed, "old image renderer was not cleaned up")
  assert(
    vim.wait(500, function()
      local state = session.image_state
      return state and not state.closed and state.win == survivor and state.image_ids[image_path]
    end),
    "image was not transmitted for the surviving preview"
  )
end

test("closing the owner restores rendering without moving focus", function(session, original, survivor, source_win)
  local old_state = session.text_size_state
  vim.api.nvim_set_current_win(source_win)
  close_owner(session, original, survivor)
  assert(vim.api.nvim_get_current_win() == source_win, "handoff moved focus")
  assert(old_state.keepalive_timer == nil, "old renderer was not cleaned up")
  assert(detach_count[old_state] == 1, "closing the owner detached its renderer more than once")
  preview.rebuild_visible()
  assert(session.text_size_state.win == survivor, "textsize rebuild lost the owner")
end)

test("a duplicated preview can toggle back before the owner closes", function(session, _, survivor)
  preview.toggle()
  assert(vim.api.nvim_win_get_buf(survivor) == session.source_bufnr, "toggle lost the source association")
  assert(vim.wo[survivor].number, "toggle did not restore source window options")
end)

test("closing a duplicate leaves the current renderer running", function(session, original, survivor)
  local state = session.text_size_state
  vim.api.nvim_win_close(survivor, true)
  vim.wait(20)
  assert(session.win == original and session.text_size_state == state, "closing a duplicate replaced the owner")
  assert(state.keepalive_timer and not detach_count[state], "closing a duplicate detached the owner")
end)

test("handoff preserves customized buffer mappings", function(session, original, survivor)
  local custom = function() end
  vim.keymap.set("n", "<CR>", custom, { buffer = session.buf })
  vim.keymap.del("n", "za", { buffer = session.buf })
  close_owner(session, original, survivor)
  assert(vim.fn.maparg("<CR>", "n", false, true).callback == custom, "handoff replaced a custom mapping")
  assert(vim.fn.maparg("za", "n") == "", "handoff restored a deleted mapping")
end)

local function click_target(session, win)
  local mark
  for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(session.buf, session.ns, 0, -1, { details = true })) do
    if extmark[4].url == "#target" then mark = extmark end
  end
  assert(mark, "fixture link missing")
  local getmousepos = vim.fn.getmousepos
  vim.fn.getmousepos = function()
    return { winid = win, line = mark[2] + 1, column = mark[3] + 1 }
  end
  local ok, err = pcall(vim.fn.maparg("<LeftRelease>", "n", false, true).callback)
  vim.fn.getmousepos = getmousepos
  assert(ok, err)
  assert(vim.api.nvim_win_get_cursor(win)[1] == session.content.heading_anchors.target + 1, "link did not jump")
end

test("handoff preserves source navigation and mouse links", function(session, original, survivor)
  close_owner(session, original, survivor)
  click_target(session, survivor)
  local source_line = session:rendered_to_source(vim.api.nvim_win_get_cursor(survivor)[1])
  preview.split()
  local source_win = vim.api.nvim_get_current_win()
  assert(vim.api.nvim_win_get_buf(source_win) == session.source_bufnr, "split did not open the source")
  vim.api.nvim_win_close(source_win, true)
  vim.api.nvim_set_current_win(survivor)
  preview.toggle()
  assert(vim.api.nvim_win_get_buf(survivor) == session.source_bufnr, "toggle did not return to source")
  assert(vim.api.nvim_win_get_cursor(survivor)[1] == source_line, "toggle lost the source position")
  assert(vim.wo[survivor].number, "source window options were lost")
end)

test(
  "split copies retain their own source options across later bindings",
  function(session, original, survivor, source_win)
    vim.api.nvim_set_current_win(source_win)
    vim.wo[source_win].number = false
    preview.toggle()
    vim.api.nvim_set_current_win(original)
    preview.toggle()
    vim.api.nvim_win_set_buf(original, session.buf) -- Returning via :buffer leaves the saved mode as source.
    vim.cmd "tab split"
    preview.toggle()
    assert(vim.api.nvim_get_current_buf() == session.source_bufnr, "tab copy lost its source")
    assert(vim.wo.number, "tab copy inherited options from another preview")
    vim.cmd.tabclose()
    vim.api.nvim_set_current_win(survivor)
    preview.toggle()
    assert(vim.wo.number, "existing split copy inherited options from another preview")
    assert(not vim.w[source_win].md_render_state.source_wo.number, "another window's saved options were changed")
  end
)

test("auto mode follows the source opened by MdRender split", function(session)
  preview.auto_on()
  preview.split()
  preview.auto_off()
  assert(vim.api.nvim_get_current_buf() == session.source_bufnr, "auto off rendered the source split")
  assert(not vim.b[session.source_bufnr].md_render_auto, "auto off did not disable the source")
  preview.auto_on()
  assert(vim.api.nvim_get_current_buf() == session.buf, "auto on left the source split unrendered")
  preview.auto_off()
end)

test("copied state cannot redirect auto mode to another document", function(session)
  preview.auto_on()
  vim.cmd.new()
  local other = vim.api.nvim_get_current_buf()
  vim.bo[other].filetype = "markdown"
  vim.api.nvim_buf_set_lines(other, 0, -1, false, { "## Other", "", "Body" })
  preview.auto_off()
  assert(vim.b[session.source_bufnr].md_render_auto, "auto off changed the previous document")
  assert(vim.api.nvim_get_current_buf() == other, "auto off rendered an unrelated buffer")
  preview.auto_on()
  assert(vim.b[other].md_render_auto, "auto on targeted the previous document")
  assert(
    vim.api.nvim_get_current_buf() == preview._toggle_sessions[other].buf,
    "auto on did not render the new document"
  )
  preview.auto_off()
  vim.api.nvim_buf_delete(other, { force = true })
end)

test("closing the last preview releases the owner", function(session, original, survivor)
  close_owner(session, original, survivor)
  local state = session.text_size_state
  vim.api.nvim_win_close(survivor, true)
  assert(
    vim.wait(100, function()
      return session.win == nil
    end),
    "closed owner remained attached"
  )
  assert(session.text_size_state == nil and state.keepalive_timer == nil, "renderer resources survived the last window")
end)

test("a queued handoff cannot replace a newer binding", function(session, original, _, source_win)
  vim.api.nvim_win_close(original, true)
  vim.api.nvim_set_current_win(source_win)
  preview.toggle()
  local state = session.text_size_state
  vim.wait(100, function()
    return false
  end)
  assert(session.win == source_win and session.text_size_state == state, "stale close callback replaced the owner")
end)

test("source wipe cancels a queued handoff", function(session, original)
  vim.api.nvim_win_close(original, true)
  vim.api.nvim_buf_delete(session.source_bufnr, { force = true })
  vim.wait(100, function()
    return false
  end)
  assert(not vim.api.nvim_buf_is_valid(session.buf), "source wipe left its preview alive")
  assert(session.image_state == nil and session.text_size_state == nil, "source wipe restarted a renderer")
end)

test("textsize rebuild recovers when WinClosed was suppressed", function(session, original, survivor)
  local old = vim.o.eventignore
  vim.o.eventignore = "WinClosed"
  vim.api.nvim_win_close(original, true)
  vim.o.eventignore = old
  preview.rebuild_visible()
  assert(
    session.win == survivor and session.text_size_state.win == survivor,
    "explicit rebuild did not recover the owner"
  )
end)

test("pager mouse links follow the surviving renderer", function(_, _, _, source_win)
  vim.api.nvim_set_current_win(source_win)
  vim.cmd.vsplit()
  preview.show_pager()
  local session = preview._sessions[vim.api.nvim_get_current_buf()]
  local original = session.win
  vim.cmd.vsplit()
  local survivor = vim.api.nvim_get_current_win()
  vim.api.nvim_win_close(original, true)
  assert(
    vim.wait(100, function()
      return session.win == survivor
    end),
    "pager did not take ownership"
  )
  click_target(session, survivor)
  vim.api.nvim_win_close(survivor, true)
end)

test("pager return replaces resources and ignores late image and heading callbacks", function(_, _, _, source_win)
  vim.api.nvim_set_current_win(source_win)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= source_win then vim.api.nvim_win_close(win, true) end
  end
  vim.wait(30)
  local source = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(source, 0, -1, false, { "## Pager", "", "![Fixture](" .. image_path .. ")" })
  vim.bo[source].modified = false
  local path = vim.fn.tempname() .. ".txt"
  vim.fn.writefile({ "ordinary editor" }, path)
  local layout = require "md-render.heading_layout"
  local request, cell, status = layout.request, image.get_cell_size, image.png_status
  local transmit, png, delete, put = image.transmit_image_async, image.transmit_png, image.delete_image, image.put_image
  local static_jobs, heading_jobs, deleted, puts, serial = {}, {}, {}, 0, 1000
  local chrome, colors = vim.o.laststatus, vim.o.termguicolors
  local tmux, pane = vim.env.TMUX, vim.env.TMUX_PANE
  local ok, err = pcall(function()
    vim.env.TMUX, vim.env.TMUX_PANE = nil, nil
    vim.o.termguicolors = true
    image.get_cell_size = function()
      return { cell_w = 19, cell_h = 44 }
    end
    image.png_status = function()
      return { supported = true }
    end
    -- The external rasterizer is ready; terminal transmissions remain pending.
    layout.request = function(input)
      local text = input.entries[1].text
      local columns = {}
      for byte = 0, #text - 1 do
        columns[#columns + 1] = byte
      end
      return {
        key = text,
        ready = true,
        output = {
          lines = {
            {
              start = 0,
              ["end"] = #text,
              text = text,
              data = "png",
              cols = #text,
              width = #text * 19,
              height = 44,
              columns = columns,
            },
          },
        },
      }
    end
    image.transmit_image_async = function(_, callback)
      static_jobs[#static_jobs + 1] = callback
    end
    image.transmit_png = function(_, callback)
      serial = serial + 1
      heading_jobs[#heading_jobs + 1] = callback
      return serial
    end
    image.delete_image = function(id)
      deleted[id] = true
    end
    image.put_image = function(...)
      puts = puts + 1
      return put(...)
    end
    text_size.setup { backend = "image" }
    preview.show_pager()
    local session = preview._sessions[vim.api.nvim_get_current_buf()]
    local old_images, old_headings = session.image_state, session.text_size_state
    assert(
      old_headings and old_headings.image_headings and #static_jobs > 0 and #heading_jobs > 0,
      "pending renderers missing"
    )
    local rebuild, rebuilds = session.rebuild, 0
    session.rebuild = function(self)
      rebuilds = rebuilds + 1
      return rebuild(self)
    end
    session:follow_file(path)
    local editor = vim.api.nvim_get_current_buf()
    assert(old_images.closed and old_headings.closed, "entering editor kept old renderers")
    local old_static_count, old_heading_count = #static_jobs, #heading_jobs
    puts = 0
    for index = 1, old_static_count do
      static_jobs[index](2000 + index, 4, 4)
    end
    for index = 1, old_heading_count do
      heading_jobs[index]()
    end
    vim.wait(200)
    assert(rebuilds == 0 and puts == 0, "late callbacks rebuilt or painted the editor")
    assert(deleted[2001], "late static image ID leaked")
    assert(vim.api.nvim_get_current_buf() == editor and vim.api.nvim_get_current_line() == "ordinary editor")
    vim.api.nvim_feedkeys(vim.keycode "<C-o>", "x", false)
    vim.wait(30)
    assert(vim.api.nvim_get_current_buf() == session.buf, "native return lost rendered document")
    local new_images, new_headings = session.image_state, session.text_size_state
    assert(new_images ~= old_images and not new_images.closed, "return did not recreate inline images")
    assert(new_headings ~= old_headings and not new_headings.closed, "return did not recreate image headings")
    for index = old_static_count + 1, #static_jobs do
      static_jobs[index](2000 + index, 4, 4)
    end
    for index = old_heading_count + 1, #heading_jobs do
      heading_jobs[index]()
    end
    vim.wait(30)
    assert(
      new_images.image_ids[image_path] and new_headings.entries[1].ready,
      "returned renderers did not become ready"
    )
    vim.api.nvim_buf_delete(source, { force = true })
    vim.wait(30)
    assert(new_images.closed and new_headings.closed, "source wipe left renderers alive")
    assert(not vim.api.nvim_buf_is_valid(session.buf), "source wipe retained pager buffer")
    assert(vim.o.laststatus == chrome, "source wipe retained pager chrome: " .. vim.o.laststatus .. " ~= " .. chrome)
  end)
  layout.request, image.get_cell_size, image.png_status = request, cell, status
  image.transmit_image_async, image.transmit_png, image.delete_image, image.put_image = transmit, png, delete, put
  text_size.setup { backend = "native" }
  vim.o.termguicolors = colors
  vim.env.TMUX, vim.env.TMUX_PANE = tmux, pane
  vim.fn.delete(path)
  assert(ok, err)
end)

test("pager restores tab-local command heights in an attached UI", function()
  local child = vim.fn.jobstart(
    { vim.v.progpath, "--embed", "--headless", "-n", "-u", "NONE", "--noplugin", "-i", "NONE" },
    { rpc = true }
  )
  local function lua(code)
    return vim.rpcrequest(child, "nvim_exec_lua", code, {})
  end
  local ok, err = pcall(function()
    -- cmdheight is stored per tab during UI updates; one headless Lua turn
    -- cannot reliably observe it after tab switches.
    vim.rpcrequest(child, "nvim_ui_attach", 120, 40, { rgb = true })
    lua [[
      package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
      vim.o.hidden, vim.o.swapfile = true, false
      require("md-render.text_size").setup { enabled = false }
      _G.preview = require "md-render.preview"
      vim.bo.filetype = "markdown"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "# Pager" })
      vim.o.cmdheight, vim.o.laststatus, vim.o.showtabline = 2, 3, 2
    ]]
    for _, step in ipairs {
      { "preview.show_pager()", 0 },
      { "preview.toggle()", 2 },
      { "vim.cmd('tab split')", 2 },
      { "vim.o.cmdheight = 4", 4 },
      { "preview.show_pager()", 0 },
      { "vim.cmd.tabprevious()", 2 },
      { "vim.cmd.tabnext()", 0 },
      { "preview.toggle()", 4 },
      { "vim.cmd.tabprevious()", 2 },
    } do
      lua(step[1])
      assert(lua "return vim.o.cmdheight" == step[2], "wrong tab command height after " .. step[1])
    end
    assert(lua "return vim.o.laststatus == 3 and vim.o.showtabline == 2", "source chrome was not restored")
  end)
  vim.fn.jobstop(child)
  assert(ok, err)
end)

assert(failures == 0, failures .. " preview window tests failed")
print "preview_window_test: 15 passed"
