# Tests

## Overview

| Layer | What | Catches | Where | How |
|-------|------|---------|-------|-----|
| 1. Unit tests | The bytes md-render *emits* | Protocol regressions | CI (push/PR) | `make test` |
| 2. Media tools | The commands md-render *runs* | An external tool changing under us | CI (push/PR **and weekly**) | `media_test.lua`, `mermaid_integration.lua` |
| 3. Terminal | What the terminal actually *holds* | Scaled text drawn wrong, or not at all | CI (push/PR **and weekly**) | `tests/terminal_test.py` |
| 4. Visual regression | What the terminal actually *draws* | Clipped glyphs, images that never paint | One CI image-heading lane; broader checks local | `tmux_terminal_test.py --images`, `./tests/run_visual_test.sh` |

### Offline CommonMark/GFM corpus

The [corpus test](compat_corpus_test.lua) replays every [pinned official input](fixtures/specs/README.md) through ContentBuilder and a real Neovim buffer as part of `make test`. From the repository root, replay the inputs and export a local case-level report:

```sh
NVIM_LOG_FILE=/tmp/md-render-corpus.log MD_RENDER_CORPUS_REPORT=/tmp/md-render-corpus-report.json make tests/compat_corpus_test.lua
```

The gate checks physical output rows, buffer/content equality, highlight/link UTF-8 endpoints, source-map bounds and unchanged source bytes/changedtick. Invalid witnesses verify the checks. The report records fixture metadata and each example's invariant status/reason; broader semantics remain `unverified`. Named subject tests separately cover their explicitly asserted payload, ownership, target and interaction cases.

The corpus runs headless at width 1000 with plain headings and text-only image fallback. It does not compare the expected HTML or prove complete block/inline semantics, list/quote/table ownership, HTML/tag filtering, image/link/title semantics, code-language metadata or empty-code identity. Bounds alone establish neither intended substrings nor source-row correspondence. Narrow wrapping, heading backends, terminal pixels and interactions need their separate tests. Executed-input counts are not a conformance percentage.

Layer 2 exists because of a silent breakage: FFmpeg 9 removed `-vsync`, frame extraction failed for every video and animated GIF, and nothing noticed — the emitted escape sequences were still correct and no commit had touched the code. The failure mode was the toolchain moving, so the test runs on a schedule, not just on push.

## Running the default checks locally

```bash
make test
```

This needs Neovim and Python 3. In addition to the Lua checks, `tests/tooling_test.py` exercises capture failure, fresh baselines, process ownership, metric parsing and staged vendor updates with isolated command stubs. It launches no real terminal and downloads nothing. If ImageMagick 7 is installed, it also checks the actual normalized RMSE interface with identical, different and corrupt images. `make test-harness` also runs `download_integration_test.py` when curl is available: a temporary loopback HTTP server exercises the real plugin downloader, literal URLs, rejected redirect protocols and cleanup without contacting external services.

### Optional Snacks integration tests

The Snacks backend lifecycle tests use a real Snacks checkout while intercepting terminal output and controlling conversion timing. Set its path to include them in `make test`:

```bash
MD_RENDER_SNACKS_PATH=/path/to/snacks.nvim make test
```

Without this optional dependency, those integration tests report a skip. They check placement rebuilding, inactive-tab completion, and rapid zoom cleanup; they do not establish terminal visual correctness.

The Fedora CI job installs the latest Snacks default branch, ImageMagick and `ffmpeg-free`, then runs these tests with the dependency enabled. Its version checks require `magick` and `ffmpeg`, so the GIF/MP4 branch cannot silently skip because FFmpeg is absent. Its log records the Neovim, ImageMagick, FFmpeg and Snacks versions.

## Layer 1: Unit tests

Mock-based tests that verify Kitty Graphics Protocol escape sequences without requiring a real terminal.

- `image_test.lua` -- `transmit_image`, `put_image`, crop parameters, delete commands, batch mode, terminal detection
- `tty_test.lua` -- TTY discovery (isatty, ttyname, socket peer)
- `link_types_test.lua` -- Link type distinction (external, anchor, Obsidian)
- `reference_links_test.lua` -- Definition validity and consumption, Unicode label matching, table ranges, source mappings and real buffer/preview application
- `atx_headings_test.lua` -- ATX boundaries, empty headings, source mappings, inline ranges and anchor activation through plain/native/image layouts and public preview rebuilds
- `markdown_checkbox_test.lua` -- Checkbox rendering
- `html_table_test.lua` -- HTML table parsing
- `markdown_table_test.lua` -- Optional outer pipes, table boundaries, cell ranges and source mappings through real buffer application

