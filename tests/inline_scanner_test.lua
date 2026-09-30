-- CommonMark 0.31.2 code span examples (CC BY-SA 4.0):
-- https://spec.commonmark.org/0.31.2/#code-spans
-- Other expectations were checked with the official commonmark.js 0.31.2 parser.
-- Run: nvim --headless -u NONE --noplugin -l tests/inline_scanner_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. package.path
local inline = require "md-render.inline"

-- Expected spans: start byte, inclusive final byte, delimiter length, normalized content.
local cases = {
  { name = "CommonMark 328", text = "`foo`\n", expected = { { 1, 5, 1, "foo" } } },
  { name = "CommonMark 329", text = "`` foo ` bar ``\n", expected = { { 1, 15, 2, "foo ` bar" } } },
  { name = "CommonMark 330", text = "` `` `\n", expected = { { 1, 6, 1, "``" } } },
  { name = "CommonMark 331", text = "`  ``  `\n", expected = { { 1, 8, 1, " `` " } } },
  { name = "CommonMark 332", text = "` a`\n", expected = { { 1, 4, 1, " a" } } },
  { name = "CommonMark 333", text = "` b `\n", expected = { { 1, 7, 1, " b " } } },
  { name = "CommonMark 334", text = "` `\n`  `\n", expected = { { 1, 4, 1, " " }, { 6, 9, 1, "  " } } },
  { name = "CommonMark 335", text = "``\nfoo\nbar  \nbaz\n``\n", expected = { { 1, 19, 2, "foo bar   baz" } } },
  { name = "CommonMark 336", text = "``\nfoo \n``\n", expected = { { 1, 10, 2, "foo " } } },
  { name = "CommonMark 337", text = "`foo   bar \nbaz`\n", expected = { { 1, 16, 1, "foo   bar  baz" } } },
  { name = "CommonMark 338", text = "`foo\\`bar`\n", expected = { { 1, 6, 1, "foo\\" } } },
  { name = "CommonMark 339", text = "``foo`bar``\n", expected = { { 1, 11, 2, "foo`bar" } } },
  { name = "CommonMark 340", text = "` foo `` bar `\n", expected = { { 1, 14, 1, "foo `` bar" } } },
  { name = "CommonMark 341", text = "*foo`*`\n", expected = { { 5, 7, 1, "*" } } },
  { name = "CommonMark 342", text = "[not a `link](/foo`)\n", expected = { { 8, 19, 1, "link](/foo" } } },
  { name = "CommonMark 343", text = '`<a href="`">`\n', expected = { { 1, 11, 1, '<a href="' } } },
  { name = "CommonMark 344", text = '<a href="`">`\n', expected = {} },
  { name = "CommonMark 345", text = "`<https://foo.bar.`baz>`\n", expected = { { 1, 19, 1, "<https://foo.bar." } } },
  { name = "CommonMark 346", text = "<https://foo.bar.`baz>`\n", expected = {} },
  { name = "CommonMark 347", text = "```foo``\n", expected = {} },
  { name = "CommonMark 348", text = "`foo\n", expected = {} },
  { name = "CommonMark 349", text = "`foo``bar``\n", expected = { { 5, 11, 2, "bar" } } },
  { name = "escaped_opener", text = "A \\`x` Z", expected = {} },
  { name = "escaped_backslash_opener", text = "A \\\\`x` Z", expected = { { 5, 7, 1, "x" } } },
  { name = "escaped_first_tick_run", text = "A \\```x`` Z", expected = { { 5, 9, 2, "x" } } },
  { name = "tab_inside", text = "A ` \t ` Z", expected = { { 3, 7, 1, "\t" } } },
  { name = "multiline_crlf", text = "A `x\r\ny` Z", expected = { { 3, 8, 1, "x y" } } },
  { name = "multiline_cr", text = "A `x\ry` Z", expected = { { 3, 7, 1, "x y" } } },
  { name = "comment_in_code", text = "A `<!-- x -->` Z", expected = { { 3, 14, 1, "<!-- x -->" } } },
  { name = "obsidian_comment_in_code", text = "A `%% x %%` Z", expected = { { 3, 11, 1, "%% x %%" } } },
  { name = "tick_in_html_comment", text = "A <!-- ` --> x ` Z", expected = {} },
  { name = "ticks_in_html_comment", text = "A <!-- `x` --> Z", expected = {} },
  { name = "link_destination_ticks", text = "A [x](foo`bar`) Z", expected = {} },
  { name = "link_angle_destination_ticks", text = "A [x](<foo`bar`>) Z", expected = {} },
  { name = "link_title_tick_cannot_pair_outside", text = 'A [x](foo "a`b") c` Z', expected = {} },
  { name = "code_label_brackets", text = "A [``x]y``](<two  spaces.md>) Z", expected = { { 4, 10, 2, "x]y" } } },
  { name = "invalid_html_unquoted_tick", text = "A <a href=`x> y` Z", expected = { { 11, 16, 1, "x> y" } } },
  { name = "escaped_html_opener", text = 'A \\<a href="`">x` Z', expected = { { 13, 17, 1, '">x' } } },
  { name = "email_autolink_owns_tick", text = "A <x`y@example.com>` Z", expected = {} },
  { name = "invalid_autolink_space", text = "A <https://a `b> c` Z", expected = { { 14, 19, 1, "b> c" } } },
  { name = "invalid_link_space", text = "A [x](a b`c) d` Z", expected = { { 10, 15, 1, "c) d" } } },
  { name = "invalid_link_title", text = 'A [x](foo`bar` "bad title) Z', expected = { { 10, 14, 1, "bar" } } },
  { name = "nested_link_outer_inactive", text = "A [a [b](url) c](foo`bar`) Z", expected = { { 21, 25, 1, "bar" } } },
  { name = "literal_nested_brackets", text = "A [a [b] c](foo`bar`) Z", expected = {} },
  { name = "reference_label_ticks", text = "A [x][a`b`c] Z", expected = {}, refs = { ["a`b`c"] = "/url" } },
  { name = "reference_label_tick_crossing", text = "A [x][a`b] c` Z", expected = {}, refs = { ["a`b"] = "/url" } },
  { name = "undefined_reference_label_tick_crossing", text = "A [x][a`b] c` Z", expected = { { 8, 13, 1, "b] c" } } },
  { name = "Obsidian comment owns its backtick", text = "A %% ` %% x ` Z", expected = {} },
  { name = "PUA cannot impersonate a placeholder", text = "󱀀1󱀁 `X`", expected = { { 11, 13, 1, "X" } } },
  { name = "byte coordinates after Unicode", text = "中 `x` `x`", expected = { { 5, 7, 1, "x" }, { 9, 11, 1, "x" } } },
}

