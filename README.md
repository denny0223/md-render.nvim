# md-render.nvim

**English** · [正體中文（台灣）](README.zh-TW.md) · [日本語](README.ja.md)

This fork of [delphinus/md-render.nvim](https://github.com/delphinus/md-render.nvim) adds an optional Snacks backend for static images and diagrams in Kitty/tmux, viewport fitting, and an image tab with zoom and pan. See the [Neovim configuration](https://github.com/denny0223/.nvim) for a complete setup.

A Markdown rendering engine for Neovim. Transforms raw Markdown into richly highlighted, interactive content — right inside your editor. Edit alongside a live preview with synchronized scrolling, read in a floating window or tab, or use the pager for `less`-like reading from the command line.

## Getting started

1. Check the [requirements](#requirements), then choose one [installation method](#installation).
2. To use this fork's Kitty/tmux support, viewport fitting, and image zoom/pan, follow the [Snacks image setup](#optional-snacks-image-backend). The basic installation keeps the native backend, which also supports animation and video.
3. Restart Neovim after installing and configuring the plugins, then open a Markdown file. Choose a workflow from its source window:

| Task | Command | Close the preview |
|---|---|---|
| Write with a live preview on the right | `:botright vert MdRender split` | Switch to the preview window, then run `:q` |
| Read in a tab | `:MdRender tab` | Press `q` |

The split keeps focus in the source window so you can keep editing; the preview updates without saving. In Normal mode, `<C-w>p` (Ctrl-w then p) selects the previous window; immediately after opening the split, that is the preview. The [keymap examples](#keymaps) include an optional `<leader>ms` shortcut.

With Snacks and `magick` configured, press Enter on a loaded image in the preview to open its [image tab](#image-tab-keys) for zoom and pan.

For the full [key reference](#keymaps), [commands](#commands), and [troubleshooting](#faq--troubleshooting), see below.

The complete [reference manual](doc/md-render.txt), including the library API, is also available inside Neovim with `:help md-render-contents@en`. Use `:help md-render-contents@tw` for Traditional Chinese (Taiwan), or `:help md-render-contents@ja` for Japanese.

<figure align="center">
  <img src="https://github.com/user-attachments/assets/6c51f971-84bb-49fe-aaff-21db40712187" width="900" height="685" alt="md-render.nvim showcase: inline formatting, tables, callouts, code blocks, images, video, and Mermaid diagrams" />
</figure>

## Highlights

- **Rich inline formatting** — bold, strikethrough, inline code, links, Obsidian `==highlight==`, all rendered in-place
- **Tables** — box-drawing borders, column alignment, proportional sizing, and inline formatting within cells
- **Callouts & folds** — GitHub and Obsidian alert types with colored borders, icons, and folding you can toggle by clicking or with `za` / `<CR>`
- **Code blocks** — fenced blocks with treesitter syntax highlighting; expandable when truncated (click or `za` / `<CR>`)
- **Images** — local and web images (PNG, JPEG, WebP, GIF, animated GIF) displayed inline via terminal graphics protocol
- **Video** — local and web video (MP4, WebM, MOV, AVI, MKV, M4V) played as animated frames inline
- **Mermaid diagrams** — rendered as images inline
- **PlantUML diagrams** — rendered as images inline by a local renderer, or by a server you name
- **CommonMark paragraphs** — soft-wrapped source lines join into one paragraph, including a list item's continuation lines and a blockquote body; no extra space is inserted between CJK characters
- **CJK spacing around inline markers** — the spaces in `これは **強調** です。`, written only so that lenient parsers notice the `**`, are closed up on screen; they stay when a neighbour is narrow, as in `これは **API** です。`
- **Nested block structure** — a blockquote, callout, or fenced code block indented to a list item's content is rendered in place, not as literal text
- **CJK-aware word wrapping** — JIS X 4051 kinsoku shori + optional [BudouX](https://github.com/google/budoux) phrase segmentation via [budoux.lua](https://github.com/delphinus/budoux.lua)
- **Clickable links** — mouse click to open URLs; hover the mouse over a link to peek the full URL in a subtle floating window; OSC 8 hyperlink support for compatible terminals
- **`<details>` support** — collapsible sections you can toggle by clicking or with `za` / `<CR>`, respecting the `open` attribute
- **Status footer** — the floating preview shows the file name, your position in the source, and a box-drawing progress bar on its bottom border, without stealing a content row or touching your statusline
- **Library API** — use the rendering engine programmatically from your own plugins

<figure align="center">
  <img src="assets/screenshot-rendering.png" width="672" height="751" alt="Inline formatting, tables, callouts, code blocks, and CJK line-breaking" />
  <figcaption><em>Static preview: inline formatting, tables, callouts, code blocks, and CJK line-breaking</em></figcaption>
</figure>

## Try it yourself

After [installing and configuring the plugin](#installation), you can open the bundled showcase with the pager. Cloning the repository alone does not install the plugin into Neovim:

```bash
git clone https://github.com/denny0223/md-render.nvim
cd md-render.nvim
nvim +"MdRender pager" assets/showcase.md
```

Or, once the plugin is installed, run `:MdRender demo` to see a built-in demo of every supported notation.

## Requirements

- Neovim >= 0.12 (uses `vim.api.nvim_ui_send` for terminal writes)
- For inline images and video with the default native backend (`kitty`): a terminal supporting the [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/).
  Verified on [WezTerm](https://wezfurlong.org/wezterm/), [Kitty](https://sw.kovidgoyal.net/kitty/), and [Ghostty](https://ghostty.org/) (macOS/Linux).
- The optional [Snacks backend](#optional-snacks-image-backend) also requires Unicode placeholders. Its documented setup targets Kitty, directly or inside tmux.

<details>
<summary><strong>Dependencies by feature</strong></summary>

These dependencies are optional for basic Markdown rendering, but required for the features that use them. Plugin managers install Neovim plugins; install command-line tools separately and make them available on Neovim's `$PATH`.

| Dependency | Purpose | Fallback |
|---|---|---|
| [curl](https://curl.se/) | Download web images and video | Custom function via `set_download_fn()` |
| [snacks.nvim](https://github.com/folke/snacks.nvim) | Optional image backend, viewport fitting, and focused image tabs | Default native backend remains available; it does not provide these fork features |
| [FFmpeg](https://ffmpeg.org/) (`ffmpeg` / `ffprobe`) | Native JPEG/WebP → PNG conversion; GIF / video frame extraction for both backends | Falls back to ImageMagick (images only; video requires ffmpeg) |
| [ImageMagick](https://imagemagick.org/) (`magick`) | Snacks image conversion and image-tab zoom/pan; native image conversion and shared GIF frame extraction | Native conversion can use the tools below. The image tab requires `magick`, including for PNG; `ffmpeg`, `sips`, or an installation providing only `convert` cannot replace it |
| [Mermaid CLI](https://github.com/mermaid-js/mermaid-cli) (`mmdc`) and its headless browser | Render Mermaid diagrams with either backend | Falls back to `npx -y @mermaid-js/mermaid-cli` (requires Node.js/npm and may download the CLI); the browser is still required |
| [PlantUML](https://plantuml.com/) (`plantuml`, or `java` with `$PLANTUML_JAR`) | Render PlantUML diagrams as images | A PlantUML server, if you name one (needs curl); otherwise the fence stays a code block |
| [budoux.lua](https://github.com/delphinus/budoux.lua) | CJK phrase-level line breaking (BudouX) | Character-level splitting (kinsoku rules still apply) |
| Treesitter parsers | Syntax highlighting in code blocks | Code blocks rendered without highlighting |
| [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) or [mini.icons](https://github.com/echasnovski/mini.icons) | File type icons in code block headers | Built-in icon table |

Static conversion in the **native backend** and frame extraction in both backends try tools in this order. [Snacks conversion](https://github.com/folke/snacks.nvim/blob/main/docs/image.md) uses ImageMagick for static non-PNG images.

| Use case | 1st | 2nd | 3rd |
|---|---|---|---|
| Static image conversion (JPEG/WebP → PNG) | `sips` (macOS) | `ffmpeg` | `magick` |
| Animated GIF frame extraction | `ffmpeg` | `magick` | — |
| Video frame extraction | `ffmpeg` | — | — |

</details>

## Installation

The examples below use the default native backend (`kitty`). For Kitty/tmux images, viewport fitting, and zoom/pan, follow [Optional Snacks image backend](#optional-snacks-image-backend) as well. Use this fork's default branch: its inherited upstream release tags do not include those features, so the lazy.nvim examples use `version = false`.

### lazy.nvim

```lua
{
  "denny0223/md-render.nvim",
  version = false,
  cmd = "MdRender",
  dependencies = {
    { "nvim-tree/nvim-web-devicons", version = "*" }, -- optional: file type icons in code blocks
    { "delphinus/budoux.lua", version = "*" }, -- optional: CJK phrase-level line breaking
  },
  keys = {
    { "<leader>ms", "<cmd>botright vert MdRender split<CR>", desc = "Open Markdown preview on the right" },
    { "<leader>mp", "<Plug>(md-render-preview)",     desc = "Markdown preview (toggle)" },
    { "<leader>mt", "<Plug>(md-render-preview-tab)", desc = "Markdown preview in tab (toggle)" },
    { "<leader>md", "<Plug>(md-render-demo)",        desc = "Markdown render demo" },
  },
}
```

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add({
  "https://github.com/denny0223/md-render.nvim",
  -- optional:
  "https://github.com/nvim-tree/nvim-web-devicons",
  "https://github.com/delphinus/budoux.lua",
})
```

### mini.deps

```lua
local add = MiniDeps.add
add({
  source = "denny0223/md-render.nvim",
  depends = {
    "nvim-tree/nvim-web-devicons", -- optional
    "delphinus/budoux.lua",        -- optional
  },
})
```

### Optional Snacks image backend

This setup enables static images, diagrams, viewport fitting, and focused image tabs. It requires:

- [snacks.nvim](https://github.com/folke/snacks.nvim), loaded and configured before opening an md-render preview.
- Kitty with Unicode placeholder support. Inside tmux, add `set -g allow-passthrough on` to your tmux configuration and reload it. Other terminals supported by Snacks have not been verified with this integration; the native backend's terminal list above does not establish Snacks compatibility.
- ImageMagick with the `magick` command on Neovim's `$PATH` for the complete image workflow, including zoom/pan. Installing only FFmpeg or `sips` is insufficient.
- For Mermaid, the Mermaid CLI (`mmdc`, or the `npx` fallback) and its headless browser. Snacks handles image display; it does not replace the diagram renderer. No browser window is opened.

For lazy.nvim, use this in place of the basic md-render spec above. Keep the optional icon/BudouX dependencies if you use them:

```lua
{
  "denny0223/md-render.nvim",
  version = false,
  cmd = "MdRender",
  dependencies = {
    {
      "folke/snacks.nvim",
      lazy = false,
      priority = 1000,
      opts = {
        image = {
          enabled = true,
          doc = { enabled = false },
          math = { enabled = false },
        },
      },
    },
  },
  config = function()
    require("md-render.image").setup({ backend = "snacks" })
  end,
  keys = {
    { "<leader>ms", "<cmd>botright vert MdRender split<CR>", desc = "Open Markdown preview on the right" },
    { "<leader>mp", "<Plug>(md-render-preview)",     desc = "Markdown preview (toggle)" },
    { "<leader>mt", "<Plug>(md-render-preview-tab)", desc = "Markdown preview in tab (toggle)" },
    { "<leader>md", "<Plug>(md-render-demo)",        desc = "Markdown render demo" },
  },
}
```

For vim.pack, add `"https://github.com/folke/snacks.nvim"` to the `vim.pack.add()` list. For mini.deps, add `"folke/snacks.nvim"` to md-render's `depends` list. After both plugins have loaded, configure them in this order:

```lua
require("snacks").setup({
  image = {
    enabled = true,
    doc = { enabled = false },
    math = { enabled = false },
  },
})
require("md-render.image").setup({ backend = "snacks" })
```

If you already configure Snacks, merge these `image` options into its existing configuration; do not call `setup()` a second time. Disabling Snacks' document and math rendering lets md-render own the Markdown preview; those Snacks features are not needed by this integration.

After loading the plugins, check the setup:

1. Run `:checkhealth snacks`. Check that `:echo executable('magick')` returns `1` and `:lua print(require("md-render.image").config().backend)` prints `snacks`.
2. Inside tmux, `tmux show-options -gv allow-passthrough` should print `on`.
3. In Kitty, open a Markdown file containing a local PNG and run `:MdRender tab`. Wait for the image to appear, place the cursor on it or its title, and press Enter to verify that its image tab opens. Tool availability alone does not verify terminal display.

Both backends play animated GIFs and videos. The Snacks backend uses Kitty animation support, including inside tmux; video frame extraction requires `ffmpeg`. The Snacks backend prepares images throughout the document, including off-screen images; diagram rendering, downloads, and frame extraction share a two-job limit across previews, and work already running may finish into the cache after closing a preview. Image-heavy documents therefore do more work up front.

Automatic layout uses the available window width instead of the native backend's 80-column cap. Images fit proportionally within that width and the window height minus six rows, without enlarging beyond their original pixel size. An explicitly supplied `max_width` still takes precedence. See [Image tab keys](#image-tab-keys) for navigation.

## Comparison with similar plugins

<details>
<summary><strong>Why not other Markdown previewers?</strong></summary>

- **[markdown-preview.nvim](https://github.com/iamcco/markdown-preview.nvim)** — Excellent for true browser-quality rendering, but requires a browser context. md-render runs entirely inside the terminal.
- **[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)** — Beautiful in-buffer rendering, but modifies the editing buffer itself. md-render keeps your editing buffer untouched and renders into a separate floating/tab window or pager view.
- **[mcat](https://github.com/Skardyy/mcat)** — Closest in spirit (a pure-terminal Markdown renderer), but lacks complex layout features like auto-folding tables, click-to-toggle folds, and CJK word wrapping.

md-render.nvim aims to be a dedicated previewer that runs entirely in the terminal, with rich layout support and first-class CJK handling.

</details>

## Keymaps

The plugin provides `<Plug>` mappings but does **not** set any default keybindings. Map them yourself:

```lua
vim.keymap.set("n", "<leader>ms", "<cmd>botright vert MdRender split<CR>", { desc = "Open Markdown preview on the right" })
vim.keymap.set("n", "<leader>mp", "<Plug>(md-render-preview)",     { desc = "Markdown preview (toggle)" })
vim.keymap.set("n", "<leader>mt", "<Plug>(md-render-preview-tab)", { desc = "Markdown preview in tab (toggle)" })
vim.keymap.set("n", "<leader>md", "<Plug>(md-render-demo)",        { desc = "Markdown render demo" })
```

Use the `<leader>ms` example from the Markdown source window to open a preview on the right. Each invocation opens a new window; see [Source/render split](#sourcerender-split) for navigation and closing.

| `<Plug>` mapping | Description |
|---|---|
| `<Plug>(md-render-preview)` | Toggle a floating preview window for the current Markdown buffer |
| `<Plug>(md-render-preview-tab)` | Toggle a tab preview for the current Markdown buffer |
| `<Plug>(md-render-toggle)` | Toggle the current window between source and render mode in place |
| `<Plug>(md-render-auto)` | **[experimental]** Toggle auto mode (render outside Insert) for the current buffer |
| `<Plug>(md-render-split)` | Open a split showing source and rendered Markdown |
| `<Plug>(md-render-demo)` | Show a demo window with all supported Markdown notations |

### In-preview keys

Inside a rendered preview (floating, tab, split, or in-place toggle), these buffer-local keys are set automatically:

| Key | Action |
|---|---|
| `za` | Toggle the fold / expandable region under the cursor (no-op elsewhere) |
| `<CR>` | Open the image under the cursor (Snacks backend), or toggle a fold / expandable region |
| `gf` | Follow the local file link under the cursor; Markdown targets stay rendered |
| `<LeftMouse>` | Toggle folds, expand regions, and open links by clicking |
| `q` / `<Esc>` / `<C-c>` | Close the window (floating / tab mode only) |

`gf` resolves the link destination relative to its source Markdown file, independently of the working directory. Markdown targets keep the current preview window; other files open for editing in the original source window, closing floating/tab previews. `Ctrl-O` returns to the preceding rendered document with its reading position and folds; after editing another file, that rendered return uses the source window. Outside a link, native `gf` and counts such as `2gf` still work.

Directories open in the original source window through the configured directory browser (such as netrw), closing floating/tab previews. The browser retains its own navigation and buffer lifecycle.

`Ctrl-O` and `Ctrl-I` remain native Neovim commands. Each window keeps its own jumplist: after opening another file in the source editing window, only the immediately preceding rendered document is guaranteed on return. Earlier preview history is not merged into that window.

Local links support relative paths, POSIX absolute paths, and `file:///` URLs, including encoded filenames, inline/reference links, and optional titles. Missing or unreadable files leave the preview unchanged. Fragments do not yet select a heading; pager navigation and Windows/UNC paths are outside this feature's initial scope.

### Image tab keys

With the [Snacks backend](#optional-snacks-image-backend) configured and ImageMagick (`magick`) installed, press Enter on an image or its title to open a focused image tab. Use arrows or `hjkl` to move, `+/-` to zoom, `f` to fit the complete image, and `q` to return. These keys are set automatically in the image tab.

GIF and video tabs require Kitty 0.31 or newer and play automatically. Press Space to pause or resume; zooming and panning preserve the playback state. Playback controls affect only the image tab.

Scroll the mouse wheel to zoom, or hold the left mouse button and drag to move the image. Vim-style navigation, Page Up/Down, Home/End, and counts are also supported. Press `?` or use `:help md-render-image-view` for the [complete reference](doc/md-render.txt).

Zoom uses the converted image's existing pixels; it does not regenerate a higher-resolution diagram.

## Commands

The plugin exposes a single `:MdRender` command with subcommands:

| Command | Description |
|---|---|
| `:MdRender` | Floating preview window (alias of `:MdRender float`) |
| `:MdRender float` | Toggle a floating preview window |
| `:MdRender tab` | Toggle a tab preview |
| `:MdRender toggle` | Toggle the current window between source and render mode in place |
| `:MdRender split` | Open a split showing source and rendered Markdown (honours `:vert`, `:tab`, `:topleft`, `:botright`) |
| `:MdRender auto [on\|off\|toggle]` | **[experimental]** Auto-toggle source/render based on Insert mode (per buffer) |
| `:MdRender textsize [on\|off\|toggle\|auto\|image\|native\|status]` | **[experimental]** Scale headings with auto selection, native text or images; inspect the active backend |
| `:MdRender pager` | Pager mode — full-screen, no chrome, `q` to quit Neovim |
| `:MdRender demo` | Show a demo window with all supported Markdown notations |

Tab completion lists the subcommands for the first arg, `on` / `off` / `toggle` after `auto` and `textsize`, and `auto` / `image` / `native` / `status` after `textsize`.

> **Backwards compatibility.** The legacy top-level commands (`:MdRenderTab`, `:MdRenderToggle`, `:MdRenderSplit`, `:MdRenderAuto`, `:MdRenderPager`, `:MdRenderDemo`) still work and forward to the new dispatcher. They print a one-shot deprecation warning per Neovim session and will be removed in a future major version.

### In-place toggle

`:MdRender toggle` swaps the current window between the source Markdown buffer and a rendered view of it — without opening a new tab or floating window. This is designed for split layouts where you want, for example, code in one split and the rendered README in the other.

```vim
:vsplit README.md
:MdRender toggle
```

Behavior:

- The render buffer is **read-only** and reused across toggles (one render buffer per source).
- When the same source is shown in multiple windows, only the invoking window swaps. Edits from other windows update the preview automatically.
- Cursor position round-trips between source and render via the source-line mapping.
- `number`, `relativenumber`, and `list` are turned off on render-mode windows. The originals are stashed on the window and restored when toggling back to source.
- Inside render mode, `q` / `<Esc>` / `<C-c>` are **not** bound to close — call `:MdRender toggle` again to return to source mode. `<LeftMouse>`, `za`, and `<CR>` still toggle folds and expand regions (and `<LeftMouse>` opens links). With the Snacks backend, `<CR>` also opens images.

### Auto-toggle on Insert mode (experimental)

> **Experimental.** This feature is new and the UX may change. Please report issues or rough edges.

`:MdRender auto on` keeps the current buffer in render mode while in Normal mode and swaps back to source automatically when you start editing. Pass `off` to disable, or call `:MdRender auto` (or `:MdRender auto toggle`) to toggle. To opt every Markdown buffer in:

```vim
autocmd FileType markdown silent! MdRender auto on
```

See `:help :MdRender-auto` for behavior details — the `i` / `I` / `a` / `A` / `o` / `O` remaps, `:w` forwarding, and the editing operations that are blocked on the read-only render buffer.

### Scaled headings (experimental)

Headings default to `auto`: **image → native OSC 66 → ordinary text**. Use `:MdRender textsize status` to check the active backend and fallback reason. After fixing the environment, run `:MdRender textsize auto` to retry.

| Mode | H1 | H2 | H3 | H4 | H5 | H6 |
|---|---|---|---|---|---|---|
| Image | 2× | 1.5× | 1.25× | 1× | 0.875× | 0.85× |
| Native | 2× | 1.75× | 1.5× | 1.4× | 1.25× | 1.17× |

Image and native layouts omit level icons and use a single rule below H1/H2. Ordinary-text layouts retain `#` through `######`, left-aligned within their container, with a double rule below H1 and a single rule below H2.

#### Try image headings

Run `:MdRender textsize image`, then `:MdRender toggle` to open a preview. Images require Neovim >= 0.12, confirmed terminal PNG support (Kitty >= 0.28), `termguicolors`, Python 3, PyGObject, Pycairo and Pango/PangoCairo. Install the Python packages and fonts on the Neovim host. Explicit `image` mode uses ordinary text when unavailable.

To change the font or base size:

```lua
require("md-render.text_size").setup {
  backend = "auto",
  image = { font = "Noto Sans Mono,Noto Sans Mono CJK TC", font_size = "auto", python = "python3" },
}
```

`font_size = "auto"` fits the font to the terminal cells; a positive pixel value overrides it. Images follow your heading and inline highlights. Unsupported glyphs/styles and headings inside `<details>` retain text. After changing fonts, run `:MdRender textsize image` to refresh.

Search, selection and cursor movement into a heading reveal the affected text without changing its layout or inserting markers. Internal anchors use ordinary clicks; external links also support the terminal shortcut (Ctrl+Shift+click in Kitty). For terminal text selection, use `:MdRender textsize off` or return to source with `:MdRender toggle`.

Image headings are disabled on Windows and through tmux. Linux with direct Kitty and SSH to Linux has been tested; other OS/client combinations and screen readers remain unverified.

#### Native text headings

Select `:MdRender textsize native` for Kitty >= 0.40 without image dependencies. Native headings preserve inline styles and links, and wrap to their painted width. If the available width is too narrow for scaling, or a heading contains control characters such as tabs, the whole document uses ordinary headings to preserve its text and hierarchy. Search, selection and unsupported highlights can still reveal individual headings as text.

Moving the cursor through a heading’s margin keeps it enlarged, including with `cursorline`. Entering its text reveals ordinary text for accurate cursor positioning and keyboard link actions.

Native headings reserve two rows per wrapped line. Scrolling or overlapping windows may briefly reveal plain text, and redraws can be more expensive. Telescope and Snacks picker previews do not use native scaling. See `:help md-render-text-size` for troubleshooting.

**Kitty through tmux:** native headings support one attached Kitty client with `set -g allow-passthrough on` (or `all`, including Snacks) and `set -g focus-events on`. Reattach after changing focus reporting. The plugin reads tmux's terminal identification and pane geometry without changing tmux settings or sending version queries into pane input. Only the focused pane is enlarged: popups, copy mode and focus loss leave ordinary text, and returning restores enlargement automatically without switching backends. External redraws use the existing 500 ms recovery timer.

To prevent cursor movement from flashing ordinary headings, native tmux previews temporarily disable Neovim’s global `termsync`, affecting all windows in that Neovim process. The previous value returns when the last preview with enlarged headings closes or falls back, unless you explicitly changed it. tmux still batches its own terminal updates.

Start Neovim in the foreground and keep focus reporting enabled. Starting underneath an existing popup, suppressing `FocusLost`/`FocusGained`, and guaranteeing zero transient frames during tmux transitions are outside this support boundary. Multiple clients, linked windows, nested multiplexers and cropped windows retain ordinary text; `:MdRender textsize status` explains fallback or a focus pause.

Tested on Linux with Kitty 0.48.2, tmux 3.7c and Neovim 0.12.5, locally and through a loopback SSH PTY. Native headings can coexist with regular Snacks images; image-rendered headings through tmux remain separate work in [#11](https://github.com/denny0223/md-render.nvim/issues/11). `auto` can use the verified native backend instead.

Native fractional sizing can leave visible gaps between text runs, including CJK headings; this also occurs without tmux and is tracked in [upstream #65](https://github.com/delphinus/md-render.nvim/issues/65).

Use `:MdRender textsize off` to turn scaling off, or disable it in your configuration:

```lua
require("md-render.text_size").setup { enabled = false }
```

### Source/render split

<figure>
  <img src="https://github.com/user-attachments/assets/24999fe8-9ff0-4ca3-9bd1-b72ec5d7f33c" width="407" height="328" alt="Source/render split" />
  <figcaption><em>Source/render split — edits propagate live, including inline images</em></figcaption>
</figure>

To edit Markdown with a live preview on the right, run this from the source window:

```vim
:botright vert MdRender split
```

The preview opens at the far right of the current tab, including when other splits already exist. Focus stays in the source window. Edits appear without saving, and cursor/scroll position is synchronized in both directions.

In Normal mode, `<C-w>p` selects the previous window. Immediately after opening the split, this takes you to the preview. To close the preview, switch to its window and use `:q` or `<C-w>c`; plain `q` is not a close key in this mode.

Each invocation opens another window. From a source window it shows the preview; from a split or in-place preview it shows the source. Direction follows standard Vim split modifiers:

- `:MdRender split` — horizontal split
- `:vert MdRender split` — source and preview side by side; placement follows `splitright`
- `:tab MdRender split` — open the other view in a new tab
- `:topleft MdRender split` — place at the top
- `:botright MdRender split` — place at the bottom

See `:help :MdRender-split` for full behavior and the inline-image limitation.

### Pager mode

<figure>
  <img src="https://github.com/user-attachments/assets/3c8d94a2-7a7d-4d99-ac9c-1b69870fee67" width="682" height="446" alt="Pager mode" />
  <figcaption><em>Pager mode — browse Markdown like <code>less</code></em></figcaption>
</figure>

Use `:MdRender pager` to view Markdown files like `less`:

```bash
nvim +"MdRender pager" README.md
```

Add a shell alias for convenience:

```bash
alias mdless='nvim +"MdRender pager"'
mdless README.md
```

## Telescope Integration

<figure>
  <img src="https://github.com/user-attachments/assets/29fff5f5-d437-46d7-b92c-3d1a4bb21dd8" width="472" height="457" alt="Telescope integration" />
  <figcaption><em>Telescope previewer with md-render</em></figcaption>
</figure>

### Previewer

`require("md-render.telescope").previewer()` creates a previewer that can be
passed to any [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
picker — builtin, extension, or custom:

```lua
local previewer = require("md-render.telescope").previewer()

require("telescope.builtin").find_files({ previewer = previewer })
require("telescope").extensions.egrepify.egrepify({ previewer = previewer })
```

The previewer automatically handles three kinds of files:

| File type | Behavior |
|---|---|
| Markdown (`.md`, `.markdown`) | Full md-render rendering with highlights, links, and images |
| Image / Video (PNG, JPEG, WebP, GIF, MP4, ...) | Inline display via Kitty graphics protocol |
| Other files | Falls back to telescope's default previewer with syntax highlighting |

For grep-based pickers, the preview scrolls to the matched line.

### `:Telescope md_render` Extension

A shortcut for builtin pickers. Wraps `telescope.builtin` pickers with the
md-render previewer. All arguments are passed through:

```vim
:Telescope md_render find_files
:Telescope md_render live_grep cwd=~/notes
:Telescope md_render grep_string search=TODO
```

## Snacks.nvim Integration

`require("md-render.snacks").preview()` creates a preview function for
[snacks.nvim](https://github.com/folke/snacks.nvim) pickers. It handles the
same three file types as the telescope previewer (Markdown, image/video, and
fallback).

This picker integration is separate from the [Snacks image backend](#optional-snacks-image-backend). If Snacks is already configured, merge one of the following `picker` tables into that configuration instead of calling `setup()` again.

Configure it globally to apply to all pickers:

```lua
require("snacks").setup({
  picker = {
    preview = require("md-render.snacks").preview(),
  },
})
```

Or per-source:

```lua
require("snacks").setup({
  picker = {
    sources = {
      files = { preview = require("md-render.snacks").preview() },
      grep = { preview = require("md-render.snacks").preview() },
    },
  },
})
```

## FAQ / Troubleshooting

<details>
<summary><strong><code>:MdRender</code> is not an editor command</strong></summary>

Check that your plugin manager has installed and loaded `denny0223/md-render.nvim`. For lazy.nvim, keep `cmd = "MdRender"` in the spec so typing the command loads the plugin. Cloning the repository alone does not install it; follow [Installation](#installation), then restart Neovim.

</details>

<details>
<summary><strong>Images don't show — only their alt text or filenames appear</strong></summary>

With the default native backend, inline image display requires a terminal supporting the [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/), such as **WezTerm**, **Kitty**, or **Ghostty**. For Kitty inside tmux, use the [Snacks setup and checks](#optional-snacks-image-backend), including `allow-passthrough`. Enabling tmux passthrough alone does not add tmux support to the native backend.

</details>

<details>
<summary><strong>Videos appear as a single static frame</strong></summary>

Both backends require `ffmpeg` in `$PATH` for video frame extraction. The Snacks backend plays those frames in Kitty, including inside tmux. Without it, the plugin falls back to displaying just the first frame as a still image. Install it via your package manager (e.g. `brew install ffmpeg`).

</details>

<details>
<summary><strong>Enter does not open an image tab</strong></summary>

Use a document preview such as `:MdRender tab`, select the [Snacks backend](#optional-snacks-image-backend), and check that `:echo executable('magick')` returns `1`. Wait for the image to finish loading, then place the cursor on it or its title before pressing Enter. The built-in `:MdRender demo` window does not provide this image-opening action.

</details>

<details>
<summary><strong>Mermaid diagrams don't render</strong></summary>

Mermaid rendering requires the `mmdc` binary from [@mermaid-js/mermaid-cli](https://github.com/mermaid-js/mermaid-cli). If `mmdc` isn't installed globally, the plugin falls back to `npx -y @mermaid-js/mermaid-cli`, which is significantly slower on first invocation. Install it globally with `npm install -g @mermaid-js/mermaid-cli` for faster rendering.

</details>

<details>
<summary><strong>PlantUML diagrams don't render</strong></summary>

Fenced blocks tagged `plantuml` or `puml` are rendered locally when a `plantuml` binary is on your `PATH` (most package managers ship one), or when `java` is available and `$PLANTUML_JAR` points at a readable `plantuml.jar`. Install one of those and the fence becomes a diagram.

There is no fallback unless you ask for one. PlantUML renders on a server by design, and rendering on somebody else's means sending the diagram there, so the plugin will not choose that for you — without a local renderer, a `plantuml` fence stays a code block. Name a server and it will be used:

```lua
require("md-render.image").setup {
  -- Your own instance, or "https://www.plantuml.com/plantuml" for the public
  -- one. Either way the diagram source is sent there, so pick knowing that.
  plantuml_server = "https://plantuml.example.com/plantuml",
}
```

The server also needs `curl`. Rendered diagrams are cached under `stdpath("cache")/md-render/plantuml`, keyed by the diagram source, so a diagram is only sent once.

</details>

<details>
<summary><strong>Japanese text wrapping looks unnatural</strong></summary>

By default, md-render applies JIS X 4051 kinsoku shori (forbidden line-break rules) at the character level. For phrase-level segmentation that respects natural word boundaries in Japanese, install [budoux.lua](https://github.com/delphinus/budoux.lua) — the plugin will automatically detect and use it.

</details>

<details>
<summary><strong>The spaces around <code>**</code> disappeared in Japanese text</strong></summary>

That is deliberate. `これは **強調** です。` is usually written with those spaces so that a parser which only recognises a `**` surrounded by whitespace still sees the emphasis. CommonMark needs no such help — `これは**強調**です。` emphasises just fine — so once the markers are gone the spaces are pure markup and read as gaps. md-render closes them up when the characters on both sides are East Asian wide, the same rule it applies to the space CommonMark inserts at a soft line break.

A space next to a narrow character is left alone, so `これは **API** です。` and `これは **1** 番目` keep theirs. So does a space between two adjacent spans — in `**あ** **い**`, or in two links in a row, it is the only thing holding them apart on screen.

</details>

<details>
<summary><strong>Code blocks have no syntax highlighting</strong></summary>

Syntax highlighting requires the corresponding Treesitter parser to be available. Neovim bundles parsers for several languages, including Lua. Install additional parsers with [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter), or see `:help treesitter-parsers` for manual installation.

</details>

## Usage as a library

<details>
<summary><strong>Programmatic API</strong></summary>

Use the rendering engine to build highlighted content programmatically:

```lua
local md = require("md-render")

-- Render a single line of markdown
local text, highlights, links = md.Markdown.render("**bold** and [link](https://example.com)")

-- Build full document content
local ContentBuilder = md.ContentBuilder
local b = ContentBuilder.new()
b:render_document(lines, {
  max_width = 80,
  indent = "  ",
  repo_base_url = "https://github.com/user/repo",
  autolinks = {
    { key_prefix = "JIRA-", url_template = "https://jira.example.com/browse/JIRA-<num>" },
  },
})
local content = b:result()

-- Apply to a buffer
local buf = vim.api.nvim_create_buf(false, true)
local ns = vim.api.nvim_create_namespace("my_ns")
md.display_utils.apply_content_to_buffer(buf, ns, content)

-- Display images (requires a Kitty Graphics Protocol compatible terminal)
-- Images are automatically cleaned up when the window is closed.
local win = vim.api.nvim_get_current_win()
md.display_utils.setup_images(win, content, ns)
```

</details>

## Development

### Running Tests

```bash
make test
```

This runs all `tests/*_test.lua` files via `nvim --headless`. New test files matching the `*_test.lua` pattern are picked up automatically.

## License

MIT — see [LICENSE](LICENSE).

`lua/md-render/vendor/` is third-party code kept verbatim under its own license:
a copy of Neovim's `vim.async` (Apache-2.0), which gives Neovim 0.12 the async
runtime 0.13 has built in. See [its README](lua/md-render/vendor/README.md).
