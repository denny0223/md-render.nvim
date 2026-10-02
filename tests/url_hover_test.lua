-- Test url_hover module: truncation, hit-testing, and hover lifecycle.
-- Run: nvim --headless -u NONE --noplugin -l tests/url_hover_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local UrlHover = require "md-render.url_hover"
local internal = UrlHover._internal()

local pass_count = 0
local fail_count = 0

local function assert_eq(actual, expected, msg)
  if vim.deep_equal(actual, expected) then
    pass_count = pass_count + 1
  else
    fail_count = fail_count + 1
    print("FAIL: " .. msg)
    print("  expected: " .. vim.inspect(expected))
    print("  actual:   " .. vim.inspect(actual))
  end
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

-- truncate_url

test("truncate_url: short URL returned as-is", function()
  assert_eq(internal.truncate_url("https://example.com", 80), "https://example.com", "short URL unchanged")
end)

test("truncate_url: long URL truncated with ellipsis", function()
  local url = "https://example.com/" .. string.rep("a", 100)
  local result = internal.truncate_url(url, 30)
  assert_eq(vim.api.nvim_strwidth(result), 30, "truncated to exact max width")
  assert_eq(result:sub(-3), "…", "ends with ellipsis (3-byte UTF-8)")
end)

test("truncate_url: max_width of 1 returns ellipsis", function()
  assert_eq(internal.truncate_url("https://example.com", 1), "…", "edge case width=1")
end)

test("truncate_url: max_width of 0 returns empty", function()
  assert_eq(internal.truncate_url("https://example.com", 0), "", "edge case width=0")
end)

test("truncate_url: handles multi-byte chars correctly", function()
  local url = "https://example.com/日本語ページ/path"
  local result = internal.truncate_url(url, 20)
  assert_eq(vim.api.nvim_strwidth(result) <= 20, true, "multi-byte truncation stays within width")
  assert_eq(result:sub(-3), "…", "ends with ellipsis")
end)

-- url_at_mouse

local function make_buf_with_url(line_text, url, start_col, end_col)
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "url_hover_test"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line_text })
  vim.api.nvim_buf_set_extmark(buf, ns, 0, start_col, {
    end_col = end_col,
    url = url,
  })
  return buf, ns
end

test("url_at_mouse: returns URL when mouse is on link", function()
  local buf, ns = make_buf_with_url("See docs here", "https://example.com/docs", 4, 8)
  -- column is 1-indexed in getmousepos; col 5 = byte 4 (0-indexed) → start of "docs"
  local mouse = { winid = 1, line = 1, column = 5 }
  assert_eq(internal.url_at_mouse(mouse, buf, ns), "https://example.com/docs", "URL detected at start")

  mouse.column = 8 -- byte 7 (0-indexed) → last char of "docs"
  assert_eq(internal.url_at_mouse(mouse, buf, ns), "https://example.com/docs", "URL detected at end")
end)

test("url_at_mouse: returns nil when mouse is outside link", function()
  local buf, ns = make_buf_with_url("See docs here", "https://example.com/docs", 4, 8)
  local mouse = { winid = 1, line = 1, column = 1 } -- on "S"
  assert_eq(internal.url_at_mouse(mouse, buf, ns), nil, "no URL before link")

  mouse.column = 10 -- on " here"
  assert_eq(internal.url_at_mouse(mouse, buf, ns), nil, "no URL after link")
end)

test("url_at_mouse: returns nil for invalid positions", function()
  local buf, ns = make_buf_with_url("See docs here", "https://example.com/docs", 4, 8)
  assert_eq(internal.url_at_mouse({ winid = 1, line = 0, column = 5 }, buf, ns), nil, "line=0 invalid")
  assert_eq(internal.url_at_mouse({ winid = 1, line = 1, column = 0 }, buf, ns), nil, "column=0 invalid")
  assert_eq(internal.url_at_mouse({ winid = 1, line = 99, column = 5 }, buf, ns), nil, "line past EOF")
end)

