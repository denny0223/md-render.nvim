-- Use real input: typeahead can suppress TextChangedI between the last edit and a jump.
for _, case in ipairs {
  "paragraph",
  "layout inputs",
  "locale and icons",
  "tab width",
  "theme jump",
  "snapshot",
  "escape",
  "cancel",
  "temporary normal",
  "replace",
  "API jump",
  "mapped mark",
  "Lua mark",
  "callback mark",
  "API mark",
  "background mark",
} do
  local child = vim.fn.jobstart(
    { vim.v.progpath, "--embed", "--headless", "-n", "-u", "NONE", "--noplugin", "-i", "NONE" },
    { rpc = true }
  )
  local function lua(code, ...)
    return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
  end
  local function type_keys(keys)
    vim.rpcrequest(child, "nvim_input", keys)
  end
  local ok, err = pcall(function()
    lua(
      [=[
      case = ...
      vim.opt.rtp:prepend(vim.fn.getcwd())
      require("md-render.text_size").setup { enabled = false }
      vim.o.hidden, vim.o.swapfile = true, false
      local api = vim.api
      local preview = require "md-render.preview"
      if case == "layout inputs" then
        image_path = vim.fn.tempname() .. ".png"
        rules = {{key_prefix="ABC", url_template="https://old.test/<num>"}}
        require("md-render.image")._set_kitty_supported(false)
      elseif case == "tab width" then
        vim.opt.list, vim.opt.listchars = true, "eol:$"
      elseif case == "locale and icons" then
        vim.cmd.language("ctype C")
        vim.o.casemap="internal,keepascii"
      end
      local function prepare(source, mark)
        api.nvim_set_current_buf(source)
        vim.bo.filetype = "markdown"
        local body = case == "paragraph" and (string.rep("word ", 16) .. "some `code` here") or "body"
        local lines = {"# Prefix", "", body, "", "# Target", "", "bottom"}
        if case == "layout inputs" then
          lines = {"# Prefix", "", body, "", "See ABC123 and https://example.org/¡", "",
            "![fixture](" .. image_path .. ")", "", "![empty]()", "", "# Target"}
        elseif case == "tab width" then
          lines = {"# Prefix", "", body, "", "Start `aaa\tbbbb` end", "", "# Target"}
        elseif case == "theme jump" then
          lines[3] = string.rep("· ", 90)
        elseif case == "locale and icons" then
          lines = {"# Prefix", "", body, "", "# Élan", "", "[go](#Élan)", "", "See ![[probe.png]] here", "",
            "```lua:example.qri", "code", "```", "", "# Target"}
        end
        api.nvim_buf_set_lines(source, 0, -1, false, lines)
        preview.toggle({autolinks=rules, max_width=case == "tab width" and 17 or nil})
        local session = assert(preview._toggle_sessions[source])
        local target = session.content.heading_anchors.target + 1
        api.nvim_win_set_cursor(0, {target, 0})
        if mark then vim.cmd("normal! m" .. mark) end
        vim.cmd.clearjumps()
        vim.cmd("normal! m'")
        preview.toggle()
        api.nvim_win_set_cursor(0, {1, 0})
        return session, target
      end
      local source, other = api.nvim_get_current_buf(), api.nvim_create_buf(true, false)
      local background = prepare(other, case == "background mark" and "B")
      local session, old_target = prepare(source, case:find("mark") and case ~= "background mark" and "A")
      destination = case == "background mark" and background or session
      initial_row = old_target
      local mark = case == "background mark" and "B" or "A"
      vim.keymap.set("i", "<F7>", "<Left>", {buffer=source})
      vim.keymap.set("i", "<F8>", "<Cmd>'" .. mark .. "<CR>", {buffer=source})
      vim.keymap.set("i", "<F9>", function() vim.cmd("'A") end, {buffer=source})
      if case == "paragraph" or case == "layout inputs" or case == "tab width" or case == "locale and icons" then
        api.nvim_win_set_cursor(0, {3, 0})
      end
      renders = session
      builds, events = 0, 0
      local rebuild = session.rebuild
      session.rebuild = function(self, ...)
        builds = builds + 1
        return rebuild(self, ...)
      end
      vim.api.nvim_create_autocmd("TextChangedI", {buffer=source, callback=function()
        events = events + 1
        if events == 3 and case ~= "paragraph" and case ~= "layout inputs" and case ~= "locale and icons" then
          api.nvim_buf_call(other, function()
            api.nvim_buf_set_lines(other, 0, 0, false, {"# New", ""})
          end)
          if case == "callback mark" then
            vim.cmd("'A")
            captured = {vim.fn.line("."), vim.fn.getline(".")}
          end
        end
      end})
    ]=],
      case
    )
    if case == "theme jump" then
      lua [[vim.o.ambiwidth="double"; vim.cmd.colorscheme("default")]]
      type_keys "<C-o>"
      assert(vim.wait(2000, function()
        return lua "return vim.api.nvim_get_current_buf()==renders.buf"
      end))
      assert(lua [[return vim.fn.getline("."):find("Target") ~= nil]], "BufEnter invalidated the native jump row")
      return
    end
    if case == "layout inputs" or case == "tab width" or case == "locale and icons" then
      local function edit(keys)
        local before = lua "return events"
        type_keys(keys)
        assert(vim.wait(2000, function()
          return lua "return events" > before
        end))
        lua [[
          local raw=vim.api.nvim_buf_get_lines(renders.source_bufnr, 0, -1, false)
          local fresh=vim.api.nvim_buf_call(renders.buf, function()
            return require("md-render.preview").build_content(raw, renders.opts)
          end)
          assert(vim.deep_equal(renders.content.link_metadata, fresh.link_metadata), "stale links")
          assert(vim.deep_equal(renders.content.heading_anchors, fresh.heading_anchors), "stale heading anchors")
          assert(vim.deep_equal(renders.content.highlights, fresh.highlights), "stale highlight groups")
          assert(vim.deep_equal(vim.api.nvim_buf_get_lines(renders.buf,0,-1,false), fresh.lines), "stale media layout")
          local jump=vim.fn.getjumplist()[1][1]
          assert(jump.bufnr==renders.buf and jump.lnum==fresh.heading_anchors.target+1, "stale jump target")
        ]]
      end
      edit "A."
      if case == "tab width" then return end
      if case == "locale and icons" then
        lua [[vim.o.casemap="keepascii"]]
        edit "a"
        lua [[
          local target=require("md-render.links").anchor_row("#Élan",renders.content)
          assert(target and vim.b[renders.buf].md_render_anchors["Élan"]==target)
        ]]
        local utf8 = lua [[
          for _, name in ipairs({"C.UTF-8","C.utf8","en_US.UTF-8"}) do
            if pcall(vim.cmd.language,"ctype "..name) and vim.fn.tolower("É")=="é" then return true end
          end
        ]]
        if utf8 then edit "b" end
        lua [[
          icon_style="Special"
          package.loaded["nvim-web-devicons"]={get_icon=function(name)
            if name=="example.qri" then return "◆", icon_style end
            if name=="probe.png" then return embed_icon end
          end}
        ]]
        edit "c"
        lua [[icon_style="Identifier"]]
        edit "d"
        lua [[embed_icon="LongSymbol"]]
        edit "e"
        return
      end
      assert(lua "return builds" == 0)
      lua [[rules[1].url_template="https://new.test/<num>"]]
      edit "a"
      lua [[vim.bo[renders.buf].iskeyword=vim.bo[renders.buf].iskeyword .. ",161"]]
      edit "b"
      lua [[vim.env.TERM_PROGRAM="kitty"; require("md-render.image").reset_cache()]]
      edit "c"
      assert(lua "return builds == 3 and #renders.content.image_placements == 0")
      lua [[assert(vim.uv.fs_copyfile("tests/fixtures/test_4x4.png", image_path))]]
      edit "d"
      assert(lua "return #renders.content.image_placements == 1")
      lua [[require("md-render.image")._set_kitty_supported(false)]]
      edit "e"
      assert(lua "return #renders.content.image_placements == 0")
      return
    end
    if case == "paragraph" then
      for i, input in ipairs { "A words", " 字", "<Tab>", "next", "!" } do
        type_keys(input)
        assert(vim.wait(2000, function()
          return lua "return events" >= i
        end))
        lua [[
          local api=vim.api
          local raw=api.nvim_buf_get_lines(renders.source_bufnr, 0, -1, false)
          local expected=require("md-render.preview").build_content(raw, renders.opts)
          local expected_buf=api.nvim_create_buf(false,true)
          local ns=api.nvim_create_namespace("hidden_edit_expected")
          require("md-render.display_utils").apply_content_to_buffer(expected_buf,ns,expected)
          local function marks(buf, namespace)
            local records=api.nvim_buf_get_extmarks(buf,namespace,0,-1,{details=true})
            for _, record in ipairs(records) do record[1],record[4].ns_id=0,nil end
            return records
          end
          assert(vim.deep_equal(marks(expected_buf,ns),marks(renders.buf,renders.ns)), "styled paragraph extmarks differ")
          api.nvim_buf_delete(expected_buf,{force=true})
          assert(vim.deep_equal(api.nvim_buf_get_lines(renders.buf, 0, -1, false), expected.lines))
          assert(vim.deep_equal(renders.source_lines, raw) and builds == 0, "plain edits should update only their paragraph")
        ]]
      end
      local col = lua "return vim.fn.col('.')"
      type_keys "<F7>"
      assert(vim.wait(2000, function()
        return lua "return vim.fn.col('.')" == col - 1
      end))
      assert(lua "return builds" == 0, "cursor mapping triggered a rebuild")
      lua [[vim.o.ambiwidth="double"]]
      type_keys "?"
      assert(
        vim.wait(2000, function()
          return lua "return builds" == 1
        end),
        "display settings must invalidate local layout"
      )
      type_keys " **bold**"
      assert(
        vim.wait(2000, function()
          return lua "return builds" >= 2
        end),
        "new Markdown styles require a full rebuild"
      )
      return
    end

    for i, input in ipairs { case == "replace" and "R# P" or "A P", "r", "<CR># New" } do
      type_keys(input)
      assert(
        vim.wait(2000, function()
          return lua "return events" >= i
        end),
        "missing Insert change"
      )
    end
    if case == "snapshot" then
      lua [[
        local stored=vim.fn.getjumplist()[1][1]
        assert(stored.bufnr==destination.buf)
        vim.api.nvim_set_current_buf(stored.bufnr)
        vim.api.nvim_win_set_cursor(0,{stored.lnum,stored.col})
        captured = {vim.fn.line("."), vim.fn.getline(".")}
      ]]
    elseif case == "API jump" then
      lua [[vim.cmd.normal { args = { vim.keycode("<C-o>") }, bang = true }]]
    elseif case == "API mark" then
      lua [[vim.cmd("'A"); captured = {vim.fn.line("."), vim.fn.getline(".")}]]
    elseif case == "Lua mark" then
      type_keys "<CR># Last<F9>"
    elseif case == "mapped mark" or case == "background mark" then
      type_keys "<CR># Last<F8>"
    elseif case == "temporary normal" then
      type_keys "<CR># Last<C-o><C-o>"
    elseif case == "cancel" then
      type_keys "<C-c>"
      assert(vim.wait(2000, function()
        return lua "return vim.fn.mode()" == "n"
      end))
      type_keys "<C-o>"
    elseif case ~= "callback mark" then
      type_keys "<CR># Last<Esc><C-o>"
    end
    assert(
      vim.wait(2000, function()
        return lua "return captured ~= nil or vim.api.nvim_get_current_buf() == destination.buf"
      end),
      "no jump"
    )
    local result = lua [[
      local target = destination.content.heading_anchors.target + 1
      local position = captured or {vim.fn.line("."), vim.fn.getline(".")}
      return { target, initial_row, position[1], position[2], builds }
    ]]
    assert(result[1] ~= result[2] and result[1] == result[3] and result[4]:find "Target", vim.inspect(result))
  end)
  vim.fn.jobstop(child)
  assert(ok, case .. ": " .. tostring(err))
end
print "hidden_preview_edit_test: local paragraph edits preserve native jump and mark targets"
