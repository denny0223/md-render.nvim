-- Native heading/outline and block controls, through real rendered previews.
-- Run: nvim --headless -n -u NONE --noplugin -i NONE -l tests/native_blocks_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local preview = require "md-render.preview"
local display = require "md-render.display_utils"
require("md-render.text_size").setup { enabled = false }
vim.o.hidden, vim.o.swapfile = true, false
local checks = 0
local function eq(actual, expected, message)
  checks = checks + 1
  assert(vim.deep_equal(actual, expected), message .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
end
local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "x", false)
  vim.wait(20)
end
local function fold_at_source(content, source)
  for _, fold in ipairs(content.callout_folds) do
    if fold.start_source_line == source then return fold end
  end
  error("missing fold at source " .. source)
end
local fully_open = {
  text_scale = false,
  max_width = 30,
  fold_state = setmetatable({}, {
    __index = function()
      return false
    end,
  }),
  expand_state = setmetatable({}, {
    __index = function()
      return true
    end,
  }),
}

-- Metadata comes from accepted parser ownership, including hidden descendants,
-- code literals, joined paragraphs, list containers, and frontmatter offsets.
local nested = {
  "> [!NOTE]- Outer",
  "> body",
  "> > [!TIP]- Inner",
  "> > content",
  ">",
  "> after",
  "",
  "tail",
}
local content = preview.build_content(nested, fully_open)
eq(fold_at_source(content, 1).end_source_line, 6, "outer nested callout source boundary")
eq(fold_at_source(content, 3).end_source_line, 4, "inner nested callout source boundary")
content = preview.build_content({ "- > [!NOTE]- Fold", "  > body", "- tail" }, fully_open)
eq(content.callout_folds[1].end_source_line, 2, "list sibling ends the accepted callout container")
content = preview.build_content({ "---", "title: example", "---", unpack(nested) }, fully_open)
eq(content.callout_folds[1].source_line, 1, "frontmatter retains the existing fold state key")
eq(content.callout_folds[1].start_source_line, 4, "physical fold start includes body offset")
eq(content.callout_folds[1].end_source_line, 9, "physical fold end includes body offset")
content = preview.build_content({ "```", "> [!NOTE]- Literal", "```" }, fully_open)
eq(content.callout_folds, {}, "code literals never create fold metadata")
content = preview.build_content({ "<details><summary>Title</summary>body</details>outside" }, fully_open)
eq(content.callout_folds[1].end_source_line, 1, "inline details source range")
eq(
  content.lines[content.callout_folds[1].end_line + 2]:find("outside", 1, true) ~= nil,
  true,
  "details end excludes suffix"
)

local buf = vim.api.nvim_create_buf(false, true)
local current = {
  lines = { "First", "body", "Second", "body", "Third" },
  heading_anchors = { third = 4, first = 0, alias = 0, second = 2 },
  heading_starts = { [0] = true, [2] = true, [4] = true },
  source_line_map = { 1, 2, 3, 4, 5 },
}
vim.api.nvim_buf_set_lines(buf, 0, -1, false, current.lines)
local win = vim.api.nvim_open_win(buf, true, { relative = "editor", row = 1, col = 1, width = 40, height = 10 })
local ns = vim.api.nvim_create_namespace "md-render-native-blocks-test"
local opts = {
  close_keys = {},
  get_content = function()
    return current
  end,
}
local custom = function() end
vim.keymap.set("n", "zR", custom, { buffer = buf })
vim.keymap.set("x", "[[", custom, { buffer = buf })
local rebind = display.setup_float_keymaps(buf, ns, win, current, nil, opts)
eq(vim.fn.maparg("zR", "n", false, true).callback, custom, "initial bind preserves an existing block mapping")
eq(vim.fn.maparg("[[", "x", false, true).callback, custom, "initial bind preserves an existing Visual mapping")
vim.cmd.clearjumps()
vim.api.nvim_win_set_cursor(win, { 2, 2 })
feed "]]"
eq(vim.api.nvim_win_get_cursor(win), { 3, 0 }, "next heading")
feed "<C-o>"
eq(vim.api.nvim_win_get_cursor(win), { 2, 2 }, "heading jump restores native byte position")
feed "<C-i>"
eq(vim.api.nvim_win_get_cursor(win), { 3, 0 }, "native forward returns to heading")
vim.api.nvim_win_set_cursor(win, { 1, 0 })
feed "2]]"
eq(vim.api.nvim_win_get_cursor(win), { 5, 0 }, "heading count skips aliases at the same rendered row")
feed "2[["
eq(vim.api.nvim_win_get_cursor(win), { 1, 0 }, "backward heading count")
feed "9]]"
eq(vim.api.nvim_win_get_cursor(win), { 5, 0 }, "heading count clamps to last available heading")
local jumps = vim.fn.getjumplist()
feed "]]"
eq(vim.api.nvim_win_get_cursor(win), { 5, 0 }, "heading motion does not wrap")
eq(vim.fn.getjumplist(), jumps, "heading boundary does not add a jump")
vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_col = 4, url = "#second" })
vim.api.nvim_win_set_cursor(win, { 2, 1 })
feed "<CR>"
eq(vim.api.nvim_win_get_cursor(win), { 3, 0 }, "Enter activates an internal heading link")
feed "<C-o>"
eq(vim.api.nvim_win_get_cursor(win), { 2, 1 }, "Enter anchor activation uses native jump history")