test("url_at_mouse: returns nil when extmark has no URL", function()
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "url_hover_test2"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Some text" })
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { end_col = 4, hl_group = "Comment" })
  assert_eq(internal.url_at_mouse({ winid = 1, line = 1, column = 2 }, buf, ns), nil, "non-URL extmark ignored")
end)

test("url_at_mouse: a link on the following row is not under the mouse", function()
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "url_hover_rows"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "plain", "link" })
  vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_col = 4, url = "target.md" })
  assert_eq(internal.url_at_mouse({ line = 1, column = 1 }, buf, ns), nil, "next row is excluded")
  assert_eq(internal.url_at_mouse({ line = 2, column = 1 }, buf, ns), "target.md", "start is included")
  assert_eq(internal.url_at_mouse({ line = 2, column = 5 }, buf, ns), nil, "end is excluded")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

test("url_at_mouse: finds links spanning multiple rows", function()
  local buf = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace "url_hover_multiline"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "first", "middle", "last" })
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 2, { end_row = 2, end_col = 2, url = "target.md" })
  assert_eq(internal.url_at_mouse({ line = 1, column = 2 }, buf, ns), nil, "before start is excluded")
  assert_eq(internal.url_at_mouse({ line = 2, column = 1 }, buf, ns), "target.md", "middle row overlaps")
  assert_eq(internal.url_at_mouse({ line = 3, column = 2 }, buf, ns), "target.md", "last byte is included")
  assert_eq(internal.url_at_mouse({ line = 3, column = 3 }, buf, ns), nil, "final end is excluded")
  vim.api.nvim_buf_delete(buf, { force = true })
end)

-- bottom_reserved_rows

test("bottom_reserved_rows: cmdheight only when no statusline", function()
  local saved_ls, saved_ch = vim.o.laststatus, vim.o.cmdheight
  vim.o.laststatus = 0
  vim.o.cmdheight = 1
  assert_eq(internal.bottom_reserved_rows(), 1, "ls=0 ch=1 → 1")
  vim.o.cmdheight = 0
  assert_eq(internal.bottom_reserved_rows(), 0, "ls=0 ch=0 → 0")
  vim.o.laststatus, vim.o.cmdheight = saved_ls, saved_ch
end)

test("bottom_reserved_rows: adds statusline row when laststatus=2", function()
  local saved_ls, saved_ch = vim.o.laststatus, vim.o.cmdheight
  vim.o.laststatus = 2
  vim.o.cmdheight = 1
  assert_eq(internal.bottom_reserved_rows(), 2, "ls=2 ch=1 → 2 (status + cmdline)")
  vim.o.cmdheight = 0
  assert_eq(internal.bottom_reserved_rows(), 1, "ls=2 ch=0 → 1 (status only)")
  vim.o.laststatus, vim.o.cmdheight = saved_ls, saved_ch
end)

test("bottom_reserved_rows: adds statusline row when laststatus=3 (global)", function()
  local saved_ls, saved_ch = vim.o.laststatus, vim.o.cmdheight
  vim.o.laststatus = 3
  vim.o.cmdheight = 2
  assert_eq(internal.bottom_reserved_rows(), 3, "ls=3 ch=2 → 3")
  vim.o.laststatus, vim.o.cmdheight = saved_ls, saved_ch
end)

-- hover window lifecycle

test("show_hover then close_hover: opens and closes a float", function()
  internal.show_hover("https://example.com", 1)
  assert_eq(internal.state.hover_win ~= nil, true, "hover window created")
  assert_eq(vim.api.nvim_win_is_valid(internal.state.hover_win), true, "hover window valid")
  assert_eq(internal.state.current_url, "https://example.com", "current_url tracked")
  assert_eq(internal.state.current_win, 1, "current_win tracked")

  internal.close_hover()
  assert_eq(internal.state.hover_win, nil, "hover window cleared from state")
  assert_eq(internal.state.current_url, nil, "current_url cleared")
end)

