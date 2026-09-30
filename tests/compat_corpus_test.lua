-- Pinned official inputs through ContentBuilder and the real buffer API (#38).
-- Run: NVIM_LOG_FILE=/tmp/md-render-corpus.log make tests/compat_corpus_test.lua
package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path
require("md-render.image").supports_kitty = function()
  return false
end
local Builder = require("md-render.content_builder").ContentBuilder
local display = require "md-render.display_utils"
local fixture_dir = "tests/fixtures/specs/"
local bytes = table.concat(vim.fn.readfile(fixture_dir .. "inputs.json", "b"), "\n")
local manifest = vim.json.decode(table.concat(vim.fn.readfile(fixture_dir .. "manifest.json"), "\n"))
assert(vim.fn.sha256(bytes) == manifest.inputs.sha256, "fixture bytes changed without a manifest update")
local cases = vim.json.decode(bytes)
assert(#cases == manifest.inputs.count, "official fixture count")
local ns = vim.api.nvim_create_namespace "compat_corpus_test"

local function validate(content, source_count)
  for _, line in ipairs(content.lines) do
    assert(not line:find("\n", 1, true), "output row contains an embedded newline")
  end
  assert(#content.source_line_map == #content.lines, "source map length differs from rendered row count")
  for _, row in ipairs(content.source_line_map) do
    assert(row % 1 == 0 and row >= 1 and row <= source_count, "source map row is outside the physical input")
  end
  local function span(row, first, last)
    assert(row % 1 == 0 and row >= 0 and row < #content.lines, "span row is outside the rendered buffer")
    local line = content.lines[row + 1]
    last = last == -1 and #line or last
    assert(first % 1 == 0 and last % 1 == 0 and first >= 0 and first <= last and last <= #line, "span byte bounds")
    for _, col in ipairs { first, last } do
      local byte = line:byte(col + 1)
      assert(not byte or byte < 128 or byte >= 192, "span endpoint splits a UTF-8 character")
    end
  end
  for _, row in ipairs(content.highlights) do
    for _, group in ipairs(row.groups) do
      span(row.line, group.col, group.end_col)
    end
  end
  for _, link in ipairs(content.link_metadata) do
    assert(link.col_end >= 0, "link endpoint must be an explicit byte offset")
    span(link.line, link.col_start, link.col_end)
  end
end

-- The shared invariant check must reject malformed rows, maps and byte ranges.
local valid = {
  lines = { "é界" },
  source_line_map = { 1 },
  highlights = { { line = 0, groups = { { col = 0, end_col = -1 } } } },
  link_metadata = { { line = 0, col_start = 2, col_end = 5 } },
}
validate(valid, 1)
for _, break_content in ipairs {
  function(c)
    c.lines[1] = "foo\nbar"
  end,
  function(c)
    c.source_line_map = {}
  end,
  function(c)
    c.source_line_map[1] = 2
  end,
  function(c)
    c.highlights[1].line = 1
  end,
  function(c)
    c.highlights[1].groups[1].end_col = 6
  end,
  function(c)
    c.highlights[1].groups[1].col = 1
  end,
  function(c)
    c.link_metadata[1].col_end = 4
  end,
  function(c)
    c.link_metadata[1].col_end = -1
  end,
} do
  local invalid = vim.deepcopy(valid)
  break_content(invalid)
  assert(not pcall(validate, invalid, 1), "invariant check accepted a deliberately incorrect witness")
end

local function run(case)
  local previous_buf = vim.api.nvim_get_current_buf()
  local source = vim.split(case.markdown, "\n", { plain = true })
  -- A final newline terminates the last physical row; preceding blank rows stay.
  if source[#source] == "" then table.remove(source) end
  local original = vim.deepcopy(source)
  local source_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, source)
  local source_tick = vim.api.nvim_buf_get_changedtick(source_buf)
  local source_rows = vim.api.nvim_buf_get_lines(source_buf, 0, -1, false)
  local buf = vim.api.nvim_create_buf(false, true)
  local ok, err = pcall(function()
    vim.api.nvim_set_current_buf(source_buf)
    local builder = Builder.new()
    builder:render_document(source, { max_width = 1000, indent = "", text_scale = false })
    local content = builder:result()
    display.apply_content_to_buffer(buf, ns, content)
    validate(content, #original)
    local expected = #content.lines == 0 and { "" } or content.lines
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), expected), "buffer differs from Content.lines")
    assert(vim.deep_equal(source, original), "builder mutated its source array")
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(source_buf, 0, -1, false), source_rows),
      "rendering mutated the source buffer"
    )
    assert(
      vim.api.nvim_buf_get_changedtick(source_buf) == source_tick,
      "rendering mutated the source buffer changedtick"
    )
  end)
  if vim.api.nvim_buf_is_valid(previous_buf) then vim.api.nvim_set_current_buf(previous_buf) end
  vim.api.nvim_buf_delete(buf, { force = true })
  vim.api.nvim_buf_delete(source_buf, { force = true })
  return ok, err
end

-- Buffer-0 writes must fail even when the renderer restores the original text.
local previous_buf = vim.api.nvim_get_current_buf()
local previous_rows = vim.api.nvim_buf_get_lines(previous_buf, 0, -1, false)
local render_document = Builder.render_document
for _, restore_rows in ipairs { false, true } do
  Builder.render_document = function(self, source, opts)
    local rows = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "SOURCE_WAS_MUTATED" })
    if restore_rows then vim.api.nvim_buf_set_lines(0, 0, -1, false, rows) end
    return render_document(self, source, opts)
  end
  local mutation_ok, mutation_err = run { markdown = "unchanged source\n" }
  Builder.render_document = render_document
  local reason = "rendering mutated the source buffer" .. (restore_rows and " changedtick" or "")
  assert(not mutation_ok and tostring(mutation_err):find(reason, 1, true), "source mutation was accepted")
  assert(vim.api.nvim_get_current_buf() == previous_buf, "failed case did not restore the original current buffer")
  assert(
    vim.deep_equal(vim.api.nvim_buf_get_lines(previous_buf, 0, -1, false), previous_rows),
    "failed case mutated the original current buffer"
  )
