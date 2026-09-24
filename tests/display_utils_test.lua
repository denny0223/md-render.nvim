-- display_utils tests
-- Run: nvim --headless -u NONE --noplugin -l tests/display_utils_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local display_utils = require "md-render.display_utils"

local pass_count = 0
local fail_count = 0

local function assert_eq(actual, expected, msg)
  if actual == expected then
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

-- ============================================================================
-- resolve_lang: map fenced info-string to treesitter parser name
-- ============================================================================

test("resolve_lang maps sh-family aliases to bash", function()
  assert_eq(display_utils._resolve_lang "sh", "bash", "sh -> bash")
  assert_eq(display_utils._resolve_lang "zsh", "bash", "zsh -> bash")
  assert_eq(display_utils._resolve_lang "shell", "bash", "shell -> bash")
  assert_eq(display_utils._resolve_lang "shellscript", "bash", "shellscript -> bash")
end)

test("resolve_lang maps common short forms", function()
  assert_eq(display_utils._resolve_lang "js", "javascript", "js -> javascript")
  assert_eq(display_utils._resolve_lang "jsx", "javascript", "jsx -> javascript")
  assert_eq(display_utils._resolve_lang "ts", "typescript", "ts -> typescript")
  assert_eq(display_utils._resolve_lang "py", "python", "py -> python")
  assert_eq(display_utils._resolve_lang "rb", "ruby", "rb -> ruby")
  assert_eq(display_utils._resolve_lang "rs", "rust", "rs -> rust")
  assert_eq(display_utils._resolve_lang "yml", "yaml", "yml -> yaml")
  assert_eq(display_utils._resolve_lang "md", "markdown", "md -> markdown")
  assert_eq(display_utils._resolve_lang "ps1", "powershell", "ps1 -> powershell")
end)

test("resolve_lang is case-insensitive", function()
  assert_eq(display_utils._resolve_lang "SH", "bash", "SH -> bash")
  assert_eq(display_utils._resolve_lang "Bash", "bash", "Bash -> bash (passthrough)")
end)

test("resolve_lang passes through names with no alias", function()
  assert_eq(display_utils._resolve_lang "bash", "bash", "bash stays bash")
  assert_eq(display_utils._resolve_lang "lua", "lua", "lua stays lua")
  assert_eq(display_utils._resolve_lang "go", "go", "go stays go")
  assert_eq(display_utils._resolve_lang "unknown_xyz", "unknown_xyz", "unknown stays unknown")
end)

test("resolve_lang honors vim.treesitter.language.register", function()
  -- Simulate a user-registered alias and confirm it wins over the literal name.
  vim.treesitter.language.register("markdown", "custom_md_lang")
  assert_eq(display_utils._resolve_lang "custom_md_lang", "markdown", "registered alias custom_md_lang -> markdown")
end)

-- ============================================================================
-- build_footer_chunks: status info drawn on a float's bottom border
-- ============================================================================

--- Concatenate the text of a chunk list, ignoring highlight groups.
local function footer_text(chunks)
  local parts = {}
  for _, chunk in ipairs(chunks) do
    table.insert(parts, chunk[1])
  end
  return table.concat(parts)
end

test("build_footer_chunks renders name, position, and progress bar", function()
  local chunks = display_utils.build_footer_chunks({ name = "README.md", line = 25, total = 100 }, 60)
  assert_eq(footer_text(chunks), " README.md   25/100  ━━╾─────── ", "all segments present")
  assert_eq(chunks[2][2], "MdRenderFooterName", "file name uses its own highlight group")
  assert_eq(chunks[4][2], "MdRenderFooter", "position uses the plain footer group")
  assert_eq(chunks[6][2], "MdRenderFooterBar", "filled part of the bar")
  assert_eq(chunks[7][2], "MdRenderFooterBarEmpty", "unfilled part blends into the border")
end)

