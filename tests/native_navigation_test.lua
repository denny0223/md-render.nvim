-- Real parser/extmarks -> native file/tag commands, stack and window lifecycle.
-- Run: nvim --clean --headless -i NONE -l tests/native_navigation_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.o.hidden, vim.o.swapfile = true, false
require("md-render.text_size").setup { enabled = false }
require("md-render.image")._set_kitty_supported(false)
local preview = require "md-render.preview"
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = assert(vim.uv.fs_realpath(root))
local checks, serial, opened, warnings = 0, 0, {}, {}
vim.ui.open = function(url)
  opened[#opened + 1] = url
end
vim.notify = function(message)
  warnings[#warnings + 1] = tostring(message)
end
local function eq(actual, expected, message)
  checks = checks + 1
  assert(vim.deep_equal(actual, expected), message .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end
local function feed(keys)
  vim.v.errmsg = ""
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
  vim.wait(15)
end
local function open(mode, lines, setup)
  feed "<Esc>"
  vim.o.hidden = true
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then vim.api.nvim_win_close(win, true) end
  end
  vim.cmd "silent! tabonly!"
  vim.cmd "silent! only!"
  serial = serial + 1
  local dir = root .. "/" .. serial
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(lines or {
    "# Start",
    "",
    "[decoy.md](target%20file.md#finish)",
    "",
    "[section](#finish)",
    "",
    "[editor](target.txt)",
    "",
    "[web](https://example.com/href)",
    "",
    "[absent](absent.md)",
    "",
    "[missing anchor](#missing)",
    "",
    "# Finish",
  }, dir .. "/source.md")
  vim.fn.writefile({ "# Decoy" }, dir .. "/decoy.md")
  vim.fn.writefile({ "# Target", "", "Body", "", "# Finish" }, dir .. "/target file.md")
  vim.fn.writefile({ "one", "two", "three", "four", "five" }, dir .. "/target.txt")
  vim.cmd.edit(dir .. "/source.md")
  vim.bo.filetype = "markdown"
  vim.wo.number, vim.wo.wrap = true, false
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  if setup then setup(source, dir) end
  if mode == "float" then
    preview.show()
  elseif mode == "tab" then
    preview.show_tab()
  elseif mode == "pager" then
    preview.show_pager()
  elseif mode == "split" then
    preview.split()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if win ~= source_win then
        vim.api.nvim_set_current_win(win)
        break
      end
    end
  else
    preview.toggle()
  end
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local session = assert(preview._sessions[buf])
  vim.fn.settagstack(win, { items = {} }, "r")
  vim.cmd.clearjumps()
  return { dir = dir, source = source, source_win = source_win, session = session, buf = buf, win = win }
end
local function point(c, href)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(c.buf, c.session.ns, 0, -1, { details = true })) do
    if mark[4].url == href then
      vim.api.nvim_win_set_cursor(0, { mark[2] + 1, mark[3] })
      return vim.api.nvim_win_get_cursor(0)
    end
  end
  error("missing href: " .. href)
end

local tag_keys = { "<C-]>", "2<C-]>", "g]1<CR>", "g<C-]>", "<C-w>]", "<C-w><C-]>", "<C-w>g]1<CR>", "<C-w>g<C-]>" }
for _, mode in ipairs { "toggle", "split", "float", "tab", "pager" } do
  for _, key in ipairs(tag_keys) do
    local c = open(mode)
    local origin = point(c, "target%20file.md#finish")
    feed(key)
    local target = assert(preview._sessions[vim.api.nvim_get_current_buf()], mode .. " " .. key .. " rendered target")
    eq(vim.api.nvim_buf_get_name(target.source_bufnr), c.dir .. "/target file.md", mode .. " " .. key .. " exact href")
    eq(vim.api.nvim_win_get_cursor(0)[1], target.content.heading_anchors.finish + 1, "cross-file fragment")
    eq(vim.fn.gettagstack().length, 1, "native tag stack")
    local dest_win = vim.api.nvim_get_current_win()
    eq(dest_win ~= c.win, key:find("<C-w>", 1, true) ~= nil, "tag split destination")
    local jumps = vim.fn.getjumplist()[1]
    eq(#jumps, 1, "no raw-source intermediary jump")
    eq(jumps[1].bufnr, c.buf, "jumplist retains origin render")
    feed "<C-t>"
    eq(vim.api.nvim_get_current_buf(), c.buf, "Ctrl-T returns to render")
    eq(vim.api.nvim_win_get_cursor(0), origin, "Ctrl-T returns to link")
    feed ":tag<CR>"
    eq(vim.api.nvim_get_current_buf(), target.buf, ":tag repeats href rather than label")
    feed ":pop<CR>"
    eq(vim.api.nvim_get_current_buf(), c.buf, ":pop returns to render")
  end
  local c = open(mode)
  local origin = point(c, "#finish")
  feed "<C-]>"
  eq(vim.api.nvim_win_get_cursor(0)[1], c.session.content.heading_anchors.finish + 1, mode .. " internal tag anchor")
  feed "<C-t>"
  eq(vim.api.nvim_win_get_cursor(0), origin, "anchor Ctrl-T returns")
  point(c, "target.txt")
  feed "<C-]>"
  eq(vim.api.nvim_buf_get_name(0), c.dir .. "/target.txt", "tag opens ordinary file")
  eq(vim.api.nvim_get_current_win(), c.win, "tag uses operated window")
  eq(vim.wo.number, mode ~= "float", mode .. " ordinary file restores editor window options")
  feed "<C-t>"
  eq(vim.api.nvim_get_current_buf(), c.buf, "ordinary file Ctrl-T returns")

  for _, key in ipairs { "gf", "gF", "<C-w>f", "<C-w><C-f>", "<C-w>F", "<C-w>gf", "<C-w>gF" } do
    c = open(mode)
    point(c, "target%20file.md#finish")
    feed(key)
    local target = assert(preview._sessions[vim.api.nvim_get_current_buf()])
    eq(
      vim.api.nvim_buf_get_name(target.source_bufnr),
      c.dir .. "/target file.md",
      mode .. " " .. key .. " exact file href"
    )
    eq(vim.api.nvim_win_get_cursor(0)[1], target.content.heading_anchors.finish + 1, "file fragment")
    eq(vim.fn.gettagstack().length, 0, "file commands do not push tag stack")
    if key:find("<C-w>", 1, true) then
      eq(vim.api.nvim_win_get_buf(c.win), c.buf, "file new window preserves original")
    end
    feed "<C-o>"
    eq(vim.api.nvim_get_current_buf(), c.buf, "file command native jump return")
  end
  c = open(mode)
  point(c, "https://example.com/href")
  local count = #opened
  feed "<C-]>"
  eq(opened[count + 1], "https://example.com/href", "external tag activation")
  eq(vim.fn.gettagstack().length, 0, "external opener does not push tag stack")
  feed "gx"
  eq(opened[count + 2], "https://example.com/href", "gx uses real external href")
  point(c, "target.txt")
  feed "gx"
  eq(opened[count + 3], c.dir .. "/target.txt", "gx resolves local href against source")
  origin = point(c, "#finish")
  feed "gx<C-o>"
  eq(vim.api.nvim_win_get_cursor(0), origin, "gx anchor uses jump history")

  for _, href in ipairs { "absent.md", "#missing" } do
    for _, key in ipairs { "<C-]>", "g]", "<C-w>]", "<C-w>f", "<C-w>gf" } do
      point(c, href)
      local wins, tabs, stack, jumps =
        #vim.api.nvim_list_wins(), #vim.api.nvim_list_tabpages(), vim.fn.gettagstack(), vim.fn.getjumplist()
      feed(key)
      eq(#vim.api.nvim_list_wins(), wins, "missing target creates no window")
      eq(#vim.api.nvim_list_tabpages(), tabs, "missing target creates no tab")
      eq(vim.fn.gettagstack(), stack, "missing target creates no tag entry")
      eq(vim.fn.getjumplist(), jumps, "missing target creates no jump")
    end
  end
end

-- Native tag lookup cannot extract a keyword from every possible link label.
for _, label in ipairs { "-", "!!!", "→", " " } do
  for _, key in ipairs(tag_keys) do
    local c = open("toggle", { "[" .. label .. "](target%20file.md#finish)" })
    point(c, "target%20file.md#finish")
    feed(key)
    local target = assert(preview._sessions[vim.api.nvim_get_current_buf()])
    eq(vim.api.nvim_buf_get_name(target.source_bufnr), c.dir .. "/target file.md", "tag accepts punctuation label")
    eq(vim.v.errmsg, "", "punctuation label avoids E349")
  end
end

for _, mode in ipairs { "float", "tab" } do
  local c = open(mode)
  local origin = point(c, "target.txt")
  feed "<C-]>"
  vim.cmd.clearjumps()
  vim.cmd "new"
  vim.cmd.close()
  vim.wait(20)
  eq(vim.api.nvim_buf_is_valid(c.buf), true, "tag stack alone retains hidden render after WinClosed")
  vim.api.nvim_set_current_win(c.win)
  feed "<C-t>"
  eq(vim.api.nvim_get_current_buf(), c.buf, "Ctrl-T survives cache pruning")
  eq(vim.api.nvim_win_get_cursor(0), origin, "tag-only history cursor survives")
end

for _, command in ipairs { "split", "vsplit", "tab split" } do
  local c = open "toggle"
  local origin = point(c, "target%20file.md#finish")
  vim.cmd(command)
  local copy = vim.api.nvim_get_current_win()
  feed "<C-]>"
  eq(vim.api.nvim_win_get_buf(c.win), c.buf, "native clone preserves original render")
  feed "<C-t>"
  eq(vim.api.nvim_get_current_win(), copy, "clone tag return keeps operated window")
  eq(vim.api.nvim_get_current_buf(), c.buf, "clone tag return restores render")
  eq(vim.api.nvim_win_get_cursor(0), origin, "clone tag return restores link cursor")
end
do
  local c = open("toggle", nil, function(source)
    vim.api.nvim_buf_set_name(source, "")
  end)
  local origin = point(c, "#finish")
  eq(vim.api.nvim_buf_get_name(c.source), "", "native tags keep unnamed source unnamed")
  eq(vim.api.nvim_buf_get_name(c.buf), "md-render://render/" .. c.buf, "unnamed render gets stable virtual name")
  feed "<C-]>"
  eq(
    vim.api.nvim_win_get_cursor(0)[1],
    c.session.content.heading_anchors.finish + 1,
    "unnamed anchor uses rendered row"
  )
  feed "<C-t>"
  eq(vim.api.nvim_win_get_cursor(0), origin, "unnamed anchor returns through native tag stack")
  feed ":tag<CR>"
  eq(vim.api.nvim_win_get_cursor(0)[1], c.session.content.heading_anchors.finish + 1, "unnamed anchor tag forward")
  feed ":tfirst<CR>"
  eq(vim.api.nvim_get_current_buf(), c.buf, "unnamed cached match remains rendered")
end

-- Cached match commands bypass tagfunc; their stored filename must be the render.
do
  local label = [[a|;"b'c]]
  local href = "#footnote-def-" .. label
  local c = open("toggle", { "Reference[^" .. label .. "]", "", "[^" .. label .. "]: note" })
  local origin = point(c, href)
  feed "<C-]>"
  eq(
    vim.api.nvim_win_get_cursor(0)[1],
    c.session.content.footnote_anchors[href:sub(2)] + 1,
    "native tag retains punctuation in footnote id"
  )
  eq(vim.fn.gettagstack().length, 1, "footnote tag retains native metadata")
  feed "<C-t>"
  eq(vim.api.nvim_win_get_cursor(0), origin, "punctuation footnote native return")
  feed ":tag<CR>"
  eq(
    vim.api.nvim_win_get_cursor(0)[1],
    c.session.content.footnote_anchors[href:sub(2)] + 1,
    "punctuation footnote native forward"
  )
end
for _, command in ipairs { "trewind", "tfirst", "tnext", "tprevious" } do
  local c = open "toggle"
  point(c, "target%20file.md#finish")
  feed "<C-]>"
  local target = preview._sessions[vim.api.nvim_get_current_buf()]
  local ok, err = pcall(vim.cmd, command)
  eq(vim.api.nvim_get_current_buf(), target.buf, "native cached " .. command .. " retains render")
  eq(vim.api.nvim_win_get_cursor(0)[1], target.content.heading_anchors.finish + 1, "native cached fragment row")
  if command == "tnext" or command == "tprevious" then
    eq(ok, false, "single-match native error remains native")
    eq(tostring(err):find(command == "tnext" and "E427" or "E425", 1, true) ~= nil, true, "native tag boundary error")
  end
  for _, jump in ipairs(vim.fn.getjumplist()[1]) do
    eq(preview._sessions[jump.bufnr] ~= nil, true, "cached tags never expose source intermediary")
  end
  vim.cmd.edit(c.dir .. "/target file.md")
  eq(vim.api.nvim_get_current_buf(), target.source_bufnr, "native source edit remains source")
end

-- Reusing a cached target in a narrower window changes rendered anchor rows.
for _, key in ipairs { "<C-]>", "gf", "<C-w>f", "<C-w>]", "<C-w>gf" } do
  vim.o.columns = 100
  local c = open "toggle"
  vim.fn.writefile({ "# Target", "", string.rep("word ", 80), "", "# Finish" }, c.dir .. "/target file.md")
  point(c, "target%20file.md#finish")
  feed "<C-]>"
  feed "<C-t>"
  vim.cmd.vsplit()
  point(c, "target%20file.md#finish")
  feed(key)
  local target = assert(preview._sessions[vim.api.nvim_get_current_buf()])
  eq(
    vim.api.nvim_win_get_cursor(0)[1],
    target.content.heading_anchors.finish + 1,
    "cached fragment follows destination layout " .. key
  )
  vim.cmd.vsplit()
  for _, command in ipairs { "trewind", "tfirst", "tnext", "tprevious" } do
    pcall(vim.cmd, command)
    eq(vim.api.nvim_get_current_buf(), target.buf, "cached tag stays rendered after another reflow")
    eq(
      vim.api.nvim_win_get_cursor(0)[1],
      target.content.heading_anchors.finish + 1,
      "cached tag resolves latest fragment row " .. command
    )
  end
end
for _, name in ipairs { "curly{a,b}.md", "single{a}.md", "star*.md", "question?.md", "back\\slash.md" } do
  local href = name:gsub(".", function(char)
    return char:match "[%w._-]" and char or string.format("%%%02X", char:byte())
  end)
  local c = open("toggle", { "[decoy.md](" .. href .. ")" })
  vim.fn.writefile({ "# Literal filename" }, c.dir .. "/" .. name)
  local origin = point(c, href)
  feed "<C-]>"
  local target = assert(preview._sessions[vim.api.nvim_get_current_buf()])
  eq(vim.api.nvim_buf_get_name(target.source_bufnr), c.dir .. "/" .. name, "native tag retains literal filename bytes")
  feed "<C-t>"
  eq(vim.api.nvim_win_get_cursor(0), origin, "literal filename Ctrl-T return")
  feed ":tag<CR>"
  eq(vim.api.nvim_get_current_buf(), target.buf, "literal filename native forward")
end
-- Core selectors re-issue an Ex command after the picker returns. Preserve
-- literal href bytes through that dispatch and never interpret them as keys/Ex.
for _, spec in ipairs {
  { name = "target|let@q='changed'|\".md" },
  { name = "target<CR><Cmd>let@q='changed'<CR>file.md" },
  { name = "target file.md", absolute = true },
} do
  for _, key in ipairs { "g]1<CR>", "<C-w>g]1<CR>" } do
    local href
    local c = open("toggle", nil, function(source, dir)
      href = (spec.absolute and dir .. "/" or "") .. spec.name
      vim.fn.writefile({ "# Literal target" }, dir .. "/" .. spec.name)
      local destination = spec.absolute and "<" .. href .. ">" or href
      vim.api.nvim_buf_set_lines(source, 0, -1, false, { "[decoy.md](" .. destination .. ")" })
    end)
    point(c, href)
    vim.fn.setreg("q", "unchanged")
    feed(key)
    local target = assert(preview._sessions[vim.api.nvim_get_current_buf()])
    eq(vim.api.nvim_buf_get_name(target.source_bufnr), c.dir .. "/" .. spec.name, "selector retains literal href")
    eq(vim.v.errmsg, "", "selector does not execute href as Ex")
    eq(vim.fn.getreg "q", "unchanged", "selector href has no Ex side effect")
    eq(vim.fn.gettagstack().length, 1, "literal selector records native history")
    feed "<C-t>"
    eq(vim.api.nvim_get_current_buf(), c.buf, "literal selector Ctrl-T returns")
    feed ":tag<CR>"
    eq(vim.api.nvim_get_current_buf(), target.buf, "literal selector native forward repeats exact href")
  end
end
do
  local c = open "toggle"
  local source_lines = vim.api.nvim_buf_get_lines(c.source, 0, -1, false)
  local render_lines = vim.api.nvim_buf_get_lines(c.buf, 0, -1, false)
  local ok = pcall(vim.cmd, "edit!")
  eq(ok, false, "virtual render cannot be reloaded as a source file")
  eq(vim.api.nvim_get_current_buf(), c.buf, "rejected render reload retains buffer")
  eq(vim.api.nvim_buf_get_lines(c.buf, 0, -1, false), render_lines, "rejected render reload preserves content")
  eq(vim.api.nvim_buf_get_lines(c.source, 0, -1, false), source_lines, "rejected render reload preserves source")
end

-- Cancelled selectors cannot redirect a later ordinary :edit.
for _, key in ipairs { "g]0<CR>", "<C-w>g]0<CR>" } do
  local c = open "toggle"
  point(c, "target%20file.md#finish")
  feed(key)
  eq(vim.api.nvim_get_current_buf(), c.buf, "cancelled tag selection stays rendered")
  eq(vim.fn.gettagstack().length, 0, "cancelled tag selection does not push")
  eq(#vim.api.nvim_list_wins(), 1, "cancelled selector does not split")
  vim.cmd.edit(c.dir .. "/target file.md")
  eq(preview._sessions[vim.api.nvim_get_current_buf()], nil, "cancelled selector leaves no pending redirect")
end

-- Preparing a cached target must not reflow a preview in another window.
for _, key in ipairs { "g]", "<C-w>g]" } do
  local c = open("toggle", { "[target](target%20file.md#finish)" }, function(_, dir)
    vim.fn.writefile({ "# Target", "", string.rep("word ", 40), "", "# Finish" }, dir .. "/target file.md")
  end)
  preview.toggle()
  preview.toggle { max_width = 70 }
  vim.cmd.vsplit()
  vim.cmd.edit(c.dir .. "/target file.md")
  vim.bo.filetype = "markdown"
  preview.toggle { max_width = 30 }
  local target, target_win = preview._sessions[vim.api.nvim_get_current_buf()], vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(c.win)
  local before = vim.api.nvim_buf_get_lines(target.buf, 0, -1, false)
  point(c, "target%20file.md#finish")
  feed(key .. "0<CR>")
  eq(vim.api.nvim_get_current_buf(), c.buf, "cancelled cached selector stays in the source preview")
  eq(target.opts.max_width, 30, "cancelled cached selector preserves target text width")
  eq(target.opts.table_max_width, 30, "cancelled cached selector preserves target table width")
  eq(target._explicit_max_width, true, "cancelled cached selector preserves fixed sizing")
  eq(target.win, target_win, "cancelled cached selector preserves target ownership")
  eq(vim.api.nvim_buf_get_lines(target.buf, 0, -1, false), before, "cancelled cached selector preserves content")
  feed(key .. "1<CR>")
  eq(vim.api.nvim_get_current_buf(), target.buf, "completed cached selector opens the target")
  eq(target.opts.max_width, 70, "completed cached selector adopts the reader's text width")
  eq(target.opts.table_max_width, 70, "completed cached selector adopts the reader's table width")
  eq(vim.api.nvim_win_get_cursor(0)[1], target.content.heading_anchors.finish + 1, "cached selector reflows its anchor")
end

for _, key in ipairs { "g]0<CR>", "<C-w>g]0<CR>" } do
  for _, repeated in ipairs { false, true } do
    local c = open "toggle"
    if repeated then
      point(c, "#finish")
      feed "<C-]>"
    end
    point(c, "target%20file.md#finish")
    feed "<C-]><C-t>"
    local origin = point(c, "#finish")
    local stack, jumps = vim.fn.gettagstack(), vim.fn.getjumplist()
    feed(key)
    eq(vim.fn.gettagstack(), stack, "cancelled same-document selector preserves forward history")
    eq(vim.fn.getjumplist(), jumps, "cancelled same-document selector preserves jumps")
    eq(vim.api.nvim_win_get_cursor(0), origin, "cancelled same-document selector preserves cursor")
    eq(#vim.api.nvim_list_wins(), 1, "cancelled same-document selector does not split")
    feed ":tag<CR>"
    local target = assert(preview._sessions[vim.api.nvim_get_current_buf()])
    eq(
      vim.api.nvim_buf_get_name(target.source_bufnr),
      c.dir .. "/target file.md",
      "old native forward entry survives cancel"
    )
  end
end
for _, key in ipairs { "g]1<CR>", "<C-w>g]1<CR>" } do
  local c = open "toggle"
  point(c, "#finish")
  feed(key)
  eq(
    vim.api.nvim_win_get_cursor(0)[1],
    c.session.content.heading_anchors.finish + 1,
    "same-document selection completes"
  )
  eq(vim.fn.gettagstack().length, 1, "same-document selection records native history")
end
for _, key in ipairs { "g]0<CR>", "<C-w>g]0<CR>" } do
  for _, forward in ipairs { false, true } do
    local c = open "toggle"
    for _ = 1, 20 do
      point(c, "#finish")
      feed "<C-]>"
    end
    eq(vim.fn.gettagstack().length, 20, "native tag stack reached its fixed capacity")
    if forward then feed "<C-t>" end
    point(c, "#finish")
    local stack = vim.fn.gettagstack()
    feed(key)
    eq(vim.fn.gettagstack(), stack, "cancelled selector preserves saturated native stack")
  end
end
do
  local c = open "toggle"
  for _ = 1, 20 do
    point(c, "#finish")
    feed "<C-]>"
  end
  point(c, "#finish")
  feed "g]1<CR>"
  eq(vim.fn.gettagstack().length, 20, "successful selector preserves native stack capacity")
  eq(
    vim.api.nvim_win_get_cursor(0)[1],
    c.session.content.heading_anchors.finish + 1,
    "successful saturated selector reaches anchor"
  )
end

-- BufEnter callbacks may perform another native jump before the outer tag returns.
do
  local c = open "toggle"
  vim.fn.mkdir(c.dir .. "/child", "p")
  vim.fn.writefile({ "# Target", "", "[next](child/third.md)", "", "# Finish" }, c.dir .. "/target file.md")
  vim.fn.writefile({ "# Third" }, c.dir .. "/child/third.md")
  local nested, note_count = false, #warnings
  local autocmd = vim.api.nvim_create_autocmd("BufEnter", {
    nested = true,
    callback = function()
      local session = preview._sessions[vim.api.nvim_get_current_buf()]
      if not nested and session and vim.api.nvim_buf_get_name(session.source_bufnr) == c.dir .. "/target file.md" then
        nested = true
        point({ buf = session.buf, session = session }, "child/third.md")
        feed "<C-]>"
      end
    end,
  })
  point(c, "target%20file.md#finish")
  feed "<C-]>"
  vim.api.nvim_del_autocmd(autocmd)
  local target = assert(preview._sessions[vim.api.nvim_get_current_buf()])
  eq(nested, true, "nested native navigation ran")
  eq(
    vim.api.nvim_buf_get_name(target.source_bufnr),
    c.dir .. "/child/third.md",
    "nested navigation reaches its own destination"
  )
  eq(#warnings, note_count, "nested navigation restores request without warnings")
  eq(vim.fn.gettagstack().length, 1, "nested tag stack matches native reentrant command semantics")
  eq(
    vim.bo[c.buf].tagfunc,
    "v:lua.require'md-render.preview'._link_tagfunc",
    "outer tagfunc restored after nested navigation"
  )
end

-- All gF variants retain the native filename-followed-by-line-number meaning.
for _, suffix in ipairs { ":4", " @ 4", " (4)", " 4", " line 4" } do
  for _, key in ipairs { "gF", "<C-w>F", "<C-w>gF" } do
    local c = open("toggle", { "[decoy.txt" .. suffix .. "](target.txt)" })
    point(c, "target.txt")
    feed(key)
    eq(vim.api.nvim_buf_get_name(0), c.dir .. "/target.txt", "gF uses href despite label filename")
    eq(vim.api.nvim_win_get_cursor(0)[1], 4, "gF retains line suffix " .. suffix)
  end
end

-- Native fallback still searches 'path' and honors counts, without using extmarks.
for _, key in ipairs { "gf", "gF", "<C-w>f", "<C-w>F", "<C-w>gf", "<C-w>gF" } do
  local c = open("toggle", { "needle.txt:4" })
  for i = 1, 2 do
    vim.fn.mkdir(c.dir .. "/" .. i, "p")
    vim.fn.writefile({ "one", "two", "three", "four" }, c.dir .. "/" .. i .. "/needle.txt")
  end
  vim.bo[c.buf].path = c.dir .. "/1," .. c.dir .. "/2"
  feed("2" .. key)
  eq(vim.api.nvim_buf_get_name(0), c.dir .. "/2/needle.txt", "native no-link fallback count " .. key)
  if key:find("F", 1, true) then eq(vim.api.nvim_win_get_cursor(0)[1], 4, "native gF line number") end
end
_G.md_render_test_tagfunc = function(pattern)
  return { { name = pattern, filename = _G.md_render_test_tag_file, cmd = "4" } }
end
for _, key in ipairs { "<C-]>", "g]1<CR>", "g<C-]>", "<C-w>]", "<C-w><C-]>", "<C-w>g]1<CR>", "<C-w>g<C-]>" } do
  local native_split = key:find("<C-w>", 1, true) ~= nil
  local c = open("toggle", { "plain", "", "[collision](plain)" }, function(source, dir)
    vim.fn.writefile({ "Wrong hyperlink target" }, dir .. "/plain")
    _G.md_render_test_tag_file = dir .. "/target.txt"
    vim.bo[source].tagfunc = "v:lua.md_render_test_tagfunc"
    if key == "<C-w>g]1<CR>" then
      -- New Neovim selectors re-dispatch this normal command asynchronously.
      -- Compare the fallback with the same native key in its source buffer.
      local origin_win = vim.api.nvim_get_current_win()
      feed(key)
      native_split = vim.api.nvim_get_current_win() ~= origin_win
      eq(vim.api.nvim_buf_get_name(0), dir .. "/target.txt", "native selector baseline file")
      eq(vim.api.nvim_win_get_cursor(0)[1], 4, "native selector baseline row")
      if vim.fn.has "nvim-0.13" == 0 then eq(native_split, true, "supported floor native selector splits") end
      if native_split then vim.api.nvim_win_close(0, false) end
      vim.api.nvim_set_current_win(origin_win)
      vim.api.nvim_win_set_buf(origin_win, source)
    end
  end)
  feed(key)
  eq(vim.api.nvim_buf_get_name(0), c.dir .. "/target.txt", "off-link native tag alias retains user tagfunc " .. key)
  eq(vim.api.nvim_win_get_cursor(0)[1], 4, "off-link native tag alias retains native command row")
  eq(vim.api.nvim_get_current_win() ~= c.win, native_split, "off-link native tag alias split semantics")
end
do
  local c = open("toggle", { "plain" })
  _G.md_render_test_tag_file = c.dir .. "/target.txt"
  vim.bo[c.buf].tagfunc = "v:lua.md_render_test_tagfunc"
  feed "<C-]>"
  eq(vim.api.nvim_buf_get_name(0), _G.md_render_test_tag_file, "off-link user tagfunc remains native")
  eq(vim.api.nvim_win_get_cursor(0)[1], 4, "user tagfunc line")
end
do
  local c = open("toggle", { "plain" }, function(source, dir)
    _G.md_render_test_tag_file = dir .. "/target.txt"
    vim.bo[source].tagfunc = "v:lua.md_render_test_tagfunc"
  end)
  feed "<C-]>"
  eq(vim.api.nvim_buf_get_name(0), c.dir .. "/target.txt", "source user tagfunc remains available in preview")
end
do
  local c = open "toggle"
  vim.o.tagstack = false
  point(c, "target%20file.md#finish")
  feed "<C-]>"
  eq(vim.fn.gettagstack().length, 0, "tagstack=false stays disabled")
  vim.o.tagstack = true
end

do
  local c = open "toggle"
  point(c, "target%20file.md#finish")
  vim.wo.winfixbuf = true
  feed "<C-]>"
  eq(vim.api.nvim_get_current_buf(), c.buf, "native tag failure preserves origin")
  eq(vim.fn.gettagstack().length, 0, "failed native tag does not push stack")
  vim.wo.winfixbuf = false
  vim.cmd.edit(c.dir .. "/target file.md")
  eq(preview._sessions[vim.api.nvim_get_current_buf()], nil, "failed native tag leaves no pending redirect")
end

-- User gx mappings can be plain RHS or expression callbacks.
local default_gx = vim.fn.maparg("gx", "n", false, true)
for _, expr in ipairs { false, true } do
  local c = open("toggle", { "[web](https://example.com/href)" }, function()
    if expr then
      vim.keymap.set("n", "gx", function()
        return ":let g:md_render_gx = 22<CR>"
      end, { expr = true })
    else
      vim.keymap.set("n", "gx", ":let g:md_render_gx = 11<CR>")
    end
  end)
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- The padding preceding the first link has no URL extmark.
  feed "gx"
  eq(vim.g.md_render_gx, expr and 22 or 11, "gx delegates user RHS/expr away from links")
end
vim.keymap.set("n", "gx", default_gx.callback, { desc = default_gx.desc })

-- Default normal/Visual gx remains available for unmarked text/selections.
do
  local c = open("toggle", { "https://example.com/plain" })
  local count = #opened
  feed "gg0gx"
  eq(opened[count + 1], "https://example.com/plain", "gx off-link delegates native mapping")
  local visual = vim.fn.maparg("gx", "x", false, true)
  eq(visual.buffer, 0, "Visual gx global mapping is untouched")
  feed "gg0v$gx<Esc>"
  eq(opened[count + 2], "https://example.com/plain", "Visual gx opens selection")
end

-- A dirty source stays intact; ordinary gf retains its existing E37 protection.
do
  local c = open "split"
  vim.api.nvim_buf_set_lines(c.source, 0, 1, false, { "# Unsaved" })
  vim.o.hidden = false
  point(c, "target.txt")
  feed "gf"
  eq(vim.api.nvim_get_current_buf(), c.buf, "gf cannot abandon dirty source")
  eq(vim.api.nvim_win_get_buf(c.source_win), c.source, "dirty source window retained")
  eq(vim.api.nvim_buf_get_lines(c.source, 0, 1, false), { "# Unsaved" }, "dirty source content retained")
  feed "<C-w>f"
  eq(vim.api.nvim_buf_get_name(0), c.dir .. "/target.txt", "new file window safely edits target")
  eq(vim.api.nvim_win_get_buf(c.source_win), c.source, "new file window preserves dirty source")
  vim.bo[c.source].modified = false
  vim.o.hidden = true
end
-- Mouse tag activation uses the clicked position, not the previous cursor.
local child = vim.fn.jobstart(
  { vim.v.progpath, "--embed", "--headless", "-u", "NONE", "--noplugin", "-i", "NONE" },
  { rpc = true }
)
local function lua(code, ...)
  return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
end
local mouse_ok, mouse_error = pcall(function()
  vim.rpcrequest(child, "nvim_ui_attach", 100, 40, { rgb = true })
  lua(
    [[
    package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
    vim.o.hidden, vim.o.swapfile, vim.o.mouse, vim.o.mousetime = true, false, "a", 0
    vim.o.lines, vim.o.columns = 40, 100
    vim.o.termguicolors = true
    vim.env.TMUX, vim.env.TMUX_PANE, vim.env.TERM_PROGRAM = nil, nil, nil
    vim.api.nvim_ui_send = function() end
    require("md-render.image")._set_kitty_supported(false)
    require("md-render.display_utils").supports_osc8 = function() return false end
    _G.size = require "md-render.text_size"
    size.setup { enabled = false }
    _G.preview = require "md-render.preview"
    _G.mouse_root = ...
    _G.mouse_events, _G.mouse_opened = 0, {}
    vim.on_key(function() mouse_events = mouse_events + 1 end)
    vim.ui.open = function(url) mouse_opened[#mouse_opened + 1] = url end
  ]],
    root
  )
  for _, modifier in ipairs { "C", "g" } do
    local dir = root .. "/mouse-" .. modifier
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({ "Cursor origin", "", "[!!!](target.md)", "", "Tail" }, dir .. "/source.md")
    vim.fn.writefile({ "# Mouse target" }, dir .. "/target.md")
    local pos = lua(
      [[
      local dir = ...
      vim.cmd.edit(dir .. "/source.md")
      vim.bo.filetype = "markdown"
      preview.toggle()
      _G.mouse_session = preview._sessions[vim.api.nvim_get_current_buf()]
      vim.cmd "normal! gg0"
      vim.cmd "redraw"
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(mouse_session.buf, mouse_session.ns, 0, -1, { details = true })) do
        if mark[4].url == "target.md" then return vim.fn.screenpos(0, mark[2] + 1, mark[3] + 1) end
      end
    ]],
      dir
    )
    if modifier == "g" then vim.rpcrequest(child, "nvim_input", "g") end
    local mods = modifier == "g" and "" or modifier
    vim.rpcrequest(child, "nvim_input_mouse", "left", "press", mods, 0, pos.row - 1, pos.col - 1)
    vim.rpcrequest(child, "nvim_input_mouse", "left", "release", mods, 0, pos.row - 1, pos.col - 1)
    eq(
      vim.wait(1000, function()
        return lua [[local s=preview._sessions[vim.api.nvim_get_current_buf()];return s and vim.api.nvim_buf_get_name(s.source_bufnr):match("/target%.md$") ~= nil]]
      end, 10),
      true,
      modifier .. " mouse follows clicked href"
    )
    eq(lua "return vim.fn.gettagstack().length", 1, "mouse activation creates native tag entry")
    vim.rpcrequest(child, "nvim_input", vim.keycode "<C-t>")
    eq(
      vim.wait(1000, function()
        return lua "return vim.api.nvim_get_current_buf() == mouse_session.buf"
      end, 10),
      true,
      "mouse Ctrl-T returns"
    )
  end
  local function mouse(action, modifier, pos, row, col)
    local events = lua "return mouse_events"
    if modifier == "g" and action == "press" then vim.rpcrequest(child, "nvim_input", "g") end
    vim.rpcrequest(
      child,
      "nvim_input_mouse",
      "left",
      action,
      modifier == "g" and "" or modifier,
      0,
      pos.row - 1 + (row or 0),
      pos.col - 1 + (col or 0)
    )
    eq(
      vim.wait(1000, function()
        return lua "return mouse_events" > events
      end, 5),
      true,
      "mouse event dispatched"
    )
  end
  local dir = root .. "/mouse-headings"
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(
    { "Body", "", "## [FIRST](#first) [SECOND](#second)", "", "## First", "", "## Second" },
    dir .. "/source.md"
  )
  lua(
    [[
    local dir = ...
    vim.cmd.edit(dir .. "/source.md")
    vim.bo.filetype = "markdown"
    size.supports = function() return true end
    size.setup { backend = "native", enabled = true }
    preview.toggle()
    _G.mouse_session = preview._sessions[vim.api.nvim_get_current_buf()]
    vim.cmd "normal! gg0"
    vim.cmd "redraw"
    size.paint(mouse_session.text_size_state)
  ]],
    dir
  )
  for _, modifier in ipairs { "C", "g" } do
    for _, target in ipairs { { "first", 2 }, { "second", 16 } } do
      for _, row in ipairs { 0, 1 } do
        lua [[vim.cmd "normal! gg0"; vim.fn.settagstack(0, {items={}}, "r"); vim.api.nvim_exec_autocmds("SafeState", {}); vim.cmd "redraw"]]
        local ready = vim.wait(1000, function()
          return lua "return #(mouse_session.text_size_state.drawn or {}) == 3"
        end, 5)
        eq(
          ready,
          true,
          "native enlarged headings visible "
            .. (
              ready and ""
              or vim.inspect(
                lua [[local s=mouse_session.text_size_state;return {drawn=s.drawn,closed=s.closed,placements=#mouse_session.content.text_placements,backend=mouse_session.content.heading_backend,config=size.config(),cursor=vim.api.nvim_win_get_cursor(0),mode=vim.fn.mode()}]]
              )
            )
        )
        local pos =
          lua [[local p=mouse_session.content.text_placements[1]; return vim.fn.screenpos(mouse_session.win,p.line+1,p.col+1)]]
        mouse("press", modifier, pos, row, target[2])
        mouse("release", modifier, pos, row, target[2])
        eq(
          lua "return vim.api.nvim_win_get_cursor(0)[1]",
          lua("return mouse_session.content.heading_anchors[...] + 1", target[1]),
          modifier .. " enlarged heading " .. target[1] .. " visual row " .. row
        )
        eq(lua "return vim.fn.gettagstack().length", 1, "enlarged heading records one native tag")
      end
    end
  end

  -- A mapped press and its release form one activation. The next plain click
  -- must remain usable even after Ctrl-release or an ordinary-file handoff.
  dir = root .. "/mouse-openers"
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile({ "Body", "", "[web](https://example.com/href)", "", "[file](target.txt)" }, dir .. "/source.md")
  vim.fn.writefile({ "Editor" }, dir .. "/target.txt")
  lua(
    [[
    local dir = ...
    vim.cmd.edit(dir .. "/source.md")
    vim.bo.filetype = "markdown"
    size.setup { enabled = false }
    preview.toggle()
    _G.mouse_session = preview._sessions[vim.api.nvim_get_current_buf()]
    vim.cmd "normal! gg0"
    vim.cmd "redraw"
    _G.link_pos = function(url)
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(mouse_session.buf, mouse_session.ns, 0, -1, {details=true})) do
        if mark[4].url == url then return vim.fn.screenpos(mouse_session.win, mark[2]+1, mark[3]+1) end
      end
    end
  ]],
    dir
  )
  for _, modifier in ipairs { "C", "g" } do
    lua [[mouse_opened = {}]]
    local pos = lua [[return link_pos("https://example.com/href")]]
    mouse("press", modifier, pos)
    mouse("release", modifier, pos)
    eq(lua "return #mouse_opened", 1, modifier .. " external click opens once")
    mouse("press", "", pos)
    mouse("release", "", pos)
    eq(lua "return #mouse_opened", 2, "plain click after modifier release remains usable")
  end
  local pos = lua [[return link_pos("target.txt")]]
  mouse("press", "g", pos)
  mouse("release", "g", pos)
  eq(lua "return vim.api.nvim_buf_get_name(0)", dir .. "/target.txt", "g mouse ordinary file handoff")
  eq(lua "return vim.w.md_render_tag_mouse_release == nil", true, "ordinary file release clears gesture")
  vim.rpcrequest(child, "nvim_input", vim.keycode "<C-t>")
  eq(
    vim.wait(1000, function()
      return lua "return vim.api.nvim_get_current_buf() == mouse_session.buf"
    end, 5),
    true,
    "ordinary mouse target native return"
  )
  pos = lua [[return link_pos("https://example.com/href")]]
  local before = lua "return #mouse_opened"
  mouse("press", "", pos)
  mouse("release", "", pos)
  eq(lua "return #mouse_opened", before + 1, "plain click after ordinary-file handoff remains usable")
  for _, dirty in ipairs { false, true } do
    lua(
      [[
      local dirty = ...
      local source = mouse_session.source_bufnr
      if dirty then vim.api.nvim_buf_set_lines(source, 0, 1, false, {"Unsaved body"}) end
      vim.bo[source].modified = dirty
      mouse_session:rebuild(true)
      vim.o.more = false
      vim.v.errmsg = ""
      _G.reload_state = function()
        local marks = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(mouse_session.buf, mouse_session.ns, 0, -1, {details=true})) do
          if mark[4].url then marks[#marks+1] = {mark[2],mark[3],mark[4].url} end
        end
        return {source=vim.api.nvim_buf_get_lines(source,0,-1,false),
          render=vim.api.nvim_buf_get_lines(mouse_session.buf,0,-1,false),
          source_modified=vim.bo[source].modified,modified=vim.bo[mouse_session.buf].modified,
          buftype=vim.bo[mouse_session.buf].buftype,modifiable=vim.bo[mouse_session.buf].modifiable,
          anchors=vim.b[mouse_session.buf].md_render_anchors,links=marks,
          disk=vim.fn.readfile(vim.api.nvim_buf_get_name(source))}
      end
      _G.before_reload = reload_state()
    ]],
      dirty
    )
    vim.rpcrequest(child, "nvim_input", ":edit!<CR><CR>")
    eq(
      vim.wait(1000, function()
        return lua [[return vim.v.errmsg:find("reload the source buffer",1,true) ~= nil]]
      end, 5),
      true,
      "interactive render reload rejected"
    )
    eq(
      lua "return reload_state()",
      lua "return before_reload",
      "interactive reload preserves source/render metadata and disk"
    )
    eq(
      lua "return vim.api.nvim_get_current_buf() == mouse_session.buf",
      true,
      "interactive reload retains render focus"
    )
  end
end)
vim.fn.jobstop(child)
assert(mouse_ok, mouse_error)
print("native_navigation_test: " .. checks .. " passed")
vim.fn.delete(root, "rf")
