-- Real parser -> render -> Session -> keyboard navigation.
-- Run: nvim --headless -u NONE --noplugin -i NONE -l tests/gf_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local preview = require "md-render.preview"
local links = require "md-render.links"
local image = require "md-render.image"
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
-- Match buffer names when the temporary directory contains symlinks (macOS).
root = assert(vim.uv.fs_realpath(root))
vim.o.hidden = true
vim.o.swapfile = false
image._set_kitty_supported(true)
vim.api.nvim_ui_send = function() end
local puts = {}
local original_put = image.put_image
image.put_image = function(id, win, ...)
  puts[#puts + 1] = vim.api.nvim_win_get_buf(win)
  return original_put(id, win, ...)
end
local warnings = {}
vim.notify = function(message)
  warnings[#warnings + 1] = message
end
local checks = 0
local function eq(actual, expected, message)
  checks = checks + 1
  assert(vim.deep_equal(actual, expected), message .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end
local function feed(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
  vim.wait(30)
end
local function follow(url, at_top)
  local buf = vim.api.nvim_get_current_buf()
  local session = assert(preview._sessions[buf], "expected rendered Session")
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, session.ns, 0, -1, { details = true })) do
    if mark[4].url == url then
      vim.api.nvim_win_set_cursor(0, { mark[2] + 1, mark[3] })
      if at_top then vim.fn.winrestview { lnum = mark[2] + 1, col = mark[3], topline = mark[2] } end
      local view = vim.fn.winsaveview()
      feed "gf"
      return view
    end
  end
  error("missing rendered URL: " .. url)
end
local serial = 0
local function open(mode, lines, opts)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(win).relative ~= "" then vim.api.nvim_win_close(win, true) end
  end
  vim.cmd "silent! tabonly!"
  vim.cmd "silent! only!"
  serial = serial + 1
  local dir = root .. "/" .. serial
  vim.fn.mkdir(dir, "p")
  vim.fn.writefile(lines, dir .. "/source.md")
  vim.cmd.edit(dir .. "/source.md")
  vim.bo.filetype = "markdown"
  vim.wo.number = true
  vim.wo.relativenumber = true
  vim.wo.list = true
  vim.wo.statusline = "editor status"
  vim.wo.winbar = "editor bar"
  local source, source_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  if mode == "float" then
    preview.show(opts)
  elseif mode == "tab" then
    preview.show_tab(opts)
  elseif mode == "split" then
    preview.split(opts)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if win ~= source_win then
        vim.api.nvim_set_current_win(win)
        break
      end
    end
  else
    preview.toggle(opts)
  end
  return dir, source, source_win, vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
end

for _, mode in ipairs { "toggle", "split", "float", "tab" } do
  local lines =
    { "# Source", "", "> [!NOTE]- Details", "> Keep this fold", "", "```", string.rep("code ", 40), "```", "" }
  for i = 1, 65 do
    lines[#lines + 1] = "Paragraph " .. i .. "."
    lines[#lines + 1] = ""
  end
  vim.list_extend(lines, {
    '[wrong.txt](<target.md> "Title")',
    "",
    "[editor](target.txt)",
    "",
    "![image](" .. vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png)",
  })
  local dir, source, source_win, render_win, render = open(mode, lines)
  vim.fn.writefile({ "# Wrong label" }, dir .. "/wrong.txt")
  vim.fn.writefile({ "# Target", "", "[third](third.md)" }, dir .. "/target.md")
  vim.fn.writefile({ "# Third" }, dir .. "/third.md")
  vim.fn.writefile({ "ordinary editor" }, dir .. "/target.txt")
  local session = assert(preview._sessions[render])
  local fold = assert(session.content.callout_folds[1])
  vim.api.nvim_win_set_cursor(0, { fold.header_line + 1, 0 })
  feed "za"
  local folds = vim.deepcopy(session.fold_state)
  local region = assert(session.content.expandable_regions[1])
  vim.api.nvim_win_set_cursor(0, { region.start_line + 1, 0 })
  feed "za"
  local expansions = vim.deepcopy(session.expand_state)
  -- Existing modified source/target buffers must be reused intact.
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { "UNSAVED SOURCE" })
  local target_source = vim.fn.bufadd(dir .. "/target.md")
  vim.fn.bufload(target_source)
  vim.api.nvim_buf_set_lines(target_source, -1, -1, false, { "UNSAVED TARGET" })
  vim.wait(100)
  local old_images = session.image_state
  local saved_view = follow "target.md"
  local target_render = vim.api.nvim_get_current_buf()
  eq(vim.api.nvim_get_current_win(), render_win, mode .. " keeps preview window")
  eq(preview._sessions[target_render].source_bufnr, target_source, mode .. " follows href and retains rendering")
  eq(old_images and old_images.closed, true, mode .. " releases old image callbacks")
  follow "third.md"
  feed "<C-o>"
  eq(vim.api.nvim_get_current_buf(), target_render, mode .. " multi-hop return")
  feed "<C-o>"
  eq(vim.api.nvim_get_current_buf(), render, mode .. " returns rendered source")
  eq(vim.fn.winsaveview(), saved_view, mode .. " restores reading view")
  eq(session.fold_state, folds, mode .. " preserves fold state")
  eq(session.expand_state, expansions, mode .. " preserves expansion state")
  eq(vim.bo[source].modified, true, mode .. " preserves modified source")
  eq(
    vim.api.nvim_buf_get_lines(target_source, -1 - 1, -1, false)[1],
    "UNSAVED TARGET",
    mode .. " preserves target content"
  )

  follow "target.txt"
  local editor = vim.api.nvim_get_current_buf()
  eq(vim.api.nvim_buf_get_name(editor), dir .. "/target.txt", mode .. " opens other files normally")
  eq(vim.api.nvim_get_current_win(), source_win, mode .. " uses original source editor")
  eq(vim.bo[editor].modifiable, true, mode .. " target is editable")
  eq(vim.wo.number, true, mode .. " restores editor number option")
  eq(vim.wo.list, true, mode .. " restores editor list option")
  eq(vim.wo.statusline, "editor status", mode .. " restores statusline")
  eq(vim.wo.winbar, "editor bar", mode .. " restores winbar")
  if mode == "float" or mode == "tab" then
    eq(vim.api.nvim_win_is_valid(render_win), false, mode .. " closes temporary preview")
  end
  puts = {}
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = editor })
  vim.wait(150)
  eq(vim.tbl_contains(puts, editor), false, mode .. " images never draw into editor")
  vim.api.nvim_buf_set_lines(editor, -1, -1, false, { "UNSAVED EDITOR" })
  feed "<C-o>"
  eq(vim.api.nvim_get_current_buf(), render, mode .. " editing return restores render")
  eq(session.fold_state, folds, mode .. " editing return retains folds")
  eq(session.expand_state, expansions, mode .. " editing return retains expansions")
  eq(vim.fn.maparg("q", "n"), "", mode .. " returned editor window has no preview-close mapping")
  eq(vim.bo[editor].modified, true, mode .. " preserves editor changes")
  feed "<C-i>"
  eq(vim.api.nvim_get_current_buf(), editor, mode .. " forward returns to editor")
  if mode == "split" then
    eq(session.win, render_win, "retained split regains image attachment")
    eq(session.image_state ~= nil, true, "retained split still renders images")
  end
