# md-render.nvim

[English](README.md) · **正體中文（台灣）** · [日本語](README.ja.md)

這是 [delphinus/md-render.nvim](https://github.com/delphinus/md-render.nvim) 的 fork，新增可選用的 Snacks 圖片後端，支援 Kitty/tmux 中的靜態圖片與圖表、自動配合視窗大小，以及可縮放、平移的圖片分頁。也可以參考這份 [Neovim 設定](https://github.com/denny0223/.nvim)作為完整設定範例。

這個 Neovim 外掛能將 Markdown 原始文字轉為有語法醒目提示、可互動的預覽，直接顯示在編輯器中。可以一邊編輯、一邊查看同步捲動的預覽，也能使用浮動視窗、分頁，或從指令列啟動、類似 `less` 的分頁閱讀模式。

## 第一次使用

1. 先確認[系統需求](#系統需求)，再選擇一種[安裝方式](#安裝)。
2. 如果要使用這個 fork 的 Kitty/tmux 支援、自動調整圖片大小、縮放與平移，請完成 [Snacks 圖片後端設定](#選用-snacks-圖片後端)。基本安裝仍使用原生後端，也能播放動畫與影片。
3. 安裝並設定外掛後，重新啟動 Neovim，再開啟 Markdown 檔案。從原始文字視窗依需求選擇：

| 用途 | 指令 | 關閉預覽 |
|---|---|---|
| 一邊編輯，一邊在右側即時預覽 | `:botright vert MdRender split` | 先切到預覽視窗，再執行 `:q` |
| 在分頁中閱讀 | `:MdRender tab` | 按 `q` |

左右分割後，焦點會留在原始文字視窗，可以直接繼續編輯；不必存檔，預覽就會更新。剛開啟分割預覽時，在一般模式按 `<C-w>p`（先按 Ctrl-w，再按 p）即可進入預覽；這組按鍵的作用是切到上一個視窗。[按鍵設定範例](#按鍵設定)也提供可自行設定的 `<leader>ms` 快捷鍵。

設定好 Snacks 與 `magick` 後，在預覽中對載入完成的圖片按 Enter，可開啟[圖片分頁](#圖片分頁按鍵)進行縮放與平移。

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
    { "<leader>ms", "<cmd>botright vert MdRender split<CR>", desc = "在右側開啟 Markdown 預覽" },
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
    { "<leader>ms", "<cmd>botright vert MdRender split<CR>", desc = "在右側開啟 Markdown 預覽" },
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
vim.keymap.set("n", "<leader>ms", "<cmd>botright vert MdRender split<CR>", { desc = "在右側開啟 Markdown 預覽" })
vim.keymap.set("n", "<leader>mp", "<Plug>(md-render-preview)",     { desc = "切換 Markdown 浮動預覽" })
vim.keymap.set("n", "<leader>mt", "<Plug>(md-render-preview-tab)", { desc = "切換 Markdown 分頁預覽" })
vim.keymap.set("n", "<leader>md", "<Plug>(md-render-demo)",        { desc = "Markdown 功能展示" })
```

範例中的 `<leader>ms` 請在 Markdown 原始文字視窗使用，會在右側開啟預覽。每次執行都會新增視窗；切換與關閉方式請見[分割原始文字與預覽](#分割原始文字與預覽)。

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
| `:MdRender textsize [on\|off\|toggle\|auto\|image\|native\|status]` | **實驗性功能**：放大標題，可選自動、原生文字或圖片渲染，並查詢實際後端 |
| `:MdRender pager` | 全螢幕分頁閱讀模式，隱藏介面裝飾，按 `q` 離開 Neovim |
| `:MdRender demo` | 顯示內建 Markdown 語法展示 |

輸入第一個參數時可用 Tab 補齊子指令；`auto` 與 `textsize` 後會提供 `on`、`off`、`toggle`，`textsize` 另有 `auto`、`image`、`native`、`status`。

> **舊版相容性：** `:MdRenderTab`、`:MdRenderToggle`、`:MdRenderSplit`、`:MdRenderAuto`、`:MdRenderPager`、`:MdRenderDemo` 等舊指令仍可使用，會轉交給新的子指令。每次 Neovim 工作階段中，首次呼叫會顯示淘汰提示；未來主要版本將移除這些舊指令。

### 在原視窗切換預覽

`:MdRender toggle` 會在目前視窗切換 Markdown 原始緩衝區與其預覽，不另外開啟分頁或浮動視窗。適合在分割畫面中，一邊編輯程式碼、一邊閱讀 README。

```vim
:vsplit README.md
:MdRender toggle
```

行為如下：

- 預覽緩衝區是**唯讀**的，同一份來源會重複使用同一個預覽緩衝區。
- 同一份來源若同時出現在多個視窗，只會切換執行指令的視窗。其他視窗中的編輯會自動反映在預覽中。
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

標題預設使用 `auto`，依序選擇 **圖片 → 原生 OSC 66 → 一般文字**。`:MdRender textsize status` 可查看實際後端與回退原因；修正環境後，執行 `:MdRender textsize auto` 重試。

| 模式 | H1 | H2 | H3 | H4 | H5 | H6 |
|---|---|---|---|---|---|---|
| 圖片 | 2 倍 | 1.5 倍 | 1.25 倍 | 1 倍 | 0.875 倍 | 0.85 倍 |
| 原生 | 2 倍 | 1.75 倍 | 1.5 倍 | 1.4 倍 | 1.25 倍 | 1.17 倍 |

圖片與原生布局不顯示層級圖示，H1／H2 下方使用單線。純文字布局保留 `#` 到 `######`，六級都在所屬容器內靠左，H1 下方使用雙線、H2 使用單線。

#### 試用圖片標題

執行 `:MdRender textsize image`，再用 `:MdRender toggle` 開啟預覽。圖片需要 Neovim >= 0.12、終端確認 PNG 支援（Kitty >= 0.28）、`termguicolors`、Python 3、PyGObject、Pycairo 與 Pango/PangoCairo。Python 套件與字型需安裝於 Neovim 所在主機；明確選擇 `image` 後，環境不足時會使用一般文字。

若要調整字型或基準大小：

```lua
require("md-render.text_size").setup {
  backend = "auto",
  image = { font = "Noto Sans Mono,Noto Sans Mono CJK TC", font_size = "auto", python = "python3" },
}
```

`font_size = "auto"` 依終端格子大小校準字型，也可指定正的像素值。圖片沿用標題與行內高亮；不支援的字形、樣式及 `<details>` 內的標題保留文字。更換字型後，執行 `:MdRender textsize image` 更新。

搜尋、選取或將游標移入標題時，受影響的文字會顯示出來，維持原布局，不臨時插入標記。內部錨點可直接點擊；外部連結也支援終端快捷操作（Kitty 為 Ctrl＋Shift＋點擊）。若要用終端選取文字，先執行 `:MdRender textsize off`，或用 `:MdRender toggle` 回到原文。

Windows 與 tmux 不啟用圖片標題。已驗證 Linux 直接使用 Kitty，以及 SSH 連入 Linux；其他作業系統／客戶端組合與螢幕閱讀器尚未驗證。

#### 原生文字標題

Kitty >= 0.40 可用 `:MdRender textsize native`，不需圖片依賴。若標題含行內格式、連結，或可用寬度不足以縮放，整份文件會使用一般標題，維持一致的層級呈現。搜尋、選取及不支援的高亮仍可能讓個別標題顯示文字。

原生標題換行後，每行占用兩列。捲動或視窗重疊時可能短暫顯示一般文字，重繪成本也較高；Telescope 與 Snacks 選取器預覽不使用原生縮放。疑難排解請見 `:help md-render-text-size`。

使用 `:MdRender textsize off` 關閉縮放，或在設定中停用：

```lua
require("md-render.text_size").setup { enabled = false }
```

### 分割原始文字與預覽

<figure>
  <img src="https://github.com/user-attachments/assets/24999fe8-9ff0-4ca3-9bd1-b72ec5d7f33c" width="407" height="328" alt="分割視窗，同時顯示原始文字與預覽" />
  <figcaption><em>原始文字與預覽並排，編輯結果與行內圖片會即時更新</em></figcaption>
</figure>

若要一邊編輯 Markdown、一邊在右側即時預覽，請從原始文字視窗執行：

```vim
:botright vert MdRender split
```

預覽會開在目前分頁的最右側，即使已經有其他分割視窗也是如此。焦點會留在原始文字視窗，編輯後不必存檔就會更新預覽，游標與捲動位置也會雙向同步。

在一般模式按 `<C-w>p` 會切到上一個視窗。剛開啟分割預覽後，可用它進入預覽。要關閉預覽，請先切到預覽視窗，再執行 `:q` 或按 `<C-w>c`；這個模式不使用單獨的 `q` 關閉。

每次執行都會新增視窗：從原始文字執行會開啟預覽，從分割或原地切換的預覽執行則會開啟原始文字。方向遵循 Vim 標準的視窗修飾指令：

- `:MdRender split`：上下分割。
- `:vert MdRender split`：將原始文字與預覽左右並排，位置依 `splitright` 設定。
- `:tab MdRender split`：在新分頁開啟另一種檢視。
- `:topleft MdRender split`：放在頂端。
- `:botright MdRender split`：放在底端。

完整行為與行內圖片限制，請見 `:help :MdRender-split`。

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