vim.fn.setloclist(win, {}, " ", { title = "Existing list", items = { { bufnr = buf, lnum = 2, text = "old" } } })
vim.api.nvim_win_set_cursor(win, { 2, 2 })
feed "gO"
local outline_win = vim.api.nvim_get_current_win()
eq(vim.fn.getloclist(win, { title = 1 }).title, "Markdown headings", "outline has a native list title")
local items = vim.fn.getloclist(win)
eq(
  vim.tbl_map(function(item)
    return { item.bufnr, item.lnum, item.text }
  end, items),
  {
    { buf, 1, "First" },
    { buf, 3, "Second" },
    { buf, 5, "Third" },
  },
  "outline has sorted unique rendered headings"
)
feed "2j<CR>"
eq(vim.api.nvim_get_current_win(), win, "outline selection returns to its preview window")
eq(vim.api.nvim_win_get_cursor(win), { 5, 0 }, "outline native Enter selects a heading")
feed "<C-o>"
eq(vim.api.nvim_win_get_cursor(win), { 2, 2 }, "outline selection records native jump history")
vim.cmd.lolder()
eq(vim.fn.getloclist(win, { title = 1 }).title, "Existing list", "outline preserves the previous location list")
vim.api.nvim_win_close(outline_win, true)

vim.keymap.set("n", "[[", custom, { buffer = buf })
vim.keymap.del("n", "]]", { buffer = buf })
vim.keymap.del("x", "]]", { buffer = buf })
current.heading_anchors = { changed = 4 }
current.heading_starts = { [4] = true }
rebind(win, nil, opts)
eq(vim.fn.maparg("[[", "n", false, true).callback, custom, "rebind preserves custom heading map")
eq(vim.fn.maparg("]]", "n"), "", "rebind preserves deleted heading map")
eq(vim.fn.maparg("[[", "x", false, true).callback, custom, "rebind preserves a custom Visual mapping")
eq(vim.fn.maparg("]]", "x"), "", "rebind preserves a deleted Visual mapping")
vim.api.nvim_win_set_cursor(win, { 1, 0 })
feed "gO"
eq(vim.fn.getloclist(win)[1].lnum, 5, "outline reads current rebuilt metadata")
vim.cmd.lclose()
vim.api.nvim_win_close(win, true)
vim.api.nvim_buf_delete(buf, { force = true })

