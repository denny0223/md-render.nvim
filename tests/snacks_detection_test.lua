-- Existing tmux panes may have no terminal-specific environment variables.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
local image = require "md-render.image"
vim.env.TERM_PROGRAM, vim.env.TERM = "tmux", "tmux-256color"
vim.env.KITTY_WINDOW_ID, vim.env.GHOSTTY_RESOURCES_DIR, vim.env.WEZTERM_EXECUTABLE = nil, nil, nil
vim.env.TMUX, vim.env.TMUX_PANE = "/tmp/test-tmux,1,0", "%95"
local client, queries = "xterm-kitty", 0
vim.system = function(cmd)
  assert(vim.deep_equal(cmd, { "tmux", "display-message", "-p", "-t", "%95", "#{client_termname}" }))
  queries = queries + 1
  return {
    wait = function()
      return { code = 0, stdout = client .. "\n" }
    end,
  }
end
local terminal = {
  env = function()
    return { placeholders = vim.env.SNACKS_KITTY == "1" }
  end,
}
assert(not image.supports_kitty() and queries == 0, "the native backend must not use the Snacks tmux workaround")
_G.Snacks = { image = { terminal = terminal } }

vim.env.SNACKS_KITTY = nil
image._set_kitty_supported(false) -- A prior native-backend result must not block Snacks.
image.setup { backend = "snacks" }
assert(image.supports_kitty(), "Kitty attached to existing tmux must enable images without KITTY_WINDOW_ID")
assert(image.supports_kitty() and queries == 1, "cache terminal detection")
image.has_mmdc = function()
  return true
end
image.get_mermaid_cached = function()
  return nil
end
local content = require("md-render.preview").build_content { "```mermaid", "graph TD", "A --> B", "```" }
assert(#content.image_placements == 1, "Mermaid must reach the image backend")

for _, override in ipairs { "none", "0" } do
  image.reset_cache()
  client = override == "0" and "xterm-kitty" or "xterm-256color"
  vim.env.SNACKS_KITTY = override == "0" and "0" or nil
  assert(not image.supports_kitty(), "do not enable Kitty for unsupported clients or an explicit opt-out")
end
vim.env.TMUX, vim.env.TMUX_PANE, vim.env.SNACKS_KITTY = nil, nil, nil
vim.env.KITTY_WINDOW_ID = "1"
image.reset_cache()
assert(image.supports_kitty(), "direct Kitty remains supported")
print "Snacks detection: existing tmux, Mermaid, unsupported client, override and direct Kitty OK"
