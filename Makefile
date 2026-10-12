NVIM := nvim --headless -u NONE --noplugin

TEST_FILES := $(sort $(wildcard tests/*_test.lua))
HARNESS_FILES := tests/tooling_test.py tests/tmux_diagnostics_test.py tests/download_integration_test.py

.PHONY: test test-harness $(HARNESS_FILES) $(TEST_FILES) lint format check

test: test-harness $(TEST_FILES)

# Maintenance checks plus loopback-only download integration; never launches a
# real terminal or contacts an external network.
test-harness: $(HARNESS_FILES)

$(HARNESS_FILES):
	python3 $@

$(TEST_FILES):
	$(NVIM) -l $@

# Format Lua sources in place (honors .stylua.toml).
format:
	stylua .

# Local gate: formatting check. Luacheck runs in CI (.github/workflows/lint.yml).
lint:
	stylua --check .

check: lint test