local document = {
  "# Start",
  "",
  "<details>",
  "<summary>Outer</summary>",
  "",
  "> [!NOTE]- Inner",
  "> ```lua",
  "> " .. string.rep("long code ", 20),
  "> ```",
  "",
  "</details>",
  "",
  "> [!TIP]- Outside",
  "> outside body",
  "",
  "# End",
  "",
  "## !!!",
  "",
  "## 😀",
  "",
  "## <em>?!</em>",
  "",
  "## A long heading that wraps onto several rendered rows",
}
for _, mode in ipairs { "toggle", "split", "float", "tab", "pager" } do
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then vim.api.nvim_win_close(w, true) end
  end
  vim.cmd "silent! tabonly!"
  vim.cmd "silent! only!"
  local source = vim.api.nvim_create_buf(true, false)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, document)
  vim.api.nvim_win_set_buf(0, source)
  if mode == "float" then
    preview.show { max_width = 30 }
  elseif mode == "tab" then
    preview.show_tab { max_width = 30 }
  elseif mode == "pager" then
    preview.show_pager { max_width = 30 }
  elseif mode == "split" then
    preview.split { max_width = 30 }
    vim.api.nvim_set_current_win(preview._toggle_sessions[source].win)
  else
    preview.toggle { max_width = 30 }
  end
  local render = vim.api.nvim_get_current_buf()
  local render_win = vim.api.nvim_get_current_win()
  local session = assert(preview._sessions[render])
  local function cursor_fold(row)
    vim.api.nvim_win_set_cursor(0, { fold_at_source(session.content, row).header_line + 1, 0 })
  end
  vim.cmd.clearjumps()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  feed "2zj"
  eq(
    vim.api.nvim_win_get_cursor(0)[1],
    fold_at_source(session.content, 13).header_line + 1,
    mode .. " fold motion count selects visible headers"
  )
  feed "<C-o>"
  eq(vim.api.nvim_win_get_cursor(0), { 1, 0 }, mode .. " fold motion uses native jump history")
  cursor_fold(13)
  feed "9zk"
  eq(
    vim.api.nvim_win_get_cursor(0)[1],
    fold_at_source(session.content, 3).header_line + 1,
    mode .. " backward fold motion clamps to first visible header"
  )
  cursor_fold(3)
  feed "2zo"
  eq(fold_at_source(session.content, 3).collapsed, false, mode .. " zo opens the current block")
  eq(fold_at_source(session.content, 6).collapsed, true, mode .. " zo leaves hidden child collapsed")
  feed "zO"
  eq(fold_at_source(session.content, 6).collapsed, true, mode .. " zO on an open parent leaves children unchanged")
  cursor_fold(6)
  feed "zO"
  eq(fold_at_source(session.content, 6).collapsed, false, mode .. " zO opens hidden child fold")
  eq(session.content.expandable_regions[1].expanded, true, mode .. " zO expands the hidden child code")
  eq(fold_at_source(session.content, 13).collapsed, true, mode .. " zO preserves sibling fold")
  cursor_fold(3)
  feed "zA"
  eq(fold_at_source(session.content, 3).collapsed, true, mode .. " zA closes the current subtree")
  feed "zA"
  eq(fold_at_source(session.content, 6).collapsed, false, mode .. " zA reopens hidden descendants")

  -- Existing native list marks follow render hunks when a fold changes rows.
  cursor_fold(3)
  feed "gO"
  local list_win = vim.api.nvim_get_current_win()
  local outline_items = vim.fn.getloclist(render_win)
  eq(#outline_items, 6, mode .. " outline includes empty-slug headings and one entry per wrapped heading")
  local outline_end = 2
  vim.api.nvim_set_current_win(render_win)
  feed "zC"
  eq(
    vim.fn.getloclist(render_win)[outline_end].lnum,
    session.content.heading_anchors["end"] + 1,
    mode .. " fold redraw adjusts native outline marks"
  )
  vim.api.nvim_set_current_win(list_win)
  vim.api.nvim_win_set_cursor(list_win, { outline_end, 0 })
  feed "<CR>"
  eq(
    vim.api.nvim_win_get_cursor(render_win)[1],
    session.content.heading_anchors["end"] + 1,
    mode .. " outline jumps to its heading after a fold redraw"
  )
  vim.cmd.lclose()
  cursor_fold(3)
  feed "zO"
  cursor_fold(3)
  feed "zC"
  eq(fold_at_source(session.content, 3).collapsed, true, mode .. " zC collapses outer block")
  feed "zo"
  eq(fold_at_source(session.content, 6).collapsed, false, mode .. " zC preserves hidden descendant state")
  cursor_fold(6)
  feed "zC"
  eq(fold_at_source(session.content, 3).collapsed, true, mode .. " zC on a child closes its containing parent")
  feed "zo"
  eq(fold_at_source(session.content, 6).collapsed, true, mode .. " zC closes the selected child in the ancestor chain")
  cursor_fold(6)
  feed "zo"
  eq(session.content.expandable_regions[1].expanded, true, mode .. " zC leaves hidden child code state unchanged")
  local region = session.content.expandable_regions[1]
  vim.api.nvim_win_set_cursor(0, { region.start_line + 1, 0 })
  feed "zo"
  eq(session.content.expandable_regions[1].expanded, true, mode .. " zo opens the current code region")
  feed "zo"
  eq(session.content.expandable_regions[1].expanded, true, mode .. " repeated zo remains open")
  feed "zc"
  eq(session.content.expandable_regions[1].expanded, false, mode .. " zc closes the current code region")
  feed "zM"
  eq(fold_at_source(session.content, 3).collapsed, true, mode .. " zM closes all folds")
  eq(fold_at_source(session.content, 13).collapsed, true, mode .. " zM closes sibling folds")
  feed "zR"
  vim.api.nvim_win_set_cursor(0, { session.content.heading_anchors["end"] + 1, 0 })
  feed "zk"
  eq(
    vim.api.nvim_win_get_cursor(0)[1],
    fold_at_source(session.content, 13).end_line + 1,
    mode .. " zk goes to the preceding open fold end"
  )
  eq(fold_at_source(session.content, 6).collapsed, false, mode .. " zR opens initially hidden folds")
  eq(fold_at_source(session.content, 13).collapsed, false, mode .. " zR opens all siblings")
  eq(session.content.expandable_regions[1].expanded, true, mode .. " zR expands initially hidden code")
  region = session.content.expandable_regions[1]
  vim.api.nvim_win_set_cursor(0, { region.start_line + 1, 0 })
  feed "2zc"
  eq(fold_at_source(session.content, 6).collapsed, true, mode .. " close count includes the containing callout")
  eq(fold_at_source(session.content, 3).collapsed, false, mode .. " close count stops before the next ancestor")
  eq(session.expand_state[region.block_id], false, mode .. " close count closes the code region first")
  eq(
    vim.api.nvim_win_get_cursor(0)[1],
    fold_at_source(session.content, 6).header_line + 1,
    mode .. " closing body returns to its visible fold header"
  )
  feed "zc"
  eq(fold_at_source(session.content, 3).collapsed, true, mode .. " another close selects the open ancestor")
  eq(
    vim.api.nvim_win_get_cursor(0)[1],
    fold_at_source(session.content, 3).header_line + 1,
    mode .. " ancestor close keeps its visible header under the cursor"
  )
  feed "zR"
  local body_row
  for row, line in ipairs(session.content.lines) do
    if line:find("outside body", 1, true) then body_row = row end
  end
  vim.api.nvim_win_set_cursor(0, { assert(body_row), 0 })
  feed "za"
  eq(fold_at_source(session.content, 13).collapsed, true, mode .. " za works inside a callout body")
  local visual_start = fold_at_source(session.content, 13).header_line + 1
  vim.api.nvim_win_set_cursor(0, { visual_start, 0 })
  feed "v]]"
  eq(vim.fn.mode(), "v", mode .. " heading motion preserves Visual mode")
  eq(vim.fn.getpos("v")[2], visual_start, mode .. " heading motion preserves the Visual anchor")
  eq(
    vim.api.nvim_win_get_cursor(0)[1],
    session.content.heading_anchors["end"] + 1,
    mode .. " Visual heading motion stops at the next heading"
  )
  feed "y"
  eq(vim.api.nvim_buf_get_mark(render, "<")[1], visual_start, mode .. " heading selection retains native start mark")
  eq(
    vim.api.nvim_buf_get_mark(render, ">")[1],
    session.content.heading_anchors["end"] + 1,
    mode .. " heading selection retains native end mark"
  )
  local headings = vim.tbl_keys(session.content.heading_starts)
  table.sort(headings)
  vim.api.nvim_win_set_cursor(0, { session.content.heading_anchors["end"] + 1, 0 })
  feed "]]"
  eq(vim.api.nvim_win_get_cursor(0)[1], headings[3] + 1, mode .. " motion includes a punctuation-only heading")
  feed "2]]"
  eq(vim.api.nvim_win_get_cursor(0)[1], headings[5] + 1, mode .. " heading count includes empty-slug HTML text")
  feed "v[["
  eq(vim.fn.mode(), "v", mode .. " backward heading motion preserves Visual mode")
  eq(vim.api.nvim_win_get_cursor(0)[1], headings[4] + 1, mode .. " Visual backward motion includes an emoji heading")
  feed "<Esc>"
  eq(vim.api.nvim_buf_get_lines(source, 0, -1, false), document, mode .. " block operations preserve source text")
  eq(vim.bo[render].modifiable, false, mode .. " render buffer stays read-only")
end

-- Compare recursive commands against Neovim's manual folds, including sibling
-- state that must survive a closed parent. Open each parent only to read it.
local chain = {
  "> [!NOTE]+ Outer",
  "> body",
  "> > [!TIP]+ First",
  "> > first body",
  ">",
  "> > [!WARNING]+ Second",
  "> > second body",
  ">",
  "> after",
  "",
  "> [!NOTE]+ Outside",
  "> outside body",
  "",
  "tail",
}
local ranges = { { 1, 9 }, { 3, 4 }, { 6, 7 }, { 11, 12 } }
local function native_states(key, state, source_row)
  local native_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(native_buf, 0, -1, false, chain)
  local native_win =
    vim.api.nvim_open_win(native_buf, true, { relative = "editor", row = 1, col = 1, width = 40, height = 15 })
  vim.wo.foldmethod, vim.wo.foldminlines = "manual", 0
  for _, range in ipairs(ranges) do
    vim.cmd "normal! zR"
    vim.cmd(range[1] .. "," .. range[2] .. "fold")
  end
  vim.cmd("normal! " .. (state == "open" and "zR" or "zM"))
  if state == "outer_open" then
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd "normal! zo"
  end
  vim.api.nvim_win_set_cursor(0, { source_row, 0 })
  vim.cmd("normal! " .. key)
  local states = {}
  for _, range in ipairs(ranges) do
    states[range[1]] = vim.fn.foldclosed(range[1]) ~= -1
    if states[range[1]] then
      vim.api.nvim_win_set_cursor(0, { range[1], 0 })
      vim.cmd "normal! zo"
    end
  end
  vim.api.nvim_win_close(native_win, true)
  vim.api.nvim_buf_delete(native_buf, { force = true })
  return states
end
for _, case in ipairs {
  { "zO", "open", 1 },
  { "zO", "open", 2 },
  { "zO", "outer_open", 2 },
  { "zO", "outer_open", 3 },
  { "zO", "closed", 1 },
  { "zC", "open", 2 },
  { "zC", "open", 3 },
  { "zC", "open", 4 },
  { "zC", "open", 7 },
  { "zA", "open", 3 },
  { "zA", "open", 4 },
  { "zA", "outer_open", 3 },
} do
  local expected = native_states(unpack(case))
  local source = vim.api.nvim_create_buf(true, false)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, chain)
  vim.api.nvim_win_set_buf(0, source)
  preview.toggle { max_width = 80 }
  local session = preview._sessions[vim.api.nvim_get_current_buf()]
  feed(case[2] == "open" and "zR" or "zM")
  if case[2] == "outer_open" then
    vim.api.nvim_win_set_cursor(0, { fold_at_source(session.content, 1).header_line + 1, 0 })
    feed "zo"
  end
  local row
  for index, owner in ipairs(session.content.source_line_map) do
    if owner == case[3] then
      row = index
      break
    end
  end
  vim.api.nvim_win_set_cursor(0, { assert(row), 0 })
  feed(case[1])
  local actual = {}
  for _, range in ipairs(ranges) do
    actual[range[1]] = session.fold_state[range[1]]
  end
  eq(actual, expected, table.concat(case, " ") .. " matches native recursive folding")