for _, case in ipairs(cases) do
  local ranges = inline.code_spans(case.text, case.refs)
  local protected, spans = inline.protect_code(case.text, case.refs)
  assert(#ranges == #spans, case.name .. ": code ranges and replacements disagree")
  local actual = {}
  for i, range in ipairs(ranges) do
    actual[i] = { range.start, range.finish, range.ticks, spans[i].content }
    assert(spans[i].raw == case.text:sub(range.start, range.finish), case.name .. ": raw source changed")
    local first, last = protected:find(spans[i].placeholder, 1, true)
    assert(first and last, case.name .. ": placeholder missing")
    protected = protected:sub(1, first - 1) .. spans[i].raw .. protected:sub(last + 1)
  end
  assert(
    vim.deep_equal(actual, case.expected),
    case.name .. ": expected " .. vim.inspect(case.expected) .. ", got " .. vim.inspect(actual)
  )
  assert(protected == case.text, case.name .. ": literal roundtrip changed source")
end

for _, source in ipairs {
  "[``x]y``](<two  spaces.md>)",
  "[![alt](image.png)](<two  spaces.md>)",
} do
  local first, last = inline.link_bounds(source, 1)
  assert(first and source:sub(first, last) == "(<two  spaces.md>)", "code/image label changed destination bounds")
end
assert(inline.link_bounds("[not a ``link`](/foo``)", 1) == nil, "code owns the apparent closing bracket")
assert(inline.autolink_end("<x`y@example.com>`", 1) == 17, "email autolink owns its backtick")
assert(inline.autolink_end("<https://x/&amp;>", 1) == 17, "raw autolink owns its entity spelling")
-- The written spec permits TAB separators, although commonmark.js 0.31.2 misses this case.
local tab_link = '[x](u\t"a`b") c`'
local _, tab_end = inline.link_bounds(tab_link, 1)
assert(tab_end == 12, "TAB is a valid link separator")
assert(#inline.code_spans(tab_link) == 0, "title backticks cannot pair outside a valid TAB-separated link")
assert(inline.link_end('(u "a\n\nb")', 1) == nil, "titles cannot contain a blank line")
-- CommonMark 0.31.2 section 6.6 permits non-whitespace C0 in unquoted values.
for _, control in ipairs { "\1", "\11", "\12" } do
  local control_tag = "<x a=" .. control .. ' title="[[note]] `">'
  assert(inline.html_end(control_tag, 1) == #control_tag, "SOH/VT/FF are permitted unquoted attribute values")
  assert(#inline.code_spans(control_tag .. " `") == 0, "HTML attribute owns its apparent code opener")
end
for _, forbidden in ipairs { " ", "\t", "\r", "\n", '"', "'", "=", "<", ">", "`" } do
  assert(inline.html_end("<x a=" .. forbidden .. ">", 1) == nil, "an invalid/empty unquoted value remains invalid")
end
assert(inline.html_end("<x a=\0>", 1) == nil, "NUL remains rejected pending source-input normalization")
print(string.format("inline_scanner_test: %d fixed cases and shared boundary checks passed", #cases))
