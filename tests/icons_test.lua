-- Run: nvim --headless -u NONE --noplugin -i NONE -l tests/icons_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local icons = require "md-render.icons"
local checked = 0
local function eq(actual, expected, message)
  assert(vim.deep_equal(actual, expected), message .. ": " .. vim.inspect(actual) .. " ~= " .. vim.inspect(expected))
  checked = checked + 1
end

local function providers(devicons, mini)
  for name, provider in pairs { ["nvim-web-devicons"] = devicons or false, ["mini.icons"] = mini or false } do
    package.loaded[name] = nil
    package.preload[name] = function()
      assert(provider, "provider unavailable")
      return provider
    end
  end
end

eq(icons.config().style, "nerd", "original icons remain the default")
for _, style in ipairs { "auto", "ascii", "", false, 1 } do
  eq(pcall(icons.setup, { style = style }), false, "invalid styles are rejected")
  eq(icons.config().style, "nerd", "invalid configuration cannot change the style")
end
eq(pcall(icons.setup, "unicode"), false, "configuration must be a table")

local file_icons = {
  cs = "󰌛",
  ps1 = "󰨊",
  xml = "󰗀",
  txt = "󰈙",
  svg = "󰜡",
  tf = "󱁢",
}
local callouts = {
  { "NOTE", "󰋽", "ℹ️" },
  { "TIP", "󰌶", "💡" },
  { "IMPORTANT", "󰅾", "❗️" },
  { "WARNING", "󰀪", "⚠️" },
  { "CAUTION", "󰳦", "⚠️" },
  { "ABSTRACT", "󱉫", "📝" },
  { "TODO", "󰄬", "📋" },
  { "SUCCESS", "󰄬", "✅" },
  { "QUESTION", "󱈅", "❓" },
  { "FAILURE", "󰅙", "❌" },
  { "DANGER", "󱐌", "⛔️" },
  { "BUG", "󱈰", "🐛" },
  { "EXAMPLE", "󰆹", "⚗️" },
  { "QUOTE", "󱗝", "💬" },
}

providers()
local captured_lookup = icons.get_file_icon
for _, style in ipairs { "nerd", "unicode", "nerd" } do
  icons.setup { style = style }
  icons.setup()
  eq(icons.config().style, style, "empty setup retains the selected style")
  for ext, original in pairs(file_icons) do
    local expected = style == "nerd" and original or (ext == "svg" and "🖼️" or "📄")
    eq({ captured_lookup("sample." .. ext) }, { expected }, "existing file fallbacks follow the current style")
  end
  eq(icons.get_file_icon "Vagrantfile", "⍱", "standard special-filename symbol remains unchanged")
  eq(icons.get_file_icon "sample.lua", "", "existing empty extension fallback remains empty")
  eq(icons.get_file_icon "unknown.extension", "", "unknown file types retain the original empty fallback")
  for _, case in ipairs(callouts) do
    eq(
      icons.get_callout_icon(case[1], case[2]),
      style == "nerd" and case[2] or case[3],
      "canonical callout icons follow the current style"
    )
  end
  eq(icons.get_callout_icon("CUSTOM", "❝"), "❝", "unknown callouts retain the existing generic icon")
  eq(icons.get_fold_icon(true), style == "nerd" and "󰅂" or "▶️", "collapsed callout indicator")
  eq(icons.get_fold_icon(false), style == "nerd" and "󰅀" or "🔽", "expanded callout indicator")
  eq(
    icons.get_image_icon "missing.png?query#fragment",
    style == "nerd" and "󰋩" or "🖼️",
    "generic image fallback"
  )
  eq(icons.get_image_icon("movie", "video"), style == "nerd" and "󰋩" or "🎬", "extensionless explicit video")
  eq(
    icons.get_image_icon("misleading.txt", "video"),
    style == "nerd" and file_icons.txt or "🎬",
    "explicit video kind retains legacy Nerd behavior and selects Unicode video"
  )
  eq(icons.get_image_icon "picture.svg", style == "nerd" and file_icons.svg or "🖼️", "SVG remains an image")
  eq(select("#", icons.get_file_icon "sample.txt"), 2, "file API retains exactly two return values")
  eq(select("#", icons.get_image_icon "missing.png"), 2, "media API retains exactly two return values")
end

