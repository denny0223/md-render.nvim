-- Hidden source edits must pick up parsers, aliases and highlight queries loaded after the preview opened.
local child = vim.fn.jobstart(
  { vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-n", "-i", "NONE" },
  { rpc = true }
)
local function lua(code, ...)
  return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
end
local ok, err = pcall(function()
  lua [[
    vim.opt.rtp:prepend(vim.fn.getcwd())
    vim.o.hidden, vim.o.swapfile = true, false
    vim.bo.filetype = "markdown"
    local api, ts = vim.api, vim.treesitter
    local preview = require "md-render.preview"
    source = api.nvim_get_current_buf()
    api.nvim_buf_set_lines(source, 0, -1, false, {
      "Prose", "", "```example_alias", "local word = 42", "```", "", "```example_parser", "local word = 42", "```",
    })
    ts.query.set("lua", "highlights", "(identifier) @variable")
    ts.query.set("example_parser", "highlights", "(identifier) @constant")
    preview.toggle()
    session = assert(preview._toggle_sessions[source])
    preview.toggle()
    api.nvim_win_set_cursor(0, {1,0})
    changes, builds = 0, 0
    local rebuild = session.rebuild
    session.rebuild = function(self, ...) builds = builds + 1; return rebuild(self, ...) end
    api.nvim_create_autocmd("TextChangedI", {buffer=source, callback=function() changes = changes + 1 end})
    function groups()
      local found = {}
      for _, mark in ipairs(api.nvim_buf_get_extmarks(session.buf, session.ns, 0, -1, {details=true})) do
        if mark[4].priority == 4200 then found[#found+1] = mark[4].hl_group end
      end
      return found
    end
  ]]
  local observations = {}
  local function edit(key)
    local before = lua "return changes"
    vim.rpcrequest(child, "nvim_input", key)
    assert(
      vim.wait(2000, function()
        return lua "return changes" > before
      end),
      "missing Insert change"
    )
    observations[#observations + 1] = lua "return {builds, groups()}"
  end
  edit "A1"
  lua [[vim.treesitter.language.register("lua", "example_alias")]]
  edit "2"
  lua [[vim.treesitter.query.set("lua", "highlights", "(number) @number")]]
  edit "3"
  lua [[
    local path = assert(vim.api.nvim_get_runtime_file("parser/lua.*", false)[1])
    assert(vim.treesitter.language.add("example_parser", {path=path, symbol_name="lua"}))
  ]]
  edit "4"
  edit "5"
  lua [[vim.treesitter.query.get("lua", "highlights").query:disable_capture("number")]]
  edit "6"
  local both = { "@number.lua", "@constant.example_parser" }
  local expected = {
    { 0, {} },
    { 0, { "@variable.lua" } },
    { 0, { "@number.lua" } },
    { 0, both },
    { 0, both },
    { 0, { "@constant.example_parser" } },
  }
  assert(vim.deep_equal(observations, expected), vim.inspect(observations))
end)
vim.fn.jobstop(child)
assert(ok, err)
print "hidden_treesitter_test: hidden previews refresh syntax captures without rebuilding Markdown"