test("build_footer_chunks fills the bar in half-cell steps", function()
  local function bar(line, total)
    return footer_text(display_utils.build_footer_chunks({ line = line, total = total }, 60))
  end
  assert_eq(bar(1, 100), "   1/100  ────────── ", "1% rounds down to an empty bar")
  assert_eq(bar(5, 100), "   5/100  ╾───────── ", "5% is one half cell")
  assert_eq(bar(50, 100), "  50/100  ━━━━━───── ", "half way")
  assert_eq(bar(100, 100), " 100/100  ━━━━━━━━━━ ", "end of file fills the bar")
  assert_eq(bar(1, 1), " 1/1  ━━━━━━━━━━ ", "single-line file is complete at line 1")
end)

test("build_footer_chunks keeps a fixed width as the line number grows", function()
  local function width_of(line)
    return vim.api.nvim_strwidth(footer_text(display_utils.build_footer_chunks({ line = line, total = 120 }, 60)))
  end
  assert_eq(width_of(1), width_of(9), "1 and 9 are the same width")
  assert_eq(width_of(9), width_of(10), "crossing ten does not resize the footer")
  assert_eq(width_of(99), width_of(120), "crossing a hundred does not resize the footer")
end)

test("build_footer_chunks omits missing info", function()
  assert_eq(footer_text(display_utils.build_footer_chunks({ name = "a.md" }, 40)), " a.md ", "name only")
  assert_eq(
    footer_text(display_utils.build_footer_chunks({ line = 1, total = 4 }, 40)),
    " 1/4  ━━╾─────── ",
    "position only"
  )
  assert_eq(#display_utils.build_footer_chunks({}, 40), 0, "no info -> no chunks")
  assert_eq(#display_utils.build_footer_chunks({ name = "" }, 40), 0, "empty name -> no chunks")
  assert_eq(#display_utils.build_footer_chunks({ line = 3, total = 0 }, 40), 0, "empty buffer -> no chunks")
end)

test("build_footer_chunks shrinks the bar, then drops segments", function()
  local info = { name = "README.md", line = 25, total = 100 }
  local function fit(width)
    return footer_text(display_utils.build_footer_chunks(info, width))
  end
  assert_eq(fit(32), " README.md   25/100  ━━╾─────── ", "exact fit")
  assert_eq(fit(31), " README.md   25/100  ━━╾────── ", "bar shrinks")
  assert_eq(fit(26), " README.md   25/100  ━─── ", "bar hits its floor at four cells")
  assert_eq(fit(25), " README.md   25/100 ", "bar dropped next")
  assert_eq(fit(19), " README.md ", "position dropped next")
  assert_eq(#display_utils.build_footer_chunks(info, 10), 0, "nothing fits -> no chunks")
end)

test("build_footer_chunks measures display width, not bytes", function()
  local chunks = display_utils.build_footer_chunks({ name = "設計メモ.md" }, 16)
  assert_eq(footer_text(chunks), " 設計メモ.md ", "CJK name fits its display width")
  assert_eq(
    #display_utils.build_footer_chunks({ name = "設計メモ.md" }, 12),
    0,
    "same name does not fit a 12-cell float"
  )
end)

test("build_footer_chunks clamps an out-of-range line", function()
  local chunks = display_utils.build_footer_chunks({ line = 999, total = 40 }, 40)
  assert_eq(footer_text(chunks), " 40/40  ━━━━━━━━━━ ", "line beyond total clamps to total")
end)

-- ============================================================================
-- setup_images: off-screen placements that have to be produced first
-- ============================================================================

--- Drive `setup_images` with `count` Mermaid placements on `line`, and report
--- how many times the render was asked for after each step.
---
--- The placements share a line when there is more than one. Nothing in the code
--- under test looks at whether they overlap, and it keeps every one of them
--- inside the viewport regardless of how tall the test window is.
---@param line integer 0-indexed buffer line to put the diagram on
---@param count integer? how many placements to put there (default 1)
---@return { renders: integer, scroll: fun(topline: integer), settle: fun(), state: table }
local function mermaid_harness(line, count)
  local image = require "md-render.image"
  local saved = {
    supports_kitty = image.supports_kitty,
    clear_all = image.clear_all,
    render_mermaid_async = image.render_mermaid_async,
  }
  local calls = { renders = 0 }
  image.supports_kitty = function()
    return true
  end
  image.clear_all = function() end
  -- Never answers: the placement stays pending, which is what makes a second
  -- request observable.
  image.render_mermaid_async = function()
    calls.renders = calls.renders + 1
  end

  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, line + 40 do
    lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  local win = vim.api.nvim_get_current_win()
  local prev_buf = vim.api.nvim_win_get_buf(win)
  vim.api.nvim_win_set_buf(win, buf)

  local placements = {}
  for i = 1, count or 1 do
    placements[i] = { line = line, col = 0, rows = 5, cols = 20, mermaid_source = "graph LR\n  A" .. i .. " --> B" }
  end
  local state = display_utils.setup_images(win, { image_placements = placements }, nil)
  calls.state = state

  calls.settle = function()
    -- Placements start behind a semaphore; the scroll path then waits out the
    -- 50 ms redraw debounce.
    vim.wait(200, function()
      return false
    end, 10)
  end
  calls.scroll = function(topline)
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview { topline = topline, lnum = topline }
    end)
    vim.api.nvim_exec_autocmds("WinScrolled", { modeline = false, pattern = tostring(win) })
    calls.settle()
  end
  calls.finish = function()
    display_utils.cleanup_images(state)
    vim.api.nvim_win_set_buf(win, prev_buf)
    vim.api.nvim_buf_delete(buf, { force = true })
    for name, fn in pairs(saved) do
      image[name] = fn
    end
  end
  return calls
end

test("cleanup_images preserves another preview's images and shared animation source", function()
  local image = require "md-render.image"
  local terminal, ghostty_resources = vim.env.TERM_PROGRAM, vim.env.GHOSTTY_RESOURCES_DIR
  vim.env.TERM_PROGRAM, vim.env.GHOSTTY_RESOURCES_DIR = "kitty", nil
  image.reset_cache()
  local real_send, real_extract = vim.api.nvim_ui_send, image.extract_frames_async
  local png = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"
  local gif = vim.fn.getcwd() .. "/assets/demo/test_animated.gif"
  local single = vim.fn.tempname() .. ".gif"
  vim.fn.writefile(vim.fn.readfile(gif, "b"), single, "b")
  local stored, placement_counts, puts = {}, {}, {}
  local global_deletes, writes = 0, 0
  -- Track stored data separately from placements: d=i retains it, d=I releases it.
  vim.api.nvim_ui_send = function(data)
    writes = writes + 1
    for seq in data:gmatch "\x1b_G(.-)\x1b\\" do
      local params = {}
      for key, value in seq:gmatch "([%w_]+)=([^,;]+)" do
        params[key] = value
      end
      local id = tonumber(params.i)
      if params.a == "t" then
        stored[id] = true
      elseif params.a == "p" then
        placement_counts[id] = (placement_counts[id] or 0) + 1
        puts[id] = (puts[id] or 0) + 1
      elseif params.a == "d" and params.d == "A" then
        global_deletes = global_deletes + 1
      elseif params.a == "d" and (params.d == "I" or params.d == "i") then
        placement_counts[id] = 0
        if params.d == "I" then stored[id] = nil end
      end
    end
  end
  image._set_kitty_supported(true)
  image.extract_frames_async = function(path, callback)
    vim.defer_fn(function()
      callback(path == single and { png } or { png, png })
    end, 1)
  end

  local states, wins, bufs = {}, {}, {}
  for i = 1, 2 do
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn["repeat"]({ "" }, 12))
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = 0,
      col = (i - 1) * 25,
      width = 24,
      height = 12,
    })
    local placements = {}
    for j, path in ipairs { png, png, gif, gif, single } do
      placements[j] = { path = path, line = (j - 1) * 2, col = 0, cols = 5, rows = 2 }
    end
    states[i] = display_utils.setup_images(win, { image_placements = placements }, nil)
    wins[i], bufs[i] = win, buf
  end
  assert_eq(
    vim.wait(1000, function()
      for _, state in ipairs(states) do
        if not state.anims[gif] or not state.anims[single] or not state.image_ids[png] then return false end
        for _, task in pairs(state.tasks) do
          if task:status() ~= "completed" then return false end
        end
      end
      return true
    end, 1),
    true,
    "both previews finish loading repeated static and animated images"
  )
  assert_eq(vim.tbl_count(stored), 8, "each preview owns one PNG and three animation frames without orphan IDs")
  assert_eq(
    states[1].anims[gif].frame_ids[1] ~= states[2].anims[gif].frame_ids[1],
    true,
    "previews own distinct frame IDs"
  )
  assert_eq(
    vim.wait(1500, function()
      return (puts[states[1].image_ids[png]] or 0) >= 6
    end, 1),
    true,
    "static images are re-placed across multiple animation ticks"
  )
  for _, state in ipairs(states) do
    assert_eq(placement_counts[state.image_ids[png]], 2, "animation ticks keep only the two intended static placements")
    assert_eq(
      placement_counts[state.anims[single].frame_ids[1]],
      1,
      "single-frame animations do not accumulate placements"
    )
  end

  -- Hold the redraw callback that would otherwise run just after cleanup.
  local real_cmd, real_schedule = vim.cmd, vim.schedule
  local queued_redraw
  vim.cmd = function(command)
    if command == "redraw!" then
      vim.schedule = function(callback)
        vim.schedule = real_schedule
        queued_redraw = callback
      end
    else
      real_cmd(command)
    end
  end
  states[1].schedule_redraw()
  local queued = vim.wait(1000, function()
    return queued_redraw ~= nil
  end, 1)
  vim.cmd, vim.schedule = real_cmd, real_schedule
  assert_eq(queued, true, "a repaint is queued before cleanup")
  global_deletes = 0 -- Exclude the deliberate first-use terminal reset.
  display_utils.cleanup_images(states[1])
  local before = writes
  if queued_redraw then queued_redraw() end
  assert_eq(writes, before, "a queued repaint cannot write after cleanup")
  assert_eq(global_deletes, 0, "preview cleanup never requests a terminal-wide deletion")
  assert_eq(stored[states[2].image_ids[png]], true, "closing one preview retains the other's static image")
  for _, id in ipairs(states[2].anims[gif].frame_ids) do
    assert_eq(stored[id], true, "closing one preview retains the other's animation frame " .. id)
  end
  assert_eq(vim.tbl_count(stored), 4, "only the surviving preview owns stored images")
  display_utils.cleanup_images(states[2])
  assert_eq(vim.tbl_count(stored), 0, "closing both previews releases all of their images")
  assert_eq(vim.fn.filereadable(png), 1, "cleanup does not delete the source PNG")
  for i, win in ipairs(wins) do
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(bufs[i], { force = true })
  end
  image.extract_frames_async, vim.api.nvim_ui_send = real_extract, real_send
  vim.env.TERM_PROGRAM, vim.env.GHOSTTY_RESOURCES_DIR = terminal, ghostty_resources
  image.reset_cache()
  vim.fn.delete(single)
end)

