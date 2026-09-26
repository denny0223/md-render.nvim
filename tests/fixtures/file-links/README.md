# 渲染連結：手動測試首頁

這是 #4 的可操作範例。將游標放在渲染後的連結文字上，按 `gf` 開啟；按 `Ctrl-O` 返回，按 `Ctrl-I` 前進。

[前往指南 B](docs/guide.md)

## 啟動方式

先在終端切到這次修改的 worktree：

```bash
cd /home/denny/repo/md-render.nvim-file-links
nvim -u NONE -i NONE -n \
  --cmd 'lua vim.opt.rtp:prepend(vim.fn.getcwd())' \
  -c 'runtime plugin/md-render.lua' \
  -c 'packadd netrw' \
  -c 'set hidden' \
  -c 'autocmd VimEnter * ++once MdRender toggle' \
  tests/fixtures/file-links/README.md
```

這個指令會載入目前 worktree 的程式，並啟用內建 netrw 供目錄測試。圖片需要支援 Kitty 圖形協定的終端；連結導覽可以先獨立測試。

每換一種模式，重新執行啟動指令，替換其中的預覽命令：

| 模式 | 預覽命令 | 如何操作 |
| --- | --- | --- |
| 同視窗 | `MdRender toggle` | 直接在目前渲染視窗測試 |
| 分割視窗 | `vert MdRender split` | 先按 `Ctrl-W w`，移到渲染的一側 |
| 浮動視窗 | `MdRender float` | 在浮動預覽中測試 |
| 分頁 | `MdRender tab` | 在預覽分頁中測試 |

測完可用 `:qa!` 離開並捨棄這次範例的未儲存修改。

## 1. Markdown 連續導覽

先從本頁上方的「前往指南 B」按 `gf`，再從指南開啟「繼續到終點 C」。兩次跳轉都應保持渲染，沿用原本的預覽視窗與模式。

接著按兩次 `Ctrl-O`，應依序回到指南和本首頁；按 `Ctrl-I` 應能前進。

## 2. 一般檔案與標籤誤導

[開啟可編輯筆記](notes.txt)

預期：`notes.txt` 在原始編輯視窗開啟，能正常輸入文字。浮動／分頁預覽會先關閉。若使用 split，原有預覽會保留。

可輸入一行文字、按 `Esc`，再按 `Ctrl-O`：應恢復本頁的渲染狀態。按 `Ctrl-I` 回到筆記，剛輸入但未儲存的文字仍應存在。

下面這個連結刻意把顯示文字寫成實際存在的 `notes.txt`，目的地卻是 Markdown 指南：

[notes.txt](docs/guide.md "實際目的地是指南")

預期：開啟「指南 B」的渲染畫面。

也可測試首頁 A → 指南 B → 一般筆記，再按 `Ctrl-O`：應返回渲染的 B。若過程換到原始編輯視窗，之後的 `Ctrl-O` 依該視窗原生歷史移動，不保證再回到渲染的 A；toggle 留在同一視窗則仍可沿原本的渲染歷史返回。

## 3. 特殊檔名、標題與參照連結

[編碼的空白與井字號](space%20%23name.md#section)

預期：開啟檔名 `space #name.md`，標題顯示「編碼檔名」。目前 fragment 不會跳到指定標題。

[檔名有連續兩個空白](<two  spaces.md> "保留檔名中的兩個空白")

預期：標題顯示「正確：兩個空白」。旁邊另有 `two spaces.md` 作為誤開對照，不應開到它。

[括號檔名](<version(1).md> "版本 (1)")

[用參照連結開啟同一份指南][guide]

以上每個連結都可用 `gf` 開啟，再用 `Ctrl-O` 回來。

## 4. 與工作目錄無關

在渲染預覽執行 `:cd /tmp`，再測試下方連結：

[工作目錄改變後仍開啟指南](docs/guide.md)

預期：仍能開啟這組範例中的指南。相對路徑以連結所在的 Markdown 檔案為準。

## 5. 開啟目錄

[瀏覽 docs 目錄](docs/)

預期：在原始編輯視窗交給目錄瀏覽器開啟，能看到 `guide.md` 與 `end.md`。浮動／分頁預覽會先關閉，split 預覽保留；按 `Ctrl-O` 返回本頁渲染。目錄瀏覽器的按鍵、前進行為與緩衝區生命週期沿用你的既有設定。

## 6. 不應開啟的目標

[不存在的檔案](missing.md)

[外部網址](https://example.com/)

在這兩個連結上按 `gf`，應留在目前預覽並顯示原因；不會建立 `missing.md`。訊息可用 `:messages` 查看。

## 7. 摺疊、展開與圖片

> [!NOTE]- 先展開這個區塊
> 將游標放在這個標題上按 `za`。展開後開啟指南，再用 `Ctrl-O` 回來，區塊應維持展開。

下面的長程式碼會提供展開／收合操作；游標放在區塊上按 `za`，再測試導覽與返回。

```text
這是一行刻意加長的程式碼範例，用來測試展開狀態在導覽之後仍能保留。ABCDEFGHIJKLMNOPQRSTUVWXYZ-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ-0123456789-ABCDEFGHIJKLMNOPQRSTUVWXYZ-0123456789
```

![藍色測試圖片](../../../assets/demo/test.png)

若終端支援圖片，離開本頁再返回後，圖片應重新出現。開啟筆記時，筆記的編輯區不應被舊圖片覆蓋；split 模式中保留的預覽仍可顯示圖片。

## 8. 原生 gf 與新視窗

下面是普通文字，不是 Markdown 連結。游標放在檔名上按 `gf`，應使用 Neovim 原生開檔行為：

notes.txt

也可以先執行 `:split` 複製目前預覽，再測試「開啟可編輯筆記」。連結應能開啟；返回或切換焦點時，編輯視窗的選項與關閉行為應正常。

## 9. 重複造訪與閱讀位置

操作路線：先從本頁上方前往指南 B → 在指南按「重新造訪首頁 A」→ 移到本頁頁尾的連結前往終點 C。

從 C 按三次 `Ctrl-O`：第一次回本頁頁尾、第二次回指南、第三次回本頁上方的第一次出發位置。可再試 `3Ctrl-O`／`3Ctrl-I` 前後導覽。

[從頁尾前往終點 C](docs/end.md)

[guide]: <docs/guide.md> "參照式連結的選用標題"
