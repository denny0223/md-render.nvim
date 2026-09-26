-- Link style defaults and explicit overrides are shared by every renderer.
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
vim.api.nvim_set_hl(0, "Normal", { fg = 0x112233 })
vim.api.nvim_set_hl(0, "@markup.heading", { fg = 0xabcdef })
vim.api.nvim_set_hl(0, "MdRenderH2", { fg = 0xff9977, bold = false })
require("md-render").setup_highlights()
assert(vim.api.nvim_get_hl(0, { name = "MdRenderH1", link = false }).fg == 0xabcdef)
assert(vim.api.nvim_get_hl(0, { name = "MdRenderH2", link = false }).fg == 0xff9977)
local link_style = vim.api.nvim_get_hl(0, { name = "MdRenderLink", link = false })
link_style.default = nil
assert(
  link_style.fg == vim.api.nvim_get_hl(0, { name = "DiagnosticInfo", link = false }).fg and link_style.underline,
  "ordinary links have a theme color as well as an underline"
)
local underline = vim.api.nvim_get_hl(0, { name = "Underlined", link = false })
vim.api.nvim_set_hl(0, "Underlined", { fg = 0xaa1122, ctermfg = 5, italic = true })
vim.api.nvim_set_hl(0, "MdRenderLink", {})
require("md-render").setup_highlights()
local custom_link = vim.api.nvim_get_hl(0, { name = "MdRenderLink", link = false })
assert(custom_link.fg == 0xaa1122 and custom_link.ctermfg == 5 and custom_link.italic and not custom_link.underline)
vim.api.nvim_set_hl(0, "MdRenderLink", { fg = 0x123456, underline = false })
require("md-render").setup_highlights()
assert(vim.api.nvim_get_hl(0, { name = "MdRenderLink", link = false }).fg == 0x123456, "explicit overrides win")
local _, link_spans = require("md-render.markdown").render "[DOC](https://example.invalid)"
assert(#link_spans == 1 and link_spans[1].hl == "MdRenderLink", "an explicit link style can remove its underline")
vim.api.nvim_set_hl(0, "Underlined", underline)
vim.api.nvim_set_hl(0, "MdRenderLink", link_style)
print "Link styles: theme defaults and explicit overrides OK"
