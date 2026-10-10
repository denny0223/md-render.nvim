# Tests

Run commands from the repository root. The default checks need Neovim ≥ 0.12, Python ≥ 3.9, Make, Bash, Perl and basic Unix tools. They run headless and do not open a terminal window.

```sh
make -k test                       # Continue independent checks after a failure
make tests/image_test.lua          # Run one *_test.lua file
make lint                          # Check formatting; requires StyLua
```

`make test` stops at the first failed target; `make -k test` continues independent Lua and Python targets and still returns failure. Optional tools enable additional integrations; a reported skip is not evidence that an integration works. With curl installed, the Python harness also tests downloads through a temporary loopback HTTP server.

| Change | Checks |
| --- | --- |
| Parsing, layout, protocol or preview behavior | The default checks, including the [corpus](#commonmarkgfm-corpus) |
| Image/video conversion or an external renderer | [Media and renderers](#media-and-renderers) |
| Image-heading layout or rasterization | [Image headings](#image-headings) |
| Kitty/tmux output, focus or interaction | [Terminal checks](#terminal-checks) |
| Visual appearance | [Manual image checks](#manual-image-checks) or [visual comparisons](#visual-comparisons) |
| CI notification policy | `node tests/ci_notify_test.js` (requires Node; separate from `make test`) |

## CommonMark/GFM corpus

The [corpus test](compat_corpus_test.lua) replays the [pinned official inputs](fixtures/specs/README.md) through ContentBuilder and a real Neovim buffer as part of the default checks. To export a case-level report:

```sh
NVIM_LOG_FILE=/tmp/md-render-corpus.log MD_RENDER_CORPUS_REPORT=/tmp/md-render-corpus-report.json make tests/compat_corpus_test.lua
```

It checks output rows, buffer/content equality, UTF-8 highlight/link endpoints, source-map bounds and unchanged source bytes/changedtick. It runs headless at width 1000 with plain headings and text-only image fallback. It does not compare expected HTML or establish semantic conformance, intended source-row correspondence, narrow wrapping, pixels or interactions. Case counts are not a conformance percentage; named subject tests cover their separately asserted semantics.

## Media and renderers

[media_test.lua](media_test.lua) exercises FFmpeg, ffprobe, ImageMagick and macOS `sips` against bundled assets. Each conversion uses a fresh temporary source so an old cache cannot satisfy the check. Missing tools normally produce skips; require them when validating a media change:

```sh
MD_RENDER_REQUIRE_MEDIA_TOOLS=1 make tests/media_test.lua
```

[plantuml_kitty_test.lua](plantuml_kitty_test.lua) needs a configured or installed PlantUML renderer and ImageMagick or macOS `sips` to decode the resulting PNG. Renderer errors and timeouts fail even if a file was written; missing optional dependencies are reported as skips. Run the graphics check and the separate configuration-security check below. Confirm the graphics log contains no skips; the required-tools flag applies only to the security check.

```sh
make tests/plantuml_kitty_test.lua
MD_RENDER_REQUIRE_PLANTUML=1 make tests/plantuml_security_test.lua
```

### Mermaid

Install `mmdc`, its matching browser and a PNG decoder (ImageMagick or macOS `sips`), then run:

```sh
nvim --headless -u NONE --noplugin -l tests/mermaid_integration.lua
MD_RENDER_REQUIRE_MERMAID_TOOLS=1 nvim --headless -u NONE --noplugin -l tests/mermaid_security_integration.lua
```

These checks require a real cold PNG render and verify that executable Puppeteer configuration from document/ancestor directories runs in the controls but not through the plugin. They are separate from `make test`. The [locked fixture](fixtures/mermaid-cli/package.json) and [media workflow](../.github/workflows/media.yml) define the pinned setup and browser installation; the hosted-runner browser wrapper is CI-only.

### Snacks

Use a real Snacks checkout and ImageMagick to include backend lifecycle checks in the default suite. FFmpeg also enables its GIF/MP4 cases:

```sh
MD_RENDER_SNACKS_PATH=/path/to/snacks.nvim make -k test
```

Missing optional dependencies produce skips. These checks intercept terminal output and control conversion timing to test placement rebuilding, inactive-tab completion and zoom cleanup. Use the terminal/image checks below to verify actual display.

## Image headings

The default suite uses mocks for image-heading layout, highlights, targets, selection, transport and fallback. Real raster/typography checks require Python with PyGObject, Pango/PangoCairo, Pycairo and the configured fonts:

```sh
python3 tests/heading_raster_test.py
nvim --headless -u NONE --noplugin -l tests/heading_typography_integration.lua
```

These verify raster pixels, six image sizes, wrapping, background coverage and click targets, and run in the Fedora CI jobs.

### Manual image checks

Load this checkout in Kitty and open [image_headings.md](fixtures/image_headings.md). Run `:MdRender textsize auto`, then `:MdRender toggle`, with the cursor on the first body line.

1. Check all six sizes, complete Han/Latin glyphs, inline code, strikethrough and backgrounds in dark/light themes. Links must remain distinct from plain underlined text. Change `Underlined` and `MdRenderLink` while the preview is open; resize to 40 columns and check wrapping/alignment.
2. Move into headings, select across heading/body boundaries, yank and search. Matching headings should reveal native feedback; a body-only search must leave unrelated headings as images. Record transitions for redraw changes: settled screenshots cannot reveal brief disappearance of unrelated content.
3. Hover then click FIRST and SECOND, including their lower rows. Images should remain visible until the action resolves the correct link. Drag from a glyph into revealed text and verify the copied characters.
4. Use Kitty Ctrl+Shift+click on both rows of external links, adjacent/wrapped labels and transparent/opaque backgrounds. Each link must open its exact URL once; gaps and padding must open nothing. After scroll, reveal, backend switch or teardown, retired cells must retain no URL.
5. Switch `native`, `off` and `image`; preserve the reading passage, cursor character and search state. Use `:MdRender toggle` for source selection or `textsize off` for rendered text selection. Source buffers must have no preview-generated OSC 8 links. Narrow/control-character headings and unsupported styles must keep readable text.
6. Check `:MdRender textsize status` after a missing dependency, rejected PNG or missing glyph. Failures should affect only the relevant headings and fall back to native support or plain text. Rebuilds must not continually restart failed work; an explicit `auto` retry after restoring dependencies must recover. Explicit `native` must not start image work, and `off` must survive toggling.

Repeat with splits, floats, tabs, inactive source edits, scrolling, overlap and teardown; retired work must not paint another document. For SSH, install dependencies/fonts on the Neovim host and verify display without copying generated images to the client. Keep screenshots with the revision, tool/font versions, cell size and colorscheme; buffer text alone does not establish pixel or interaction correctness.

### Tmux image headings

Use a private Kitty/tmux session with `allow-passthrough all` and `terminal-features` including `xterm-kitty:RGB:hyperlinks`. Repeat the manual image checks, including right/bottom panes, status rows, resize/zoom, copy mode, pane/window changes, popups, client suspend/resume and detach/reattach. Disabled or `on` passthrough, unknown/multiple clients, oversized viewports and oversized uploads must retain text and report a reason.

Capture input in an isolated receiver while switching panes or opening a popup during uploads; no graphics response may enter it. Quiet transport cannot detect a discarded upload or evicted image data. Verify that `:MdRender toggle` recovers unchanged source, `textsize off` recovers rendered text, and explicit `image` retry restores pictures and clears stale URL cells.

The automated pixel regression requires the image-heading dependencies above, Pillow, ImageMagick and tmux ≥ 3.6 for its native-fallback check. It checks all six glyph sizes, painted OSC 8 targets and recovery through source/native/plain modes:

```sh
xvfb-run -a --server-args="-screen 0 2400x1800x24" python3 tests/tmux_terminal_test.py --images --passthrough all --output /tmp/md-image-tmux-results
```

Use a fresh output directory. Add `--ssh` to repeat over an isolated loopback OpenSSH server. Loopback verifies PTY transport without a shared image path; it does not establish a separate remote-host/local-client setup. Repeat over real SSH before claiming that support. This compact pixel regression does not replace the broader manual interaction checks, and Linux results do not establish other OS/client support.

## Terminal checks

Use Kitty ≥ 0.40 and an isolated X display. The direct driver starts Xvfb when `xvfb-run` is available; otherwise it opens a window on the current desktop. The tmux driver creates its own server and does not touch an existing tmux session. Native-heading checks need tmux ≥ 3.6; use `--expect-plain` with older tmux to verify readable fallback.

```sh
python3 tests/terminal_test.py
xvfb-run -a --server-args="-screen 0 2400x1800x24" python3 tests/tmux_terminal_test.py
xvfb-run -a --server-args="-screen 0 2400x1800x24" python3 tests/tmux_terminal_test.py --passthrough all
```

These inspect terminal state for native sizes, complete CJK text, wrapped headings, cursor/search/Visual feedback, links and disabling scaling. Tmux checks also cover pane geometry, focus/popups, redraw, copy mode, passthrough changes, detach/reattach and cleanup. Terminal text/OSC 66 state does not prove actual pixels; use `--images` or visual checks for those.

Useful tmux driver options:

- `--output-on-failure DIR`: retain the original error, completed checks, versions, input, terminal/Neovim state and best-effort screenshots. Use a new or empty directory; it cannot be combined with `--output`.
- `--output DIR`: capture normal checkpoints too; requires ImageMagick (`magick`, or ImageMagick 6 `import`/`convert`). Captures are sequential, not atomic; inspect their timestamps when diagnosing focus or geometry.
- `--checkout PATH`: test another checkout with the same driver and fixture.
- `--ssh`: use a temporary loopback OpenSSH server; needs `sshd` and `ssh-keygen`. The driver removes its server, keys and terminal processes on exit.
- `--snacks PATH`: include the real backend and an adjacent image; Snacks sets passthrough to `all`. Inspect the captured PNG as well as its placeholder.

Desktop focus changes can pause native output, so keep these checks isolated. For redraw changes, also record continuous scroll and cursor/search/Visual transitions in a document containing headings and an image. An eventual correct frame cannot establish that no intermediate frame flashed.

## Visual comparisons

[run_visual_test.sh](run_visual_test.sh) captures and compares terminal screenshots. New captures need macOS, WezTerm/Kitty/Ghostty, ImageMagick 7, `pyobjc-framework-Quartz` and Screen Recording permission. Capture opens GUI windows and controls focus; it is scoped to a single window and fails if that window cannot be identified. Compare-only mode needs saved PNGs and ImageMagick, with no desktop access.

```sh
./tests/run_visual_test.sh --update   # Capture references after an intentional visual change
./tests/run_visual_test.sh            # Capture and compare
./tests/run_visual_test.sh --compare  # Compare existing captures only
```

Run these for display/layout changes and before releases. Review `tests/screenshots/reference/` before committing updated baselines; current captures and differences are under `tests/screenshots/` and `tests/screenshots/diff/`. All new captures must succeed before `--update` replaces any reference. Missing/corrupt inputs, empty comparisons and ImageMagick errors fail.

Normalized RMSE is a distance: identical images score zero, and lower is better. The default `0.05` threshold needs calibration with representative unchanged and intentionally broken images for the chosen terminal/font/OS. Set `MD_RENDER_VISUAL_MAX_RMSE` accordingly before using it as an acceptance gate. Font, theme, OS updates and GIF animation timing can change captures; passing the metric alone does not establish visual correctness.

## CI policy and maintenance

PRs and pushes to `main` run representative baselines, which maintainers require to pass before merging. Broader toolchain observation runs weekly, including changes in upstream tools when this repository has not changed. Development-branch pushes do not duplicate PR runs. Exact versions, schedules and installation inputs live in the linked workflows, [archive manifests](../.github/ci/) and [Mermaid fixture](fixtures/mermaid-cli/package.json).

| Workflow | PR/main baseline | Weekly observation |
| --- | --- | --- |
| [Lint](../.github/workflows/lint.yml) | Formatting and Lua lint | — |
| [Tests](../.github/workflows/test.yml) | Minimum/current Neovim on Ubuntu/macOS; released Fedora image integrations | Minimum/stable/nightly Neovim, latest Snacks and Rawhide |
| [Terminal](../.github/workflows/terminal.yml) | Minimum/current Kitty and Neovim; native on/all and image headings through tmux | Broader Kitty/Neovim combinations and older-tmux plain fallback |
| [Media](../.github/workflows/media.yml) | Fixed FFmpeg releases and locked Mermaid | Additional FFmpeg releases/master and locked/latest Mermaid |

Fedora release pins the root filesystem but installs updated official RPMs. Rawhide follows official RPMs with a fixed Snacks checkout to isolate RPM changes. Its Xvfb/X11/software-GL checks establish userspace behavior, not Wayland, hardware GPU, kernel, SELinux or personal desktop behavior; `ffmpeg-free` does not imply full-codec support. Representative CI runtimes, including Node, do not add plugin requirements.

Tests, Media and Terminal accept `suite=baseline` or `suite=observation` on a chosen ref:

```sh
gh workflow run test.yml --ref YOUR_BRANCH -f suite=baseline
gh workflow run media.yml --ref YOUR_BRANCH -f suite=observation
gh workflow run terminal.yml --ref YOUR_BRANCH -f suite=observation
```

### Investigating failures

Start with the failed job's summary, find the failed or missing phase, then read that step's log and download artifacts from the same attempt. Independent checks continue where possible, but a required phase that fails or does not run cannot pass. Cancellation, whole-job timeout or runner loss is **incomplete**; later phases and artifact uploads are best effort.

Inspect and preserve the first failure before retrying. A successful retry is additional evidence, not a diagnosis. Weekly failures may remain red while their cause is tracked; skipping them is not a resolution. Only superseded PR runs are cancelled automatically. Successful artifacts are kept for 14 days, failed baselines for 30 and failed observations for 90, subject to the repository retention cap; logs have a separate retention setting.

PRs and branch dispatches only preview reports. First-attempt main observations maintain one issue per workflow: new/changed failures and normal scheduled recovery are visible; unchanged failures refresh the evidence link. Classify new failures before the next weekly review, leave unknown causes unknown, and close issues manually. Retry/manual success and incomplete runs do not announce scheduled recovery.

### Updating baselines

Maintainers review fixed baselines after the first weekly observation of each month and minimum support each quarter. Version changes and merges are manual; record the decision and evidence in the upgrade PR.

- Patch candidates need one relevant first-attempt successful observation. A new series or OS needs observations in two distinct weekly periods. Evidence must identify the same candidate version/digest/lockfile; different `latest` resolutions or successful retries cannot be combined into that evidence.
- Candidates outside weekly coverage need their own installation/driver checks. The explicit candidate must then pass the complete baseline, with any relevant earlier failures accounted for.
- Review security fixes and unavailable downloads immediately. Find a trusted replacement source before dropping support. Updating a representative baseline does not automatically raise minimum support.

## Adding tests

New `tests/*_test.lua` files are picked up automatically by `make test`. Follow a nearby test such as [image_test.lua](image_test.lua), report meaningful assertion counts and return nonzero on failure. Browser/terminal integrations remain explicit commands with their own prerequisites. Keep the test at the cheapest layer that can observe the behavior: mock output, real tool/buffer state, terminal state or pixels.