for _, code in ipairs { 0xE000, 0xF8FF, 0xF0000, 0xFFFFD, 0x100000, 0x10FFFD } do
  for _, value in ipairs { vim.fn.nr2char(code), "✓" .. vim.fn.nr2char(code) } do
    for _, style in ipairs { "nerd", "unicode" } do
      icons.setup { style = style }
      local expected = style == "nerd" and { value, "ProviderHighlight" } or { "📄" }
      providers {
        get_icon = function()
          return value, "ProviderHighlight"
        end,
      }
      eq({ icons.get_file_icon "sample.txt" }, expected, "devicons private glyph policy is explicitly selected")
      providers(nil, {
        get = function()
          return value, "ProviderHighlight"
        end,
      })
      eq({ icons.get_file_icon "sample.txt" }, expected, "mini.icons follows the same explicit private glyph policy")
    end
  end
end

for _, style in ipairs { "nerd", "unicode" } do
  local calls = {}
  icons.setup { style = style }
  providers({
    get_icon = function()
      calls[#calls + 1] = "devicons"
      return "󰄱", "NerdHighlight"
    end,
  }, {
    get = function()
      calls[#calls + 1] = "mini"
      return "◆", "MiniHighlight"
    end,
  })
  eq(
    { icons.get_file_icon "sample.txt" },
    style == "nerd" and { "󰄱", "NerdHighlight" } or { "◆", "MiniHighlight" },
    "fallback retains the selected provider's own highlight"
  )
  eq(
    { icons.get_image_icon("actual.png", "video") },
    style == "nerd" and { "󰄱", "NerdHighlight" } or { "◆", "MiniHighlight" },
    "the selected provider remains ahead of the media-kind fallback"
  )
  eq(
    calls,
    style == "nerd" and { "devicons", "devicons" } or { "devicons", "mini", "devicons", "mini" },
    "provider priority is preserved for file and media lookups"
  )
end

for _, value in ipairs { "A", "◆", "🖼︎", "!!", "" } do
  icons.setup { style = "unicode" }
  providers({
    get_icon = function()
      return value, "ProviderHighlight"
    end,
  }, {
    get = function()
      error "the accepted first provider must win"
    end,
  })
  eq(
    { icons.get_file_icon "sample.txt" },
    { value, "ProviderHighlight" },
    "Unicode and custom icons retain their colors"
  )
  eq(
    { icons.get_image_icon("movie", "video") },
    value ~= "" and { value, "ProviderHighlight" } or { "🎬" },
    "accepted provider icons precede the media fallback; empty icons still use the generic image API fallback"
  )
end

icons.setup { style = "unicode" }
providers({
  get_icon = function()
    return "󰄱", "RejectedHighlight"
  end,
}, {
  get = function()
    return "󰄲", "AlsoRejectedHighlight"
  end,
})
eq({ icons.get_file_icon "sample.txt" }, { "📄" }, "both private provider icons fall back without either color")
eq(
  { icons.get_image_icon("actual.png", "video") },
  { "🎬" },
  "rejected provider highlights cannot leak into media fallback"
)
providers(nil, {
  get = function()
    error "provider unavailable before setup"
  end,
})
eq({ icons.get_file_icon "sample.txt" }, { "📄" }, "mini.icons lookup failure retains the built-in fallback")

local loads = 0
package.loaded["nvim-web-devicons"] = nil
package.preload["nvim-web-devicons"] = function()
  loads = loads + 1
  return {
    get_icon = function()
      return "🖼︎", "DiagnosticHighlight"
    end,
  }
end
icons.setup { style = "nerd" }
icons.config()
eq(loads, 0, "configuration access does not load or probe providers")
eq(icons.inspect("actual.png", "image"), {
  style = "nerd",
  icon = "🖼︎",
  hl = "DiagnosticHighlight",
  source = "nvim-web-devicons",
  codepoints = { "U+1F5BC", "U+FE0E" },
  width = vim.api.nvim_strwidth "🖼︎",
}, "an explicit diagnostic resolves the actual provider icon and codepoints")
eq(loads, 1, "only the explicit diagnostic loads the selected provider")

providers()
icons.setup { style = "nerd" }
eq(icons.inspect("missing.png", "image"), {
  style = "nerd",
  icon = "󰋩",
  source = "generic",
  codepoints = { "U+F02E9" },
  width = vim.api.nvim_strwidth "󰋩",
}, "default diagnostics expose the original Nerd Font glyph without asserting its font support")
icons.setup { style = "unicode" }
local original_ambiwidth = vim.o.ambiwidth
for _, ambiwidth in ipairs { "single", "double" } do
  vim.o.ambiwidth = ambiwidth
  eq(icons.inspect("misleading.txt", "video"), {
    style = "unicode",
    icon = "🎬",
    source = "generic",
    codepoints = { "U+1F3AC" },
    width = vim.api.nvim_strwidth "🎬",
  }, "diagnostic width reports Neovim cells and media kind, not font coverage")
  for _, case in ipairs(callouts) do
    eq(vim.api.nvim_strwidth(icons.get_callout_icon(case[1], case[2])), 2, "Unicode callouts keep two display cells")
  end
  for _, icon in ipairs {
    icons.get_fold_icon(true),
    icons.get_fold_icon(false),
    icons.get_image_icon("missing.png", "image"),
    icons.get_image_icon("movie", "video"),
    icons.get_file_icon "sample.txt",
  } do
    eq(vim.api.nvim_strwidth(icon), 2, "built-in Unicode slots use two cells with the default emoji option")
    eq(icons.pad_icon(icon), icon, "two-cell icons need no additional padding")
  end
end
vim.o.ambiwidth = original_ambiwidth
eq(icons.inspect("sample.svg").source, "builtin", "file diagnostics identify the built-in type mapping")
eq(icons.inspect("unknown.extension").source, "generic", "unknown file diagnostics identify the generic empty fallback")
eq(pcall(icons.inspect, "sample.txt", "audio"), false, "diagnostic kind is validated")
eq(pcall(icons.get_image_icon, "sample.png", "audio"), false, "media kind is validated")

-- A multi-codepoint image icon changes byte offsets, not authored text or source
-- ownership. Verify real buffer links after CJK wrapping in both width settings.
do
  local Builder = require("md-render.content_builder").ContentBuilder
  local display = require "md-render.display_utils"
  local links = require "md-render.links"
  require("md-render.image").supports_kitty = function()
    return false
  end
  local source = {
    '前 <img src="/missing.png"',
    'alt="甲乙丙丁"> 後',
    "末 [連結甲乙丙丁戊己](https://example.invalid/target)",
    "作者 󰋩",
  }
  local ns = vim.api.nvim_create_namespace "icons_source_links_test"
  for _, ambiwidth in ipairs { "single", "double" } do
    vim.o.ambiwidth = ambiwidth
    local builder = Builder.new()
    builder:render_document(source, { max_width = 12, indent = "", text_scale = false })
    local content = builder:result()
    eq(
      content.lines,
      { "前 🖼️ 甲乙丙", "丁後末連結甲", "乙丙丁戊己作", "者 󰋩" },
      "visible text preserves authored private glyphs"
    )
    eq(content.source_line_map, { 1, 2, 3, 4 }, "Unicode media wrapping retains physical source ownership")
    local labels = {}
    local buf = vim.api.nvim_create_buf(false, true)
    display.apply_content_to_buffer(buf, ns, content)
    for _, link in ipairs(content.link_metadata) do
      local label = content.lines[link.line + 1]:sub(link.col_start + 1, link.col_end)
      labels[link.url] = (labels[link.url] or "") .. label
      eq(links.at(buf, ns, link.line, link.col_start), link.url, "first UTF-8 label byte keeps its target")
      eq(links.at(buf, ns, link.line, link.col_end - 1), link.url, "last UTF-8 label byte keeps its target")
    end
    eq(labels["/missing.png"], "🖼️ 甲乙丙丁", "image alt and variation selector remain linked")
    eq(
      labels["https://example.invalid/target"],
      "連結甲乙丙丁戊己",
      "following link retains its exact authored label"
    )
    eq(source[4], "作者 󰋩", "the profile never strips authored private-use characters")
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  vim.o.ambiwidth = original_ambiwidth
end

do
  local image = require "md-render.image"
  image.supports_kitty = function()
    return true
  end
  image.get_video_cached = function()
    return nil
  end
  for _, source in ipairs {
    { '<video src="https://example.invalid/stream"></video>' },
    { "| Media |", "|---|", '| <video src="https://example.invalid/clip.mp4"></video> |' },
  } do
    local builder = require("md-render.content_builder").ContentBuilder.new()
    builder:render_document(source, { max_width = 60, indent = "", text_scale = false })
    local content = builder:result()
    eq(content.image_placements[1].video, true, "standalone and table captions retain the video occurrence")
    eq(table.concat(content.lines, "\n"):find("🎬", 1, true) ~= nil, true, "both caption paths use the video icon")
  end
end

print(string.format("Icons: %d mode, provider, media, and diagnostic checks passed", checked))
