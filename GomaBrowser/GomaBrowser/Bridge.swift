import Foundation
import WebKit

// MARK: - goma-ext:// スキーム (拡張内ファイル配信)

final class GomaSchemeHandler: NSObject, WKURLSchemeHandler {
    weak var extensionManager: ExtensionManager?
    static let scheme = "goma-ext"

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.scheme == Self.scheme,
              let extId = url.host,
              let ext = extensionManager?.extensions.first(where: { $0.id == extId }),
              let mgr = extensionManager else {
            urlSchemeTask.didFailWithError(NSError(domain: "GomaScheme", code: 404))
            return
        }
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        // background 用の仮想ページ
        if path == "__background.html" {
            let sw = ext.manifest.background?.serviceWorker ?? ""
            let html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body><script src=\"\(sw)\"></script></body></html>"
            respond(task: urlSchemeTask, url: url, data: Data(html.utf8), mime: "text/html")
            return
        }
        let fileURL = mgr.fileURL(ext: ext, relativePath: path.removingPercentEncoding ?? path)
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(NSError(domain: "GomaScheme", code: 404))
            return
        }
        respond(task: urlSchemeTask, url: url, data: data, mime: Self.mime(for: fileURL.pathExtension))
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func respond(task: WKURLSchemeTask, url: URL, data: Data, mime: String) {
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)"])!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }
    static func mime(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html"
        case "js", "mjs": return "text/javascript"
        case "css": return "text/css"
        case "json": return "application/json"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "gif": return "image/gif"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - Background service worker 実行

final class BackgroundService {
    private(set) var webViews: [String: WKWebView] = [:] // extId -> webView
    weak var bridge: Bridge?

    func ensureRunning(ext: InstalledExtension, manager: ExtensionManager, schemeHandler: GomaSchemeHandler) {
        guard ext.isEnabled, ext.manifest.background?.serviceWorker != nil else { return }
        if webViews[ext.id] != nil { return }
        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge!, name: Bridge.handlerName)
        config.setURLSchemeHandler(schemeHandler, forURLScheme: GomaSchemeHandler.scheme)
        let shim = ShimFactory.userScript(extId: ext.id, context: "background", tabId: nil, manifest: ext.manifest)
        config.userContentController.addUserScript(shim)
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 10, height: 10), configuration: config)
        // 隠しWebViewは画面外ホストビューに載せて JS タイマを止められにくくする
        BackgroundHost.shared.attach(wv)
        webViews[ext.id] = wv
        let url = URL(string: "\(GomaSchemeHandler.scheme)://\(ext.id)/__background.html")!
        wv.load(URLRequest(url: url))
    }

    func stop(extId: String) {
        if let wv = webViews.removeValue(forKey: extId) { wv.removeFromSuperview() }
    }
    func webView(for extId: String) -> WKWebView? { webViews[extId] }
}

/// 隠しWKWebViewを載せるだけのオフスクリーンView（App起動時にwindowへ追加）
final class BackgroundHost: UIView {
    static let shared = BackgroundHost(frame: CGRect(x: -20, y: -20, width: 10, height: 10))
    func attach(_ wv: WKWebView) {
        DispatchQueue.main.async {
            wv.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
            self.addSubview(wv)
        }
    }
}

// MARK: - Shim 組み立て

enum ShimFactory {
    static var shimSource: String = {
        guard let url = Bundle.main.url(forResource: "chrome-shim", withExtension: "js"),
              let src = try? String(contentsOf: url, encoding: .utf8) else {
            NSLog("[GomaBrowser] chrome-shim.js missing")
            return ""
        }
        return src
    }()

    static func preamble(extId: String, context: String, tabId: Int?, manifest: ExtensionManifest?) -> String {
        var manifestJSON = "{}"
        if let m = manifest, let data = try? JSONEncoder().encode(m),
           let s = String(data: data, encoding: .utf8) { manifestJSON = s }
        return """
        window.__GOMA_EXT_ID__ = \(jsonString(extId));
        window.__GOMA_CONTEXT__ = \(jsonString(context));
        window.__GOMA_TAB_ID__ = \(tabId.map(String.init) ?? "null");
        window.__GOMA_MANIFEST__ = \(manifestJSON);
        """
    }
    static func source(extId: String, context: String, tabId: Int?, manifest: ExtensionManifest?) -> String {
        preamble(extId: extId, context: context, tabId: tabId, manifest: manifest) + "\n" + shimSource
    }
    static func userScript(extId: String, context: String, tabId: Int?, manifest: ExtensionManifest?) -> WKUserScript {
        WKUserScript(source: source(extId: extId, context: context, tabId: tabId, manifest: manifest),
                     injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }
    static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[]".utf8)
        let arr = String(data: data, encoding: .utf8) ?? "[]"
        return String(arr.dropFirst().dropLast())
    }
    static func jsLiteral(_ value: Any?) -> String {
        guard let v = value, !(v is NSNull) else { return "null" }
        if let data = try? JSONSerialization.data(withJSONObject: [v]),
           let s = String(data: data, encoding: .utf8) {
            return String(s.dropFirst().dropLast())
        }
        return "null"
    }
}

