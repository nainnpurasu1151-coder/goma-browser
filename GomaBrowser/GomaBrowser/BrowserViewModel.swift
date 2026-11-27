import Foundation
import WebKit

final class BrowserViewModel: NSObject, ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var selectedTabId: Int?
    private var nextTabId = 1

    let extensionManager = ExtensionManager()
    let downloadManager = DownloadManager()
    let bridge = Bridge()
    let schemeHandler = GomaSchemeHandler()
    let linkSaver = LinkSaverEngine()

    var selectedTab: BrowserTab? { tabs.first { $0.id == selectedTabId } }

    override init() {
        super.init()
        schemeHandler.extensionManager = extensionManager
        bridge.browser = self
        bridge.extensionManager = extensionManager
        bridge.downloadManager = downloadManager
        linkSaver.downloadManager = downloadManager
        downloadManager.onChanged = { [weak self] item, prev in
            self?.bridge.broadcastDownloadChanged(item: item, previousState: prev)
        }
        createTab(urlString: "https://www.youtube.com/")
        startBackgrounds()
    }

    func startBackgrounds() {
        for ext in extensionManager.extensions where ext.isEnabled {
            bridge.backgroundService.ensureRunning(ext: ext, manager: extensionManager, schemeHandler: schemeHandler)
        }
    }

    @discardableResult
    func createTab(urlString: String?) -> BrowserTab {
        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: Bridge.handlerName)
        config.setURLSchemeHandler(schemeHandler, forURLScheme: GomaSchemeHandler.scheme)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // 有効な拡張の shim を documentStart にページワールドへ注入する
        for ext in extensionManager.extensions where ext.isEnabled {
            config.userContentController.addUserScript(
                ShimFactory.userScript(extId: ext.id, context: "content", tabId: nextTabId, manifest: ext.manifest))
            // content scripts も WKUserScript でネイティブ注入する (URLマッチは JS ガードで判定。
            // run_at は document_start / それ以外→documentEnd に寄せる)
            for entry in ext.manifest.contentScripts ?? [] {
                let patterns = entry.matches ?? []
                guard !patterns.isEmpty else { continue }
                let time: WKUserScriptInjectionTime = (entry.runAt == "document_start") ? .atDocumentStart : .atDocumentEnd
                for file in entry.js ?? [] {
                    if let code = try? String(contentsOf: extensionManager.fileURL(ext: ext, relativePath: file), encoding: .utf8) {
                        config.userContentController.addUserScript(
                            WKUserScript(source: ShimFactory.guardedContentScript(code, patterns: patterns),
                                         injectionTime: time, forMainFrameOnly: false, in: .page))
                    }
                }
                for file in entry.css ?? [] {
                    if let css = try? String(contentsOf: extensionManager.fileURL(ext: ext, relativePath: file), encoding: .utf8) {
                        let payload = ";(function(){var s=document.createElement('style');s.textContent=\(ShimFactory.jsLiteral(css));(document.head||document.documentElement).appendChild(s);})();"
                        config.userContentController.addUserScript(
                            WKUserScript(source: ShimFactory.guardedContentScript(payload, patterns: patterns),
                                         injectionTime: time, forMainFrameOnly: false, in: .page))
                    }
                }
            }
        }
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.allowsBackForwardNavigationGestures = true
        // iPad 向けにデスクトップ寄り表示 (YouTube の PC 向けUIでカード一覧を出すため)
        wv.customUserAgent = "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 GomaBrowser/1.0"
        let tab = BrowserTab(id: nextTabId, webView: wv)
        nextTabId += 1
        wv.navigationDelegate = self
        wv.uiDelegate = self
        tabs.append(tab)
        selectedTabId = tab.id
        if let s = urlString, let url = normalizedURL(from: s) {
            wv.load(URLRequest(url: url))
        }
        return tab
    }

    func closeTab(_ tab: BrowserTab) {
        tab.webView.stopLoading()
        tabs.removeAll { $0.id == tab.id }
        if selectedTabId == tab.id { selectedTabId = tabs.last?.id }
        if tabs.isEmpty { createTab(urlString: nil) }
    }

    func select(_ tab: BrowserTab) { selectedTabId = tab.id }

    func navigateSelected(to input: String) {
        guard let tab = selectedTab, let url = normalizedURL(from: input) else { return }
        tab.webView.load(URLRequest(url: url))
    }

    /// アドレスバー入力 -> URL (検索語は DuckDuckGo へ)
    func normalizedURL(from input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if let u = URL(string: s), u.scheme != nil, u.host != nil { return u }
        if !s.contains(" "), s.contains(".") {
            return URL(string: "https://" + s)
        }
        let q = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        return URL(string: "https://duckduckgo.com/?q=\(q)")
    }
}

// MARK: - WKNavigationDelegate / WKUIDelegate
extension BrowserViewModel: WKNavigationDelegate, WKUIDelegate {
    private func tab(for webView: WKWebView) -> BrowserTab? { tabs.first { $0.webView === webView } }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.url = webView.url
        tab.isLoading = true
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.url = webView.url
        tab.title = webView.title ?? webView.url?.host ?? "タブ"
        tab.isLoading = false
        tab.canGoBack = webView.canGoBack
        tab.canGoForward = webView.canGoForward
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let tab = tab(for: webView) else { return }
        tab.isLoading = false
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let tab = tab(for: webView) else { return }
        tab.isLoading = false
    }
    // target=_blank を同一タブで開く (v1 簡易対応)
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
