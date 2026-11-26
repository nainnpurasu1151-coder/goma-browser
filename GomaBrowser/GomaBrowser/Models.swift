import Foundation
import WebKit

// MARK: - Extension manifest (MV3, 必要部分のみ)

struct ExtensionManifest: Codable {
    var manifestVersion: Int?
    var name: String?
    var version: String?
    var description: String?
    var background: Background?
    var action: Action?
    var contentScripts: [ContentScript]?
    var permissions: [String]?
    var hostPermissions: [String]?
    var webAccessibleResources: [WebAccessibleResource]?

    struct Background: Codable { var serviceWorker: String? }
    struct Action: Codable {
        var defaultPopup: String?
        var defaultTitle: String?
        enum CodingKeys: String, CodingKey { case defaultPopup = "default_popup", defaultTitle = "default_title" }
    }
    struct ContentScript: Codable {
        var matches: [String]?
        var excludeMatches: [String]?
        var js: [String]?
        var css: [String]?
        var runAt: String?
        enum CodingKeys: String, CodingKey {
            case matches, js, css
            case excludeMatches = "exclude_matches"
            case runAt = "run_at"
        }
    }
    struct WebAccessibleResource: Codable {
        var resources: [String]?
        var matches: [String]?
    }
    enum CodingKeys: String, CodingKey {
        case manifestVersion = "manifest_version"
        case name, version, description, background, action, permissions
        case contentScripts = "content_scripts"
        case hostPermissions = "host_permissions"
        case webAccessibleResources = "web_accessible_resources"
    }
}

struct InstalledExtension: Identifiable, Codable {
    var id: String            // フォルダ名から決まる安定ID
    var manifest: ExtensionManifest
    var directoryName: String // Application Support/Extensions/<directoryName>
    var isEnabled: Bool = true
    var isBundled: Bool = false
    var name: String { manifest.name ?? directoryName }
}

// MARK: - Tabs

final class BrowserTab: Identifiable, ObservableObject {
    let id: Int
    @Published var title: String = "新しいタブ"
    @Published var url: URL?
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    let webView: WKWebView
    init(id: Int, webView: WKWebView) {
        self.id = id
        self.webView = webView
    }
    var urlString: String { url?.absoluteString ?? "" }
}

// MARK: - Downloads

enum GomaDownloadState: String, Codable {
    case inProgress = "in_progress"
    case complete
    case interrupted
}

struct DownloadItem: Identifiable, Codable {
    var id: Int
    var url: String
    var filename: String        // Downloads フォルダ内のファイル名
    var finalURL: String?       // 完了後の絶対URL文字列
    var state: GomaDownloadState
    var bytesReceived: Int64 = 0
    var totalBytes: Int64 = -1
    var startTime: String       // ISO8601
    var endTime: String?
    var error: String?
    var mime: String = ""
    var byExtensionId: String?

    /// chrome.downloads.search の返却形式に寄せた辞書
    func toChromeDict() -> [String: Any] {
        var d: [String: Any] = [
            "id": id,
            "url": url,
            "filename": filename,
            "state": state.rawValue,
            "bytesReceived": bytesReceived,
            "totalBytes": totalBytes,
            "startTime": startTime,
            "mime": mime,
            "paused": false,
            "canResume": false,
            "exists": state == .complete
        ]
        if let e = error { d["error"] = e }
        if let et = endTime { d["endTime"] = et }
        return d
    }
}

/// chrome.downloads.onChanged の delta 形式
func downloadDelta(item: DownloadItem, previousState: GomaDownloadState?) -> [String: Any] {
    var delta: [String: Any] = ["id": item.id]
    delta["state"] = ["current": item.state.rawValue, "previous": previousState?.rawValue ?? ""]
    if let e = item.error {
        delta["error"] = ["current": e, "previous": ""]
    }
    delta["bytesReceived"] = ["current": item.bytesReceived, "previous": 0]
    if item.totalBytes >= 0 {
        delta["totalBytes"] = ["current": item.totalBytes, "previous": -1]
    }
    return delta
}
