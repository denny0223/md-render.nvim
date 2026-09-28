# md-render.nvim

[English](README.md) · [正體中文（台灣）](README.zh-TW.md) · **日本語**

この [delphinus/md-render.nvim](https://github.com/delphinus/md-render.nvim) のフォークは、Kitty/tmux 向けのオプションの Snacks 画像バックエンド、ウィンドウに合わせた画像サイズ調整、ズーム・パン可能な画像タブを追加しています。

Neovim 用の Markdown レンダリングエンジンです。生の Markdown テキストをハイライト付きのインタラクティブなコンテンツに変換して、エディタ内で表示します。スクロールが同期するライブプレビューを横に置いて編集でき、フローティングウィンドウやタブ、コマンドラインからの `less` ライクなページャーモードでも閲覧できます。

## はじめて使う

1. [必要要件](#必要要件) を確認し、[インストール方法](#インストール) をひとつ選びます。
2. このフォークの Kitty/tmux 対応、画像サイズ調整、ズーム・パンを使う場合は [Snacks 画像バックエンド](#snacks-画像バックエンド) を設定します。基本のインストールではネイティブバックエンドを使い、アニメーションや動画も扱えます。
3. インストールと設定後に Neovim を再起動し、Markdown ファイルを開きます。ソースウィンドウで用途に合わせて選びます：

| 用途 | コマンド | プレビューを閉じる |
|---|---|---|
| 右側でリアルタイムに確認しながら編集 | `:botright vert MdRender split` | プレビューウィンドウに移って `:q` |
| タブで閲覧 | `:MdRender tab` | `q` |

分割後もフォーカスはソースウィンドウに残るので、そのまま編集できます。保存しなくてもプレビューに反映されます。Normal モードの `<C-w>p`（Ctrl-w の後に p）は直前のウィンドウへ移動する操作で、分割直後はプレビューに移れます。[キーマップ例](#キーマップ)には任意で設定できる `<leader>ms` もあります。

Snacks と `magick` の設定後は、プレビュー内の読み込み済みの画像上で Enter を押すと、ズーム・パンできる[画像タブ](#画像タブのキー)が開きます。

詳しくは [キーマップ](#キーマップ)、[コマンド](#コマンド)、[トラブルシューティング](#faq--トラブルシューティング) を参照してください。

ライブラリ API を含む[リファレンスマニュアル](doc/md-render.jax)は、Neovim 内でも `:help md-render-contents@ja` で開けます。英語は `:help md-render-contents@en`、正體中文（台灣）は `:help md-render-contents@tw` を使ってください。

<figure align="center">
  <img src="https://github.com/user-attachments/assets/6c51f971-84bb-49fe-aaff-21db40712187" width="900" height="685" alt="md-render.nvim ショーケース：インライン書式、テーブル、コールアウト、コードブロック、画像、動画、Mermaid ダイアグラム" />
</figure>

## 主な機能

- **リッチなインライン書式** — 太字、取り消し線、インラインコード、リンク、Obsidian `==highlight==` をその場でレンダリング
- **テーブル** — 罫線文字による描画、列アラインメント、比例サイズ調整、セル内インライン書式
- **コールアウト & 折りたたみ** — GitHub / Obsidian のアラートタイプに対応。色付きボーダー・アイコン・クリックまたは `za` / `<CR>` で折りたたみ切り替え
- **コードブロック** — treesitter シンタックスハイライト付きフェンスコードブロック。省略時はクリックまたは `za` / `<CR>` で展開
- **画像** — ローカルおよび Web 画像（PNG, JPEG, WebP, GIF, アニメーション GIF）をターミナルグラフィクスプロトコルでインライン表示
- **動画** — ローカルおよび Web 動画（MP4, WebM, MOV, AVI, MKV, M4V）をアニメーションフレームとしてインライン再生
- **Mermaid ダイアグラム** — 画像としてインライン表示
- **PlantUML ダイアグラム** — ローカルのレンダラ、または指定したサーバで画像としてインライン表示
- **CommonMark の段落** — 原文で折り返された行はひとつの段落に連結。箇条書き項目の継続行や引用の本文も同様で、和字同士の連結では半角スペースを入れません
- **インラインマーカー周りの和字空白** — 一部のパーサに `**` を認識させるためだけに置かれた `これは **強調** です。` の空白は詰めて表示。`これは **API** です。` のように隣が半角なら残します
- **入れ子のブロック構造** — 箇条書き項目の内容位置に揃えた引用・コールアウト・フェンスコードブロックも、リテラルではなくその場でレンダリング
- **CJK 対応ワードラップ** — JIS X 4051 禁則処理 + [BudouX](https://github.com/google/budoux)（[budoux.lua](https://github.com/delphinus/budoux.lua) 経由）によるオプションのフレーズ分割
- **クリック可能リンク** — マウスクリックで URL を開く。対応ターミナルでは OSC 8 ハイパーリンク
- **`<details>` 対応** — クリックまたは `za` / `<CR>` で折りたたみ可能なセクション。`open` 属性にも対応
- **ステータスフッタ** — フローティングプレビューの下ボーダーにファイル名・ソース内の現在位置・罫線素片のプログレスバーを表示。本文の行を消費せず、ステータスラインにも干渉しない
- **ライブラリ API** — レンダリングエンジンを自作プラグインからプログラム的に利用可能

<figure align="center">
  <img src="assets/screenshot-rendering.png" width="672" height="751" alt="インライン書式、テーブル、コールアウト、コードブロック、CJK 折り返し" />
  <figcaption><em>静止プレビュー：インライン書式、テーブル、コールアウト、コードブロック、CJK 折り返し</em></figcaption>
</figure>

## 試してみる

[プラグインのインストールと設定](#インストール) を済ませてから、同梱のショーケースをページャーで開けます。リポジトリをクローンするだけでは Neovim にプラグインはインストールされません：

```bash
git clone https://github.com/denny0223/md-render.nvim
cd md-render.nvim
nvim +"MdRender pager" assets/showcase.md
```

プラグインをインストール済みの場合は、`:MdRender demo` で対応する全記法を確認できます。

## 必要要件

- Neovim >= 0.12（端末への書き出しに `vim.api.nvim_ui_send` を使用）
- デフォルトのネイティブバックエンド（`kitty`）での画像・動画のインライン表示には [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) 対応ターミナルが必要。
  動作確認は [WezTerm](https://wezfurlong.org/wezterm/) / [Kitty](https://sw.kovidgoyal.net/kitty/) / [Ghostty](https://ghostty.org/)（macOS/Linux）で実施。
- オプションの [Snacks バックエンド](#snacks-画像バックエンド) は Unicode プレースホルダーにも依存します。以下の設定例は Kitty 単体、または Kitty 内の tmux を対象としています。

<details>
<summary><strong>機能ごとの依存関係</strong></summary>

基本的な Markdown レンダリングでは省略できますが、各機能を使う場合は対応する依存関係が必要です。プラグインマネージャーがインストールするのは Neovim プラグインです。コマンドラインツールは別途インストールし、Neovim の `$PATH` から実行できるようにしてください。

| 依存 | 用途 | フォールバック |
|---|---|---|
| [curl](https://curl.se/) | Web 画像・動画のダウンロード | `set_download_fn()` でカスタム関数を指定可 |
| [snacks.nvim](https://github.com/folke/snacks.nvim) | オプションの画像バックエンド、サイズ調整、専用画像タブ | デフォルトのネイティブバックエンドは引き続き使用可。ただし、これらのフォーク独自機能は使えません |
| [FFmpeg](https://ffmpeg.org/) (`ffmpeg` / `ffprobe`) | ネイティブの JPEG/WebP → PNG 変換、両バックエンド共通の GIF / 動画のフレーム展開 | ImageMagick にフォールバック（画像のみ。動画には ffmpeg が必要） |
| [ImageMagick](https://imagemagick.org/) (`magick`) | Snacks の画像変換と画像タブのズーム・パン、ネイティブの画像変換と共通の GIF フレーム展開 | ネイティブの変換は下表のツールで代替可。画像タブは PNG でも `magick` が必須で、`ffmpeg`、`sips`、`convert` のみのインストールでは代替できません |
| [Mermaid CLI](https://github.com/mermaid-js/mermaid-cli) (`mmdc`) とヘッドレスブラウザ | 両バックエンドで Mermaid ダイアグラムを描画 | `npx -y @mermaid-js/mermaid-cli` にフォールバック（Node.js/npm が必要で、CLI をダウンロードする場合があります）。ブラウザも引き続き必要です |
| [PlantUML](https://plantuml.com/) (`plantuml`、または `java` と `$PLANTUML_JAR`) | PlantUML ダイアグラムを画像として描画 | 指定した場合のみ PlantUML サーバ（curl が必要）。指定が無ければコードブロックのまま |
| [budoux.lua](https://github.com/delphinus/budoux.lua) | CJK フレーズ単位の改行（BudouX） | 1文字ずつ分割（禁則処理は維持） |
| Treesitter パーサー | コードブロックのシンタックスハイライト | ハイライトなしで表示 |
| [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) または [mini.icons](https://github.com/echasnovski/mini.icons) | コードブロックヘッダのファイルタイプアイコン | 内蔵アイコンテーブル |

**ネイティブバックエンド**の静止画変換と、両バックエンド共通のフレーム展開では、以下の順でツールを検索します。[Snacks の変換](https://github.com/folke/snacks.nvim/blob/main/docs/image.md) は PNG 以外の静止画に ImageMagick を使います。

| ユースケース | 1st | 2nd | 3rd |
|---|---|---|---|
| 静止画変換（JPEG/WebP → PNG） | `sips`（macOS） | `ffmpeg` | `magick` |
| アニメーション GIF フレーム展開 | `ffmpeg` | `magick` | — |
| 動画フレーム展開 | `ffmpeg` | — | — |

</details>

## インストール

以下の例ではデフォルトのネイティブバックエンド（`kitty`）を使います。Kitty/tmux での画像表示、サイズ調整、ズーム・パンを使う場合は [Snacks 画像バックエンド](#snacks-画像バックエンド) も設定してください。これらの機能は引き継いだ upstream のリリースタグには含まれないため、このフォークのデフォルトブランチを使います。lazy.nvim の例ではそのために `version = false` を指定しています。

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

### vim.pack（Neovim 0.12+）

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

### Snacks 画像バックエンド

オプションのバックエンドで、静止画・ダイアグラムの表示、ウィンドウに合わせたサイズ調整、専用画像タブを有効にします。必要なものは以下のとおりです：

- [snacks.nvim](https://github.com/folke/snacks.nvim)：md-render のプレビューを開く前に読み込みと設定を完了してください。
- Unicode プレースホルダーに対応した Kitty。tmux 内では設定ファイルに `set -g allow-passthrough on` を追加して再読み込みしてください。Snacks が対応する他のターミナルは、この連携では未検証です。上記のネイティブバックエンドの対応一覧は Snacks の互換性を保証しません。
- Neovim の `$PATH` から `magick` を実行できる ImageMagick。ズーム・パンを含む画像機能一式に必要です。FFmpeg や `sips` だけでは足りません。
- Mermaid を使う場合は Mermaid CLI（`mmdc`、または `npx` のフォールバック）とヘッドレスブラウザ。Snacks は画像の表示を担当し、ダイアグラムのレンダラを置き換えません。ブラウザのウィンドウは開きません。

lazy.nvim では、上記の基本的な md-render の spec を次の例に置き換えます。アイコンや BudouX を使う場合は、それらの依存関係も残してください：

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

vim.pack では `vim.pack.add()` のリストに `"https://github.com/folke/snacks.nvim"` を追加します。mini.deps では md-render の `depends` に `"folke/snacks.nvim"` を追加します。両プラグインを読み込んだ後、次の順で設定してください：

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

Snacks をすでに設定している場合は、その設定に上記の `image` オプションを統合し、`setup()` を二度呼ばないでください。Snacks 側の document と math の描画を無効にして、Markdown プレビューを md-render に任せます。この連携にそれらの Snacks 機能は不要です。

読み込み後に設定を確認してください：

1. `:checkhealth snacks` を実行します。`:echo executable('magick')` が `1`、`:lua print(require("md-render.image").config().backend)` が `snacks` を返すことを確認してください。
2. tmux 内では `tmux show-options -gv allow-passthrough` が `on` を返す必要があります。
3. Kitty でローカルの PNG を含む Markdown ファイルを開き、`:MdRender tab` を実行します。画像が表示されたら画像またはそのタイトル上で Enter を押し、画像タブが開くことを確認してください。ツールが見つかるだけでは、端末での表示確認にはなりません。

両バックエンドで GIF アニメーションと動画を再生できます。Snacks は Kitty のアニメーション機能を使い、tmux 内でも再生できます。動画のフレーム展開には `ffmpeg` が必要です。Snacks バックエンドは画面外も含む文書全体の画像を準備します。ダイアグラム描画、ダウンロード、フレーム展開は全プレビューで同時に 2 ジョブまで実行し、プレビューを閉じても実行中の処理はキャッシュへの保存まで完了する場合があります。画像が多い文書では初期処理量が増えます。

自動レイアウトはネイティブバックエンドの 80 桁上限を使わず、利用可能なウィンドウ幅を使います。画像は縦横比を保ち、その幅と「ウィンドウの高さ − 6 行」に収まり、元のピクセルサイズを超えて拡大しません。`max_width` を明示した場合はそちらを優先します。操作方法は [画像タブのキー](#画像タブのキー) を参照してください。

## 類似プラグインとの比較

<details>
<summary><strong>他の Markdown プレビューアではダメ?</strong></summary>

- **[markdown-preview.nvim](https://github.com/iamcco/markdown-preview.nvim)** — ブラウザ品質のレンダリングが必要な場合は最適ですが、ブラウザを必要とします。md-render はターミナル内で完結します。
- **[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim)** — バッファ内レンダリングが美しいですが、編集中のバッファ自体を変更します。md-render は編集バッファに手を加えず、別のフローティング/タブウィンドウまたはページャーへ描画します。
- **[mcat](https://github.com/Skardyy/mcat)** — 思想として最も近い（ピュアターミナルの Markdown レンダラー）ですが、自動折りたたみテーブルやクリックで折りたたみ切り替え、CJK ワードラップなどの複雑なレイアウト機能は未対応です。

md-render.nvim は、ターミナル内で完結する専用プレビューアとして、リッチなレイアウトと第一級の CJK サポートを目指しています。

</details>

## キーマップ

このプラグインは `<Plug>` マッピングを提供しますが、デフォルトのキーバインドは設定**しません**。自分でマッピングしてください：

```lua
vim.keymap.set("n", "<leader>ms", "<cmd>botright vert MdRender split<CR>", { desc = "Open Markdown preview on the right" })
vim.keymap.set("n", "<leader>mp", "<Plug>(md-render-preview)",     { desc = "Markdown preview (toggle)" })
vim.keymap.set("n", "<leader>mt", "<Plug>(md-render-preview-tab)", { desc = "Markdown preview in tab (toggle)" })
vim.keymap.set("n", "<leader>md", "<Plug>(md-render-demo)",        { desc = "Markdown render demo" })
```

この例の `<leader>ms` は Markdown のソースウィンドウで使うと、右側にプレビューを開きます。呼び出すたびに新しいウィンドウが開きます。移動と閉じ方は[ソース/レンダーの分割表示](#ソースレンダーの分割表示)を参照してください。

| `<Plug>` マッピング | 説明 |
|---|---|
| `<Plug>(md-render-preview)` | 現在の Markdown バッファのフローティングプレビューをトグル |
| `<Plug>(md-render-preview-tab)` | 現在の Markdown バッファのタブプレビューをトグル |
| `<Plug>(md-render-toggle)` | 現在のウィンドウをソース ↔ レンダーモードでその場切替 |
| `<Plug>(md-render-auto)` | **[実験的]** 現在のバッファで auto モード(Insert 以外で render)をトグル |
| `<Plug>(md-render-split)` | ウィンドウを分割してソースとレンダリング表示を並べる |
| `<Plug>(md-render-demo)` | 対応する全 Markdown 記法のデモウィンドウを表示 |

### プレビュー内のキー

レンダリングされたプレビュー(フローティング・タブ・その場トグル)内では、以下のバッファローカルなキーが自動で設定されます:

| キー | 動作 |
|---|---|
| `za` | カーソル行の折りたたみ / 展開ブロックを切り替える(該当しない行では何もしない) |
| `<CR>` | カーソル位置の画像を開く（Snacks バックエンド）、または折りたたみ / 展開ブロックを切り替える |
| `<LeftMouse>` | クリックで折りたたみ・展開を切り替え、リンクを開く |
| `q` / `<Esc>` / `<C-c>` | ウィンドウを閉じる(フローティング / タブモードのみ) |

### 画像タブのキー

[Snacks バックエンド](#snacks-画像バックエンド) と ImageMagick（`magick`）を設定した状態で、画像またはそのタイトル上で Enter を押すと専用画像タブが開きます。以下のキーはタブ内で自動設定され、追加のプラグインやキーマップ設定は不要です。

GIF / 動画タブには Kitty 0.31 以降が必要で、開くと自動再生されます。Space で一時停止 / 再開でき、ズームやパンでも再生状態を維持します。再生操作は画像タブだけに適用されます。

| 画像タブ内のキー | 動作 |
|---|---|
| `+` / `=` / `-` | 全体表示を基準に 1〜16 倍の範囲でズームイン / アウト |
| `h/j/k/l` または矢印キー | 表示中の画像の幅 / 高さの 1/8 ずつパン |
| `zH` / `zL` | 左 / 右へ半画面パン |
| `<C-d>` / `<C-u>` | 下 / 上へ半画面パン |
| `<C-f>` / `<C-b>` | 下 / 上へページ移動（可能なら画面上の 2 行分を重複） |
| `gg` / `G` | 上端 / 下端へ移動 |
| `0` / `^` | 左端へ移動 |
| `$` | 右端へ移動 |
| `f` | 画像全体をウィンドウに収め、中央に配置 |
| `q` / `<Esc>` | 画像タブを閉じて文書に戻る |

端への移動はズーム倍率ともう一方の軸の位置を維持します。ズームは変換済み画像のピクセルを拡大するもので、高解像度のダイアグラムを再生成する機能ではありません。

## コマンド

このプラグインが公開するユーザコマンドは `:MdRender` ひとつで、サブコマンドで動作モードを切り替えます。

| コマンド | 説明 |
|---|---|
| `:MdRender` | フローティングプレビュー(`:MdRender float` のエイリアス) |
| `:MdRender float` | フローティングプレビューをトグル |
| `:MdRender tab` | タブプレビューをトグル |
| `:MdRender toggle` | 現在のウィンドウをソース ↔ レンダーモードでその場切替 |
| `:MdRender split` | ウィンドウを分割してソースとレンダリング表示を並べる(`:vert` / `:tab` / `:topleft` / `:botright` を尊重) |
| `:MdRender auto [on\|off\|toggle]` | **[実験的]** Insert モードに連動して source/render を自動切替(バッファ単位) |
| `:MdRender textsize [on\|off\|toggle\|auto\|image\|native\|status]` | **[実験的]** 見出しの表示方式の選択と状態の確認 |
| `:MdRender pager` | ページャーモード — フルスクリーン、装飾なし、`q` で Neovim 終了 |
| `:MdRender demo` | 対応する全 Markdown 記法のデモウィンドウを表示 |

タブ補完ではサブコマンドと、そのコマンドで使える引数が候補になります。

> **後方互換について。** 従来のトップレベルコマンド (`:MdRenderTab`、`:MdRenderToggle`、`:MdRenderSplit`、`:MdRenderAuto`、`:MdRenderPager`、`:MdRenderDemo`) は新しいディスパッチャへ転送されるエイリアスとして残しています。Neovim セッションごとに最初の呼び出しで非推奨警告を1度だけ表示します。将来のメジャーバージョンで削除されます。

### その場トグル

`:MdRender toggle` は、現在のウィンドウをソース Markdown バッファとそのレンダリング表示の間で**その場で**切り替えます。新しいタブやフローティングウィンドウは開きません。スプリットレイアウトでコードと README のレンダリングを並べたい、といった用途を想定しています。

```vim
:vsplit README.md
:MdRender toggle
```

挙動:

- レンダーバッファは**読み取り専用**で、トグル間で再利用されます(ソース1つにつきレンダーバッファ1つ)。
- 同じソースが複数のウィンドウで表示されている場合、切替はそのウィンドウだけに作用します。他のウィンドウでの編集はプレビューに自動で反映されます。
- カーソル位置は source line マップを介してソース ↔ レンダー間を往復します。
- レンダーモードのウィンドウでは `number` / `relativenumber` / `list` が無効化されます。元の値はウィンドウに保存され、ソースに戻したときに復元されます。
- レンダーモード中、`q` / `<Esc>` / `<C-c>` は閉じる動作に**割り当てられません**。ソースに戻すには再度 `:MdRender toggle` を呼びます。`<LeftMouse>` / `za` / `<CR>` は折りたたみ・展開を引き続き切り替えます(リンク open は `<LeftMouse>`)。Snacks バックエンドでは `<CR>` で画像も開けます。

### Insert モード連動の自動トグル(実験的)

> **実験的機能です。** 新しく追加された機能で、UX が変わる可能性があります。問題や違和感があればぜひお知らせください。

`:MdRender auto on` は、現在のバッファを Normal モード中はレンダー表示にしておき、編集を始めると自動的に source に戻すモードです。`off` で解除、`:MdRender auto`(または `:MdRender auto toggle`)でトグル。すべての Markdown バッファで有効にしたいときは:

```vim
autocmd FileType markdown silent! MdRender auto on
```

`i` / `I` / `a` / `A` / `o` / `O` の再マップ、`:w` の source への転送、読み取り専用なレンダーバッファ上で効かない編集操作などの詳細は `:help :MdRender-auto` を参照してください。

### 見出しの拡大表示(実験的・Kitty 専用)

既定の `auto` は **画像 → native OSC 66 → 通常の文字** の順で利用可能な方式を選びます。画像と native のフォントサイズは次のとおりです。

| 方式 | H1 | H2 | H3 | H4 | H5 | H6 |
|---|---|---|---|---|---|---|
| 画像 | 2 倍 | 1.5 倍 | 1.25 倍 | 1 倍 | 0.875 倍 | 0.85 倍 |
| native | 2 倍 | 1.75 倍 | 1.5 倍 | 1.4 倍 | 1.25 倍 | 約 1.17 倍 |

画像と native では Hn アイコンを表示せず、H1 と H2 の下に一重線を引きます。通常の文字では `#` から `######` を残してコンテナ内で左揃えにし、H1 は二重線、H2 は一重線で区切ります。

- `:MdRender textsize image` / `native` / `auto`：表示方式を選択します。
- `:MdRender textsize off`：通常の文字に切り替えます。`on` で選択済みの方式に戻ります。
- `:MdRender textsize status`：方式とフォールバック理由を確認します。環境を修正した後は `auto` または `image` を指定して再試行します。

画像用のフォントは次の設定で変更できます。`font_size` は自動調整する `"auto"`、または正のピクセル数を指定します。以下は既定値です。

```lua
require("md-render.text_size").setup {
  backend = "auto",
  image = { font = "Noto Sans Mono,Noto Sans Mono CJK TC", font_size = "auto", python = "python3" },
}
```

画像表示には Neovim 0.12 以降、PNG 対応を確認できる Kitty 0.28 以降、`termguicolors`、Python 3、PyGObject、Pycairo、Pango/PangoCairo と Cairo の introspection データが必要です。Python、描画ライブラリ、フォントは Neovim を実行するホストにインストールします。native は Kitty 0.40 以降に対応し、画像用の依存関係は不要です。

画像表示は Linux 上の Kitty への直接接続と SSH PTY 接続で検証しています。Windows と tmux 内では無効になり、その他の OS・クライアントの組み合わせは未検証です。

検索や Visual 選択では必要な見出しだけ一時的に通常の文字へ戻り、配置は変えません。コピーには Neovim の Visual 選択と `y` を使えます。端末側の Shift-drag 選択では画像と文字の位置が一致せず、透明背景では文字を取得できない場合もあるため、先に `textsize off` にするかソースへ戻してください。スクリーンリーダーとの互換性は未検証です。

画像で描画できない字形・書式・リンクや `<details>` 内の見出しは、その見出しだけ文字で表示します。native はインライン書式とリンクを保ち、拡大後の幅に合わせて折り返します。拡大に必要な幅が不足する場合や、見出しの文字にタブなどの制御文字が含まれる場合は、文書全体を通常の文字に戻して内容を保ちます。Telescope と Snacks のプレビューでは見出しの拡大は無効です。その他の制限とちらつきの対処は `:help md-render-text-size` を参照してください。

**Kitty と tmux:** 接続中の Kitty クライアントが 1 つで、`set -g allow-passthrough on`（Snacks が使う `all` も可）と `set -g focus-events on` が必要です。フォーカス通知の設定を変更したら再接続してください。tmux が保持する端末識別とペイン座標を使い、tmux 設定の変更やペイン入力へのバージョン問い合わせは行いません。拡大するのはフォーカス中のペインだけです。ポップアップ、コピーモード、フォーカス喪失時は等倍になり、戻るとバックエンドを切り替えず自動で復帰します。外部の再描画には既存の 500 ms タイマーを使います。

カーソル移動で見出しが等倍にちらつくのを防ぐため、tmux のネイティブプレビューは Neovim のグローバルオプション `termsync` を一時的に無効にします。同じ Neovim プロセス内の全ウィンドウに適用され、拡大見出しのある最後のプレビューを閉じるか通常表示へ戻ると元の値に復元します。その間に明示的に変更した値は上書きしません。tmux 自身による端末更新の一括処理は維持されます。

Neovim は前面で起動し、フォーカス通知を有効に保ってください。既存のポップアップの下での起動、`FocusLost`／`FocusGained` の抑制、tmux 切り替え時の過渡的な表示が一切ないことは保証しません。複数クライアント、リンクしたウィンドウ、入れ子のマルチプレクサー、端末より大きいウィンドウでは等倍表示になり、`:MdRender textsize status` で理由やフォーカスによる一時停止を確認できます。

Linux、Kitty 0.48.2、tmux 3.7c、Neovim 0.12.5 で、ローカルとループバック SSH PTY を検証しています。通常の Snacks 画像と共存できますが、画像として描画する見出しの tmux 対応は [#11](https://github.com/denny0223/md-render.nvim/issues/11) で別途追跡します。`auto` は確認済みのネイティブ描画へフォールバックできます。

ネイティブの分数倍率では、漢字を含む見出しの文字列の境界に隙間が生じることがあります。tmux を使わない Kitty でも発生し、[upstream #65](https://github.com/delphinus/md-render.nvim/issues/65) で追跡しています。

### ソース/レンダーの分割表示

<figure>
  <img src="https://github.com/user-attachments/assets/24999fe8-9ff0-4ca3-9bd1-b72ec5d7f33c" width="407" height="328" alt="ソース/レンダーの分割表示" />
  <figcaption><em>ソース/レンダーの分割表示 — 編集がインライン画像も含めてリアルタイムに反映される</em></figcaption>
</figure>

Markdown を編集しながら右側でリアルタイムに確認するには、ソースウィンドウで実行します：

```vim
:botright vert MdRender split
```

既にほかの分割ウィンドウがある場合も、現在のタブの一番右にプレビューが開きます。フォーカスはソースウィンドウに残ります。保存しなくても編集が反映され、カーソルとスクロール位置も双方向に同期します。

Normal モードの `<C-w>p` は直前のウィンドウへ移動します。分割直後はこの操作でプレビューへ移れます。プレビューを閉じるには、そのウィンドウに移って `:q` または `<C-w>c` を使います。このモードでは `q` だけでは閉じません。

呼び出すたびに新しいウィンドウが開きます。ソースからはプレビューを、分割表示やその場トグルのプレビューからはソースを開きます。分割方向は標準的な Vim のモディファイアに従います：

- `:MdRender split` — 水平分割
- `:vert MdRender split` — ソースとプレビューを左右に並べる。配置は `splitright` の設定に従う
- `:tab MdRender split` — もう一方の表示を新しいタブで開く
- `:topleft MdRender split` — 一番上に配置
- `:botright MdRender split` — 一番下に配置

詳細な挙動とインライン画像の制限事項は `:help :MdRender-split` を参照してください。

### ページャーモード

<figure>
  <img src="https://github.com/user-attachments/assets/3c8d94a2-7a7d-4d99-ac9c-1b69870fee67" width="682" height="446" alt="ページャーモード" />
  <figcaption><em>ページャーモード — Markdown を <code>less</code> のように閲覧</em></figcaption>
</figure>

`:MdRender pager` を使うと Markdown ファイルを `less` のように閲覧できます：

```bash
nvim +"MdRender pager" README.md
```

シェルエイリアスを設定すると便利です：

```bash
alias mdless='nvim +"MdRender pager"'
mdless README.md
```

## Telescope 連携

<figure>
  <img src="https://github.com/user-attachments/assets/29fff5f5-d437-46d7-b92c-3d1a4bb21dd8" width="472" height="457" alt="Telescope 連携" />
  <figcaption><em>md-render による Telescope プレビュー</em></figcaption>
</figure>

### Previewer

`require("md-render.telescope").previewer()` で作成した previewer は、任意の
[telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) picker
（builtin、extension、カスタム問わず）に渡せます：

```lua
local previewer = require("md-render.telescope").previewer()

require("telescope.builtin").find_files({ previewer = previewer })
require("telescope").extensions.egrepify.egrepify({ previewer = previewer })
```

ファイルの種類に応じて自動的に表示方法を切り替えます：

| ファイル種別 | 動作 |
|---|---|
| Markdown (`.md`, `.markdown`) | md-render によるフルレンダリング（ハイライト、リンク、画像） |
| 画像・動画 (PNG, JPEG, WebP, GIF, MP4, ...) | Kitty graphics protocol でインライン表示 |
| その他 | telescope のデフォルト previewer（シンタックスハイライト付き）にフォールバック |

grep 系の picker では、マッチした行に自動スクロールします。

### `:Telescope md_render` Extension

builtin picker 用のショートカットです。`telescope.builtin` の picker を md-render
previewer 付きでラップします。引数はすべてそのまま渡されます：

```vim
:Telescope md_render find_files
:Telescope md_render live_grep cwd=~/notes
:Telescope md_render grep_string search=TODO
```

## Snacks.nvim 連携

`require("md-render.snacks").preview()` で
[snacks.nvim](https://github.com/folke/snacks.nvim) の picker 用プレビュー関数を
作成します。telescope 版と同じく Markdown、画像・動画、その他のファイルに対応します。

この picker 連携は [Snacks 画像バックエンド](#snacks-画像バックエンド) とは別の機能です。Snacks を設定済みの場合は、以下のいずれかの `picker` テーブルを既存の設定に統合し、`setup()` を再度呼ばないでください。

グローバルに全 picker へ適用：

```lua
require("snacks").setup({
  picker = {
    preview = require("md-render.snacks").preview(),
  },
})
```

source ごとに個別設定：

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

## FAQ / トラブルシューティング

<details>
<summary><strong><code>:MdRender</code> がエディタのコマンドとして認識されない</strong></summary>

プラグインマネージャーで `denny0223/md-render.nvim` がインストールされ、読み込まれているか確認してください。lazy.nvim では spec に `cmd = "MdRender"` を残し、コマンド入力時にプラグインを読み込ませます。クローンだけではインストールになりません。[インストール手順](#インストール) に従い、Neovim を再起動してください。

</details>

<details>
<summary><strong>画像が表示されない（alt テキストやファイル名だけが出る）</strong></summary>

デフォルトのネイティブバックエンドでは、**WezTerm**、**Kitty**、**Ghostty** などの [Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/) 対応ターミナルが必要です。Kitty 内の tmux では、`allow-passthrough` を含む [Snacks の設定と確認手順](#snacks-画像バックエンド) に従ってください。tmux の passthrough を有効にするだけでは、ネイティブバックエンドに tmux 対応は追加されません。

</details>

<details>
<summary><strong>動画が静止画 1 枚しか表示されない</strong></summary>

両バックエンドで動画のフレーム展開には `ffmpeg` が `$PATH` に必要です。Snacks は Kitty で再生し、tmux 内のプレビューにも対応します。なければ、最初のフレームを静止画として表示するフォールバックになります。パッケージマネージャでインストールしてください（例：`brew install ffmpeg`）。

</details>

<details>
<summary><strong>Enter で画像タブが開かない</strong></summary>

`:MdRender tab` などの文書プレビューを使い、[Snacks バックエンド](#snacks-画像バックエンド) を選択して、`:echo executable('magick')` が `1` を返すことを確認してください。画像の読み込み完了後、画像またはそのタイトル上で Enter を押します。組み込みの `:MdRender demo` ウィンドウには、この画像を開く操作はありません。

</details>

<details>
<summary><strong>Mermaid ダイアグラムが描画されない</strong></summary>

Mermaid のレンダリングには [@mermaid-js/mermaid-cli](https://github.com/mermaid-js/mermaid-cli) の `mmdc` バイナリが必要です。グローバルに `mmdc` がない場合は `npx -y @mermaid-js/mermaid-cli` にフォールバックしますが、初回呼び出しが大幅に遅くなります。`npm install -g @mermaid-js/mermaid-cli` でグローバルインストールするのがおすすめです。

</details>

<details>
<summary><strong>PlantUML ダイアグラムが描画されない</strong></summary>

`plantuml` / `puml` のフェンスは、`plantuml` バイナリが `PATH` にあるか、`java` があって `$PLANTUML_JAR` が読み取れる `plantuml.jar` を指しているときにローカルで描画されます。どちらか一方を入れればフェンスがダイアグラムになります。

明示的に指定しない限りフォールバックはしません。PlantUML はサーバ上で描画する設計であり、他人のサーバで描画するということはダイアグラムをそこへ送るということなので、このプラグインが勝手にそれを選ぶことはしません。ローカルのレンダラが無ければ、`plantuml` のフェンスはコードブロックのままになります。サーバを指定すればそちらを使います:

```lua
require("md-render.image").setup {
  -- 自分のインスタンス、または公開サーバの
  -- "https://www.plantuml.com/plantuml"。いずれにせよダイアグラムのソースは
  -- そこへ送られるので、承知の上で指定してください。
  plantuml_server = "https://plantuml.example.com/plantuml",
}
```

サーバを使う場合は `curl` も必要です。描画したダイアグラムはソースをキーにして `stdpath("cache")/md-render/plantuml` にキャッシュされるので、送信は 1 回だけです。

</details>

<details>
<summary><strong>日本語の折り返しが不自然</strong></summary>

デフォルトでは JIS X 4051 の禁則処理を文字単位で適用します。自然な単語境界に従うフレーズ単位の分割が必要なら [budoux.lua](https://github.com/delphinus/budoux.lua) をインストールしてください。プラグインが自動検出して使用します。

</details>

<details>
<summary><strong>日本語の <code>**</code> の周りの空白が消える</strong></summary>

意図的な動作です。`これは **強調** です。` と書かれるのは、`**` が空白で囲まれていないと強調と認識しないパーサがあるためです。CommonMark はこの助けを必要とせず (`これは**強調**です。` で問題無く強調になります)、マーカーを取り除いた後に残る空白はマークアップそのものなので、そのままだと隙間として見えてしまいます。md-render は両隣が全角文字のときにこの空白を詰めます。CommonMark がソフト改行に挿入する空白を落とすのと同じ規則です。

隣が半角文字なら空白は残すので、`これは **API** です。` や `これは **1** 番目` はそのまま表示されます。隣り合う 2 つの span の間の空白も残します。`**あ** **い**` や連続するリンクでは、その空白だけが 2 つを画面上で分けているからです。

</details>

<details>
<summary><strong>コードブロックにシンタックスハイライトが付かない</strong></summary>

シンタックスハイライトには対応する Treesitter パーサーが必要です。Neovim には Lua など一部の言語のパーサーが同梱されています。追加のパーサーは [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) でインストールするか、手動での導入方法を `:help treesitter-parsers` で確認してください。

</details>

## ライブラリとして使う

<details>
<summary><strong>プログラム API</strong></summary>

レンダリングエンジンをプログラムから利用してハイライト付きコンテンツを構築できます：

```lua
local md = require("md-render")

-- 1 行の Markdown をレンダリング
local text, highlights, links = md.Markdown.render("**bold** and [link](https://example.com)")

-- ドキュメント全体のコンテンツを構築
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

-- バッファに適用
local buf = vim.api.nvim_create_buf(false, true)
local ns = vim.api.nvim_create_namespace("my_ns")
md.display_utils.apply_content_to_buffer(buf, ns, content)

-- 画像を表示（Kitty Graphics Protocol 対応ターミナルが必要）
-- ウィンドウを閉じると自動的にクリーンアップされます。
local win = vim.api.nvim_get_current_win()
md.display_utils.setup_images(win, content, ns)
```

</details>

## 開発

### テストの実行

```bash
make test
```

`tests/*_test.lua` にマッチする全テストファイルを `nvim --headless` で実行します。新しいテストファイルは自動的に検出されます。

## ライセンス

MIT — [LICENSE](LICENSE) を参照。

`lua/md-render/vendor/` は原文のまま同梱している第三者のコードで、それぞれ独自の
ライセンスに従います。中身は Neovim の `vim.async` のコピー (Apache-2.0) で、0.13
に組み込まれている非同期ランタイムを Neovim 0.12 にも与えるためのものです。詳細は
[同ディレクトリの README](lua/md-render/vendor/README.md) を参照。
