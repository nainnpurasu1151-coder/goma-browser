import SwiftUI
import WebKit

struct ContentView: View {
    @StateObject private var browser = BrowserViewModel()
    @State private var addressText = ""
    @State private var showDownloads = false
    @State private var showExtensions = false
    @State private var showLinkSaver = false
    @State private var popupExtension: InstalledExtension?
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            toolbar
            Divider()
            if let tab = browser.selectedTab {
                WebView(webView: tab.webView)
                    .id(tab.id)
            } else {
                Color(.systemBackground)
            }
        }
        .sheet(isPresented: $showDownloads) {
            DownloadsView(manager: browser.downloadManager)
        }
        .sheet(isPresented: $showExtensions) {
            ExtensionsView(manager: browser.extensionManager, browser: browser)
        }
        .sheet(isPresented: $showLinkSaver) {
            LinkSaverView(engine: browser.linkSaver)
        }
        .sheet(item: $popupExtension) { ext in
            ExtensionPopupView(ext: ext, browser: browser)
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            // 隠し background WebView のホストを window に載せる
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let window = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene }).first?.windows.first {
                    BackgroundHost.shared.removeFromSuperview()
                    window.addSubview(BackgroundHost.shared)
                    BackgroundHost.shared.isUserInteractionEnabled = false
                }
            }
        }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(browser.tabs) { tab in
                    HStack(spacing: 6) {
                        Text(tab.title.isEmpty ? "タブ" : tab.title)
                            .lineLimit(1)
                            .font(.caption)
                        Button {
                            browser.closeTab(tab)
                        } label: {
                            Image(systemName: "xmark").font(.caption2)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(tab.id == browser.selectedTabId ? Color.accentColor.opacity(0.25) : Color(.secondarySystemBackground))
                    .cornerRadius(8)
                    .onTapGesture { browser.select(tab); syncAddress() }
                }
                Button {
                    _ = browser.createTab(urlString: "https://www.youtube.com/")
                    syncAddress()
                } label: {
                    Image(systemName: "plus")
                }
                .padding(.horizontal, 6)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(Color(.systemBackground))
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { browser.selectedTab?.webView.goBack() } label: { Image(systemName: "chevron.backward") }
                .disabled(!(browser.selectedTab?.canGoBack ?? false))
            Button { browser.selectedTab?.webView.goForward() } label: { Image(systemName: "chevron.forward") }
                .disabled(!(browser.selectedTab?.canGoForward ?? false))
            Button {
                if browser.selectedTab?.isLoading == true {
                    browser.selectedTab?.webView.stopLoading()
                } else {
                    browser.selectedTab?.webView.reload()
                }
            } label: {
                Image(systemName: browser.selectedTab?.isLoading == true ? "xmark" : "arrow.clockwise")
            }

            TextField("URL または検索", text: $addressText)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($addressFocused)
                .onSubmit { browser.navigateSelected(to: addressText); addressFocused = false }
                .onAppear { syncAddress() }
                .onChange(of: browser.selectedTab?.url) { _ in if !addressFocused { syncAddress() } }

            // 有効な拡張の action ボタン
            ForEach(browser.extensionManager.extensions.filter { $0.isEnabled && $0.manifest.action?.defaultPopup != nil }) { ext in
                Button {
                    popupExtension = ext
                } label: {
                    Text(String(ext.name.prefix(1)))
                        .font(.caption.bold())
                        .frame(width: 26, height: 26)
                        .background(Color(red: 0.79, green: 0.64, blue: 0.08))
                        .foregroundColor(.black)
                        .clipShape(Circle())
                }
                .accessibilityLabel(ext.name)
            }

            Button { showLinkSaver = true } label: { Image(systemName: "link.badge.plus") }
                .accessibilityLabel("リンクを貼って保存")
            Button { showDownloads = true } label: {
                ZStack {
                    Image(systemName: "arrow.down.circle")
                    if browser.downloadManager.items.contains(where: { $0.state == .inProgress }) {
                        Circle().fill(Color.orange).frame(width: 8, height: 8).offset(x: 8, y: -8)
                    }
                }
            }
            Button { showExtensions = true } label: { Image(systemName: "puzzlepiece.extension") }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
    }

    private func syncAddress() {
        addressText = browser.selectedTab?.urlString ?? ""
    }
}

