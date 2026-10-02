-- Bound interpreter work instead of imposing machine-dependent timing limits.
-- Run: NVIM_LOG_FILE=/tmp/md-render-scaling.log timeout 10s nvim --headless -u NONE --noplugin -i NONE -l tests/parser_scaling_test.lua
-- Growth benchmark: prefix the command with MD_RENDER_PARSER_BENCHMARK=1 (use timeout 30s).
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. package.path
local markdown = require "md-render.markdown"
jit.off()

local function bounded(source, expected, expected_link, budget)
  local instructions = 0
  debug.sethook(function()
    instructions = instructions + 1000
    assert(instructions < (budget or 30000000), "paragraph exceeded its bounded parser work budget")
  end, "", 1000)
  local ok, text, _, links = pcall(markdown.render, source)
  debug.sethook()
  assert(ok, text)
  assert(text == expected, "large paragraph changed visible text")
  if expected_link then
    assert(#links == 1 and links[1].url == expected_link, "unmatched brackets changed URL ownership")
    assert(text:sub(links[1].col_start + 1, links[1].col_end) == "www.example.com", "URL byte positions changed")
  end
  return instructions
end

local brackets = string.rep("[", 4000)
bounded(brackets, brackets)
bounded(brackets .. " www.example.com", brackets .. " www.example.com", "http://www.example.com")
for _, body in ipairs {
  { "`x`", "x" },
  { "&amp;", "&" },
  { "*x*", "x" },
  { "<https://example.com>", "https://example.com" },
} do
  local opening, closing = string.rep("[ ", 4000), string.rep(" ]", 4000)
  bounded(opening .. body[1] .. closing, opening .. body[2] .. closing)
end
bounded(string.rep("**x** ", 4000), string.rep("x ", 4000))
print "parser_scaling_test: unmatched brackets, autolink lookahead and formatted text stay within the work budget"

if vim.env.MD_RENDER_PARSER_BENCHMARK == "1" then
  print "scenario,n,median_ms,instructions (three runs; elapsed time is informational)"
  for _, case in ipairs {
    { "brackets", "[", "[" },
    { "brackets_www", "[", "[", " www.example.com" },
    { "formatted", "**x** ", "x " },
    { "formatted_www", "**x** ", "x ", "www.example.com" },
  } do
    for _, n in ipairs { 1000, 2000, 4000, 8000 } do
      local source, expected = string.rep(case[2], n) .. (case[4] or ""), string.rep(case[3], n) .. (case[4] or "")
      local samples, instructions = {}, nil
      for run = 1, 3 do
        collectgarbage "collect"
        local start = vim.uv.hrtime()
        instructions = bounded(source, expected, case[4] and "http://www.example.com", 30000000 * math.max(1, n / 4000))
        samples[run] = (vim.uv.hrtime() - start) / 1e6
      end
      table.sort(samples)
      print(string.format("%s,%d,%.3f,%d", case[1], n, samples[2], instructions))
    end
  end
end
