# md-render.nvim

[English](README.md) · **正體中文（台灣）** · [日本語](README.ja.md)

這是 [delphinus/md-render.nvim](https://github.com/delphinus/md-render.nvim) 的 fork，新增可選用的 Snacks 圖片後端，支援 Kitty/tmux 中的靜態圖片與圖表、自動配合視窗大小，以及可縮放、平移的圖片分頁。也可以參考這份 [Neovim 設定](https://github.com/denny0223/.nvim)作為完整設定範例。

這個 Neovim 外掛能將 Markdown 原始文字轉為有語法醒目提示、可互動的預覽，直接顯示在編輯器中。支援浮動視窗、分頁，以及從指令列啟動、類似 `less` 的分頁閱讀模式。

## 第一次使用

1. 先確認[系統需求](#系統需求)，再選擇一種[安裝方式](#安裝)。
2. 如果要使用這個 fork 的 Kitty/tmux 支援、自動調整圖片大小、縮放與平移，請完成 [Snacks 圖片後端設定](#選用-snacks-圖片後端)。基本安裝仍使用原生後端，也能播放動畫與影片。
3. 安裝並設定外掛後，重新啟動 Neovim。開啟 Markdown 檔案，執行 `:MdRender tab` 預覽，按 `q` 關閉預覽。設定好 Snacks 與 `magick` 後，在載入完成的圖片上按 Enter 可開啟圖片分頁；`+` / `-` 縮放、`hjkl` 平移、`f` 顯示完整圖片，`q` 回到文件。

完整的[按鍵說明](#按鍵設定)、[指令](#指令)與[疑難排解](#常見問題與疑難排解)請見下方。

包含函式庫 API 的[完整參考手冊](doc/md-render.twx)，也能在 Neovim 中以 `:help md-render-contents@tw` 開啟。英文版使用 `:help md-render-contents@en`，日文版使用 `:help md-render-contents@ja`。若想優先使用正體中文說明，可在 `init.lua` 設定 `vim.opt.helplang = { "tw", "en" }`；沒有翻譯的項目會使用英文。

<figure align="center">
  <img src="https://github.com/user-attachments/assets/6c51f971-84bb-49fe-aaff-21db40712187" width="900" height="685" alt="md-render.nvim 功能展示：行內格式、表格、提示區塊、程式碼區塊、圖片、影片與 Mermaid 圖表" />
</figure>

## 主要功能

- **行內格式**：粗體、刪除線、行內程式碼、連結，以及 Obsidian 的 `==醒目標示==`。
- **表格**：以框線字元繪製，支援欄位對齊、依比例調整寬度及儲存格內的行內格式。
- **提示區塊與摺疊**：支援 GitHub 與 Obsidian 的提示類型，具有彩色邊框與圖示，可用滑鼠、`za` 或 `<CR>` 切換摺疊。
- **程式碼區塊**：透過 Treesitter 提供語法醒目提示；內容被省略時，可用滑鼠、`za` 或 `<CR>` 展開。
- **圖片**：透過終端機圖形協定，在文件中顯示本機與網路圖片，包括 PNG、JPEG、WebP、GIF 與 GIF 動畫。
- **影片**：以連續影格在文件中播放本機與網路影片，包括 MP4、WebM、MOV、AVI、MKV、M4V。
- **Mermaid 圖表**：轉為圖片並顯示在文件中。
- **PlantUML 圖表**：使用本機繪圖工具，或由你指定的伺服器，產生圖片並顯示在文件中。
- **CommonMark 段落**：將原始檔中同一段落的換行合併，包含清單項目的後續文字與引用區塊；相鄰中日韓字元之間不會額外插入空白。
- **中日韓文字與行內標記的空白**：例如 `これは **強調** です。` 中，為了讓部分 Markdown 剖析器辨識標記而加入的空白，顯示時會移除；若相鄰字元是半形字元，如 `これは **API** です。`，則保留空白。
- **巢狀區塊**：縮排在清單項目內的引用、提示與程式碼區塊，會依結構顯示，不會被當成一般文字。
- **中日韓文字換行**：套用 JIS X 4051 行首行尾禁則，也可透過 [budoux.lua](https://github.com/delphinus/budoux.lua) 使用 [BudouX](https://github.com/google/budoux) 依詞組斷行。
- **可點擊的連結**：按滑鼠開啟網址；游標停留在連結上可預覽完整網址。相容的終端機也支援 OSC 8 超連結。
- **`<details>`**：支援可摺疊區塊，並遵循 `open` 屬性。
- **底部狀態列**：浮動預覽的下邊框會顯示檔名、原始文件中的位置與閱讀進度，不占用內容行，也不修改你的 statusline。
- **程式庫 API**：可以在其他外掛中直接使用 Markdown 繪製引擎。

<figure align="center">
  <img src="assets/screenshot-rendering.png" width="672" height="751" alt="行內格式、表格、提示區塊、程式碼區塊與中日韓文字換行" />
  <figcaption><em>靜態預覽：行內格式、表格、提示區塊、程式碼區塊與中日韓文字換行</em></figcaption>
</figure>

## 試用展示文件

完成[外掛安裝與設定](#安裝)後，可以用分頁閱讀模式開啟儲存庫內的展示文件。單純複製儲存庫，還不會將外掛安裝到 Neovim：

```bash
git clone https://github.com/denny0223/md-render.nvim
cd md-render.nvim
nvim +"MdRender pager" assets/showcase.md
```

安裝後也可以執行 `:MdRender demo`，檢視內建的 Markdown 語法展示。

## 系統需求

- Neovim >= 0.12，使用 `vim.api.nvim_ui_send` 寫入終端機。
- 預設的原生圖片後端（`kitty`）需要支援 [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) 的終端機，才能在文件中顯示圖片與影片。已在 [WezTerm](https://wezfurlong.org/wezterm/)、[Kitty](https://sw.kovidgoyal.net/kitty/) 與 [Ghostty](https://ghostty.org/) 的 macOS/Linux 環境驗證。
- 選用的 [Snacks 後端](#選用-snacks-圖片後端)還需要 Unicode 佔位字元支援。本文的設定方式以 Kitty 為對象，包含 Kitty 內執行 tmux 的情況。

<details>
<summary><strong>各功能需要的套件與工具</strong></summary>

基本的 Markdown 預覽不需要安裝所有項目，但使用特定功能時，對應的套件或工具就是必要條件。外掛管理器只會安裝 Neovim 外掛；指令列工具要另外安裝，並且能從 Neovim 的 `$PATH` 找到。

| 套件或工具 | 用途 | 替代方式或限制 |
|---|---|---|
| [curl](https://curl.se/) | 下載網路圖片與影片 | 可透過 `set_download_fn()` 提供自訂下載函式 |
| [snacks.nvim](https://github.com/folke/snacks.nvim) | 選用圖片後端、自動調整圖片大小與獨立圖片分頁 | 仍可使用預設原生後端，但不會有這些 fork 新增功能 |
| [FFmpeg](https://ffmpeg.org/)（`ffmpeg` / `ffprobe`） | 原生後端的 JPEG/WebP → PNG 轉換，以及兩個後端共用的 GIF 動畫與影片影格擷取 | 圖片可改用 ImageMagick；影片仍需要 ffmpeg |
| [ImageMagick](https://imagemagick.org/)（`magick`） | Snacks 圖片轉換、圖片分頁縮放與平移，以及原生圖片轉換與共用的 GIF 影格擷取 | 原生後端可使用下表的替代工具。圖片分頁即使開啟 PNG 也需要 `magick`，無法用 `ffmpeg`、`sips` 或只有 `convert` 指令的安裝取代 |
| [Mermaid CLI](https://github.com/mermaid-js/mermaid-cli)（`mmdc`）及其無頭瀏覽器 | 兩種後端都用它產生 Mermaid 圖表 | 找不到 `mmdc` 時會改用 `npx -y @mermaid-js/mermaid-cli`，需要 Node.js/npm，且可能下載 CLI；瀏覽器仍是必要條件 |
| [PlantUML](https://plantuml.com/)（`plantuml`，或 `java` 搭配 `$PLANTUML_JAR`） | 產生 PlantUML 圖表 | 只有在你指定伺服器時，才會改用該伺服器，並需要 curl；否則維持程式碼區塊 |
| [budoux.lua](https://github.com/delphinus/budoux.lua) | 使用 BudouX，讓中日韓文字依詞組換行 | 未安裝時依字元斷行，仍保留行首行尾禁則 |
| Treesitter 剖析器 | 程式碼區塊的語法醒目提示 | 未安裝時仍會顯示程式碼，但沒有語法醒目提示 |
| [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) 或 [mini.icons](https://github.com/echasnovski/mini.icons) | 程式碼區塊標題的檔案類型圖示 | 改用內建圖示表 |

**原生後端**的靜態圖片轉換，以及兩個後端共用的影格擷取，會依下列順序尋找工具。[Snacks 的轉換流程](https://github.com/folke/snacks.nvim/blob/main/docs/image.md)則使用 ImageMagick 處理非 PNG 靜態圖片。

| 用途 | 第一順位 | 第二順位 | 第三順位 |
|---|---|---|---|
| 靜態圖片轉換（JPEG/WebP → PNG） | `sips`（macOS） | `ffmpeg` | `magick` |
| GIF 動畫影格擷取 | `ffmpeg` | `magick` | — |
| 影片影格擷取 | `ffmpeg` | — | — |

</details>

## 安裝

以下基本範例使用預設的原生後端（`kitty`）。若要在 Kitty/tmux 中顯示圖片、自動調整大小，以及縮放和平移，請接著完成 [Snacks 圖片後端設定](#選用-snacks-圖片後端)。請使用這個 fork 的預設分支；沿用自上游的發行標籤不包含這些新增功能，因此 lazy.nvim 範例使用 `version = false`。

### lazy.nvim

```lua
{
  "denny0223/md-render.nvim",
  version = false,
  cmd = "MdRender",
  dependencies = {
    { "nvim-tree/nvim-web-devicons", version = "*" }, -- 選用：程式碼區塊的檔案類型圖示
    { "delphinus/budoux.lua", version = "*" }, -- 選用：中日韓文字依詞組換行
  },
  keys = {
    { "<leader>mp", "<Plug>(md-render-preview)",     desc = "切換 Markdown 浮動預覽" },
    { "<leader>mt", "<Plug>(md-render-preview-tab)", desc = "切換 Markdown 分頁預覽" },
    { "<leader>md", "<Plug>(md-render-demo)",        desc = "Markdown 功能展示" },
  },
}
```

### vim.pack（Neovim 0.12 以上）

```lua
vim.pack.add({
  "https://github.com/denny0223/md-render.nvim",
  -- 選用：
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
    "nvim-tree/nvim-web-devicons", -- 選用
    "delphinus/budoux.lua",        -- 選用
  },
})
```

### 選用 Snacks 圖片後端

這套設定能啟用靜態圖片、圖表、自動配合視窗大小，以及獨立圖片分頁。需要準備：

- [snacks.nvim](https://github.com/folke/snacks.nvim)：開啟 md-render 預覽前，必須先載入並完成設定。
- 支援 Unicode 佔位字元的 Kitty。如果在 tmux 內使用，請將 `set -g allow-passthrough on` 加入 tmux 設定檔並重新載入。Snacks 支援的其他終端機尚未在這個整合中驗證；上方原生後端的相容性清單不代表 Snacks 後端也已通過驗證。
- ImageMagick，而且 Neovim 的 `$PATH` 必須能找到 `magick`。完整的圖片功能，包括縮放與平移，都需要它；只安裝 FFmpeg 或 `sips` 並不足夠。
- 若要顯示 Mermaid 圖表，還需要 Mermaid CLI（`mmdc` 或替代的 `npx` 流程）及其無頭瀏覽器。Snacks 負責顯示圖片，不會取代圖表產生工具；執行時不會開啟瀏覽器視窗。

使用 lazy.nvim 時，請用以下範例取代上方基本安裝的 md-render 設定。如果原本有使用圖示或 BudouX，也請保留對應的相依外掛：

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
    { "<leader>mp", "<Plug>(md-render-preview)",     desc = "切換 Markdown 浮動預覽" },
    { "<leader>mt", "<Plug>(md-render-preview-tab)", desc = "切換 Markdown 分頁預覽" },
    { "<leader>md", "<Plug>(md-render-demo)",        desc = "Markdown 功能展示" },
  },
}
```

使用 vim.pack 時，將 `"https://github.com/folke/snacks.nvim"` 加入 `vim.pack.add()` 清單。使用 mini.deps 時，將 `"folke/snacks.nvim"` 加入 md-render 的 `depends` 清單。兩個外掛都載入後，再依序設定：

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

如果已經有 Snacks 設定，請把上述 `image` 選項合併到原本的設定，**不要呼叫第二次 `setup()`**。這裡停用 Snacks 自己的文件與數學式繪製，讓 Markdown 預覽交由 md-render 處理；這個整合不需要啟用那些 Snacks 功能。

外掛載入後，請確認設定：

1. 執行 `:checkhealth snacks`。確認 `:echo executable('magick')` 回傳 `1`，且 `:lua print(require("md-render.image").config().backend)` 顯示 `snacks`。
2. 如果使用 tmux，`tmux show-options -gv allow-passthrough` 應顯示 `on`。
3. 在 Kitty 中開啟含有本機 PNG 圖片的 Markdown 檔案，執行 `:MdRender tab`。等圖片出現後，將游標移到圖片或標題上，按 Enter 確認能開啟圖片分頁。找到工具不代表終端機一定能正確顯示，仍需完成這一步。

兩個後端都能播放 GIF 動畫與影片。Snacks 後端使用 Kitty 的動畫功能，也支援在 tmux 內播放；影片影格擷取需要 `ffmpeg`。Snacks 後端會準備整份文件的圖片，包括目前畫面外的圖片；所有預覽共用最多兩個圖表產生／下載／影格擷取工作，關閉預覽後，已經開始的工作仍可能繼續執行並寫入快取。因此，圖片較多的文件會有較多前置處理。

自動排版會使用視窗可用寬度，不套用原生後端的 80 欄上限。圖片保持長寬比，放入可用寬度與「視窗高度減 6 行」的範圍內，且不會超過原始像素大小。若明確指定 `max_width`，仍會優先使用該值。操作方式請見[圖片分頁按鍵](#圖片分頁按鍵)。

## 與其他外掛的比較

<details>
<summary><strong>與其他 Markdown 預覽工具有什麼不同？</strong></summary>

- **[markdown-preview.nvim](https://github.com/iamcco/markdown-preview.nvim)**：適合需要完整瀏覽器呈現效果的情境，但需要瀏覽器環境；md-render 的預覽介面在終端機內。
- **[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)**：直接美化正在編輯的緩衝區；md-render 保留編輯緩衝區，在另一個浮動視窗、分頁或分頁閱讀模式中呈現。
- **[mcat](https://github.com/Skardyy/mcat)**：同樣是純終端機 Markdown 閱讀工具，但未涵蓋 md-render 的表格自動摺疊、點擊切換摺疊及中日韓文字換行等組合功能。

md-render 的目標是在終端機內提供獨立的 Markdown 預覽，兼顧豐富排版與中日韓文字。

</details>

## 按鍵設定

外掛提供 `<Plug>` 對應，但**不會直接指定預設快捷鍵**。可自行設定：

```lua
vim.keymap.set("n", "<leader>mp", "<Plug>(md-render-preview)",     { desc = "切換 Markdown 浮動預覽" })
vim.keymap.set("n", "<leader>mt", "<Plug>(md-render-preview-tab)", { desc = "切換 Markdown 分頁預覽" })
vim.keymap.set("n", "<leader>md", "<Plug>(md-render-demo)",        { desc = "Markdown 功能展示" })
```

| `<Plug>` 對應 | 說明 |
|---|---|
| `<Plug>(md-render-preview)` | 開啟或關閉目前 Markdown 緩衝區的浮動預覽 |
| `<Plug>(md-render-preview-tab)` | 開啟或關閉目前 Markdown 緩衝區的分頁預覽 |
| `<Plug>(md-render-toggle)` | 在目前視窗切換原始文字與預覽 |
| `<Plug>(md-render-auto)` | **實驗性功能**：切換自動模式，離開插入模式時顯示預覽 |
| `<Plug>(md-render-split)` | 分割視窗，同時顯示原始文字與預覽 |
| `<Plug>(md-render-demo)` | 顯示支援的 Markdown 語法展示 |

### 預覽中的按鍵

浮動、分頁、分割視窗或原地切換的文件預覽，會自動設定以下緩衝區專用按鍵：

| 按鍵 | 動作 |
|---|---|
| `za` | 切換游標下區塊的摺疊／展開；其他位置不執行動作 |
| `<CR>` | 開啟游標下的圖片（Snacks 後端），或切換區塊的摺疊／展開 |
| `gf` | 跟隨游標下的本機檔案連結；Markdown 目標維持渲染 |
| `<LeftMouse>` | 點擊切換摺疊、展開區塊或開啟連結 |
| `q` / `<Esc>` / `<C-c>` | 關閉視窗，僅適用於浮動／分頁預覽 |

`gf` 依連結所在 Markdown 檔案的目錄解析目的地，不受工作目錄影響。Markdown 目標沿用目前的預覽視窗；其他檔案在原始編輯視窗開啟，浮動／分頁預覽會先關閉。`Ctrl-O` 返回前一份渲染文件，保留閱讀位置與摺疊狀態；從其他檔案返回時，會在原始編輯視窗恢復渲染。游標不在連結上時，仍使用原生 `gf`，也支援 `2gf` 等數字前綴。

目錄會在原始編輯視窗交給已設定的目錄瀏覽器（例如 netrw）開啟，浮動／分頁預覽會先關閉。目錄畫面的導覽與緩衝區生命週期沿用該瀏覽器的行為。

`Ctrl-O` 與 `Ctrl-I` 維持 Neovim 原生行為。每個視窗各自保留 jumplist：在來源編輯視窗開啟其他檔案後，只保證返回緊接在前的渲染文件；較早的預覽歷史不會合併到該視窗。

本機連結支援相對路徑、POSIX 絕對路徑與 `file:///` URL，包含編碼檔名、行內／參照連結及選用標題。檔案不存在或無法讀取時會留在原預覽。Fragment 目前不會定位到標題；pager 導覽與 Windows／UNC 路徑不在首版支援範圍。

### 圖片分頁按鍵

完成 [Snacks 後端](#選用-snacks-圖片後端)設定並安裝 ImageMagick（`magick`）後，在圖片或其標題上按 Enter，即可開啟獨立圖片分頁。使用方向鍵或 `hjkl` 移動、`+/-` 縮放、`f` 顯示完整圖片、`q` 返回。這些按鍵會自動設定在圖片分頁內。

GIF 與影片分頁需要 Kitty 0.31 以上版本，開啟後會自動播放，按空白鍵可暫停或繼續；縮放與平移會維持目前的播放狀態。播放控制只影響圖片分頁。

滑鼠滾輪可縮放圖片，按住左鍵拖曳可移動圖片。也支援 Vim 風格導覽、Page Up／Down、Home／End 與數字前綴。按 `?` 或使用 `:help md-render-image-view` 查閱[完整操作說明](doc/md-render.twx)。

縮放使用轉換後圖片既有的像素，不會重新產生更高解析度的圖表。

## 指令

外掛使用單一 `:MdRender` 指令，搭配子指令選擇功能：

| 指令 | 說明 |
|---|---|
| `:MdRender` | 浮動預覽，等同 `:MdRender float` |
| `:MdRender float` | 開啟或關閉浮動預覽 |
| `:MdRender tab` | 開啟或關閉分頁預覽 |
| `:MdRender toggle` | 在目前視窗切換 Markdown 原始文字與預覽 |
| `:MdRender split` | 分割視窗，同時顯示原始文字與預覽；支援 `:vert`、`:tab`、`:topleft`、`:botright` |
| `:MdRender auto [on\|off\|toggle]` | **實驗性功能**：依插入模式自動切換原始文字／預覽，各緩衝區分別設定 |
| `:MdRender textsize [on\|off\|toggle\|image\|native]` | **實驗性功能**：放大標題，可選原生文字（預設）或圖片渲染 |
| `:MdRender pager` | 全螢幕分頁閱讀模式，隱藏介面裝飾，按 `q` 離開 Neovim |
| `:MdRender demo` | 顯示內建 Markdown 語法展示 |

輸入第一個參數時可用 Tab 補齊子指令；`auto` 與 `textsize` 後會提供 `on`、`off`、`toggle`，`textsize` 另有 `image`、`native`。

> **舊版相容性：** `:MdRenderTab`、`:MdRenderToggle`、`:MdRenderSplit`、`:MdRenderAuto`、`:MdRenderPager`、`:MdRenderDemo` 等舊指令仍可使用，會轉交給新的子指令。每次 Neovim 工作階段中，首次呼叫會顯示淘汰提示；未來主要版本將移除這些舊指令。

### 在原視窗切換預覽

`:MdRender toggle` 會在目前視窗切換 Markdown 原始緩衝區與其預覽，不另外開啟分頁或浮動視窗。適合在分割畫面中，一邊編輯程式碼、一邊閱讀 README。

```vim
:vsplit README.md
:MdRender toggle
```

行為如下：

- 預覽緩衝區是**唯讀**的，同一份來源會重複使用同一個預覽緩衝區。
- 同一份來源若同時出現在多個視窗，只會切換執行指令的視窗；其他視窗中的編輯，會在下次切換到預覽時反映。
- 游標透過來源行對應，在原始文字與預覽之間保留位置。
- 預覽視窗會關閉 `number`、`relativenumber` 與 `list`，原本設定會保存在視窗中，切回原始文字時還原。
- 在這種預覽模式中，`q` / `<Esc>` / `<C-c>` **不會用來關閉視窗**；請再次執行 `:MdRender toggle` 回到原始文字。`<LeftMouse>`、`za`、`<CR>` 仍能切換摺疊與展開，`<LeftMouse>` 也能開啟連結；Snacks 後端的 `<CR>` 還能開啟圖片。

### 隨插入模式自動切換

> **實驗性功能：** 操作方式仍可能調整。歡迎回報問題或不順手的地方。

`:MdRender auto on` 會在一般模式顯示目前緩衝區的預覽，開始編輯時自動切回原始文字。使用 `off` 停用，或執行 `:MdRender auto`／`:MdRender auto toggle` 切換。若要在所有 Markdown 緩衝區啟用：

```vim
autocmd FileType markdown silent! MdRender auto on
```

完整行為請見 `:help :MdRender-auto`，包括 `i` / `I` / `a` / `A` / `o` / `O` 的按鍵對應、`:w` 轉送，以及唯讀預覽緩衝區中被停用的編輯操作。

### 放大標題

#### 試用圖片標題

執行 `:MdRender textsize image`，再照常用 `:MdRender toggle` 開啟預覽；已開啟的預覽會立即更新。`:MdRender textsize native` 恢復 OSC 66 標題，`:MdRender textsize off` 則顯示一般大小的文字。

這個實驗後端以 [Pango](https://www.pango.org/)／[Cairo](https://www.cairographics.org/) 在六級字型大小下排出自然字距，需要 Python 3、PyGObject、Pycairo，以及 Pango/PangoCairo 與 Cairo 的 introspection 資料。缺少套件時保留一般文字。字型與基準像素大小可設定為：

```lua
require("md-render.text_size").setup {
  backend = "image",
  image = { font = "Noto Sans Mono,Noto Sans Mono CJK TC", font_size = "auto", python = "python3" },
}
```

預設 `"auto"` 會依終端格子的大小校準指定字型，保留六級不同的字級倍率；也可指定正的像素值。Pango 量測換行與字形位置，同一份位元組範圍會用於 buffer 文字、行內樣式與連結定位。排版在背景產生，預覽開啟期間會重用結果。

懸停時圖片保持原位。單擊依可見字形定位，包含圖片下半列，再交由既有連結處理器操作。游標沿標題左側空白或圖示移動時保留圖片；進入圖片範圍時，該段顯示文字，確保游標位置正確。拖曳從按下時的字元開始選取，Visual 選取只讓選取經過的標題列顯示文字。使用者設定的 yank 或其他高亮也會讓涵蓋的列暫時顯示文字，依高亮原本的持續時間恢復圖片。搜尋命中的標題保留高亮，其他標題仍顯示圖片，也不會清除搜尋狀態。在其他視窗編輯時，可見預覽仍保留圖片；重新換行或切換後端時，會維持正在閱讀的原文段落與標題字元。背景重新排版會等到選取、待完成的操作指令、命令列輸入與 yank 高亮結束後才套用。

圖片沿用使用者的 `MdRenderH1`～`MdRenderH6` 與行內高亮群組，基本顏色來自 `Normal` 或 `NormalFloat`。未指定背景色時保留透明；只在顯示圖片的視窗遮住底下的字形，避免重影，buffer 文字與座標保持不變。顏色、背景、粗體、斜體、底線與刪除線保留 Markdown 樣式順序，並讓 `vim.hl.on_yank()` 等使用者高亮優先顯示。自訂反相、`nocombine`、透明混合、其他底線樣式或視窗專屬高亮會退回文字；缺字、字型尺寸過大、終端格線無法容納文字或連結目標，以及 `<details>` 內的標題，也保留文字。更換配色與終端尺寸時會更新排版；直接調整字型或高亮設定後，可用 `:MdRender textsize image` 手動更新並重試失敗的繪圖。繪圖錯誤可在 `:messages` 檢視。

**終端操作：** 使用 Shift＋拖曳選取，或以終端修飾鍵點擊 OSC 8 連結前，請先執行 `:MdRender textsize off`；操作後用 `:MdRender textsize image` 恢復圖片閱讀。終端操作不經過 Neovim，使用的是文字格座標，因此直接在圖片字形上進行終端選取或超連結點擊不在此後端的保證範圍。切換時會保留搜尋狀態。

**相容範圍：** 需要 Kitty >= 0.40、Neovim >= 0.12，並啟用 `termguicolors`；索引色模式保留文字。已在 Linux 上驗證直接執行 Kitty，以及透過 SSH PTY 連入 Linux。Python、Pango/Cairo 與指定字型需安裝於 Neovim 所在主機；PNG 資料經終端連線傳送，不需共用圖片檔案。其他作業系統／客戶端組合及 tmux 圖片標題尚未驗證。需要純文字畫面的終端工具或輔助科技可使用 `textsize off` 或原始 buffer；目前未進行螢幕閱讀器相容性實測。

#### 原生文字標題

> **實驗性功能，僅支援 Kitty：** 操作方式可能改變，也可能移除此功能。歡迎回報問題或不順手的地方。

Kitty 0.40 加入[文字大小協定](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/)（OSC 66），可以依基本字型大小的倍率繪製文字。md-render 用它為各層級標題設定不同大小：

| 層級 | `#` | `##` | `###` | `####` | `#####` | `######` |
|---|---|---|---|---|---|---|
| 大小 | 2.00 倍 | 1.75 倍 | 1.50 倍 | 1.40 倍 | 1.25 倍 | 1.17 倍 |

終端機支援時就會自動啟用，不需要另外設定。可用 `:MdRender textsize off` 關閉，或在設定中永久停用：

```lua
require("md-render.text_size").setup { enabled = false }
```

這組倍率是固定的。Kitty 的 `s=` 會放大文字占用的終端機格子，不只是字型，因此所有層級都使用 `s=2`，固定多占一行。小於兩倍的大小則透過分數縮放及各段文字的 `w=` 寬度設定達成。協定限制 `d` 最大為 15、`w` 最大為 7，因此最深層標題使用 1.17 倍，無法任意接近一般文字大小。

標題以一般寬度的 `1 / 倍率` 進行換行，讓各層級都能放大；換行後的每一行，各占用一個兩行高的區塊。

分數倍率的標題會拆成數段送出，每段都必須以整數格宣告寬度，但實際文字寬度未必是整數。為避免 Kitty 丟棄放不下的字元，寬度一律無條件進位；分段時優先選擇剛好整除的位置，否則選在空白後，讓多出的空間成為稍寬的字距，而不是單字中間的缺口。

Emoji 會獨立成段。對 Kitty 而言，宣告了寬度的一段文字是一個跨格字元，只使用一種字型繪製。如果 emoji 和一般文字放在同一段，可能連帶影響整段文字。原有測量在 Kitty 0.48 中發現：emoji 位於中間時，整段會變成缺字方框；位於開頭時，後方文字會被丟棄。獨立成段可正確顯示，但各段寬度的進位可能讓 emoji 兩側多一點空隙；如果標題因此放不下，就維持一般大小。`#` 層級只使用 `s=`，不宣告寬度，由 Kitty 自行拆分格子並逐格選擇字型，所以不受此限制。

放大的文字和行內圖片一樣，直接繪製到終端機，Neovim 並不知道它的存在。緩衝區內仍保留原本大小的標題，放大文字覆蓋在上方；終端機重繪時會暫時回到一般標題，而不是變成空白。`y`、`/`、`:w` 操作的仍是真正的文字。

已知限制：

- **僅支援 Kitty >= 0.40。** 外掛會透過 XTVERSION 詢問終端機身分，收到明確回覆才啟用。某些終端機會把 OSC 66 連同附帶文字一起丟棄，因此這裡採取嚴格偵測，避免標題消失。其他環境仍以一般大小顯示，不啟用此功能。
- 標題內的行內程式碼、連結、`==醒目標示==` 等格式，在放大時不保留原本顏色。
- 每個層級都預留兩行高，只有 `#` 會填滿。其他層級使用 `v=2` 垂直置中，避免沿用協定預設的靠上對齊；例如 `######` 只有 1.17 倍，靠上時下方幾乎會空出一整行。
- 層級圖示維持一般大小，但會獨立成段並置中，與標題對齊。使用 `n=1:d=2` 抵銷 `s=2` 的格子縮放。這也能避免 Nerd Font 圖示被裁切：這些圖示回報為一格寬，實際圖形卻更寬，若跟標題共用同一段，`󰉬` 可能只剩下「H」。獨立一段並設定 `w=1`，就能使用原本預留的兩格寬度。
- 如果標題的第二行超出視窗，會先維持一般大小，捲動進入可見範圍後才放大。
- 其他外掛強制重繪、訊息或彈出視窗覆蓋畫面、終端機因滑鼠捲動而搬移格子，都可能讓標題暫時恢復一般大小。外掛會依序透過三種方式補繪：捲動、調整大小、開關視窗時立即補繪；其他重繪由 decoration provider 在下一輪事件迴圈處理；其餘狀況交由 `SafeState` 限速處理，另有 500 毫秒計時器處理持續重繪的情況。圖片與放大標題都畫在 Neovim 格線之外，完整重繪會同時清掉兩者，因此任一方重繪時，也會通知另一方立即補上。
- **若其他外掛在 `eventignore = "all"` 的情況下重繪，至少會有一個畫面影格無法立即補回。** 這個設定會停用所有自動指令；decoration provider 不屬於自動指令，仍能在下一輪補繪，但中間會短暫恢復一般大小。已知例子是 [nvim-scrollview](https://github.com/dstein64/nvim-scrollview)：滑鼠移動時，它會在 `eventignore = "all"` 內反覆開啟、移動及關閉浮動視窗。原有測量在 15 秒內記錄到 308 次 `nvim_open_win`，卻只觸發一次 `WinNew`。若想在預覽期間停用它，可檢查 `b:md_render`；所有 md-render 預覽緩衝區都會設定這個標記。這種方式也能涵蓋多個預覽或使用者手動分割視窗的情況：

  ```lua
  local off = false
  vim.api.nvim_create_autocmd({ "WinNew", "WinClosed", "BufWinEnter" }, {
    callback = vim.schedule_wrap(function()
      local want = false
      for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.b[vim.api.nvim_win_get_buf(w)].md_render then
          want = true
          break
        end
      end
      if want ~= off then
        off = want
        vim.cmd(want and "ScrollViewDisable" or "ScrollViewEnable")
      end
    end),
  })
  ```

- 每次排版變動都需要完整畫面重繪，才能清除先前放大的文字，因此捲動成本會較高。視窗內也有圖片時，會利用圖片重繪清除舊畫面，再寫入放大的文字。
- Telescope 與 Snacks 的選取器預覽不啟用這個功能，避免每次移動游標都造成完整畫面重繪。

完整說明請見 `:help md-render-text-size`。

### 分割原始文字與預覽

<figure>
  <img src="https://github.com/user-attachments/assets/24999fe8-9ff0-4ca3-9bd1-b72ec5d7f33c" width="407" height="328" alt="分割視窗，同時顯示原始文字與預覽" />
  <figcaption><em>原始文字與預覽並排，編輯結果與行內圖片會即時更新</em></figcaption>
</figure>

`:MdRender split` 會分割視窗，同時顯示原始緩衝區與預覽。方向遵循 Vim 標準的視窗修飾指令：

- `:MdRender split`：上下分割。
- `:vert MdRender split`：左右分割，適合 README 與程式碼並排。
- `:tab MdRender split`：在新分頁中分割。
- `:topleft MdRender split`：放在頂端。
- `:botright MdRender split`：放在底端。

原始文字的編輯會即時反映，游標與捲動位置會雙向同步。完整行為與行內圖片限制，請見 `:help :MdRender-split`。

### 分頁閱讀模式

<figure>
  <img src="https://github.com/user-attachments/assets/3c8d94a2-7a7d-4d99-ac9c-1b69870fee67" width="682" height="446" alt="Markdown 分頁閱讀模式" />
  <figcaption><em>像使用 <code>less</code> 一樣閱讀 Markdown</em></figcaption>
</figure>

使用 `:MdRender pager`，即可像 `less` 一樣閱讀 Markdown 檔案：

```bash
nvim +"MdRender pager" README.md
```

也可以加入 shell 別名：

```bash
alias mdless='nvim +"MdRender pager"'
mdless README.md
```

## Telescope 整合

<figure>
  <img src="https://github.com/user-attachments/assets/29fff5f5-d437-46d7-b92c-3d1a4bb21dd8" width="472" height="457" alt="Telescope 與 md-render 整合" />
  <figcaption><em>在 Telescope 選取器中使用 md-render 預覽</em></figcaption>
</figure>

### 預覽器

`require("md-render.telescope").previewer()` 會建立預覽器，可交給 [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) 的內建、擴充或自訂選取器使用：

```lua
local previewer = require("md-render.telescope").previewer()

require("telescope.builtin").find_files({ previewer = previewer })
require("telescope").extensions.egrepify.egrepify({ previewer = previewer })
```

預覽器會自動處理三類檔案：

| 檔案類型 | 行為 |
|---|---|
| Markdown（`.md`、`.markdown`） | 完整 md-render 預覽，包含語法醒目提示、連結與圖片 |
| 圖片／影片（PNG、JPEG、WebP、GIF、MP4 等） | 透過 Kitty graphics protocol 顯示 |
| 其他檔案 | 使用 Telescope 預設的語法醒目提示預覽器 |

在 grep 搜尋類型的選取器中，預覽會捲動到符合搜尋結果的行。

### `:Telescope md_render` 擴充功能

這是內建選取器的簡便入口，會替 `telescope.builtin` 的選取器加上 md-render 預覽器，並傳遞所有參數：

```vim
:Telescope md_render find_files
:Telescope md_render live_grep cwd=~/notes
:Telescope md_render grep_string search=TODO
```

## Snacks.nvim 整合

`require("md-render.snacks").preview()` 會建立 [snacks.nvim](https://github.com/folke/snacks.nvim) 選取器使用的預覽函式。它和 Telescope 預覽器一樣，可處理 Markdown、圖片／影片，以及其他檔案的預設預覽。

這個選取器整合與 [Snacks 圖片後端](#選用-snacks-圖片後端)是不同功能。如果已經設定 Snacks，請將下方其中一種 `picker` 設定合併到原本的設定，避免再次呼叫 `setup()`。

套用到所有選取器：

```lua
require("snacks").setup({
  picker = {
    preview = require("md-render.snacks").preview(),
  },
})
```

或依來源分別設定：

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

## 常見問題與疑難排解

<details>
<summary><strong><code>:MdRender</code> 不是有效的編輯器指令</strong></summary>

請確認外掛管理器已安裝並載入 `denny0223/md-render.nvim`。使用 lazy.nvim 時，請保留 `cmd = "MdRender"`，讓輸入指令時能自動載入外掛。單純複製儲存庫不等於完成安裝；請依[安裝說明](#安裝)設定，再重新啟動 Neovim。

</details>

<details>
<summary><strong>圖片沒有顯示，只有替代文字或檔名</strong></summary>

預設原生後端需要支援 [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) 的終端機，例如 **WezTerm**、**Kitty** 或 **Ghostty**。若在 Kitty 內使用 tmux，請依 [Snacks 的設定與確認步驟](#選用-snacks-圖片後端)操作，包括啟用 `allow-passthrough`。單獨啟用 tmux 的 passthrough，不會讓原生後端取得 tmux 支援。

</details>

<details>
<summary><strong>影片只顯示一張靜態圖片</strong></summary>

兩個後端都需要能從 `$PATH` 找到 `ffmpeg`，才能擷取影片影格。Snacks 後端可在 Kitty 中播放，包括 tmux 內的預覽；沒有安裝時，會退回以第一個影格顯示靜態圖片。請透過套件管理器安裝，例如 `brew install ffmpeg`。

</details>

<details>
<summary><strong>按 Enter 沒有開啟圖片分頁</strong></summary>

請使用 `:MdRender tab` 之類的文件預覽，選擇 [Snacks 後端](#選用-snacks-圖片後端)，並確認 `:echo executable('magick')` 回傳 `1`。等圖片載入完成，再將游標移到圖片或其標題上按 Enter。內建的 `:MdRender demo` 展示視窗沒有提供這個開圖操作。

</details>

<details>
<summary><strong>Mermaid 圖表沒有顯示</strong></summary>

Mermaid 圖表需要 [@mermaid-js/mermaid-cli](https://github.com/mermaid-js/mermaid-cli) 提供的 `mmdc` 指令。若未全域安裝 `mmdc`，外掛會改用 `npx -y @mermaid-js/mermaid-cli`，但第一次執行會較慢。可用 `npm install -g @mermaid-js/mermaid-cli` 全域安裝，以減少啟動時間。

</details>

<details>
<summary><strong>PlantUML 圖表沒有顯示</strong></summary>

標記為 `plantuml` 或 `puml` 的程式碼區塊，會在 `$PATH` 中有 `plantuml` 時使用本機繪圖；另一種方式是安裝 `java`，並讓 `$PLANTUML_JAR` 指向可讀取的 `plantuml.jar`。任一方式可用時，就能將區塊轉為圖表。

外掛不會自動替你選擇遠端服務。使用別人的 PlantUML 伺服器，代表會把圖表原始文字傳送給對方；因此沒有本機工具時，預設保留為程式碼區塊。若要使用伺服器，請明確指定：

```lua
require("md-render.image").setup {
  -- 可使用自己的服務，或公開的 "https://www.plantuml.com/plantuml"。
  -- 圖表原始文字會傳送到指定服務，請了解這一點後再選擇。
  plantuml_server = "https://plantuml.example.com/plantuml",
}
```

使用伺服器也需要 `curl`。產生的圖表會依原始文字快取於 `stdpath("cache")/md-render/plantuml`，相同圖表可重複使用快取。

</details>

<details>
<summary><strong>日文換行看起來不自然</strong></summary>

md-render 預設會套用 JIS X 4051 行首行尾禁則，但仍以字元為單位斷行。如果需要依日文詞組換行，請安裝 [budoux.lua](https://github.com/delphinus/budoux.lua)，外掛會自動偵測並使用。

</details>

<details>
<summary><strong>日文中 <code>**</code> 兩側的空白消失了</strong></summary>

這是預期行為。`これは **強調** です。` 中的空白，通常是為了讓只接受標記兩側有空白的剖析器辨識粗體；CommonMark 本身不需要這些空白，`これは**強調**です。` 一樣有效。移除標記後，這些空白只會變成文字之間的空隙，因此當兩側都是東亞全形字元時，md-render 會將空白移除；同一規則也適用於一般段落合併換行時的空白。

如果相鄰的是半形字元，則保留空白，例如 `これは **API** です。` 或 `これは **1** 番目`。兩個相鄰格式區段之間也會保留，例如 `**あ** **い**` 或連續兩個連結，避免原本分開的內容黏在一起。

</details>

<details>
<summary><strong>程式碼區塊沒有語法醒目提示</strong></summary>

需要能找到對應語言的 Treesitter 剖析器。Neovim 已內建 Lua 等部分語言的剖析器；其他語言可透過 [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) 安裝，手動安裝方式請見 `:help treesitter-parsers`。

</details>

## 作為程式庫使用

<details>
<summary><strong>程式 API</strong></summary>

可以透過繪製引擎建立帶有醒目提示的內容。以下範例的 `lines` 代表 Markdown 原始文件的各行文字：

```lua
local md = require("md-render")

-- 繪製單行 Markdown
local text, highlights, links = md.Markdown.render("**bold** and [link](https://example.com)")

-- 建立整份文件內容
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

-- 套用到緩衝區
local buf = vim.api.nvim_create_buf(false, true)
local ns = vim.api.nvim_create_namespace("my_ns")
md.display_utils.apply_content_to_buffer(buf, ns, content)

-- 顯示圖片，需要支援 Kitty graphics protocol 的終端機
-- 關閉視窗時會自動清除圖片。
local win = vim.api.nvim_get_current_win()
md.display_utils.setup_images(win, content, ns)
```

</details>

## 開發

### 執行測試

```bash
make test
```

這會透過 `nvim --headless` 執行所有 `tests/*_test.lua`。新增符合 `*_test.lua` 命名方式的測試檔，會自動納入。

## 授權

MIT，詳見 [LICENSE](LICENSE)。

`lua/md-render/vendor/` 中的第三方程式碼保留原樣，依其原有授權提供：其中包含 Neovim 的 `vim.async`（Apache-2.0），讓 Neovim 0.12 也能使用 0.13 內建的非同步執行環境。詳見[該目錄的 README](lua/md-render/vendor/README.md)。