end

local counts, failures, report = {}, 0, {}
for _, case in ipairs(cases) do
  assert(manifest.specs[case.spec], "unknown specification")
  counts[case.spec] = (counts[case.spec] or 0) + 1
  assert(case.example == counts[case.spec], "official case order/identifier")
  local ok, err = run(case)
  if not ok then
    failures = failures + 1
    print("FAIL " .. case.spec .. " " .. case.example .. ": " .. tostring(err))
  end
  report[#report + 1] = {
    spec = case.spec,
    example = case.example,
    section = case.section,
    invariants = {
      status = ok and "measured_match" or "known_bug",
      reason = ok and "Builder, real buffer, physical rows, byte endpoints, map bounds and unchanged source checked."
        or tostring(err),
    },
    semantics = {
      status = "unverified",
      reason = "This gate does not compare HTML/AST semantics; named subject tests cover only their explicitly asserted dimensions.",
    },
  }
end
for spec, record in pairs(manifest.specs) do
  assert(counts[spec] == record.count, spec .. " fixture count")
end

-- CommonMark 116 / GFM 86 are included above with no exception list. #30's
-- code_isolation_test.lua asserts their exact code payload and source rows.
-- Neovim represents empty content with one empty physical buffer row.
local empty_ok, empty_err = run { markdown = "" }
assert(empty_ok, empty_err)
if vim.env.MD_RENDER_CORPUS_REPORT then
  vim.fn.writefile(
    { vim.json.encode { fixture_sha256 = manifest.inputs.sha256, specs = manifest.specs, cases = report } },
    vim.env.MD_RENDER_CORPUS_REPORT
  )
end
print(
  string.format(
    "Official corpus invariants: %d inputs, %d failures; semantic conformance remains unverified",
    #cases,
    failures
  )
)
if failures > 0 then vim.cmd "cquit 1" end
