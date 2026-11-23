-- Let the child editor deliver CursorMoved and Enter through its normal input loop.
for _, early_mapping in ipairs { true, false } do
  local child = vim.fn.jobstart(
    { vim.v.progpath, "--embed", "--headless", "-n", "-u", "NONE", "--noplugin", "-i", "NONE" },
    { rpc = true }
  )
  local function lua(code, ...)
    return vim.rpcrequest(child, "nvim_exec_lua", code, { ... })
  end
  local function expect(condition, message)
    assert(
      vim.wait(1000, function()
        return lua(condition)
      end, 5),
      message
    )
  end
  local function press(key)
    vim.rpcrequest(child, "nvim_input", key)
  end
  local ok, err = pcall(function()
    local row = lua(
      [[
      vim.opt.rtp:prepend(vim.fn.getcwd())
      local image = require "md-render.image"
      image.setup { backend = "snacks" }
      image._set_kitty_supported(true)
      image._test_cell_size = { cell_w = 9, cell_h = 18 }
      require("md-render.display_utils").setup_images = function() end
      require("md-render.async").run = function() end
      local executable = vim.fn.executable
      vim.fn.executable = function(name) return name == "magick" and 1 or executable(name) end

      _G.calls = 0
      function _G.custom_enter() calls = calls + 1 end
      if ... then
        vim.api.nvim_create_autocmd("BufEnter", { callback = function(ev)
          if vim.b[ev.buf].md_render then
            vim.keymap.set("n", "<CR>", custom_enter, { buffer = ev.buf })
            return true
          end
        end })
      end
      vim.bo.filetype = "markdown"
      local fixture = vim.fn.getcwd() .. "/tests/fixtures/test_4x4.png"
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "# Document", "", "Text", "", "![Picture](" .. fixture .. ")" })
      local preview = require "md-render.preview"
      preview.show_tab()
      _G.session = assert(preview._sessions[vim.api.nvim_get_current_buf()])
      session.image_state = { objects = { { ready = function() return true end } } }
      vim.bo.filetype = "markdown"
      local ns = vim.api.nvim_create_namespace "md_render_image_hint"
      function _G.hints() return #vim.api.nvim_buf_get_extmarks(session.buf, ns, 0, -1, {}) end
      vim.schedule(function() _G.settled = true end)
      return session.content.image_placements[1].line
    ]],
      early_mapping
    )
    expect("return settled and hints() == 0", "preview setup must settle before moving to the image")
    press(row .. "G")
    if not early_mapping then
      expect("return hints() == 1", "cursor movement in a renamed preview must show Enter")
      press "<CR>"
      expect("return vim.b.md_render_image_view", "the advertised Enter must open the image")
      press "q"
      expect("return vim.api.nvim_get_current_buf() == session.buf", "return to the preview")
      lua [[vim.keymap.set("n", "<CR>", custom_enter, { buffer = session.buf })]]
    end
    lua [[session:rebuild(); session:install_float_keymaps(nil)]]
    press "gg"
    expect("return vim.fn.line('.') == 1 and hints() == 0", "moving away must clear the hint")
    press(row .. "G")
    press "<CR>"
    expect("return calls == 1", "Enter must invoke the custom mapping across a rebuild and rebind")
    assert(
      lua "return vim.api.nvim_get_current_buf() == session.buf and hints() == 0",
      "custom Enter showed an image hint"
    )
  end)
  vim.fn.jobstop(child)
  assert(ok, err)
end
print "Image hints: preview identity and early or late buffer-local Enter mappings OK"
