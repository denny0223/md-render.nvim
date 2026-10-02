NVIM := nvim --headless -u NONE --noplugin

TEST_FILES := $(sort $(wildcard tests/*_test.lua))

.PHONY: test test-harness $(TEST_FILES) lint format check

test: test-harness $(TEST_FILES)

# Stdlib-only checks for test/maintenance tools; never launches a real terminal.
test-harness:
	python3 tests/tooling_test.py
	python3 tests/download_integration_test.py

$(TEST_FILES):
	$(NVIM) -l $@

# Format Lua sources in place (honors .stylua.toml).
format:
	stylua .

# Local gate: formatting check. Luacheck runs in CI (.github/workflows/lint.yml).
lint:
	stylua --check .

check: lint test