for _, animated in ipairs { false, true } do
  test("cleanup_images releases late " .. (animated and "animation" or "static") .. " results", function()
    local image = require "md-render.image"
    local method = animated and "extract_frames_async" or "ensure_png_async"
    local real_produce, real_send = image[method], vim.api.nvim_ui_send
    local png = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"
    local path = animated and vim.fn.getcwd() .. "/assets/demo/test_animated.gif" or png
    local pending, stored, deleted = {}, {}, {}
    local resurrected = false
    image[method] = function(_, callback)
      pending[#pending + 1] = callback
    end
    vim.api.nvim_ui_send = function(data)
      for seq in data:gmatch "\x1b_G(.-)\x1b\\" do
        local id = tonumber(seq:match ",i=(%d+)")
        if seq:match "^a=t," then
          if deleted[id] then resurrected = true end
          stored[id] = true
        elseif seq:match "^a=d,d=I," then
          stored[id], deleted[id] = nil, true
        end
      end
    end
    image._set_kitty_supported(true)
    local states, wins, bufs = {}, {}, {}
    for i = 1, 2 do
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn["repeat"]({ "" }, 12))
      local win = vim.api.nvim_open_win(buf, false, {
        relative = "editor",
        row = 0,
        col = (i - 1) * 25,
        width = 24,
        height = 12,
      })
      states[i] = display_utils.setup_images(win, {
        image_placements = { { path = path, line = 0, col = 0, cols = 5, rows = 2 } },
      }, nil)
      wins[i], bufs[i] = win, buf
    end
    assert_eq(
      vim.wait(1000, function()
        return #pending == 2
      end, 1),
      true,
      "both previews await their source"
    )
    -- Keep the window valid: closing the renderer is enough to end ownership.
    display_utils.cleanup_images(states[1])
    for _, callback in ipairs(pending) do
      if animated then
        callback(vim.fn["repeat"]({ png }, 23))
      else
        callback(png, false)
      end
    end
    local expected = animated and 23 or 1
    assert_eq(
      vim.wait(1000, function()
        return vim.tbl_count(stored) == expected and vim.tbl_count(deleted) == expected
      end, 1),
      true,
      "late results are released while the live preview finishes loading"
    )
    assert_eq(resurrected, false, "deleted frame IDs are never transmitted again")
    assert_eq(next(states[1].image_ids), nil, "closed preview never adopts late static IDs")
    assert_eq(next(states[1].anims), nil, "closed preview never starts a late animation")
    display_utils.cleanup_images(states[2])
    assert_eq(next(stored), nil, "both previews leave no stored images")
    for i, win in ipairs(wins) do
      vim.api.nvim_win_close(win, true)
      vim.api.nvim_buf_delete(bufs[i], { force = true })
    end
    image[method], vim.api.nvim_ui_send = real_produce, real_send
    image._set_kitty_supported(nil)
  end)
