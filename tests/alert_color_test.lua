vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.termguicolors = true
local render = require "md-render"
local checked, failures = 0, {}

local function check(ok, message)
  checked = checked + 1
  if not ok then table.insert(failures, message) end
end

local function hl(group)
  return vim.api.nvim_get_hl(0, { name = group, link = false })
end

local function colorscheme(groups)
  vim.api.nvim_create_autocmd("ColorScheme", {
    once = true,
    callback = function()
      for group, style in pairs(groups) do
        vim.api.nvim_set_hl(0, group, style)
      end
    end,
  })
  vim.cmd.colorscheme "default"
  assert(
    vim.wait(1000, function()
      return hl("MdRenderAlertNote").fg ~= nil
    end),
    "alert defaults were not restored after ColorScheme"
  )
end

local function channel(rgb, shift)
  return bit.band(bit.rshift(rgb, shift), 0xff)
end

local function luminance(rgb)
  local function linear(shift)
    local c = channel(rgb, shift) / 255
    return c <= 0.04045 and c / 12.92 or ((c + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
end

local function readable_purple(group, message)
  local fg, bg = hl(group).fg, hl(group .. "Bg").bg
  local r, g, b = channel(fg, 16), channel(fg, 8), channel(fg, 0)
  check(b > r and r > g, ("%s: expected purple, got #%06x"):format(message, fg))
  local a, z = luminance(fg) + 0.05, luminance(bg) + 0.05
  local ratio = math.max(a, z) / math.min(a, z)
  check(ratio >= 4.5, ("%s: #%06x on #%06x gives %.2f:1"):format(message, fg, bg, ratio))
  return fg
end

-- Tokyo Night Storm's distinct Info, Hint and Special all sit near cyan.
colorscheme {
  NormalFloat = { bg = 0x1f2335 },
  DiagnosticInfo = { fg = 0x0db9d7 },
  DiagnosticHint = { fg = 0x1abc9c },
  DiagnosticOk = { fg = 0xb3f6c0 },
  DiagnosticError = { fg = 0xdb4b4b },
  Special = { fg = 0x2ac3de },
}
check(hl("MdRenderAlertNote").fg == 0x0db9d7, "NOTE keeps DiagnosticInfo")
check(hl("MdRenderAlertTip").fg == 0xb3f6c0, "TIP takes DiagnosticOk")
local pale = readable_purple("MdRenderAlertImportant", "Tokyo Night IMPORTANT")
check(hl("MdRenderAlertExample").fg == pale, "EXAMPLE uses the same purple on the same background")

-- quiet/light uses this gray float and a black Special. A cterm-only Ok has no RGB foreground to copy.
colorscheme {
  NormalFloat = { bg = 0xa8a8a8 },
  DiagnosticInfo = { fg = 0xadd8e6 },
  DiagnosticOk = { ctermfg = 2 },
  DiagnosticHint = { fg = 0xd3d3d3 },
  DiagnosticError = { fg = 0xff0000 },
  Special = { fg = 0x000000 },
}
check(hl("MdRenderAlertTip").fg == 0xd3d3d3, "TIP retains the theme's Hint when Ok has no RGB foreground")
local dark = readable_purple("MdRenderAlertImportant", "quiet IMPORTANT")
check(dark ~= pale and hl("MdRenderAlertExample").fg == dark, "changing the theme rebuilds both purple headers")

-- Neither purple reaches 4.5:1 on desert's float. Keep the more legible original foreground and tint.
local function check_fallback(special, fg, bg, message)
  colorscheme { Normal = { bg = 0x333333 }, NormalFloat = { bg = 0x666666 }, Special = special }
  for _, group in ipairs { "MdRenderAlertImportant", "MdRenderAlertExample" } do
    check(hl(group).fg == fg and hl(group .. "Bg").bg == bg, group .. " " .. message)
  end
end
check_fallback({ fg = 0xffde9b }, 0xffde9b, 0x75726b, "retains desert's 3.70:1 Special")
check_fallback({ ctermfg = 3 }, 0xffffff, 0x757575, "retains 4.61:1 white when Special has no RGB foreground")

-- On this float, the light purple reaches 4.5:1 only before its own tint is applied.
colorscheme {
  NormalFloat = { bg = 0x505050 },
  Special = { fg = 0xffffff },
  MdRenderAlertExample = { fg = 0xff0000 },
}
check(hl("MdRenderAlertImportant").fg == 0xffffff, "IMPORTANT evaluates contrast on its final tinted background")
check(hl("MdRenderAlertExampleBg").bg == 0x624848, "EXAMPLE tints its background with its explicit red foreground")

-- Model default's exact NOTE/IMPORTANT collision on a mid-gray background that can support a pale purple.
colorscheme {
  Normal = { bg = 0x4a4a4a },
  NormalFloat = {},
  Special = { link = "DiagnosticInfo" },
  Pmenu = { bg = 0xffffff },
  MdRenderAlertImportantBg = { link = "Pmenu" },
  MdRenderAlertTip = { fg = 0xff0000, italic = true },
}
render.setup_alert_highlights()
check(hl("MdRenderAlertImportantBg").bg == 0xffffff, "a linked explicit alert background wins")
check(
  readable_purple("MdRenderAlertImportant", "IMPORTANT on a white override") ~= hl("MdRenderAlertNote").fg,
  "IMPORTANT separates from NOTE when Special links to DiagnosticInfo"
)
check(
  readable_purple("MdRenderAlertExample", "EXAMPLE on the dark float") ~= hl("MdRenderAlertImportant").fg,
  "one alert background override does not change the other type"
)
local tip = hl "MdRenderAlertTip"
check(tip.fg == 0xff0000 and tip.italic, "an explicit header survives setup")
check(hl("MdRenderAlertTipBg").bg == 0x5c4343, "the automatic tint follows the explicit red foreground")

assert(#failures == 0, table.concat(failures, "\n"))
print(("alert_color_test: %d assertions passed"):format(checked))
