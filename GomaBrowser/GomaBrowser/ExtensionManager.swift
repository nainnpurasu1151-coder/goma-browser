import Foundation
import UniformTypeIdentifiers

/// 拡張の登録・取り込み・保存・storage を管理する
final class ExtensionManager: ObservableObject {
    @Published var extensions: [InstalledExtension] = []

    static let bundledVideoSaverDir = "goma-video-saver"

    var extensionsRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Extensions", isDirectory: true)
    }
    private var registryURL: URL { extensionsRoot.appendingPathComponent("registry.json") }

    init() {
        try? FileManager.default.createDirectory(at: extensionsRoot, withIntermediateDirectories: true)
        loadRegistry()
        installBundledIfNeeded()
    }

    func directory(for ext: InstalledExtension) -> URL {
        extensionsRoot.appendingPathComponent(ext.directoryName, isDirectory: true)
    }
    func fileURL(ext: InstalledExtension, relativePath: String) -> URL {
        directory(for: ext).appendingPathComponent(relativePath)
    }

    // MARK: 同梱拡張 (ごま動画セーバー v2.1)
    private func installBundledIfNeeded() {
        if extensions.contains(where: { $0.directoryName == Self.bundledVideoSaverDir }) { return }
        guard let src = Bundle.main.url(forResource: "goma-video-saver", withExtension: nil, subdirectory: "Extensions")
                ?? Bundle.main.url(forResource: "goma-video-saver", withExtension: nil) else {
            NSLog("[GomaBrowser] bundled extension not found in app bundle")
            return
        }
        let dest = extensionsRoot.appendingPathComponent(Self.bundledVideoSaverDir, isDirectory: true)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            if let manifest = try loadManifest(in: dest) {
                let ext = InstalledExtension(
                    id: Self.stableID(forDirectory: Self.bundledVideoSaverDir),
                    manifest: manifest,
                    directoryName: Self.bundledVideoSaverDir,
                    isEnabled: true,
                    isBundled: true
                )
                extensions.append(ext)
                saveRegistry()
            }
        } catch {
            NSLog("[GomaBrowser] bundled install failed: \(error)")
        }
    }

    /// ディレクトリ名から決まる安定ID (Chrome の ID 形式に寄せた32文字)
    static func stableID(forDirectory name: String) -> String {
        var hash: UInt64 = 1469598103934665603 // FNV-1a
        for b in name.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        var out = ""
        var h = hash
        let letters = Array("abcdefghijklmnop")
        for _ in 0..<32 {
            out.append(letters[Int(h % 16)])
            h = h / 16 &+ 0x9E3779B97F4A7C15
            h ^= h >> 29
        }
        return out
    }

    func loadManifest(in dir: URL) throws -> ExtensionManifest {
        let data = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(ExtensionManifest.self, from: data)
    }

    // MARK: zip 取り込み
    /// ファイルピッカーで選ばれた zip を解凍して登録する。
    /// 解凍は ZipArchive を使わず、Foundation の NSFileCoordinator ではなく
    /// 簡易実装として `Compression` 不可のため、SSZipArchive 等にも依存しない。
    /// iOS には標準の zip 解凍 API が無いため、内蔵の最小 Inflater (ZipReader.swift) を使う。
    func importExtension(zipURL: URL) throws -> InstalledExtension {
        let accessing = zipURL.startAccessingSecurityScopedResource()
        defer { if accessing { zipURL.stopAccessingSecurityScopedResource() } }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try ZipReader.extract(zipAt: zipURL, to: tmp)

        // manifest.json の場所を探す（直下 or 1階層下）
        let manifestDir = findManifestDir(in: tmp)
        guard let srcDir = manifestDir else {
            throw NSError(domain: "GomaBrowser", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "manifest.json が zip 内に見つかりません"])
        }
        return try registerExtension(from: srcDir)
    }

    /// 解凍済みフォルダ (manifest.json を含む) をそのまま取り込む。zip解凍の保険経路。
    func importExtensionFolder(folderURL: URL) throws -> InstalledExtension {
        let accessing = folderURL.startAccessingSecurityScopedResource()
        defer { if accessing { folderURL.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("manifest.json").path)
            ? folderURL : findManifestDir(in: folderURL)
        guard let srcDir = dir else {
            throw NSError(domain: "GomaBrowser", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "manifest.json がフォルダ内に見つかりません"])
        }
        return try registerExtension(from: srcDir)
    }

    private func registerExtension(from srcDir: URL) throws -> InstalledExtension {
        let manifest = try loadManifest(in: srcDir)
        guard (manifest.manifestVersion ?? 0) == 3 else {
            throw NSError(domain: "GomaBrowser", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Manifest V3 の拡張のみ対応しています"])
        }
        let baseName = (manifest.name ?? "extension").lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "-")
        var dirName = baseName.isEmpty ? "extension" : baseName
        var n = 2
        let original = dirName
        while FileManager.default.fileExists(atPath: extensionsRoot.appendingPathComponent(dirName).path) {
            dirName = "\(original)-\(n)"; n += 1
        }
        let dest = extensionsRoot.appendingPathComponent(dirName, isDirectory: true)
        try FileManager.default.copyItem(at: srcDir, to: dest)
        let ext = InstalledExtension(id: Self.stableID(forDirectory: dirName), manifest: manifest, directoryName: dirName)
        extensions.append(ext)
        saveRegistry()
        return ext
    }

    private func findManifestDir(in root: URL) -> URL? {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path) { return root }
        let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for c in children where FileManager.default.fileExists(atPath: c.appendingPathComponent("manifest.json").path) {
            return c
        }
        return nil
    }

    func setEnabled(_ ext: InstalledExtension, _ enabled: Bool) {
        guard let i = extensions.firstIndex(where: { $0.id == ext.id }) else { return }
        extensions[i].isEnabled = enabled
        saveRegistry()
    }

    func remove(_ ext: InstalledExtension) {
        guard !ext.isBundled else { return }
        try? FileManager.default.removeItem(at: directory(for: ext))
        extensions.removeAll { $0.id == ext.id }
        saveRegistry()
    }

    // MARK: registry 永続化
    private func loadRegistry() {
        guard let data = try? Data(contentsOf: registryURL),
              let list = try? JSONDecoder().decode([InstalledExtension].self, from: data) else { return }
        extensions = list.filter { FileManager.default.fileExists(atPath: directory(for: $0).path) }
    }
    private func saveRegistry() {
        if let data = try? JSONEncoder().encode(extensions) {
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    // MARK: chrome.storage.local 実体 (拡張ごとに JSON ファイル)
    private func storageURL(for extId: String) -> URL {
        extensionsRoot.appendingPathComponent("storage-\(extId).json")
    }
    func storageGet(extId: String, keys: Any?) -> [String: Any] {
        guard let data = try? Data(contentsOf: storageURL(for: extId)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return defaultValues(for: keys)
        }
        if keys == nil || keys is NSNull { return obj }
        var result: [String: Any] = [:]
        if let arr = keys as? [String] {
            for k in arr { if let v = obj[k] { result[k] = v } }
        } else if let dict = keys as? [String: Any] {
            for (k, dv) in dict { result[k] = obj[k] ?? dv }
        } else if let s = keys as? String {
            if let v = obj[s] { result[s] = v }
        }
        return result
    }
    private func defaultValues(for keys: Any?) -> [String: Any] {
        if let dict = keys as? [String: Any] { return dict }
        return [:]
    }
    func storageSet(extId: String, items: [String: Any]) {
        var obj = storageGet(extId: extId, keys: nil)
        for (k, v) in items { obj[k] = v }
        writeStorage(extId: extId, obj: obj)
    }
    func storageRemove(extId: String, keys: Any?) {
        var obj = storageGet(extId: extId, keys: nil)
        if let arr = keys as? [String] { arr.forEach { obj.removeValue(forKey: $0) } }
        if let s = keys as? String { obj.removeValue(forKey: s) }
        writeStorage(extId: extId, obj: obj)
    }
    func storageClear(extId: String) { writeStorage(extId: extId, obj: [:]) }
    private func writeStorage(extId: String, obj: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: storageURL(for: extId), options: .atomic)
        }
    }
}