end

test("setup_images renders an on-screen diagram straight away", function()
  local h = mermaid_harness(0)
  h.settle()
  assert_eq(h.renders, 1, "a diagram in the viewport is rendered on the first pass")
  h.finish()
end)

test("setup_images renders an off-screen diagram once it is scrolled to", function()
  local h = mermaid_harness(400)
  h.settle()
  assert_eq(h.renders, 0, "a diagram far below the viewport is left alone at first")

  h.scroll(395)
  assert_eq(h.renders, 1, "scrolling to it asks for the render")

  -- The retry runs on every scroll, and the render has not answered yet.
  h.scroll(396)
  assert_eq(h.renders, 1, "a render already in flight is not asked for twice")
  h.finish()
end)

test("setup_images keeps only a few placements in flight at once", function()
  -- A screenful of large PNGs sent in one burst makes the terminal block its
  -- UI thread decoding them all. Eight placements are asked for; the renders
  -- stub never answers, so whatever number is running is the permit count.
  local h = mermaid_harness(0, 8)
  h.settle()
  assert_eq(h.renders, 4, "at most MAX_IN_FLIGHT placements are worked on at a time")
  h.finish()
end)

test("cleanup_images stops work that is still running", function()
  -- Cancel active placements and work queued behind the semaphore. Shared
  -- producers may finish; late-result cleanup is covered above.
  local h = mermaid_harness(0, 8)
  h.settle()

  local running = 0
  for _, task in pairs(h.state.tasks) do
    if task:status() ~= "completed" then running = running + 1 end
  end
  assert_eq(running, 8, "every placement has work outstanding before teardown")

  h.finish()

  local still_running = 0
  for _, task in pairs(h.state.tasks) do
    if task:status() ~= "completed" then still_running = still_running + 1 end
  end
  assert_eq(still_running, 0, "and none of it survives the teardown")
end)

print(string.format("display_utils_test: %d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