end

-- Repeated visits must not replace an older native jump's cursor or viewport.
for _, mode in ipairs { "toggle", "split", "float", "tab" } do
  local lines = { "# A", "" }
  for i = 1, 20 do
    vim.list_extend(lines, { "Early paragraph " .. i, "" })
  end
  vim.list_extend(lines, { "[B](b.md)", "" })
  for i = 1, 60 do
    vim.list_extend(lines, { "Paragraph " .. i, "" })
  end
  lines[#lines + 1] = "[C](c.md)"
  local cycle_dir, _, _, cycle_win, cycle_render = open(mode, lines)
  vim.fn.writefile({ "# B", "", "[A](source.md)" }, cycle_dir .. "/b.md")
  vim.fn.writefile({ "# C" }, cycle_dir .. "/c.md")
  vim.cmd.clearjumps()
  local first_view = follow("b.md", true)
  follow "source.md"
  follow "c.md"
  local last_render = vim.api.nvim_get_current_buf()
  feed "3<C-o>"
  eq(vim.api.nvim_get_current_buf(), cycle_render, mode .. " counted return to earlier visit")
  eq(vim.fn.winsaveview(), first_view, mode .. " earlier visit keeps its own viewport")
  feed "3<C-i>"
  eq(vim.api.nvim_get_current_buf(), last_render, mode .. " counted forward follows native history")
  feed "<C-o>"
  feed "<C-o>"
  feed "<C-o>"
  eq(vim.fn.winsaveview(), first_view, mode .. " successive return keeps earlier viewport")
  feed "3<C-i>"
  feed "3<C-o>3<C-i>3<C-o>"
  eq(vim.fn.winsaveview(), first_view, mode .. " rapid jumps never cache a transient viewport")
  feed "3<C-i>"
  feed "3<C-o><C-e>"
  eq(vim.fn.winsaveview().topline, first_view.topline + 1, mode .. " return precedes a macro's explicit scroll")
end

-- Native window copies share the associated source editor, without inheriting
-- temporary close keys or treating render options as editor options.
for _, mode in ipairs { "toggle", "split", "float", "tab" } do
  local copy_dir, _, source_win, original_win, original_render = open(mode, { "[edit](target.txt)" })
  vim.fn.writefile({ "target" }, copy_dir .. "/target.txt")
  vim.cmd.split()
  local copy_win = vim.api.nvim_get_current_win()
  -- No vim.wait here: gf must also work within the same macro as :split.
  follow "target.txt"
  eq(vim.api.nvim_get_current_win(), source_win, mode .. " copied preview uses associated editor")
  eq(vim.api.nvim_buf_get_name(0), copy_dir .. "/target.txt", mode .. " native split gf opens target")
  eq(vim.wo.number, true, mode .. " native split preserves editor options")
  eq(vim.api.nvim_win_get_buf(copy_win), original_render, mode .. " native copy stays rendered")
  if mode ~= "toggle" then
    eq(vim.api.nvim_win_get_buf(original_win), original_render, mode .. " original preview stays rendered")
  end
end

-- Window creation may switch away from its inherited render before deferred
-- attachment. Editor options must already be registered for that transition.
for _, command in ipairs { "split", "tab split", "new", "tabnew" } do
  local native_dir, _, _, _, native_render = open("toggle", { "target.txt" })
  vim.fn.writefile({ "target" }, native_dir .. "/target.txt")
  vim.bo[native_render].path = native_dir
  local original_images = preview._sessions[native_render].image_state
  vim.cmd(command)
  if command:find("split", 1, true) then
    feed "gf"
    eq(vim.api.nvim_buf_get_name(0), native_dir .. "/target.txt", command .. " native gf opens editor")
  else
    vim.wait(30)
  end
  eq(vim.wo.number, true, command .. " does not leave render options in an ordinary editor")
  eq(preview._sessions[native_render].image_state, original_images, command .. " keeps original image attachment")
end

local reverse_dir, _, reverse_render_win, _, reverse_render = open("toggle", { "[edit](target.txt)" })
vim.fn.writefile({ "target" }, reverse_dir .. "/target.txt")
preview.split()
local reverse_source_win = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(reverse_render_win)
follow "target.txt"
eq(vim.api.nvim_get_current_win(), reverse_source_win, "split from render pairs the new source editor")
eq(vim.api.nvim_win_get_buf(reverse_render_win), reverse_render, "reverse split retains render")

local handback_dir, _, _, handback_win, handback_render =
  open("split", { "[edit](target.txt)", "", "![image](" .. vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png)" })
vim.fn.writefile({ "target" }, handback_dir .. "/target.txt")
follow "target.txt"
feed "<C-o>"
preview.toggle()
local handback_session = preview._sessions[handback_render]
eq(handback_session.win, handback_win, "toggle back to source returns image ownership to retained split")
eq(handback_session.image_state ~= nil, true, "retained split keeps image resources")

-- The original source window can be reused while its float stays open. Seeding
-- a return jump must release the other document and retain its current view.
local reuse_dir, _, reuse_source_win, reuse_float = open("float", { "[edit](target.txt)" })
vim.fn.writefile({ "target" }, reuse_dir .. "/target.txt")
vim.fn.writefile({ "# B", "", "![image](" .. vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png)" }, reuse_dir .. "/b.md")
vim.api.nvim_set_current_win(reuse_source_win)
vim.cmd.edit(reuse_dir .. "/b.md")
preview.toggle()
local displaced = preview._sessions[vim.api.nvim_get_current_buf()]
local displaced_images = displaced.image_state
local displaced_view = vim.fn.winsaveview()
vim.api.nvim_set_current_win(reuse_float)
follow "target.txt"
eq(displaced_images.closed, true, "reused source editor closes displaced image callbacks")
eq(displaced.win, nil, "hidden displaced preview releases its window")
eq(displaced.views[reuse_source_win], displaced_view, "seeding remembers displaced document view")
puts = {}
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_get_current_buf() })
vim.wait(100)
eq(#puts, 0, "displaced document cannot paint into target editor")

-- Exact supported destinations, real inline/reference parsing, unrelated cwd.
for _, destination in ipairs {
  "linked%20%23file.md#heading",
  '<linked%20%23file.md> "Title"',
  '<linked%20%23file.md> "Title with )"',
  "FILE_URI",
  "ABSOLUTE",
  "REFERENCE",
} do
  local dir, _, _, _, render = open("toggle", { "placeholder" })
  local source = preview._sessions[render].source_bufnr
  local target = dir .. "/linked #file.md"
  vim.fn.writefile({ "# Destination" }, target)
  local href = destination
  if href == "FILE_URI" then href = "file://" .. dir .. "/linked%20%23file.md?query#heading" end
  if href == "ABSOLUTE" then href = dir .. "/linked%20%23file.md" end
  local markdown = href == "REFERENCE" and { "[label][ref]", "", '[ref]: <linked%20%23file.md> "Title"' }
    or { "[label](" .. href .. ")" }
  vim.api.nvim_buf_set_lines(source, 0, -1, false, markdown)
  preview._sessions[render]:refresh_source()
  preview._sessions[render]:rebuild()
  eq(vim.trim(preview._sessions[render].content.lines[1]), "label", "link syntax and title are hidden")
  local marks = vim.api.nvim_buf_get_extmarks(render, preview._sessions[render].ns, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    if mark[4].url then
      vim.api.nvim_win_set_cursor(0, { mark[2] + 1, mark[3] })
      feed "gf"
      break
    end
  end
  eq(vim.api.nvim_buf_get_name(preview._sessions[vim.api.nvim_get_current_buf()].source_bufnr), target, destination)
end

do
  local dir, source, _, _, render = open("split", {
    "plain",
    "[link](missing.md)",
    "",
    "before [web](https://example.com) after",
    "",
    "[private directory](private-dir/)",
    "",
    "[private](private.md)",
    "",
    "[invalid slash](private.md/)",
    "",
    "[NUL](private.md%00extra)",
    "",
    "[device](/dev/null)",
  })
  local session = preview._sessions[render]
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(render, session.ns, 0, -1, { details = true })) do
    if mark[4].url then
      eq(links.at(render, session.ns, mark[2], mark[3]), mark[4].url, "link starts inclusive")
      eq(links.at(render, session.ns, mark[2], mark[4].end_col), nil, "link ends exclusive")
      if mark[3] > 0 then eq(links.at(render, session.ns, mark[2], mark[3] - 1), nil, "text before link") end
      if mark[2] > 0 then
        eq(links.at(render, session.ns, mark[2] - 1, 0), nil, "previous row does not activate link")
      end
    end
  end
  vim.fn.mkdir(dir .. "/private-dir", "p")
  vim.fn.setfperm(dir .. "/private-dir", "---------")
  vim.fn.writefile({ "secret" }, dir .. "/private.md")
  vim.fn.setfperm(dir .. "/private.md", "---------")
  for _, href in ipairs {
    "missing.md",
    "https://example.com",
    "private-dir/",
    "private.md",
    "private.md/",
    "private.md%00extra",
    "/dev/null",
  } do
    local before = #warnings
    follow(href)
    eq(vim.api.nvim_get_current_buf(), render, href .. " leaves preview unchanged")
    eq(#warnings, before + 1, href .. " reports actionable failure")
  end
  vim.fn.setfperm(dir .. "/private-dir", "rwx------")
  vim.fn.setfperm(dir .. "/private.md", "rw-------")
  eq(vim.fn.bufnr(dir .. "/missing.md"), -1, "missing link creates no buffer")
end

-- Filesystem traversal after a symlink is not lexical .. elimination.
local symlink_dir = open("toggle", { "[exact](link/../target.md)" })
vim.fn.mkdir(symlink_dir .. "/real/inner", "p")
assert(vim.uv.fs_symlink(symlink_dir .. "/real/inner", symlink_dir .. "/link"))
vim.fn.writefile({ "# Correct destination" }, symlink_dir .. "/real/target.md")
vim.fn.writefile({ "# Wrong lexical destination" }, symlink_dir .. "/target.md")
follow "link/../target.md"
eq(preview._sessions[vim.api.nvim_get_current_buf()].source_lines[1], "# Correct destination", "symlink traversal")

local paren_dir = open("toggle", { '[version](<version(1).md> "A (title)")' })
vim.fn.writefile({ "# Version one" }, paren_dir .. "/version(1).md")
follow "version(1).md"
eq(preview._sessions[vim.api.nvim_get_current_buf()].source_lines[1], "# Version one", "parentheses in destination")

for _, reference in ipairs { false, true } do
  local line = reference and "[exact][file]" or "[exact](<two  spaces.md>)"
  local exact_dir = open("toggle", { line, "", "[file]: <two  spaces.md>" })
  vim.fn.writefile({ "# Exact destination" }, exact_dir .. "/two  spaces.md")
  vim.fn.writefile({ "# Wrong destination" }, exact_dir .. "/two spaces.md")
  follow "two  spaces.md"
  eq(preview._sessions[vim.api.nvim_get_current_buf()].source_lines[1], "# Exact destination", "literal href spaces")
end

-- Native gf and count handling, using native path/suffix search on plain text.
for count = 1, 2 do
  local native_dir, _, _, _, native_render = open("toggle", { "needle" })
  for i = 1, 2 do
    vim.fn.mkdir(native_dir .. "/" .. i, "p")
    vim.fn.writefile({ tostring(i) }, native_dir .. "/" .. i .. "/needle.txt")
  end
  vim.bo[native_render].path = native_dir .. "/1," .. native_dir .. "/2"
  vim.bo[native_render].suffixesadd = ".txt"
  vim.cmd "normal! gg0w"
  feed((count == 1 and "" or tostring(count)) .. "gf")
  eq(vim.api.nvim_buf_get_name(0), native_dir .. "/" .. count .. "/needle.txt", "native counted gf")
  feed "<C-o>"
  eq(vim.api.nvim_get_current_buf(), native_render, "native gf can return to render")
end

-- Failed abandonment must leave both source contents and preview intact.
for _, mode in ipairs { "split", "float", "tab" } do
  local protect_dir, protect_source, _, protect_win, protect_render = open(mode, { "[edit](target.txt)" })
  vim.fn.writefile({ "target" }, protect_dir .. "/target.txt")
  vim.api.nvim_buf_set_lines(protect_source, -1, -1, false, { "UNSAVED" })
  vim.o.hidden = false
  follow "target.txt"
  eq(vim.api.nvim_get_current_win(), protect_win, mode .. " failed abandonment keeps preview window")
  eq(vim.api.nvim_get_current_buf(), protect_render, mode .. " failed abandonment keeps preview document")
  eq(
    vim.api.nvim_buf_get_lines(protect_source, -2, -1, false)[1],
    "UNSAVED",
    mode .. " failed abandonment preserves edits"
  )
  vim.o.hidden = true
end

local options_dir, _, options_source_win, options_float = open("float", { "[edit](target.txt)" })
vim.fn.writefile({ "target" }, options_dir .. "/target.txt")
vim.api.nvim_set_current_win(options_source_win)
vim.wo.number = false
vim.wo.statusline = "changed while reading"
vim.api.nvim_set_current_win(options_float)
follow "target.txt"
eq(vim.wo.number, false, "navigation preserves changes to source editor options")
eq(vim.wo.statusline, "changed while reading", "navigation restores current editor statusline")

-- A floating window that temporarily became an editor can return after another
-- float was opened. Closing the focused preview must target that same window.
local handle_dir, _, handle_source_win, first_float, first_render = open("float", { "# A" })
vim.fn.writefile({ "editor" }, handle_dir .. "/target.txt")
vim.fn.writefile({ "# B" }, handle_dir .. "/b.md")
vim.cmd.edit(handle_dir .. "/target.txt")
vim.api.nvim_set_current_win(handle_source_win)
vim.cmd.edit(handle_dir .. "/b.md")
preview.show()
local second_float = vim.api.nvim_get_current_win()
vim.api.nvim_set_current_win(first_float)
vim.cmd.buffer(first_render)
vim.api.nvim_set_current_win(second_float)
preview.show()
eq(vim.api.nvim_win_is_valid(first_float), true, "closing focused float preserves the other restored preview")
eq(vim.api.nvim_win_is_valid(second_float), false, "close handle follows the focused float")

-- Independent presentations must retain their own layout, resources and writes.
do
  local shared_dir, shared_source, shared_source_win, split_win, shared_render = open(
    "split",
    { "# Shared", "", string.rep("A paragraph with several words. ", 12) },
    { max_width = 25 }
  )
  local split_session = preview._sessions[shared_render]
  local split_lines = vim.api.nvim_buf_get_lines(shared_render, 0, -1, false)
  local split_images = split_session.image_state
  vim.api.nvim_set_current_win(shared_source_win)
  preview.show { max_width = 70 }
  local float_win = vim.api.nvim_get_current_win()
  local float_render = vim.api.nvim_get_current_buf()
  local float_lines = vim.api.nvim_buf_get_lines(float_render, 0, -1, false)
  eq(float_render ~= shared_render, true, "independent previews have separate render buffers")
  eq(vim.api.nvim_buf_get_lines(shared_render, 0, -1, false), split_lines, "opening float preserves split layout")
  vim.api.nvim_set_current_win(split_win)
  eq(vim.api.nvim_buf_get_lines(float_render, 0, -1, false), float_lines, "focus preserves float layout")
  eq(vim.fn.maparg("q", "n"), "", "split has no close key")
  vim.api.nvim_set_current_win(float_win)
  eq(vim.fn.maparg("q", "n"), ":close<CR>", "floating preview has close key")
  eq(split_session.image_state, split_images, "float never replaces split image attachment")
  vim.api.nvim_buf_set_lines(shared_source, -1, -1, false, { "", "UPDATED SOURCE" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = shared_source })
  vim.wait(200)
  for _, buf in ipairs { shared_render, float_render } do
    eq(
      preview._sessions[buf].source_lines[#preview._sessions[buf].source_lines],
      "UPDATED SOURCE",
      "source updates every presentation"
    )
  end
  vim.cmd.write()
  eq(vim.fn.readfile(shared_dir .. "/source.md")[5], "UPDATED SOURCE", "independent float forwards writes to source")
  feed "q"
  eq(vim.api.nvim_win_is_valid(split_win), true, "closing independent float retains split")
  vim.api.nvim_set_current_win(split_win)
  eq(vim.fn.maparg("q", "n"), "", "split retains its keymaps")
  eq(split_session.opts.max_width, 25, "split retains its explicit width")
  vim.api.nvim_set_current_win(shared_source_win)
  preview.show { max_width = 40 }
  eq(preview._sessions[vim.api.nvim_get_current_buf()].opts.max_width, 40, "reopened float honors new options")
  feed "q"
  vim.api.nvim_set_current_win(shared_source_win)
  preview.show()
  eq(
    preview._sessions[vim.api.nvim_get_current_buf()]._explicit_max_width,
    false,
    "reopened float restores automatic sizing"
  )
  eq(
    preview._sessions[vim.api.nvim_get_current_buf()].source_bufnr,
    shared_source,
    "reopening preserves source ownership"
  )
end

local _, _, explicit_source_win, explicit_split, explicit_render = open(
  "split",
  { "# Shared layout" },
  { max_width = 15 }
)
vim.api.nvim_set_current_win(explicit_source_win)
preview.show { max_width = 60 }
feed "q"
eq(preview._sessions[explicit_render].win, explicit_split, "closed float returns ownership to the split")
eq(preview._sessions[explicit_render].opts.max_width, 15, "shared preview restores the split's explicit width")

-- Another presentation's cached target must not leak its layout options.
local layout_dir, layout_source, layout_win = open("toggle", { "[B](b.md)" })
vim.fn.writefile({ "# B", "", "A sentence that wraps in a narrow preview." }, layout_dir .. "/b.md")
preview.toggle()
vim.cmd.edit(layout_dir .. "/b.md")
preview.toggle { max_width = 10 }
preview.toggle()
vim.cmd.buffer(layout_source)
preview.show { max_width = 50 }
local layout_float = vim.api.nvim_get_current_win()
follow "b.md"
eq(vim.api.nvim_get_current_win(), layout_float, "independent target retains preview window")
eq(
  preview._sessions[vim.api.nvim_get_current_buf()].opts.max_width,
  50,
  "independent target follows current preview width"
)
feed "q"
eq(vim.api.nvim_get_current_win(), layout_win, "independent target closes to original editor")

-- Close-time cursor synchronization must use the active document/session.
for _, mode in ipairs { "float", "tab" } do
  local _, close_source, close_source_win, close_win, close_render =
    open(mode, { "# Title", "", "one", "", "two", "", "last" })
  local close_session = preview._sessions[close_render]
  close_session._syncing = true -- isolate close synchronization from live scroll sync
  close_session:scroll_to_source_line(7)
  local line = close_session:rendered_to_source(vim.api.nvim_win_get_cursor(close_win)[1])
  vim.api.nvim_win_set_cursor(close_source_win, { 1, 0 })
  feed "q"
  eq(vim.api.nvim_win_get_buf(close_source_win), close_source, mode .. " closes to source")
  eq(vim.api.nvim_win_get_cursor(close_source_win)[1], line, mode .. " syncs source cursor on close")
end

-- Same-window history remains native. A handoff to the original editor seeds
-- only the immediately preceding render; it does not import the old window's list.
for _, mode in ipairs { "toggle", "split", "float", "tab" } do
  local dir, source, _, _, a_render = open(mode, { "[B](b.md)" })
  vim.fn.writefile({ "[edit](notes.txt)" }, dir .. "/b.md")
  vim.fn.writefile({ "notes" }, dir .. "/notes.txt")
  for _, key in ipairs { "<C-o>", "<C-i>" } do
    eq(vim.fn.maparg(key, "n"), "", mode .. " leaves " .. key .. " native")
  end
  follow "b.md"
  local b_render = vim.api.nvim_get_current_buf()
  follow "notes.txt"
  feed "<C-o>"
  eq(vim.api.nvim_get_current_buf(), b_render, mode .. " handoff returns preceding rendered document")
  feed "<C-o>"
  eq(
    vim.api.nvim_get_current_buf(),
    mode == "toggle" and a_render or source,
    mode .. " earlier history belongs to its window"
  )
end

-- A repaint of untouched rows must not collapse the native jump's line number.
for _, mode in ipairs { "toggle", "split", "float", "tab" } do
  local lines = { "# A", "" }
  for i = 1, 70 do
    vim.list_extend(lines, { "Paragraph " .. i, "" })
  end
  lines[#lines + 1] = "[B](b.md)"
  local dir, source = open(mode, lines)
  vim.fn.writefile({ "# B" }, dir .. "/b.md")
  local before = follow("b.md", true)
  vim.api.nvim_buf_set_lines(source, -1, -1, false, { "", "APPEND ONLY" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = source })
  feed "<C-o>"
  eq(vim.fn.winsaveview(), before, mode .. " append preserves first return view")
  feed "<C-i><C-o>"
  eq(vim.fn.winsaveview(), before, mode .. " append preserves subsequent native return")
  feed "<C-i>"
  vim.api.nvim_buf_set_lines(source, 0, 1, false, { "# Updated A" })
  vim.api.nvim_buf_set_lines(source, -2, -1, false, { "UPDATED END" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = source })
  feed "<C-o><C-i><C-o>"
  eq(vim.fn.winsaveview(), before, mode .. " disjoint edits preserve unchanged middle jump")
  for _, insert in ipairs { true, false } do
    feed "<C-i>"
    vim.api.nvim_buf_set_lines(source, 0, insert and 0 or 2, false, insert and { "PREPEND", "" } or {})
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = source })
    feed "<C-o>"
    eq(vim.trim(vim.api.nvim_get_current_line()), "B", mode .. " first return follows shifted native mark")
    eq(vim.api.nvim_win_get_cursor(0)[1], before.lnum + (insert and 2 or 0), mode .. " native mark shifts with rows")
  end
end

-- Independent presentations remain the same Session after returning to the
-- editor: toggling and auto mode must preserve their folds and insert mappings.
for _, mode in ipairs { "float", "tab" } do
  local dir, _, _, _, render = open(mode, { "> [!NOTE]- Details", "> Keep this", "", "[edit](notes.txt)" })
  vim.fn.writefile({ "notes" }, dir .. "/notes.txt")
  local session = preview._sessions[render]
  feed "za"
  local folds = vim.deepcopy(session.fold_state)
  follow "notes.txt"
  feed "<C-o>"
  preview.auto_on()
  eq(vim.fn.maparg("i", "n") ~= "", true, mode .. " returned render supports auto insert")
  preview.auto_off()
  eq(vim.fn.maparg("i", "n", false, true), {}, mode .. " auto off removes insert mapping")
  preview.toggle()
  eq(vim.api.nvim_get_current_buf(), render, mode .. " toggle reuses independent presentation")
  eq(preview._sessions[render].fold_state, folds, mode .. " toggle preserves independent folds")
  eq(vim.fn.maparg("i", "n"), "", mode .. " auto off leaves no mapping on render")
end

-- Ordinary editing can update its window options between preview visits.
for _, mode in ipairs { "toggle", "split", "float", "tab" } do
  local dir = open(mode, { "[edit](notes.txt)" })
  vim.fn.writefile({ "notes" }, dir .. "/notes.txt")
  follow "notes.txt"
  vim.wo.number = false
  vim.wo.statusline = "USER UPDATED"
  feed "<C-o><C-i>"
  eq(vim.wo.number, false, mode .. " keeps updated editor options")
  eq(vim.wo.statusline, "USER UPDATED", mode .. " keeps updated editor statusline")
end

do
  local dir = open("toggle", { "[target](target.md)" })
  vim.fn.writefile({ "# Old target" }, dir .. "/target.md")
  vim.fn.mkdir(dir .. "/moved", "p")
  vim.fn.writefile({ "# New target" }, dir .. "/moved/target.md")
  preview.toggle()
  vim.cmd.saveas(dir .. "/moved/source.md")
  preview.toggle()
  follow "target.md"
  eq(
    preview._sessions[vim.api.nvim_get_current_buf()].source_lines[1],
    "# New target",
    "saveas refreshes relative link base"
  )
end

for _, mode in ipairs { "toggle", "split", "float", "tab" } do
  for _, reference in ipairs { false, true } do
    local lines = reference and { "[decoy.md][file]", "", "[file]: <a\\>b.md>" } or { "[decoy.md](a<b.md)" }
    local dir, _, _, _, render = open(mode, lines)
    local filename = reference and "a>b.md" or "a<b.md"
    vim.fn.writefile({ "# Correct target" }, dir .. "/" .. filename)
    vim.fn.writefile({ "# Decoy" }, dir .. "/decoy.md")
    local line = vim.api.nvim_buf_get_lines(render, 0, 1, false)[1]
    vim.api.nvim_win_set_cursor(0, { 1, assert(line:find("decoy.md", 1, true)) - 1 })
    feed "gf"
    eq(
      preview._sessions[vim.api.nvim_get_current_buf()].source_lines[1],
      "# Correct target",
      mode .. " unusual href overrides a real filename label"
    )
  end
end

-- Source cleanup must reach every presentation while preserving other documents.
do
  local dir, source, source_win, _, split_render = open("split", { "[B](b.md)" }, { max_width = 25 })
  vim.fn.writefile({ "# B", "", "[A](source.md)" }, dir .. "/b.md")
  vim.api.nvim_set_current_win(source_win)
  preview.show { max_width = 70 }
  local float_render = vim.api.nvim_get_current_buf()
  follow "b.md"
  local b_render = vim.api.nvim_get_current_buf()
  local b_source = preview._sessions[b_render].source_bufnr
  follow "source.md"
  feed "<C-o><C-i>"
  follow "b.md"
  vim.api.nvim_buf_delete(source, { force = true })
  eq(vim.api.nvim_buf_is_valid(split_render), false, "source wipe cleans the independent split")
  eq(vim.api.nvim_buf_is_valid(float_render), false, "source wipe cleans the hidden float document")
  eq(vim.api.nvim_buf_is_valid(b_render), true, "source wipe retains other navigated documents")
  vim.api.nvim_buf_set_lines(b_source, -1, -1, false, { "UPDATED B" })
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = b_source })
  vim.wait(200)
  local text = table.concat(vim.api.nvim_buf_get_lines(b_render, 0, -1, false), "\n")
  eq(text:find("UPDATED B", 1, true) ~= nil, true, "remaining document still live-updates")
end

do
  local _, _, source_win, _, split_render = open(
    "split",
    { "# Layout", "", string.rep("words ", 60) },
    { max_width = 25 }
  )
  local before = vim.api.nvim_buf_get_lines(split_render, 0, -1, false)
  vim.api.nvim_set_current_win(source_win)
  preview.show_tab { max_width = 70 }
  local tab_render = vim.api.nvim_get_current_buf()
  eq(tab_render ~= split_render, true, "tab has an independent presentation")
  eq(vim.api.nvim_buf_get_lines(split_render, 0, -1, false), before, "tab leaves split layout unchanged")
  feed "q"
  eq(vim.api.nvim_buf_is_valid(split_render), true, "closing tab preserves split render")
end

-- A scheduled viewport-cache prune can run after another tab becomes current.
do
  local dir = open("toggle", { "[B](b.md)" })
  vim.fn.writefile({ "# B" }, dir .. "/b.md")
  vim.v.errmsg = ""
  vim.cmd "normal! gg0w"
  vim.cmd "normal gf"
  vim.cmd.tabnew()
  vim.wait(50)
  eq(vim.v.errmsg, "", "history pruning uses the remembered window's tab")
end
-- Directories belong to the installed directory browser, including names
-- ending in .md. Exercise real netrw instead of an empty directory buffer.
vim.cmd.packadd "netrw"
vim.cmd.runtime "plugin/netrwPlugin.vim"
vim.api.nvim_exec_autocmds("VimEnter", { group = "FileExplorer" })
for _, mode in ipairs { "toggle", "split", "float", "tab" } do
  for _, href in ipairs { "docs/", "docs.md/" } do
    local dir, _, source_win, render_win, render = open(mode, { "[browse](" .. href .. ")" })
    vim.fn.mkdir(dir .. "/" .. href, "p")
    vim.fn.writefile({ "entry" }, dir .. "/" .. href .. "entry.txt")
    local before = #warnings
    follow(href)
    eq(vim.api.nvim_get_current_win(), source_win, mode .. " directory uses source window")
    eq(vim.bo.filetype, "netrw", mode .. " opens real directory browser")
    eq(vim.b.md_render, nil, mode .. " directory is not rendered as Markdown")
    eq(
      table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("entry.txt", 1, true) ~= nil,
      true,
      mode .. " directory listing contains its file"
    )
    eq(#warnings, before, mode .. " directory opens without warning")
    if mode == "float" or mode == "tab" then
      eq(vim.api.nvim_win_is_valid(render_win), false, mode .. " directory closes temporary preview")
    end
    feed "<C-o>"
    eq(vim.api.nvim_get_current_buf(), render, mode .. " directory native return restores render")
  end
end

vim.fn.delete(root, "rf")
print("gf_test: " .. checks .. " passed")
vim.cmd "qa!"