// MARK: - Bridge 本体

final class Bridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "gomaBridge"

    weak var browser: BrowserViewModel?
    weak var extensionManager: ExtensionManager?
    weak var downloadManager: DownloadManager?
    let backgroundService = BackgroundService()
    weak var popupWebView: WKWebView?
    var popupExtId: String?

    /// 配送中メッセージの応答待ち: responseCallbackId -> (送信元WebView, 元callbackId)
    private var pendingResponses: [String: (WKWebView, String)] = [:]
    private var responseSeq = 0

    override init() {
        super.init()
        backgroundService.bridge = self
    }

    // MARK: 受信
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let api = body["api"] as? String,
              let method = body["method"] as? String else { return }
        let extId = body["extId"] as? String ?? ""
        let context = body["context"] as? String ?? "content"
        let senderTabId = body["tabId"] as? Int
        let args = body["args"] as? [String: Any] ?? [:]
        let callbackId = body["callbackId"] as? String ?? ""
        let source = message.webView

        switch (api, method) {
        case ("runtime", "__messageResponse"):
            if let (origin, originCb) = pendingResponses.removeValue(forKey: callbackId) {
                resolve(webView: origin, callbackId: originCb, result: ["value": args["value"] as Any], error: nil)
            }
        case ("runtime", "sendMessage"):
            handleRuntimeSendMessage(extId: extId, context: context, senderTabId: senderTabId,
                                     message: args["message"], source: source, callbackId: callbackId)
        case ("tabs", "query"):
            let tabs = queryTabs(args["query"] as? [String: Any] ?? [:], senderTabId: senderTabId)
            resolve(webView: source, callbackId: callbackId, result: ["tabs": tabs], error: nil)
        case ("tabs", "sendMessage"):
            guard let target = args["targetTabId"] as? Int else {
                resolve(webView: source, callbackId: callbackId, result: nil, error: "No tab with given id"); return
            }
            deliverToTab(tabId: target, extId: extId, message: args["message"], source: source, callbackId: callbackId)
        case ("tabs", "create"):
            let props = args["properties"] as? [String: Any] ?? [:]
            let urlStr = props["url"] as? String
            DispatchQueue.main.async {
                let tab = self.browser?.createTab(urlString: urlStr)
                self.resolve(webView: source, callbackId: callbackId,
                             result: ["tab": tab.map { self.tabDict($0) } as Any], error: nil)
            }
        case ("tabs", "get"):
            let t = (args["targetTabId"] as? Int).flatMap { id in browser?.tabs.first { $0.id == id } }
            resolve(webView: source, callbackId: callbackId, result: ["tab": t.map { tabDict($0) } as Any], error: t == nil ? "No tab" : nil)
        case ("tabs", "update"):
            resolve(webView: source, callbackId: callbackId, result: ["tab": NSNull()], error: nil) // v1: no-op成功扱い
        case ("downloads", "download"):
            let opts = args["options"] as? [String: Any] ?? [:]
            let urlStr = opts["url"] as? String ?? ""
            if let id = downloadManager?.start(urlString: urlStr, filename: opts["filename"] as? String,
                                               conflictAction: opts["conflictAction"] as? String, byExtension: extId) {
                resolve(webView: source, callbackId: callbackId, result: ["downloadId": id], error: nil)
            } else {
                resolve(webView: source, callbackId: callbackId, result: nil, error: "Invalid URL")
            }
        case ("downloads", "search"):
            let q = args["query"] as? [String: Any] ?? [:]
            let items = (downloadManager?.search(query: q) ?? []).map { $0.toChromeDict() }
            resolve(webView: source, callbackId: callbackId, result: ["items": items], error: nil)
        case ("storage", "get"):
            let values = extensionManager?.storageGet(extId: extId, keys: args["keys"]) ?? [:]
            resolve(webView: source, callbackId: callbackId, result: ["values": values], error: nil)
        case ("storage", "set"):
            extensionManager?.storageSet(extId: extId, items: args["items"] as? [String: Any] ?? [:])
            resolve(webView: source, callbackId: callbackId, result: [:], error: nil)
        case ("storage", "remove"):
            extensionManager?.storageRemove(extId: extId, keys: args["keys"])
            resolve(webView: source, callbackId: callbackId, result: [:], error: nil)
        case ("storage", "clear"):
            extensionManager?.storageClear(extId: extId)
            resolve(webView: source, callbackId: callbackId, result: [:], error: nil)
        case ("scripting", "executeScript"):
            handleExecuteScript(extId: extId, args: args, source: source, callbackId: callbackId)
        default:
            resolve(webView: source, callbackId: callbackId, result: nil, error: "Unsupported API: \(api).\(method)")
        }
    }

    // MARK: runtime.sendMessage 配送
    private func handleRuntimeSendMessage(extId: String, context: String, senderTabId: Int?, message: Any?, source: WKWebView?, callbackId: String) {
        if context != "background" {
            // content / popup -> background
            guard let bg = backgroundService.webView(for: extId) else {
                resolve(webView: source, callbackId: callbackId, result: ["value": NSNull()], error: nil)
                return
            }
            deliver(to: bg, extId: extId, message: message, sender: ["id": extId, "tab": senderTabId.map { ["id": $0] } as Any],
                    source: source, callbackId: callbackId)
        } else {
            // background -> 全タブの content (最初の応答を採用。それ以外は無視)
            let targets = browser?.tabs.map { $0.webView } ?? []
            if targets.isEmpty {
                resolve(webView: source, callbackId: callbackId, result: ["value": NSNull()], error: nil)
                return
            }
            for t in targets {
                deliver(to: t, extId: extId, message: message, sender: ["id": extId], source: source, callbackId: callbackId)
            }
        }
    }

    private func deliverToTab(tabId: Int, extId: String, message: Any?, source: WKWebView?, callbackId: String) {
        guard let tab = browser?.tabs.first(where: { $0.id == tabId }) else {
            resolve(webView: source, callbackId: callbackId, result: nil, error: "No tab with id: \(tabId)")
            return
        }
        deliver(to: tab.webView, extId: extId, message: message, sender: ["id": extId], source: source, callbackId: callbackId)
    }

    /// 対象WebViewの __gomaDeliverMessage を呼ぶ。応答は pendingResponses 経由で送信元へ返す。
    private func deliver(to target: WKWebView, extId: String, message: Any?, sender: [String: Any], source: WKWebView?, callbackId: String) {
        responseSeq += 1
        let responseId = "resp\(responseSeq)_\(callbackId)"
        if let source = source, !callbackId.isEmpty {
            pendingResponses[responseId] = (source, callbackId)
            // 応答が来ない場合のタイムアウト (Chrome はポート切断になる)
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                if let (origin, originCb) = self?.pendingResponses.removeValue(forKey: responseId) {
                    self?.resolve(webView: origin, callbackId: originCb, result: ["value": NSNull()], error: nil)
                }
            }
        }
        let js = "window.__gomaDeliverMessage && window.__gomaDeliverMessage(\(ShimFactory.jsLiteral(message)), \(ShimFactory.jsLiteral(sender)), \(ShimFactory.jsLiteral(responseId)));"
        DispatchQueue.main.async {
            target.evaluateJavaScript(js, in: .page) { _ in }
        }
    }

    // MARK: downloads.onChanged 配送
    func broadcastDownloadChanged(item: DownloadItem, previousState: GomaDownloadState?) {
        let delta = downloadDelta(item: item, previousState: previousState)
        let js = "window.__gomaDownloadsChanged && window.__gomaDownloadsChanged(\(ShimFactory.jsLiteral(delta)));"
        DispatchQueue.main.async {
            for (_, wv) in self.backgroundService.webViews { wv.evaluateJavaScript(js, in: .page) { _ in } }
            for tab in self.browser?.tabs ?? [] { tab.webView.evaluateJavaScript(js, in: .page) { _ in } }
            self.popupWebView?.evaluateJavaScript(js, in: .page) { _ in }
        }
    }

    // MARK: tabs.query
    private func queryTabs(_ query: [String: Any], senderTabId: Int?) -> [[String: Any]] {
        guard let browser = browser else { return [] }
        var tabs = browser.tabs
        if let active = query["active"] as? Bool, active {
            if let sel = browser.selectedTab { tabs = tabs.filter { $0.id == sel.id } } else { tabs = [] }
        }
        if let urlPattern = query["url"] as? String, let mp = MatchPattern(urlPattern) {
            tabs = tabs.filter { t in t.url.map { mp.matches($0) } ?? false }
        }
        // currentWindow / lastFocusedWindow は単一ウィンドウ前提で無視する
        return tabs.map { tabDict($0) }
    }
    private func tabDict(_ tab: BrowserTab) -> [String: Any] {
        [
            "id": tab.id,
            "index": browser?.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0,
            "title": tab.title,
            "url": tab.url?.absoluteString ?? "",
            "active": browser?.selectedTab?.id == tab.id,
            "highlighted": browser?.selectedTab?.id == tab.id,
            "pinned": false,
            "incognito": false,
            "windowId": 1,
            "status": tab.isLoading ? "loading" : "complete"
        ]
    }

    // MARK: scripting.executeScript (files のみ対応。func は postMessage で関数が運べないため未対応)
    private func handleExecuteScript(extId: String, args: [String: Any], source: WKWebView?, callbackId: String) {
        let injection = args["injection"] as? [String: Any] ?? [:]
        let target = injection["target"] as? [String: Any] ?? [:]
        let tabId = (target["tabId"] as? Int) ?? browser?.selectedTab?.id
        let files = injection["files"] as? [String] ?? []
        guard let tabId = tabId, let tab = browser?.tabs.first(where: { $0.id == tabId }),
              let ext = extensionManager?.extensions.first(where: { $0.id == extId }),
              let mgr = extensionManager else {
            resolve(webView: source, callbackId: callbackId, result: ["results": []], error: "executeScript: invalid target")
            return
        }
        var combined = ""
        for f in files {
            if let src = try? String(contentsOf: mgr.fileURL(ext: ext, relativePath: f), encoding: .utf8) {
                combined += "\n" + src
            }
        }
        DispatchQueue.main.async {
            tab.webView.evaluateJavaScript(combined, in: .page) { result in
                var value: Any = NSNull()
                if case .success(let v) = result { value = v }
                self.resolve(webView: source, callbackId: callbackId,
                             result: ["results": [["frameId": 0, "result": value]]], error: nil)
            }
        }
    }

    // MARK: 応答
    func resolve(webView: WKWebView?, callbackId: String, result: [String: Any]?, error: String?) {
        guard let webView = webView, !callbackId.isEmpty else { return }
        let js = "window.__gomaResolve && window.__gomaResolve(\(ShimFactory.jsLiteral(callbackId)), \(ShimFactory.jsLiteral(result)), \(ShimFactory.jsLiteral(error)));"
        DispatchQueue.main.async { webView.evaluateJavaScript(js, in: .page) { _ in } }
    }

    // MARK: content script 注入 (ナビゲーション完了時に呼ぶ)
    func injectContentScripts(into tab: BrowserTab, url: URL, atDocumentStart: Bool) {
        guard let mgr = extensionManager else { return }
        for ext in mgr.extensions where ext.isEnabled {
            guard let scripts = ext.manifest.contentScripts else { continue }
            for entry in scripts {
                let runAt = entry.runAt ?? "document_idle"
                let isStart = (runAt == "document_start")
                if isStart != atDocumentStart { continue }
                let matched = (entry.matches ?? []).contains { p in MatchPattern(p)?.matches(url) ?? false }
                let excluded = (entry.excludeMatches ?? []).contains { p in MatchPattern(p)?.matches(url) ?? false }
                guard matched, !excluded else { continue }
                var source = ShimFactory.source(extId: ext.id, context: "content", tabId: tab.id, manifest: ext.manifest)
                for css in entry.css ?? [] {
                    if let cssText = try? String(contentsOf: mgr.fileURL(ext: ext, relativePath: css), encoding: .utf8) {
                        source += "\n;(function(){var s=document.createElement('style');s.textContent=\(ShimFactory.jsLiteral(cssText));(document.head||document.documentElement).appendChild(s);})();"
                    }
                }
                for js in entry.js ?? [] {
                    if let code = try? String(contentsOf: mgr.fileURL(ext: ext, relativePath: js), encoding: .utf8) {
                        source += "\n" + code
                    }
                }
                let full = source
                DispatchQueue.main.async {
                    tab.webView.evaluateJavaScript(full, in: .page) { result in
                        if case .failure(let e) = result {
                            NSLog("[GomaBrowser] content script inject failed (\(ext.name)): \(e)")
                        }
                    }
                }
            }
        }
    }
}
