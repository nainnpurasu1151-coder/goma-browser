# ごまブラウザ v1 — 設計・検証レポート

作成: 2026-11-26。盛らない方針で、未検証は未検証と明記する。

## 設計判断

1. **content script は WKContentWorld.page（ページ本体）注入**
   ごま動画セーバー v2.1 の content.js は YouTube player API をページ内から叩く設計が必須だった（拡張オリジンから叩くと Google にブロックされる、という既存の知見）。そのため分離ワールドではなくページ本体へ shim ごと注入する。代償としてページ側 JS から `window.chrome` が見える・複数拡張で競合する。v1 は自作拡張専用ブラウザなので許容した（README に明記）。

2. **注入タイミングはナビゲーションイベント駆動**
   WKUserScript は URL マッチを持てないため、didCommit（≒document_start）と didFinish（≒document_idle / document_end）で MatchPattern を評価して該当スクリプトを evaluateJavaScript 注入する方式にした。document_idle 拡張（セーバー）には十分だが、document_start の厳密なタイミング保証はない。

3. **background は隠し WKWebView 常駐**
   MV3 の service_worker 停止モデルは再現せず常駐。セーバーの background.js は `setInterval` 2.5 秒で downloads.search ポーリングする設計で、常駐の方が素直に動く。仮想ページ `goma-ext://<id>/__background.html` から service_worker を `<script src>` で読み、相対パス解決もスキームハンドラに寄せた。

4. **メッセージ中継は単一ブリッジ**
   全文脈（content / background / popup）が `webkit.messageHandlers.gomaBridge` に送り、Swift 側 Bridge が配送・応答管理（pendingResponses + 30 秒タイムアウト）。downloads.onChanged は全 background・全タブ・popup へブロードキャスト。

5. **ダウンロードは URLSession**
   Documents/Downloads へ保存、index を JSON 永続化、再起動時は in_progress を interrupted として復元。chrome.downloads.search の in_progress 進捗は実タスクの countOfBytes で最新化する（セーバーのポーリング表示のため）。

6. **zip 解凍は自前実装 + フォルダ取り込みの保険**
   iOS 標準に zip 解凍 API がなく、外部ライブラリも入れられない（SPM 取得は Actions で可能だが v1 は依存ゼロを優先）。ZipReader は store / deflate のみ。deflate は raw deflate を zlib 形式に包み直して Compression を使う簡易変換で、**実機未検証**。保険として「解凍済みフォルダを取り込む」経路を併設した。

## 検証結果（この VM で実施）

| 検証 | 方法 | 結果 |
|---|---|---|
| JS 構文 | `node --check`（shim、同梱拡張の background/content/popup、テスト） | 全て PASS |
| manifest 解析 | Tests/run-tests.js で同梱 manifest.json を読み、MV3・各ファイル存在・run_at を確認 | PASS |
| API カバレッジ | 拡張ソースから `chrome.*` 使用箇所を抽出し shim の定義と突合 | 使用 8 API 全て shim に定義あり |
| URL パターンマッチ | Swift 版と同仕様の JS 実装で 14 ケース（youtube / *.googlevideo.com / * スキーム / <all_urls> / path glob） | 14/14 PASS |
| pbxproj 構造 | 括弧バランス、オブジェクト ID 33 件の参照整合、参照ファイルの実在確認 | 整合 OK、欠落ファイルなし |
| ワークフロー YAML | Python yaml でパース | OK |
| Swift 括弧バランス | 全 10 ファイルで {} / () の差分 | 全て 0 |

テスト出力は `Tests/test-results.txt` に保存済み（36 passed, 0 failed）。

## 未検証（正直な記録）

- **Swift はこの VM でコンパイルしていない**（Xcode が無い）。初回コンパイルは GitHub Actions。型・API の使い方でコンパイルエラーが出る可能性は残る。特にリスクが高いのは:
  - `ZipReader.swift` の Compression ストリーム API の使い方（コンパイル・実行の両方）
  - `Bridge.swift` の `evaluateJavaScript(_:in:completionHandler:)`（WKContentWorld 版）呼び出し形式
  - SwiftUI の `.onChange(of:)` クロージャ形式
- 実機動作（拡張の注入、ダウンロード、popup 表示）は未検証。川原の iPad での確認が初回になる。
- WKWebView の `loadHTMLString` ではなくスキーム経由で background を読む方式は、WKURLSchemeHandler が `<script src>` の相対解決まで含めて期待通り動くか未検証。
- YouTube 側の player API が WKWebView（Safari UA）から叩けるかは実機でしか分からない。デスクトップ寄り UA を設定してあるが保証はない。
- 隠し WKWebView のタイマがバックグラウンドや画面ロック時にどう制限されるか未検証（フォアグラウンド使用が前提）。

## 残課題（v1.1 以降の候補）

- Actions 初回ビルドのエラー修正（発生したらログを見て直す）
- 実機でセーバーの一連の流れ（カード選択 → 取得 → ダウンロード → パネル表示）の確認
- zip 解凍が実機で失敗する場合、実績のある解凍実装への差し替え
- `chrome.storage.sync` の分離、`scripting.executeScript` の `func` 対応（関数を文字列化して運ぶ方式なら可能）
- 複数拡張が同一ページで競合する問題（拡張ごとに名前空間を分ける）
- webRequest / declarativeNetRequest（広告ブロック系）は設計から別物なので大きめの追加になる

## 川原側の次の手順

1. このプロジェクトを GitHub リポジトリ（WindowsiOS-build と同型の新規リポジトリ推奨）へ push
2. Actions「Build GomaBrowser IPA (unsigned)」を手動実行 → artifact `GomaBrowser-unsigned-ipa` を取得
3. 署名枠を空ける（単体 StikDebug を削除。WindowsiOS は StikJIT 内蔵済みのため不要）
4. SideInstaller で IPA を自分の Apple ID で署名してインストール
5. 起動 → YouTube でごま動画セーバーの「☑ 動画を選ぶ」が出るか確認
