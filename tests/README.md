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
| CI required-step results | `python3 tests/ci_results_test.py` (also included in `make test`) |

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

[plantuml_kitty_test.lua](plantuml_kitty_test.lua) needs a configured or installed PlantUML renderer and ImageMagick or macOS `sips` to decode the resulting PNG. Renderer errors and timeouts fail even if a file was written; missing optional dependencies are reported as skips. The security check also needs Java and the PlantUML JAR; set `PLANTUML_JAR` when it is not at `/usr/share/java/plantuml.jar`. Require the tools when running both checks:

```sh
MD_RENDER_REQUIRE_PLANTUML=1 make -k tests/plantuml_kitty_test.lua tests/plantuml_security_test.lua
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

CI follows the `ubuntu-latest` and `macos-latest` runner labels and major-version Action tags. Runner releases follow GitHub's rollout schedule; rerunning the same repository commit can use newer OS images, packages or Action code.

PRs and pushes to `main` run representative baselines, which maintainers require to pass before merging. Broader toolchain observation runs weekly, including changes in upstream tools when this repository has not changed. Development-branch pushes do not duplicate PR runs. Exact versions, schedules and installation inputs live in the linked workflows, [archive manifests](../.github/ci/) and [Mermaid fixture](fixtures/mermaid-cli/package.json).

In public repositories, [GitHub disables scheduled workflows after 60 days without repository activity](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule); re-enable a disabled workflow before relying on weekly observation again.

| Workflow | PR/main baseline | Weekly observation |
| --- | --- | --- |
| [Lint](../.github/workflows/lint.yml) | Formatting and Lua lint | — |
| [Tests](../.github/workflows/test.yml) | Fixed minimum/reference Neovim on Ubuntu/macOS; released Fedora image integrations | Minimum/stable/nightly Neovim, latest Snacks and Rawhide |
| [Terminal](../.github/workflows/terminal.yml) | Fixed minimum/reference Kitty and Neovim; native on/all and image headings through tmux | Broader Kitty/Neovim combinations; tmux 3.4 plain fallback on minimum Kitty/Neovim and latest Kitty/nightly Neovim |
| [Media](../.github/workflows/media.yml) | Ubuntu's FFmpeg package, fixed FFmpeg 9.0 and locked Mermaid | Baseline FFmpeg checks plus master; locked/latest Mermaid |

Released Fedora follows `registry.fedoraproject.org/fedora:latest` and updated official RPMs. Rawhide follows official RPMs with a fixed Snacks checkout to isolate RPM changes. Its `all` passthrough check verifies Snacks image placeholders alongside native headings and saves screenshots for inspection; it does not check Snacks image pixels.

Rawhide's Xvfb/X11/software-GL checks establish userspace behavior, not Wayland, hardware GPU, kernel, SELinux or personal desktop behavior; `ffmpeg-free` does not imply full-codec support. Representative CI runtimes, including Node, do not add plugin requirements.

Tests, Media and Terminal accept `suite=baseline` or `suite=observation` on a chosen ref:

```sh
gh workflow run test.yml --ref YOUR_BRANCH -f suite=baseline
gh workflow run media.yml --ref YOUR_BRANCH -f suite=observation
gh workflow run terminal.yml --ref YOUR_BRANCH -f suite=observation
```

### Investigating failures

Start with the failed job's summary, find the failed or missing phase, then read that step's log and download artifacts from the same attempt. Independent checks continue where possible, but a required phase that fails or does not run cannot pass. Cancellation, a job timeout or missing execution metadata cannot establish successful verification. Later phases and artifact uploads are best effort.

Inspect the first failure before retrying. A successful retry is additional evidence, not a diagnosis. Only superseded PR executions are cancelled automatically. Successful artifacts are kept for 14 days, failed baselines for 30 and failed observations for 90, subject to the repository retention cap; logs have a separate retention setting.

Failures use GitHub Actions' native run status, logs and notifications. Check your [Actions notification preferences](https://docs.github.com/en/subscriptions-and-notifications/how-tos/managing-github-actions-notifications) if you want failure notifications; delivery follows [GitHub's recipient rules](https://docs.github.com/en/actions/concepts/workflows-and-actions/notifications-for-workflow-runs).

### Updating baselines

Weekly observations check compatibility with the selected upstream tools. Propose a baseline change when there is a concrete benefit, an observed regression, an unavailable download, a relevant security fix or an upstream support deadline. Record the candidate, its effect on this repository and the relevant validation evidence in the upgrade PR. Updating a representative baseline and changing minimum support are separate decisions.

[Renovate](../renovate.json) prepares ordinary update PRs before 04:00 Monday in Taiwan, with at most two open at a time and no automatic merging. This controls when candidates are proposed, not when maintainers must respond or which updates must be accepted. Dependabot's separate version updater is removed to avoid duplicate PRs; GitHub's security alerts remain separate. Security-remediation PRs can bypass Renovate's ordinary schedule and limits.

| Tracked input | Update boundary |
| --- | --- |
| GitHub Actions and `setup-node`'s Node version | Action tags and the installed Node runtime are tracked separately. |
| Mermaid CLI and Puppeteer | The test fixture's package versions and lockfile are updated together; `tests/` is included explicitly. |
| StyLua | The pre-commit frozen SHA/tag and CI formatter version share one update PR. |
| Neovim reference | Both platform archives, installer allowlist and workflow references share one PR. A release must have valid SHA256 digests for both platforms before it is eligible. |
| Kitty reference | The installer version/digest and terminal matrix share one PR. |
| Snacks | Both fixed integration checkouts move together, with ordinary proposals limited to the first day of the month; the weekly `HEAD` observation is unchanged. |
| FFmpeg 9.0 archive | The URL and SHA256 move together to the last available build of a completed UTC month, retaining the 9.0 series and linux64 GPL variant. |

The custom archive datasources read GitHub release metadata and use the upstream asset SHA256; they do not run extra update scripts or require a self-hosted Renovate service. The custom datasource API is experimental, so validate configuration changes with the installed Renovate engine and inspect the hosted onboarding preview or Dependency Dashboard for lookup warnings. FFmpeg's retained monthly snapshots still have finite upstream availability.

Neovim and Kitty minimums, tmux's native minimum and older fallback witness remain deliberately fixed. Floating runner/image labels and stable/nightly/latest observations keep their existing meaning. Vendored source, Unicode tables and specification fixtures retain their explicit sync/generation procedures: changing only their provenance version would not update the payload. Product documentation's previously validated versions are historical evidence, not updater targets.

Review applicable release notes, changed runtime requirements, permissions and default behavior, then run the affected checks. A PR baseline does not exercise every weekly observation path. Green observations and version-update PRs do not establish complete security-advisory coverage or upstream support status.

Validate a specific candidate version/digest/lockfile against the relevant integration and baseline checks, including cold installation when changing a download source or archive. An archive-cache hit does not verify that its download URL remains available. Investigate earlier failures rather than treating a successful retry as their explanation. Choose additional observation according to the change. Find a trusted replacement source before dropping supported coverage.

When changing Renovate rules, install Renovate in a disposable environment and run the validator plus the offline extraction/replacement regression. These checks exercise Renovate itself without modifying the checkout or contacting upstream services:

```sh
renovate-config-validator --strict renovate.json
node tests/renovate_test.mjs "$(command -v renovate)"
```

## Adding tests

New `tests/*_test.lua` files are picked up automatically by `make test`. Follow a nearby test such as [image_test.lua](image_test.lua), report meaningful assertion counts and return nonzero on failure. Browser/terminal integrations remain explicit commands with their own prerequisites. Keep the test at the cheapest layer that can observe the behavior: mock output, real tool/buffer state, terminal state or pixels.
