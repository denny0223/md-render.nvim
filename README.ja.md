# md-render.nvim

[English](README.md) · [正體中文（台灣）](README.zh-TW.md) · **日本語**

この [delphinus/md-render.nvim](https://github.com/delphinus/md-render.nvim) のフォークは、Kitty/tmux 向けのオプションの Snacks 画像バックエンド、ウィンドウに合わせた画像サイズ調整、ズーム・パン可能な画像タブを追加しています。

Neovim 用の Markdown レンダリングエンジンです。生の Markdown テキストをハイライト付きのインタラクティブなコンテンツに変換して、エディタ内で表示します。フローティングウィンドウ、タブ表示、コマンドラインからの `less` ライクなページャーモードに対応しています。

## はじめて使う

1. [必要要件](#必要要件) を確認し、[インストール方法](#インストール) をひとつ選びます。
2. このフォークの Kitty/tmux 対応、画像サイズ調整、ズーム・パンを使う場合は [Snacks 画像バックエンド](#snacks-画像バックエンド) を設定します。基本のインストールではネイティブバックエンドを使い、アニメーションや動画も扱えます。
3. インストールと設定後に Neovim を再起動します。Markdown ファイルを開き、`:MdRender tab` でプレビュー、`q` で閉じます。Snacks と `magick` の設定後は、読み込み済みの画像上で Enter を押すと画像タブが開きます。`+` / `-` でズーム、`hjkl` でパン、`f` で全体表示、`q` で文書に戻ります。

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
| [FFmpeg](https://ffmpeg.org/) (`ffmpeg` / `ffprobe`) | ネイティブバックエンド：JPEG/WebP → PNG 変換、アニメーション GIF / 動画のフレーム展開 | ImageMagick にフォールバック（画像のみ。動画には ffmpeg が必要） |
| [ImageMagick](https://imagemagick.org/) (`magick`) | Snacks の画像変換と画像タブのズーム・パン、ネイティブの画像変換と GIF フレーム展開 | ネイティブの変換は下表のツールで代替可。画像タブは PNG でも `magick` が必須で、`ffmpeg`、`sips`、`convert` のみのインストールでは代替できません |
| [Mermaid CLI](https://github.com/mermaid-js/mermaid-cli) (`mmdc`) とヘッドレスブラウザ | 両バックエンドで Mermaid ダイアグラムを描画 | `npx -y @mermaid-js/mermaid-cli` にフォールバック（Node.js/npm が必要で、CLI をダウンロードする場合があります）。ブラウザも引き続き必要です |
| [PlantUML](https://plantuml.com/) (`plantuml`、または `java` と `$PLANTUML_JAR`) | PlantUML ダイアグラムを画像として描画 | 指定した場合のみ PlantUML サーバ（curl が必要）。指定が無ければコードブロックのまま |
| [budoux.lua](https://github.com/delphinus/budoux.lua) | CJK フレーズ単位の改行（BudouX） | 1文字ずつ分割（禁則処理は維持） |
| Treesitter パーサー | コードブロックのシンタックスハイライト | ハイライトなしで表示 |
| [nvim-web-devicons](https://github.com/nvim-tree/nvim-web-devicons) または [mini.icons](https://github.com/echasnovski/mini.icons) | コードブロックヘッダのファイルタイプアイコン | 内蔵アイコンテーブル |

**ネイティブバックエンド**では、画像・動画の変換ツールを以下の順で検索します。[Snacks の変換](https://github.com/folke/snacks.nvim/blob/main/docs/image.md) は PNG 以外に ImageMagick を使うため、このフォールバック順序は適用されません。

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

アニメーションと動画の再生はネイティブバックエンドの機能です。Snacks バックエンドは画面外も含む文書全体の画像を準備します。ダイアグラム描画とダウンロードは全プレビューで同時に 2 ジョブまで実行し、プレビューを閉じても実行中の処理はキャッシュへの保存まで完了する場合があります。画像が多い文書では初期処理量が増えます。

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
vim.keymap.set("n", "<leader>mp", "<Plug>(md-render-preview)",     { desc = "Markdown preview (toggle)" })
vim.keymap.set("n", "<leader>mt", "<Plug>(md-render-preview-tab)", { desc = "Markdown preview in tab (toggle)" })
vim.keymap.set("n", "<leader>md", "<Plug>(md-render-demo)",        { desc = "Markdown render demo" })
```

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
| `:MdRender textsize [on\|off\|toggle]` | **[実験的]** Kitty text sizing protocol で見出しを拡大(既定で有効) |
| `:MdRender pager` | ページャーモード — フルスクリーン、装飾なし、`q` で Neovim 終了 |
| `:MdRender demo` | 対応する全 Markdown 記法のデモウィンドウを表示 |

タブ補完では第1引数としてサブコマンド一覧、`auto` と `textsize` の後では `on` / `off` / `toggle` が候補になります。

> **後方互換について。** 従来のトップレベルコマンド (`:MdRenderTab`、`:MdRenderToggle`、`:MdRenderSplit`、`:MdRenderAuto`、`:MdRenderPager`、`:MdRenderDemo`) は新しいディスパッチャへ転送されるエイリアスとして残しています。Neovim セッションごとに最初の呼び出しで非推奨警告を1度だけ表示します。将来のメジャーバージョンで削除されます。

### その場トグル

`:MdRender toggle` は、現在のウィンドウをソース Markdown バッファとそのレンダリング表示の間で**その場で**切り替えます。新しいタブやフローティングウィンドウは開きません。スプリットレイアウトでコードと README のレンダリングを並べたい、といった用途を想定しています。

```vim
:vsplit README.md
:MdRender toggle
```

挙動:

- レンダーバッファは**読み取り専用**で、トグル間で再利用されます(ソース1つにつきレンダーバッファ1つ)。
- 同じソースが複数のウィンドウで表示されている場合、切替はそのウィンドウだけに作用し、他のウィンドウの編集は次に当該ウィンドウをレンダーモードにした時点で反映されます。
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

> **実験的機能です。** 新しく追加された Kitty 専用の機能です。UX が変わったり、機能ごと取り下げられる可能性があります。問題や違和感があればぜひお知らせください。

Kitty 0.40 で追加された [text sizing protocol](https://sw.kovidgoyal.net/kitty/text-sizing-protocol/) (OSC 66) は、テキストを基準フォントサイズの定数倍で描画します。md-render はこれを使って、見出しのレベルごとに大きさを変えます:

| レベル | `#` | `##` | `###` | `####` | `#####` | `######` |
|---|---|---|---|---|---|---|
| 倍率 | 2.00 倍 | 1.75 倍 | 1.50 倍 | 1.40 倍 | 1.25 倍 | 1.17 倍 |

端末が対応していれば設定なしで有効になります。切りたいときは `:MdRender textsize off`、常に切っておきたいときは次のようにします:

```lua
require("md-render.text_size").setup { enabled = false }
```

倍率は固定です。Kitty の `s=` はフォントだけでなく**セルの数**を倍にするため、どのレベルも `s=2` に固定して確保する描画行を 1 行だけに抑え、2 倍未満の大きさはプロトコルの小数倍と、描画幅を指定する `w=` の組み合わせで作っています。`d` は 15 まで、`w` は 7 までという制限があるため、いちばん深いレベルは等倍寄りではなく 1.17 倍で止まっています。

見出しは `1 / 倍率` の幅で折り返すので、たまたま収まったものだけでなくすべてのレベルが拡大されます。折り返した行はそれぞれ 2 行ぶんのブロックになります。

小数倍で拡大する見出しは、複数の run に分けて送ります。run ごとに描画幅を整数セルで宣言する必要がある一方、中身のテキストの幅は整数セルとは限らないためです。この幅は切り上げます (足りないと Kitty が文字を捨てるため)。そのうえで run の切れ目は余りが消える位置を選び、ちょうど整数で収まる位置が無ければ空白の直後で切るので、余りは単語の途中の穴ではなく少し広い語間として見えます。

絵文字は単独の run にします。幅を宣言した run は Kitty にとって 1 つの multicell 文字であり、multicell は 1 つのフォントで整形されるため、絵文字を普通のテキストと同じ run に混ぜると run 全体が巻き添えになります。Kitty 0.48 での実測では、絵文字が run の途中にあると run のセルがすべてグリフ欠落の四角になり、先頭にあると残りのテキストが消えます。単独の run なら正しく描画されます。代償はその run 自身の切り上げで、絵文字の前後が少し広い間隔になり、それで収まらなくなった見出しは等倍のままになります。`#` は例外です。`s=` だけで拡大するので run は幅を宣言せず、セルへの分割とセルごとのフォント選択は Kitty がやってくれます。

拡大テキストはインライン画像と同じく端末へ直接書き込むので、Neovim はこの描画を関知しません。等倍の見出しはバッファに残したままその上に重ね描きするため、端末が再描画すれば空行ではなく通常の見出しに戻り、`y` / `/` / `:w` は本来のテキストを見ます。

既知の制限:

- **Kitty 0.40 以降でのみ動作します。** 対応判定は端末に自己申告させる方法 (XTVERSION) で行い、肯定的な応答があった場合のみ有効になります。これは意図的に厳しくしてあり、OSC 66 を**ペイロードのテキストごと**捨てる端末があるためです(等倍で表示されるのではなく、見出しが消えてしまう)。それ以外の端末では何も起こらず、見出しは従来どおりに描画されます。
- 見出し内のインライン書式(インラインコード・リンク・`==highlight==`)は拡大中は色が失われます。
- どのレベルも 2 行ぶんのブロックを確保しますが、それを埋めるのは `#` だけなので、残りはブロックの中央に配置しています (`v=2`)。プロトコルの既定は上辺揃えで、特に `######` (2 倍の高さのブロックに 1.17 倍) では見出しの下にほぼ 1 行ぶんの空白が残ってしまいます。
- レベルアイコンは等倍のままですが、下地の素のテキストではなく独立した run として描画します。こうすることで同じブロックの中央に揃い、見出しと同じ高さに並びます (`s=2` に対する `n=1:d=2` がセルの拡大をちょうど打ち消します)。独立した run にすることは可読性の面でも必要です。Kitty は拡大されたテキストに元の 1 セルあたり `s` セルだけを割り当てますが、これらの Nerd Font グリフは幅 1 セルと報告されながら実際にはより広く描画されるため、見出しの run に混ぜると切り取られてしまいます(`󰉬` が「H」だけになる)。単独なら `w=1` でアイコンが元々占めている 2 セルぶんのブロックが与えられ、収まります。
- 2 行目がウィンドウの外にはみ出す見出しは、スクロールして見えるようになるまで等倍のままです。
- 他の何かによる再描画(他のプラグインによる強制再描画、メッセージやポップアップの重なり、マウススクロール時に端末がセルをずらす動作)が起きると、見出しは一旦等倍に戻ります。これを防ぐ手段はありません。復帰は 3 つの信号で行っており、届くのが速い順に、スクロール・リサイズ・ウィンドウの開閉は即座に描き直し、それ以外のあらゆる再描画はデコレーションプロバイダで次の tick に拾い、残りを `SafeState` (レート制限あり) と、入力待ちに戻らない再描画のための 500 ms のタイマーが受け持ちます。md-render 自身の再描画はこの経路ではなく正しく処理されます。インライン画像と拡大見出しはどちらも Neovim のグリッドの外に描かれ、どちらも全画面の再描画で消えるため、再描画した側がそれを通知し、もう一方が即座に描き直します。
- **`eventignore = "all"` で囲んで再描画するプラグインがいると、1 フレームだけ取りこぼしが残ります。** これは短縮できません。上に挙げた仕組みはどれも autocmd で「何かが起きた」ことを知りますが、この設定はその autocmd を全部黙らせます。デコレーションプロバイダは autocmd ではないので発火し続け、次の tick で見出しは戻りますが、その 1 フレームだけは消えます。既知の該当例は [nvim-scrollview](https://github.com/dstein64/nvim-scrollview) です。マウスを動かしている間、毎秒約 20 回、エディタ全面のフロートを開き、小さなフロートを十数個動かし、また閉じる、という処理を `eventignore = "all"` で囲んで実行します。15 秒間の実測では `nvim_open_win` の呼び出し 308 回に対して `WinNew` の発火は 1 回でした。プレビューが画面にある間だけ止めたい場合は、開閉イベントを対にするのではなく `b:md_render` (md-render が描画するすべてのバッファで `true`) で判定してください。プレビューは複数開けますし手で分割もできるため、「今開いているか」を問うほうが数える必要が無く確実です:

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

- レイアウトが変わるたびに、前回の拡大テキストを消すために画面全体を再描画します。そのぶんスクロールのコストは通常より高くなります。同じウィンドウに画像がある場合は画像側の再描画がその役目を果たすので、拡大テキストはその後に書き込むだけです。
- Telescope と Snacks のプレビューでは無効です。カーソル移動のたびに再描画されるため、そのたびに画面全体を描き直すのは割に合いません。

詳しい背景は `:help md-render-text-size` を参照してください。

### ソース/レンダーの分割表示

<figure>
  <img src="https://github.com/user-attachments/assets/24999fe8-9ff0-4ca3-9bd1-b72ec5d7f33c" width="407" height="328" alt="ソース/レンダーの分割表示" />
  <figcaption><em>ソース/レンダーの分割表示 — 編集がインライン画像も含めてリアルタイムに反映される</em></figcaption>
</figure>

`:MdRender split` は、現在のウィンドウを分割してソースとレンダリング表示を並べます。分割方向は標準的な Vim のモディファイアに従います:

- `:MdRender split` — 水平分割
- `:vert MdRender split` — 垂直分割(README とコードを並べる定番)
- `:tab MdRender split` — 新しいタブ内で分割
- `:topleft MdRender split` — 一番上に配置
- `:botright MdRender split` — 一番下に配置

ソースの編集はライブでもう一方のウィンドウに反映され、カーソル/スクロール位置も双方向に同期します。詳細な挙動とインライン画像の制限事項は `:help :MdRender-split` を参照してください。

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

動画の再生にはネイティブバックエンド（`kitty`）を使います。Snacks バックエンドはアニメーションや動画の再生を提供しません。ネイティブバックエンドでのフレーム展開には `ffmpeg` が `$PATH` に必要です。なければ、最初のフレームを静止画として表示するフォールバックになります。パッケージマネージャでインストールしてください（例：`brew install ffmpeg`）。

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
