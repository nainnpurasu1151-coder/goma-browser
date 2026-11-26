import SwiftUI
import WebKit

struct ContentView: View {
    @StateObject private var browser = BrowserViewModel()
    @State private var addressText = ""
    @State private var showDownloads = false
    @State private var showExtensions = false
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
