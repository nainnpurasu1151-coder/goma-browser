# ごまブラウザ v1

iPad 用の自作ブラウザアプリ（SwiftUI + WKWebView）。目的は **iPad の Chrome には無い「Chrome 拡張機能（Manifest V3）」の仕組みを自作し、自分で作った拡張を動かすこと**。
最優先対応の拡張は同梱の「ごま動画セーバー v2.1」（YouTube の動画を GUI で選んで MP4 保存する拡張）。

## 機能

- ブラウザ本体: アドレスバー（URL / 検索）、戻る / 進む / 再読み込み（読み込み中は停止）、横スクロールのタブバー（追加・切替・閉じる）
- ダウンロード一覧: アプリ内 `Documents/Downloads` に保存。進捗表示、共有シート（ファイルアプリ等へ渡せる）、削除。`UIFileSharingEnabled` 有効なので「ファイル」アプリからも見える
- 拡張機能の管理画面: 有効 / 無効の切替、削除、zip 取り込み、解凍済みフォルダ取り込み

## Chrome 拡張互換レイヤー

拡張は `Application Support/Extensions/` に保存され、manifest.json（MV3）を解析して登録します。
JS 側の窓口は `GomaBrowser/Resources/chrome-shim.js`、ネイティブ側の受け口は `Bridge.swift` です。

### 仕組み

| 部品 | 実体 |
|---|---|
| content_scripts | ページ読み込み時（didCommit ≒ document_start / didFinish ≒ document_idle・document_end）に、matches に一致した拡張の shim + JS を **ページ本体ワールド（WKContentWorld.page）** へ評価注入。CSS は `<style>` 注入 |
| background service_worker | 画面外の隠し WKWebView で実行。`goma-ext://<拡張ID>/__background.html` という仮想ページから service_worker を読み込む |
| action popup | popup.html を小さい WKWebView で表示し、同じ shim を通す |
| 拡張内ファイル | カスタムスキーム `goma-ext://<拡張ID>/<パス>` で配信（`chrome.runtime.getURL` もこの形式） |
| メッセージ | `webkit.messageHandlers.gomaBridge` 経由でネイティブが中継。sendResponse / `return true` の非同期応答、Promise 応答に対応。応答なしは 30 秒でタイムアウト |

content script をページ本体ワールドに入れるのは意図的です。ごま動画セーバーは YouTube の player API を「ページ内スクリプト」から叩く設計でないと Google にブロックされる経緯があったためです。

### 対応 API（v1）

- `chrome.runtime`: `sendMessage` / `onMessage` / `getURL` / `getManifest` / `id` / `lastError`
- `chrome.tabs`: `query`（active / url パターン対応、currentWindow は単一ウィンドウ前提で無視）/ `sendMessage` / `create` / `get` / `update`（no-op）
- `chrome.downloads`: `download`（conflictAction: uniquify 対応）/ `search`（id / state / query）/ `onChanged`。`pause` / `resume` / `cancel` / `erase` はスタブ（何もしない）
- `chrome.storage.local`: get / set / remove / clear（拡張ごとに JSON ファイルへ永続化）。`storage.sync` は local と同一扱い
- `chrome.scripting.executeScript`: `files` 指定のみ対応（`func` はメッセージ経由で関数を運べないため未対応）
- `chrome.action.setBadgeText` / `setTitle`: スタブ

### 未対応（v1 の割り切り）

- **Chromium そのものではありません。** 中身は WebKit (WKWebView) です。Chrome 専用の挙動や API に依存する拡張は動きません
- `chrome.webRequest` / `chrome.declarativeNetRequest` は未対応（広告ブロック系は不可）
- **Chrome ウェブストアの任意の拡張が動く保証はありません。** 自作拡張を前提に、上記 API の範囲で動くものだけが対象です
- service_worker の「一定時間で停止・再起動」モデルは再現していません（常駐に近い挙動）。`setInterval` 前提の拡張（ごま動画セーバーの進捗ポーリング等）はこの方が都合が良いですが、メモリ消費は増えます
- 同一ページに複数拡張の content script が入ると `window.chrome` が競合します（v1 は実質 1 拡張ずつが前提）
- zip 解凍は依存なしの自前実装（store / deflate）。動かない場合は「解凍済みフォルダを取り込む」経路を使ってください
- ページの権限ダイアログ、ファイルダウンロードの `saveAs` ダイアログ、タブのピン留め等は未実装

## 同梱拡張

`GomaBrowser/Resources/Extensions/goma-video-saver/` に「ごま動画セーバー v2.1」を同梱し、初回起動時に自動で登録・有効化されます（元ソース: `~/workspace/youtube-offline-test/goma-video-saver2/`）。

使う API はすべて上記の対応範囲内です:
`chrome.downloads.download/onChanged/search`、`chrome.runtime.sendMessage/onMessage/lastError`、`chrome.tabs.query/sendMessage`、content_scripts（`https://www.youtube.com/*`、document_idle）、background service_worker、action popup、permissions: downloads / activeTab、host_permissions: youtube.com / *.googlevideo.com。

## ビルド（未署名 IPA）

GitHub Actions（`.github/workflows/build-ipa.yml`）が macOS ランナーで:

1. `xcodebuild` を `CODE_SIGNING_ALLOWED=NO` でビルド
2. `.app` を `Payload/` に固めて `GomaBrowser-unsigned.ipa` を作成
3. artifact `GomaBrowser-unsigned-ipa` にアップロード

手動実行は Actions タブの「Build GomaBrowser IPA (unsigned)」→ Run workflow。

## iPad への入れ方（SideInstaller）

WindowsiOS と同じ方式です。

1. GitHub Actions の artifact から `GomaBrowser-unsigned.ipa` をダウンロード
2. iPad の SideInstaller で IPA を選び、自分の Apple ID で署名してインストール
3. 起動すると YouTube が開き、ごま動画セーバーが有効な状態で始まります

### 署名枠について（無料 Apple ID は 3 枠）

現在 SideInstaller / StikDebug / WindowsiOS で 3 枠埋まっている可能性があります。
**WindowsiOS は StikJIT 内蔵化（Phase 4）済みで単体 StikDebug は不要になっているため、単体 StikDebug を削除すれば 1 枠空く見込み**です。ごまブラウザを入れる前に StikDebug の削除で枠を空けてください。

## ローカル検証

```sh
node Tests/run-tests.js
```

JS 構文チェック、同梱 manifest の解析と API カバレッジ、URL パターンマッチ 14 ケースを実行します（結果は `Tests/test-results.txt`）。
Swift はこの開発 VM ではコンパイルできません。初回コンパイルは GitHub Actions になります（詳細は REPORT.md）。