Tests monkey-patch `vim.api.nvim_ui_send` to capture the bytes the image module would emit (mirrors Neovim's own `test/functional/ui/img_spec.lua`). The image module also exposes `_set_kitty_supported` and `_reset_image_id` for state control.

## Layer 2: Media tool tests

`media_test.lua` runs the real external tools (ffmpeg, ffprobe, ImageMagick, sips) against the bundled assets in `assets/demo/` and asserts that frames and PNGs actually come out.

Two details make it meaningful rather than decorative:

- **It forces a cache miss.** Frame caches include the source path, size and modification time; converted-PNG caches include the path and modification time. Testing a bundled path directly can therefore hit a cache from an earlier run and never invoke the tool. The test copies each asset to a unique temporary path first.
- **It refuses to pass by not testing.** A missing tool is reported as `skip` so contributors without ffmpeg can still run `make test`, but CI sets `MD_RENDER_REQUIRE_MEDIA_TOOLS=1`, which turns every skip into a failure.

The test prints the version of each tool it found; when the matrix goes red the first useful question is which toolchain it went red on.

`plantuml_kitty_test.lua` skips when no renderer is installed or configured. Once a renderer is available, a cold render must succeed; command failure and timeout fail even if a PNG was written. ImageMagick (`magick` or `convert`) or macOS `sips` then decodes the PNG before the protocol checks run. If no decoder is installed, the test explicitly skips PNG validation without reporting those checks as passed. Its cache is temporary; CI installs ImageMagick and exercises truncated-image and failed-command controls.

### FFmpeg matrix

`.github/workflows/media.yml` runs the suite against FFmpeg 6.1, 7.1, 8.1, 9.0 and master, plus a weekly `schedule`.

Spanning majors is the point. Ubuntu 24.04 still ships FFmpeg 6.1, so a job that ran `apt-get install ffmpeg` would have stayed green through the entire `-vsync` incident. The 8.x/9.x/master entries point at BtbN's rolling `latest` release, so the scheduled run picks up new point releases and reports drift; 6.1 and 7.1 come from a pinned older autobuild, because BtbN drops EOL branches from `latest` while keeping the release assets reachable.

### Real Mermaid renderer

The media workflow has one Mermaid lane using CLI 12.0.0 and Puppeteer 25.12.0, which selects its own fixed browser revision. The fixture in `tests/fixtures/mermaid-cli/` locks its npm dependencies; CI runs `npm ci --ignore-scripts`, then explicitly runs the locked Puppeteer browser installer. It prints the CLI, Puppeteer and browser versions, then renders a small diagram through the plugin from an empty temporary cache. The output must pass real PNG decoding with positive dimensions. A second real-process regression proves that executable Puppeteer configuration in the document and temporary ancestor directories runs in the controls but not through the plugin. Missing tools and a broken browser fail these explicit integration checks:

```sh
nvim --headless -u NONE --noplugin -l tests/mermaid_integration.lua
nvim --headless -u NONE --noplugin -l tests/mermaid_security_integration.lua
```

Install `mmdc`, its browser and a PNG decoder (ImageMagick or macOS `sips`) before running it locally. The ordinary `make test` target does not invoke this check or install a browser. The CI-only wrapper supplies `--no-sandbox` to the browser for its fixed fixture on the hosted runner; plugin configuration and ordinary local runs do not use that override.

## Optional image heading tests

The image heading checks in `make test` use mocks and need no optional packages. The separate integration checks require Python with PyGObject, Pango/PangoCairo, Pycairo and the configured fonts:

```bash
python3 tests/heading_raster_test.py
nvim --headless -u NONE --noplugin -l tests/heading_typography_integration.lua
```

The mock tests cover layout ownership, highlights, mouse targets, selection, transport and asynchronous fallback. The integration checks verify real raster pixels, six image sizes, wrapping, background coverage and click targets. Both integration checks run in the Fedora CI job with the required packages installed.

For a visual check, load this checkout in Kitty and open [image_headings.md](fixtures/image_headings.md). Run `:MdRender textsize auto`, then `:MdRender toggle`, and keep the cursor on the first body line:

1. Check six sizes, Han/Latin spacing, complete glyphs, inline code, strikethrough and highlighted backgrounds in dark and light themes. Compare external `[DOC](...)` with `<u>DOC</u>`: links need a distinct default color. Switch themes while the preview stays open; test a colored `Underlined`, an explicit `MdRenderLink` override and a live `:highlight MdRenderLink` edit. Resize to 40 columns: short Han headings should fit, and wrapped continuation text should stay aligned.
2. Move into a heading, select across headings/body text, yank, and search for `important`. Only matching headings should reveal search highlights. A body-only search must leave unrelated headings as images.
3. Hover over the trailing part of image-rendered FIRST, then click without moving. The image must stay visible until the link action resolves FIRST. Repeat in the lower row and for SECOND. Drag from an image glyph into the revealed text and verify the copied characters.
4. Use Kitty Ctrl+Shift+click on both rows of external image links, including adjacent links and wrapped Han/Latin labels. Verify the terminal opens the exact URL once; gaps and padding must open nothing. Repeat with transparent and opaque backgrounds, checking the visible PNG glyphs as well as URL cells, then scroll, reveal native feedback and switch backends: retired image cells must retain no URL. Use `:MdRender toggle` to return to source for terminal Shift-drag selection, or `textsize off` to select rendered text. Separately switch among `native`, `off` and `image`; verify the reading passage, cursor character and search state. Native headings retain scaling, link colors and inline styles. Narrow layouts or headings containing control characters such as tabs use ordinary headings throughout; verify the fallback reason and preserved text. The source buffer has no preview-generated OSC 8 links.
5. Check `:MdRender textsize status`. A missing Python/Pango installation or rejected PNG should select native OSC 66 when supported, otherwise ordinary text. Repeated rebuilds must not restart failed work; restoring the environment and running `:MdRender textsize auto` must recover images. Explicit `native` must not start image work, and `off` must survive toggling back to the preview. Missing glyphs affect only their heading.
6. Repeat with split/float/tab, inactive source editing, scrolling, floating overlap, tab/buffer changes and teardown. Retired work must never paint another document. Run through SSH with dependencies/fonts on the Neovim host and without copying generated image files to the client.

Keep screenshots with the terminal/Neovim/Pango/Cairo versions, font, cell size and colorscheme. Inspect pixels and interaction results, not only buffer/terminal text. Custom reverse, nocombine, blending and alternate underlines deliberately use text fallback; unsupported fonts and renderer failures must leave usable text.

### Tmux image headings

Tmux `auto` selects image headings after connection checks pass, retains ordinary text while pending, and falls back through native support on failure. `heading_tmux_test.lua` checks this selection, quiet output, capability gates, one/two-row placeholders, local failures and connection ownership. Direct uploads retain their separate acknowledgement tests. These checks do not establish terminal display.

For real-terminal acceptance, repeat the image-heading procedure in a private Kitty/tmux session with `allow-passthrough all` and `terminal-features` including `xterm-kitty:RGB:hyperlinks`. Check all six sizes and linked heading pixels, dark/light/transparent backgrounds, both rows of OSC 8 targets, gaps, wrapped labels, search, cursor feedback, Visual/yank and drag origin. Include right/bottom panes, status rows, scrolling, resizing/zoom, copy mode, pane/window changes, popup closure, client suspend/resume, detach/reattach and teardown. Disabled or `on` passthrough, unknown clients, multiple clients, oversized viewports and uploads exceeding the input buffer limit must retain text and report a reason.

Capture input in an isolated receiver while switching pane or opening a popup during uploads; no graphics response may enter it. Separately discard an upload or evict its image data: quiet transport cannot detect this, but `:MdRender toggle` must immediately recover unchanged source, `textsize off` must recover rendered text, and explicit `image` retry must restore pictures. Verify stale image URL cells disappear too. Record the code revision, tool versions and source hashes with pixels and interaction results in the untracked workspace.

Repeat over SSH before claiming remote tmux support. A loopback SSH PTY verifies byte transport without a shared image path, but does not establish a separate remote-host/local-client configuration. Linux acceptance does not establish other OS/client support.

The `--images` path reuses the isolated Kitty/tmux terminal harness and requires the image-heading Python dependencies, Pillow and ImageMagick (either the `magick` commands or ImageMagick 6's `import`/`convert`). Its native-fallback check requires tmux >= 3.6. It compares foreground glyph pixels for all six levels against their PNGs, verifies reference/angle-link destinations in painted OSC 8 cells, and checks source toggle/reopening plus auto recovery through native and plain fallback. One CI lane runs it with latest Kitty, tmux 3.6 and Neovim 0.12.0, retaining screenshots and diagnostics. Use an isolated X display; `--ssh` repeats the same checks over the temporary loopback server. This compact regression does not replace the broader interaction procedure above.

```sh
xvfb-run -a --server-args="-screen 0 2400x1800x24" python3 tests/tmux_terminal_test.py --images --passthrough all --output /tmp/md-image-tmux-results
xvfb-run -a --server-args="-screen 0 2400x1800x24" python3 tests/tmux_terminal_test.py --images --passthrough all --ssh --output /tmp/md-image-tmux-ssh-results
```

## Layer 3: Terminal tests

`terminal_test.py` launches a real Kitty (under `xvfb-run` when present), runs Neovim with the plugin, and asserts on what the terminal ended up holding.

The trick that makes this cheap is that `kitty @ get-text --ansi` **round-trips OSC 66 verbatim**:

```
ESC ] 66 ; s=2 ; Level One Heading ESC \
ESC ] 66 ; s=2:n=3:d=4:w=6 ; Level Th ESC \
```

The tests explicitly select native sizing and check all six scales, complete CJK text, protocol width limits, absence of level icons, cursor feedback and disabling scaling.

A fractionally scaled heading goes out as several runs — `n=` / `d=` shrink the font but not the cells, so each run states its own width — which is why the assertions join a level's payloads back together before matching.

`.github/workflows/terminal.yml` runs it against Kitty **0.40.0** (the version that introduced the protocol, so the floor this can work on) and **latest**, crossed with Neovim **v0.12.0** and **nightly**, plus a weekly schedule.

### Native headings through tmux

`tests/tmux_terminal_test.py` creates its own tmux server and Kitty window with focus reporting enabled. It checks six heading levels, wrapped CJK text, pane borders, status rows, resize/zoom, scrolling, copy mode, search, Visual/yank, passthrough changes, policy switching, detach/reattach, multiple-client fallback and teardown. Fullscreen and partial popups must keep their keyboard input and remain clear across redraws and keepalive; repeated popup recovery also runs during synchronous plugin-style refreshes with `eventignore=all`. It never uses your existing tmux server. CI builds tmux 3.6, the minimum with popup focus events, and tmux 3.4 to verify readable fallback with `--expect-plain`. Both versions run with both passthrough modes under Xvfb:

```sh
xvfb-run -a --server-args="-screen 0 2400x1800x24" python3 tests/tmux_terminal_test.py
xvfb-run -a --server-args="-screen 0 2400x1800x24" python3 tests/tmux_terminal_test.py --passthrough all
```

For redraw changes, also record continuous scrolling and cursor/search/Visual transitions in a document containing multiple headings and an image. Inspect frames during each transition: unrelated headings and images must not disappear while waiting for a debounce, and native feedback must contain the complete text. Settled screenshots and terminal text alone cannot detect a flashed intermediate frame.

On Linux/X11, `--output /tmp/md-native-tmux-results` also saves terminal snapshots, state and screenshots using ImageMagick. `--ssh` repeats the checks through a temporary loopback OpenSSH server with a generated key and password authentication disabled; it requires `sshd` and `ssh-keygen`. The test removes its server, keys and terminal processes on exit. `--checkout /path/to/checkout` permits a before/after comparison with the same fixture and terminal settings.

`--snacks /path/to/snacks.nvim` loads the real optional backend and adds an image beside the wrapped heading; Snacks sets passthrough to `all`. Inspect the captured image as well as the placeholder assertion, since placeholders alone do not prove PNG visibility. Use an isolated X display: desktop focus changes intentionally pause native output and can otherwise interfere with the checks. The temporary suppression test does not establish support for plugins that yield to the event loop while discarding focus events.

Ubuntu's own kitty package is 0.32 — below the 0.40 the protocol needs — so the workflow takes the release tarball. Kitty then needs its runtime dependencies installed by hand: `fontconfig` plus a font, and the X client libraries it `dlopen`s (`libxcursor1`, `libxrandr2`, `libxi6`, `libxinerama1`, `libxkbcommon-x11-0`). A missing one is a startup failure, not a link error — without libXcursor kitty dies with `Failed to dlopen .../kitty.glfw-x11.so`.

## Layer 4: Visual regression tests

Screenshot-based tests that launch real terminal emulators and compare rendered output against reference images.

### Requirements

- macOS for new captures (uses `screencapture` and Quartz); `--compare` needs no desktop
- At least one of WezTerm, Kitty or Ghostty for new captures; `--compare` needs only saved PNGs
- ImageMagick 7 (`magick`) for normalized RMSE comparison
- **PyObjC**: `pip install pyobjc-framework-Quartz`. Without it the capture cannot be scoped to one window and the script aborts.
- **Screen Recording permission** for whatever runs the script (System Settings > Privacy & Security > Screen Recording)

This layer is a deliberate gate, not something to run on every save. Most questions people reach for a screenshot to answer are cheaper in layer 3: it opens GUI windows and takes over the screen while it runs, and a whole-window comparison is sensitive to font, colorscheme and OS updates.

### Usage

```bash
# First time: capture screenshots and save as reference
./tests/run_visual_test.sh --update

# After changes: capture and compare (maximum normalized RMSE: 0.05)
./tests/run_visual_test.sh

# Compare only (skip capture, use existing screenshots)
./tests/run_visual_test.sh --compare
```

Normalized RMSE is a distance: identical images score 0, and smaller is better. `0.05` is an initial tolerance, not an equivalent of the former SSIM 0.95 setting or evidence of visual correctness. Inspect representative unchanged and intentionally broken captures for your font, terminal and OS, then calibrate `MD_RENDER_VISUAL_MAX_RMSE` before treating the result as an acceptance gate. The same-image/different-image controls in `tooling_test.py` verify the metric direction and failure handling, not this visual tolerance.

Missing captures, missing references, an empty comparison set and ImageMagick errors fail. New captures use temporary files; every capture must succeed before `--update` can replace any baseline. Capture failure cannot promote an older screenshot. Compare-only mode deliberately uses the saved files and never launches a terminal.

### When to run

- After changing image display logic (`image.lua`, `display_utils.lua`)
- After changing layout/rendering (`content_builder.lua`)
- Before releases

### When to update reference images

```bash
./tests/run_visual_test.sh --update
```

Run this after intentional visual changes (new features, layout adjustments). Review the screenshots in `tests/screenshots/` before committing the updated references.

### Output

```
tests/screenshots/
  wezterm.png          # Latest capture
  kitty.png
  ghostty.png
  reference/           # Baseline images (tracked in git)
    wezterm.png
    kitty.png
    ghostty.png
  diff/                # Difference images (gitignored)
    wezterm.png
    kitty.png
    ghostty.png
```

### Notes

- The test Markdown (`tests/fixtures/visual_test.md`) avoids using the same image file in multiple places to prevent WezTerm image ID conflicts.
- Animated GIF tests are included -- the animation timer affects image placement timing on WezTerm.
- `tests/capture_window.py` finds the window by a unique per-run/per-terminal **title**: terminals re-exec, so the PID the shell holds often does not own the window. `tests/visual_test_init.lua` sets the title from Neovim via `'title'` (OSC 2), which every supported terminal honours. Each launch gets its own process group; teardown signals only that group and never searches the desktop for a matching process name.
- The script **never falls back to a full-screen capture**. An earlier version did, and with PyObjC missing it silently photographed the whole desktop and wrote it out as a reference image.
- Much of what a screenshot is reached for can be answered without pixels: `kitty @ get-text` reports the actual cell grid, which is enough to check things like whether a heading occupies a two-row multicell group. Reserve this layer for questions that genuinely need pixels.

## Adding new tests

Follow the existing pattern:

```lua
-- tests/my_test.lua
-- Run: nvim --headless -u NONE --noplugin -l tests/my_test.lua

package.path = vim.fn.getcwd() .. "/lua/?.lua;" .. vim.fn.getcwd() .. "/lua/?/init.lua;" .. package.path

local pass_count = 0
local fail_count = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    fail_count = fail_count + 1
    print("ERROR: " .. name .. ": " .. tostring(err))
  end
end

-- ... tests ...

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
```

`make test` globs `tests/*_test.lua` and runs the Python tooling checks. A new matching Lua file is picked up automatically — no workflow change needed. Explicit browser/terminal integration checks stay separate.