test("show_hover: updates existing window for new URL", function()
  internal.show_hover("https://example.com", 1)
  local first_win = internal.state.hover_win
  internal.show_hover("https://example.org/different", 1)
  assert_eq(internal.state.hover_win, first_win, "reuses same window handle")
  assert_eq(internal.state.current_url, "https://example.org/different", "URL updated")
  internal.close_hover()
end)

test("attach: updates one registration and cleans up on close", function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "x" })
  local ns = vim.api.nvim_create_namespace "attach_test"
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = 5,
    height = 1,
    row = 0,
    col = 0,
    style = "minimal",
  })
  UrlHover.attach(buf, ns, win)
  assert_eq(internal.registered[win] ~= nil, true, "window registered")
  assert_eq(internal.registered[win].buf, buf, "buf stored")
  assert_eq(internal.registered[win].ns, ns, "ns stored")

  local function close_handlers()
    return #vim.api.nvim_get_autocmds {
      group = "md_render_url_hover",
      event = "WinClosed",
      pattern = tostring(win),
    }
  end
  assert_eq(close_handlers(), 1, "one close handler installed")
  local next_buf, next_ns = make_buf_with_url("next", "https://example.org", 0, 4)
  vim.api.nvim_win_set_buf(win, next_buf)
  for _ = 1, 20 do
    UrlHover.attach(next_buf, next_ns, win)
  end
  assert_eq(internal.registered[win], { buf = next_buf, ns = next_ns }, "reattach updates buffer and namespace")
  assert_eq(close_handlers(), 1, "reattach does not accumulate close handlers")
  internal.show_hover("https://example.org", win)
  local hover_win = internal.state.hover_win

  vim.api.nvim_win_close(win, true)
  -- WinClosed autocmd should clear registration
  vim.wait(50, function()
    return internal.registered[win] == nil
  end)
  assert_eq(internal.registered[win], nil, "WinClosed cleared registration")
  assert_eq(close_handlers(), 0, "WinClosed removes its handler")
  assert_eq(vim.api.nvim_win_is_valid(hover_win), false, "WinClosed closes the hover")
end)

-- Summary
test("hover observes mouse events without replacing mappings and detaches on buffer change", function()
  local previous_option = vim.o.mousemoveevent
  vim.o.mousemoveevent = false
  local calls = 0
  local custom = function()
    calls = calls + 1
  end
  for _, mode in ipairs { "n", "i", "v" } do
    vim.keymap.set(mode, "<MouseMove>", custom)
  end
  local buf, ns = make_buf_with_url("link", "https://example.org/current", 0, 4)
  local win = vim.api.nvim_open_win(buf, false, { relative = "editor", width = 10, height = 2, row = 1, col = 1 })
  UrlHover.attach(buf, ns, win)
  assert_eq(vim.o.mousemoveevent, true, "active hover enables mouse events")
  for _, mode in ipairs { "n", "i", "v" } do
    assert_eq(
      vim.fn.maparg("<MouseMove>", mode, false, true).callback,
      custom,
      "existing mapping is preserved while active"
    )
  end
  local display = require "md-render.display_utils"
  local getmousepos = display.getmousepos
  display.getmousepos = function()
    return { winid = win, line = 1, column = 1 }
  end
  vim.api.nvim_feedkeys(vim.keycode "<MouseMove>", "xt", false)
  vim.wait(internal.DEBOUNCE_MS + 100)
  assert_eq(calls, 1, "the original mouse mapping still runs")
  assert_eq(
    internal.state.current_url,
    "https://example.org/current",
    "observer sees the event over an unfocused preview"
  )
  local other = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, other)
  vim.wait(20)
  assert_eq(internal.registered[win], nil, "changing the displayed buffer drops registration")
  assert_eq(internal.state.hover_win, nil, "changing buffers closes the stale hover")
  assert_eq(vim.o.mousemoveevent, false, "last preview leaving restores mouse events")
  internal.handle_mouse_move()
  vim.wait(internal.DEBOUNCE_MS + 20)
  assert_eq(internal.state.hover_win, nil, "old extmarks cannot reopen a hover on another buffer")
  display.getmousepos = getmousepos
  vim.api.nvim_win_close(win, true)
  for _, mode in ipairs { "n", "i", "v" } do
    assert_eq(vim.fn.maparg("<MouseMove>", mode, false, true).callback, custom, "teardown preserves user mappings")
    vim.keymap.del(mode, "<MouseMove>")
  end
  vim.o.mousemoveevent = previous_option