end

local footnote_source = vim.api.nvim_create_buf(true, false)
vim.bo[footnote_source].filetype = "markdown"
vim.api.nvim_buf_set_lines(
  footnote_source,
  0,
  -1,
  false,
  { "[^f]: outside note", "", "> [!NOTE]+ Outer", "> body[^f]" }
)
vim.api.nvim_win_set_buf(0, footnote_source)
preview.toggle { max_width = 80 }
local footnote_session = preview._sessions[vim.api.nvim_get_current_buf()]
local note = footnote_session.content.footnote_anchors["footnote-def-f"]
local body_end = footnote_session.content.callout_folds[1].end_line
eq(body_end < note - 1, true, "callout rendered boundary excludes the synthetic footnote separator")
vim.api.nvim_win_set_cursor(0, { note, 0 })
feed "za"
eq(footnote_session.content.callout_folds[1].collapsed, false, "footnote separator is outside the callout")
feed "zk"
eq(vim.api.nvim_win_get_cursor(0)[1], body_end + 1, "previous fold end excludes synthetic footer rows")

for _, key in ipairs { "zO", "zA" } do
  local source = vim.api.nvim_create_buf(true, false)
  vim.bo[source].filetype = "markdown"
  vim.api.nvim_buf_set_lines(source, 0, -1, false, {
    "> [!NOTE]- First",
    "> first body",
    "> [!TIP]- Second",
    "> second body",
  })
  vim.api.nvim_win_set_buf(0, source)
  preview.toggle { max_width = 80 }
  local session = preview._sessions[vim.api.nvim_get_current_buf()]
  feed "zM"
  vim.api.nvim_win_set_cursor(0, { session.content.callout_folds[1].header_line + 1, 0 })
  feed(key)
  eq(fold_at_source(session.content, 1).collapsed, false, key .. " opens the first contiguous callout")
  eq(fold_at_source(session.content, 3).collapsed, true, key .. " preserves the same-depth following callout")
end

print("native_blocks_test: " .. checks .. " checks passed")
