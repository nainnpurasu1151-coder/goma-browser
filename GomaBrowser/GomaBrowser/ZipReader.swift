import Foundation
import Compression

/// 依存ライブラリなしの最小 ZIP 解凍 (store / deflate のみ)
/// 拡張 zip 取り込み専用。ZIP64・暗号化には非対応。
enum ZipReader {
    enum ZipError: Error { case invalid, unsupported }

    static func extract(zipAt url: URL, to dest: URL) throws {
        let data = try Data(contentsOf: url)
        guard data.count > 22 else { throw ZipError.invalid }
        // End Of Central Directory を後方から探す
        var eocd = -1
        var i = data.count - 22
        while i >= 0 {
            if data[i] == 0x50 && data[i + 1] == 0x4B && data[i + 2] == 0x05 && data[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.invalid }
        func u16(_ o: Int) -> Int { Int(data[o]) | (Int(data[o + 1]) << 8) }
        func u32(_ o: Int) -> Int { Int(data[o]) | (Int(data[o + 1]) << 8) | (Int(data[o + 2]) << 16) | (Int(data[o + 3]) << 24) }
        let count = u16(eocd + 10)
        var cd = u32(eocd + 16)
        for _ in 0..<count {
            guard cd + 46 <= data.count, u32(cd) == 0x02014B50 else { throw ZipError.invalid }
            let method = u16(cd + 10)
            let compSize = u32(cd + 20)
            let nameLen = u16(cd + 28)
            let extraLen = u16(cd + 30)
            let commentLen = u16(cd + 32)
            let localOffset = u32(cd + 42)
            let nameData = data.subdata(in: (cd + 46)..<(cd + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            cd += 46 + nameLen + extraLen + commentLen
            guard !name.isEmpty else { continue }
            // パストラバーサル防止
            let safe = name.replacingOccurrences(of: "../", with: "").replacingOccurrences(of: "..\\", with: "")
            let outURL = dest.appendingPathComponent(safe)
            if name.hasSuffix("/") {
                try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)
                continue
            }
            // Local File Header
            guard localOffset + 30 <= data.count, u32(localOffset) == 0x04034B50 else { throw ZipError.invalid }
            let lNameLen = u16(localOffset + 26)
            let lExtraLen = u16(localOffset + 28)
            let start = localOffset + 30 + lNameLen + lExtraLen
            guard start + compSize <= data.count else { throw ZipError.invalid }
            let comp = data.subdata(in: start..<(start + compSize))
            let raw: Data
            switch method {
            case 0: raw = comp
            case 8: raw = try inflate(comp)
            default: throw ZipError.unsupported
            }
            try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try raw.write(to: outURL)
        }
    }

    private static func inflate(_ data: Data) throws -> Data {
        // raw deflate を zlib 形式に包み直して Compression で解凍する
        var out = Data()
        let chunk = 64 * 1024
        var src = [UInt8](data)
        // 先頭が zlib ヘッダでない raw deflate 前提: COMPRESSION_ZLIB は zlib 形式を期待するため
        // ストリームAPIで raw を扱う。失敗時はそのまま返すフォールバックを持つ。
        var status: compression_status
        var stream = compression_stream(dst_ptr: nil, dst_size: 0, src_ptr: nil, src_size: 0, state: nil)
        status = compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        guard status == COMPRESSION_STATUS_OK else { throw ZipError.unsupported }
        defer { compression_stream_destroy(&stream) }
        // raw deflate 用に zlib ヘッダ(0x78 0x01) + Adler32(ダミー) を付ける簡易変換
        var wrapped = Data([0x78, 0x01])
        wrapped.append(data)
        wrapped.append(contentsOf: [0, 0, 0, 1]) // Adler32 of empty-ish; 多くの実装で検証されない場合の保険
        src = [UInt8](wrapped)
        var ok = false
        try src.withUnsafeBufferPointer { srcPtr in
            stream.src_ptr = UnsafeMutablePointer(mutating: srcPtr.baseAddress!)
            stream.src_size = src.count
            while true {
                let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
                stream.dst_ptr = dst
                stream.dst_size = chunk
                // COMPRESSION_STREAM_FINALIZE == 1 (Compression ヘッダの定義値)
                let flags: Int32 = stream.src_size == 0 ? 1 : 0
                status = compression_stream_process(&stream, flags)
                let produced = chunk - stream.dst_size
                out.append(Data(bytes: dst, count: produced))
                dst.deallocate()
                if status == COMPRESSION_STATUS_END { ok = true; break }
                if status == COMPRESSION_STATUS_ERROR { break }
                if stream.src_size == 0 && produced == 0 { break }
            }
        }
        if !ok && out.isEmpty { throw ZipError.unsupported }
        return out
    }
}
