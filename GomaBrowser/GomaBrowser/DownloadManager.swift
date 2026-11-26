import Foundation

/// chrome.downloads の実体。Documents/Downloads へ保存する。
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    @Published var items: [DownloadItem] = [] // 新しい順
    private var nextId = 1
    private var tasks: [Int: URLSessionDownloadTask] = [:]
    private var session: URLSession!
    /// 状態変化の通知先 (Bridge が background/content へ delta を配送する)
    var onChanged: ((DownloadItem, GomaDownloadState?) -> Void)?

    var downloadsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var storeURL: URL { downloadsDirectory.appendingPathComponent(".downloads-index.json") }

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        loadIndex()
    }

    @discardableResult
    func start(urlString: String, filename requested: String?, conflictAction: String?, byExtension extId: String?) -> Int? {
        guard let url = URL(string: urlString) else { return nil }
        var name = (requested ?? "").isEmpty ? (url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent) : requested!
        name = name.components(separatedBy: "/").last ?? name // パス要素は落とす
        if conflictAction == "uniquify" || conflictAction == nil {
            name = uniquify(name)
        }
        let id = nextId; nextId += 1
        let item = DownloadItem(
            id: id, url: urlString, filename: name,
            state: .inProgress,
            startTime: ISO8601DateFormatter().string(from: Date()),
            byExtensionId: extId
        )
        DispatchQueue.main.async { self.items.insert(item, at: 0); self.saveIndex() }
        let task = session.downloadTask(with: url)
        tasks[id] = task
        task.resume()
        return id
    }

    private func uniquify(_ name: String) -> String {
        let dir = downloadsDirectory
        if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { return name }
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var n = 1
        while true {
            let candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent(candidate).path) { return candidate }
            n += 1
        }
    }

    func search(query: [String: Any]) -> [DownloadItem] {
        var result = items
        if let id = query["id"] as? Int { result = result.filter { $0.id == id } }
        if let state = query["state"] as? String { result = result.filter { $0.state.rawValue == state } }
        if let q = query["query"] as? [String], let first = q.first, !first.isEmpty {
            result = result.filter { $0.filename.localizedCaseInsensitiveContains(first) || $0.url.localizedCaseInsensitiveContains(first) }
        }
        // 進行中は実タスクの進捗で bytesReceived/totalBytes を最新化する
        return result.map { item in
            var it = item
            if it.state == .inProgress, let t = tasks[it.id] {
                it.bytesReceived = t.countOfBytesReceived
                it.totalBytes = t.countOfBytesExpectedToReceive
            }
            return it
        }
    }

    func fileURL(for item: DownloadItem) -> URL { downloadsDirectory.appendingPathComponent(item.filename) }

    func removeRecord(_ item: DownloadItem) {
        tasks[item.id]?.cancel()
        tasks[item.id] = nil
        items.removeAll { $0.id == item.id }
        saveIndex()
    }
    func deleteFile(_ item: DownloadItem) {
        try? FileManager.default.removeItem(at: fileURL(for: item))
    }

    // MARK: URLSessionDownloadDelegate
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let id = tasks.first(where: { $0.value == downloadTask })?.key else { return }
        DispatchQueue.main.async {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            let prev = self.items[idx].state
            let dest = self.downloadsDirectory.appendingPathComponent(self.items[idx].filename)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.moveItem(at: location, to: dest)
                self.items[idx].state = .complete
                if self.items[idx].totalBytes < 0 {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
                    if let n = attrs?[.size] as? NSNumber { self.items[idx].bytesReceived = n.int64Value }
                } else {
                    self.items[idx].bytesReceived = self.items[idx].totalBytes
                }
                self.items[idx].finalURL = dest.absoluteString
            } catch {
                self.items[idx].state = .interrupted
                self.items[idx].error = "SAVE_FAILED"
            }
            self.items[idx].endTime = ISO8601DateFormatter().string(from: Date())
            self.saveIndex()
            self.onChanged?(self.items[idx], prev)
            self.tasks[id] = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error,
              let dt = task as? URLSessionDownloadTask,
              let id = tasks.first(where: { $0.value == dt })?.key else { return }
        DispatchQueue.main.async {
            guard let idx = self.items.firstIndex(where: { $0.id == id }),
                  self.items[idx].state == .inProgress else { return }
            let prev = self.items[idx].state
            self.items[idx].state = .interrupted
            self.items[idx].error = (error as NSError).localizedDescription
            self.items[idx].endTime = ISO8601DateFormatter().string(from: Date())
            self.saveIndex()
            self.onChanged?(self.items[idx], prev)
            self.tasks[id] = nil
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let id = tasks.first(where: { $0.value == downloadTask })?.key else { return }
        DispatchQueue.main.async {
            guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
            self.items[idx].bytesReceived = totalBytesWritten
            self.items[idx].totalBytes = totalBytesExpectedToWrite
        }
    }

    // MARK: 永続化
    private func saveIndex() {
        let snapshot = items.filter { $0.state != .inProgress } + items.filter { $0.state == .inProgress }.map { var c = $0; c.state = .interrupted; c.error = "INTERRUPTED_BY_RESTART"; return c }
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: storeURL, options: .atomic) }
    }
    private func loadIndex() {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = list
        nextId = (list.map { $0.id }.max() ?? 0) + 1
    }
}