// MARK: - Downloads

struct DownloadsView: View {
    @ObservedObject var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var shareItem: ShareItem?

    var body: some View {
        NavigationView {
            List {
                if manager.items.isEmpty {
                    Text("ダウンロードはまだありません").foregroundColor(.secondary)
                }
                ForEach(manager.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.filename).lineLimit(2)
                        HStack(spacing: 8) {
                            switch item.state {
                            case .inProgress:
                                if item.totalBytes > 0 {
                                    ProgressView(value: Double(item.bytesReceived), total: Double(item.totalBytes))
                                        .frame(width: 120)
                                    Text("\(Int(Double(item.bytesReceived) / Double(max(item.totalBytes, 1)) * 100))%")
                                        .font(.caption).foregroundColor(.secondary)
                                } else {
                                    Text("ダウンロード中… \(byteText(item.bytesReceived))").font(.caption).foregroundColor(.secondary)
                                }
                            case .complete:
                                Text("完了 ・ \(byteText(item.bytesReceived))").font(.caption).foregroundColor(.green)
                            case .interrupted:
                                Text("失敗: \(item.error ?? "中断")").font(.caption).foregroundColor(.red)
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            manager.deleteFile(item); manager.removeRecord(item)
                        } label: { Label("削除", systemImage: "trash") }
                        if item.state == .complete {
                            Button { shareItem = ShareItem(url: manager.fileURL(for: item)) } label: {
                                Label("共有", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    .contextMenu {
                        if item.state == .complete {
                            Button { shareItem = ShareItem(url: manager.fileURL(for: item)) } label: {
                                Label("共有 / ファイルで開く", systemImage: "square.and.arrow.up")
                            }
                            Text(manager.fileURL(for: item).path)
                        }
                    }
                }
            }
            .navigationTitle("ダウンロード")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
        .sheet(item: $shareItem) { s in ShareSheet(url: s.url) }
    }
    private func byteText(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

struct ShareItem: Identifiable { let id = UUID(); let url: URL }

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Extensions

struct ExtensionsView: View {
    @ObservedObject var manager: ExtensionManager
    @ObservedObject var browser: BrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var showFolderImporter = false
    @State private var importError: String?

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("インストール済み")) {
                    ForEach(manager.extensions) { ext in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ext.name)
                                Text("v\(ext.manifest.version ?? "?")\(ext.isBundled ? " ・ 同梱" : "")")
                                    .font(.caption).foregroundColor(.secondary)
                                if let desc = ext.manifest.description {
                                    Text(desc).font(.caption2).foregroundColor(.secondary).lineLimit(2)
                                }
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { ext.isEnabled },
                                set: { newValue in
                                    manager.setEnabled(ext, newValue)
                                    if newValue {
                                        browser.bridge.backgroundService.ensureRunning(ext: ext, manager: manager, schemeHandler: browser.schemeHandler)
                                    } else {
                                        browser.bridge.backgroundService.stop(extId: ext.id)
                                    }
                                }
                            ))
                            .labelsHidden()
                        }
                        .swipeActions {
                            if !ext.isBundled {
                                Button(role: .destructive) {
                                    browser.bridge.backgroundService.stop(extId: ext.id)
                                    manager.remove(ext)
                                } label: { Label("削除", systemImage: "trash") }
                            }
                        }
                    }
                }
                Section {
                    Button { showImporter = true } label: {
                        Label("拡張機能の zip を取り込む", systemImage: "square.and.arrow.down")
                    }
                    Button { showFolderImporter = true } label: {
                        Label("解凍済みフォルダを取り込む", systemImage: "folder.badge.plus")
                    }
                    if let e = importError {
                        Text(e).font(.caption).foregroundColor(.red)
                    }
                    Text("Chrome拡張 (Manifest V3) の zip を選んでください。対応APIは README を参照。Chromeウェブストアからの直接インストールには対応していません。")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            .navigationTitle("拡張機能")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.zip], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        do {
                            let ext = try manager.importExtension(zipURL: url)
                            browser.bridge.backgroundService.ensureRunning(ext: ext, manager: manager, schemeHandler: browser.schemeHandler)
                            importError = nil
                        } catch {
                            importError = "取り込み失敗: \(error.localizedDescription)"
                        }
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            .fileImporter(isPresented: $showFolderImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    do {
                        let ext = try manager.importExtensionFolder(folderURL: url)
                        browser.bridge.backgroundService.ensureRunning(ext: ext, manager: manager, schemeHandler: browser.schemeHandler)
                        importError = nil
                    } catch {
                        importError = "取り込み失敗: \(error.localizedDescription)"
                    }
                } else if case .failure(let error) = result {
                    importError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Extension popup

struct ExtensionPopupView: View {
    let ext: InstalledExtension
    @ObservedObject var browser: BrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?

    var body: some View {
        NavigationView {
            Group {
                if let wv = webView {
                    PopupWebView(webView: wv)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(ext.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
        }
        .onAppear { setup() }
        .onDisappear {
            browser.bridge.popupWebView = nil
            webView?.removeFromSuperview()
        }
    }

    private func setup() {
        guard webView == nil,
              let popupPath = ext.manifest.action?.defaultPopup else { return }
        let config = WKWebViewConfiguration()
        config.userContentController.add(browser.bridge, name: Bridge.handlerName)
        config.setURLSchemeHandler(browser.schemeHandler, forURLScheme: GomaSchemeHandler.scheme)
        let shim = ShimFactory.userScript(extId: ext.id, context: "popup", tabId: browser.selectedTab?.id, manifest: ext.manifest)
        config.userContentController.addUserScript(shim)
        let wv = WKWebView(frame: .zero, configuration: config)
        browser.bridge.popupWebView = wv
        browser.bridge.popupExtId = ext.id
        webView = wv
        let url = URL(string: "\(GomaSchemeHandler.scheme)://\(ext.id)/\(popupPath)")!
        wv.load(URLRequest(url: url))
    }
}

// MARK: - リンクを貼って保存 (v1.2 内蔵機能。拡張の仕組みを使わない)

/// 隠し WebView のページ内 (youtube.com) から player API を叩いて MP4 直リンクを取り、
/// DownloadManager で保存する。取得 JS は同梱拡張 content.js の fetchInfo と同じ方式。
final class LinkSaverEngine: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var loaded = false
    private(set) var isReady = false
    weak var downloadManager: DownloadManager?

    override init() {
        webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        super.init()
        webView.customUserAgent = "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15 GomaBrowser/1.0"
        webView.navigationDelegate = self
    }

    func prepare() {
        if webView.superview == nil {
            BackgroundHost.shared.addSubview(webView)
            webView.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
            webView.isHidden = true
        }
        if !loaded {
            loaded = true
            webView.load(URLRequest(url: URL(string: "https://www.youtube.com/")!))
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isReady = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { isReady = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { isReady = false }

    private func waitReady() async -> Bool {
        for _ in 0..<60 {
            if isReady { return true }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return isReady
    }

    private static let fetchBody = """
    const clients = [
      { key: "AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w", body: { context: { client: { clientName: "ANDROID", clientVersion: "20.10.38", androidSdkVersion: 30, hl: "en", gl: "US" } }, videoId: vid, playbackContext: { contentPlaybackContext: { vis: 0, splay: false, signatureTimestamp: 20000 } }, racyCheckOk: true, contentCheckOk: true } },
      { key: "AIzaSyB-1vPrdLhSz5YKrVqEaBzTrjoGVUsaXuI", body: { context: { client: { clientName: "IOS", clientVersion: "20.10.4", deviceMake: "Apple", deviceModel: "iPhone16,2", hl: "en", gl: "US", osName: "iPhone", osVersion: "18.3.2.22D82", utcOffsetMinutes: 540 } }, videoId: vid, playbackContext: { contentPlaybackContext: { vis: 0, splay: false, signatureTimestamp: 20000 } }, racyCheckOk: true, contentCheckOk: true } }
    ];
    for (const c of clients) {
      try {
        const r = await fetch("https://www.youtube.com/youtubei/v1/player?key=" + c.key + "&prettyPrint=false", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(c.body), credentials: "omit" });
        const data = await r.json();
        const fmts = (data.streamingData && data.streamingData.formats) || [];
        for (const f of fmts) {
          if (f.url && (f.mimeType || "").indexOf("video/mp4") === 0) {
            return { url: f.url, title: (data.videoDetails && data.videoDetails.title) || vid, height: f.height || 360 };
          }
        }
      } catch (e) {}
    }
    return { error: "MP4一本の形式が見つからなかった" };
    """

    /// 1本保存する。結果メッセージを返す。
    func save(videoId: String) async -> String {
        guard await waitReady() else { return "保存できなかった：YouTubeの読み込みが終わらなかった" }
        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(Self.fetchBody, arguments: ["vid": videoId], in: nil, contentWorld: .page)
        } catch {
            return "保存できなかった：\(error.localizedDescription)"
        }
        guard let dict = result as? [String: Any], let url = dict["url"] as? String else {
            return "保存できなかった：\((result as? [String: Any])?["error"] as? String ?? "形式が見つからなかった")"
        }
        let rawTitle = dict["title"] as? String ?? videoId
        let height = dict["height"] as? Int ?? 360
        var title = rawTitle.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { title = videoId }
        let filename = String(title.prefix(80)) + ".mp4"
        if downloadManager?.start(urlString: url, filename: filename, conflictAction: nil, byExtension: "link-saver") != nil {
            return "ダウンロード開始（\(height)p）：\(title)"
        }
        return "保存できなかった：ダウンロードを開始できなかった"
    }
}

struct LinkSaverView: View {
    let engine: LinkSaverEngine
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var rows: [(id: String, text: String)] = []
    @State private var running = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("YouTubeのリンクを貼ると MP4（360p）で保存します。複数行まとめてOK。進み具合と再生はダウンロード画面（↓）で。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $input)
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator)))
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                Button {
                    start()
                } label: {
                    Text(running ? "保存中…" : "保存を開始")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(running || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                List(rows, id: \.id) { row in
                    Text(row.text).font(.caption)
                }
                .listStyle(.plain)
            }
            .padding()
            .navigationTitle("リンクを貼って保存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
            .onAppear { engine.prepare() }
        }
    }

    private func parseIds(_ text: String) -> [String] {
        var ids: [String] = []
        let pattern = "(?:[?&]v=|youtu\\.be\\/|\\/shorts\\/)([\\w-]{11})"
        let regex = try? NSRegularExpression(pattern: pattern)
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            if let m = regex?.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
               let r = Range(m.range(at: 1), in: t) {
                let id = String(t[r])
                if !ids.contains(id) { ids.append(id) }
            } else if t.count == 11 {
                if !ids.contains(t) { ids.append(t) }
            }
        }
        return ids
    }

    private func start() {
        let ids = parseIds(input)
        if ids.isEmpty {
            rows = [(id: "none", text: "YouTubeのリンクが見つかりませんでした")]
            return
        }
        running = true
        rows = ids.map { (id: $0, text: "待機中：\($0)") }
        Task {
            var delayMs = 0
            for id in ids {
                if delayMs > 0 { try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000) }
                delayMs = 900
                setRow(id, "情報を取得中…：\(id)")
                let msg = await engine.save(videoId: id)
                setRow(id, msg)
            }
            running = false
        }
    }

    private func setRow(_ id: String, _ text: String) {
        if let i = rows.firstIndex(where: { $0.id == id }) { rows[i].text = text }
    }
}