end)

test("teardown does not override a later mouse option or mapping change", function()
  local saved = vim.o.mousemoveevent
  vim.o.mousemoveevent = true
  local buf, ns = make_buf_with_url("link", "https://example.org", 0, 4)
  local win = vim.api.nvim_open_win(buf, false, { relative = "editor", width = 10, height = 2, row = 1, col = 1 })
  UrlHover.attach(buf, ns, win)
  local later = function() end
  vim.keymap.set("n", "<MouseMove>", later)
  vim.o.mousemoveevent = false
  UrlHover.detach(win)
  assert_eq(vim.o.mousemoveevent, false, "later option setting is preserved")
  assert_eq(vim.fn.maparg("<MouseMove>", "n", false, true).callback, later, "later mapping is preserved")
  vim.keymap.del("n", "<MouseMove>")
  vim.api.nvim_win_close(win, true)
  vim.o.mousemoveevent = saved
end)

test("pending and existing hovers belong to the current tab", function()
  local display = require "md-render.display_utils"
  local getmousepos = display.getmousepos
  local first_buf, ns = make_buf_with_url("first", "https://example.org/first", 0, 5)
  local first_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(first_win, first_buf)
  UrlHover.attach(first_buf, ns, first_win)
  display.getmousepos = function()
    return { winid = first_win, line = 1, column = 1 }
  end
  internal.handle_mouse_move()
  vim.cmd.tabnew()
  local second_tab = vim.api.nvim_get_current_tabpage()
  vim.wait(internal.DEBOUNCE_MS + 20)
  assert_eq(internal.state.hover_win, nil, "departing tab's pending URL never paints in the new tab")
  assert_eq(internal.registered[first_win] ~= nil, true, "background preview retains its registration")

  vim.api.nvim_set_current_win(first_win)
  internal.handle_mouse_move()
  assert_eq(
    vim.wait(500, function()
      return internal.state.hover_win ~= nil
    end),
    true,
    "returning to preview can show a hover"
  )
  local first_hover = internal.state.hover_win
  vim.api.nvim_set_current_tabpage(second_tab)
  assert_eq(vim.api.nvim_win_is_valid(first_hover), false, "tab leave closes the old hover float")
  local second_buf, second_ns = make_buf_with_url("second", "https://example.org/second", 0, 6)
  local second_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(second_win, second_buf)
  UrlHover.attach(second_buf, second_ns, second_win)
  display.getmousepos = function()
    return { winid = second_win, line = 1, column = 1 }
  end
  internal.handle_mouse_move()
  assert_eq(
    vim.wait(500, function()
      return internal.state.current_url == "https://example.org/second"
    end),
    true,
    "new tab shows its own URL"
  )
  assert_eq(
    vim.api.nvim_win_get_tabpage(internal.state.hover_win),
    second_tab,
    "new hover is visible in its owning tab"
  )

  -- The callback still validates tab ownership when an external command has
  -- suppressed TabLeave; valid window and buffer IDs alone are insufficient.
  internal.close_hover()
  internal.handle_mouse_move()
  local eventignore = vim.o.eventignore
  vim.o.eventignore = "TabLeave"
  vim.api.nvim_set_current_win(first_win)
  vim.o.eventignore = eventignore
  vim.wait(internal.DEBOUNCE_MS + 20)
  assert_eq(internal.state.hover_win, nil, "late callback rejects a source in another tab")
  display.getmousepos = getmousepos
  UrlHover.detach(first_win)
  UrlHover.detach(second_win)
  vim.api.nvim_win_close(second_win, true)
end)

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
