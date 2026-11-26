import Foundation

/// Chrome の match pattern 実装 (v1)
/// 形式: <scheme>://<host><path>  または  <all_urls>
/// scheme: http / https / file / ftp / *  (* は http と https のみ)
/// host:   * / *.example.com / example.com
/// path:   * を含む glob
struct MatchPattern {
    let raw: String
    let scheme: String
    let host: String
    let path: String
    let allURLs: Bool

    init?(_ pattern: String) {
        raw = pattern
        if pattern == "<all_urls>" {
            scheme = "*"; host = "*"; path = "/*"; allURLs = true
            return
        }
        allURLs = false
        guard let sep = pattern.range(of: "://") else { return nil }
        scheme = String(pattern[pattern.startIndex..<sep.lowerBound])
        let rest = pattern[sep.upperBound...]
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        host = String(rest[rest.startIndex..<slash])
        path = String(rest[slash...])
        guard !scheme.isEmpty, !host.isEmpty, !path.isEmpty else { return nil }
    }

    func matches(_ url: URL) -> Bool {
        guard let schemeU = url.scheme?.lowercased(),
              let hostU = url.host?.lowercased() else { return false }
        if allURLs { return ["http", "https", "file", "ftp"].contains(schemeU) }
        // scheme
        if scheme == "*" {
            guard schemeU == "http" || schemeU == "https" else { return false }
        } else if scheme != schemeU { return false }
        // host
        if host != "*" {
            if host.hasPrefix("*.") {
                let domain = String(host.dropFirst(2))
                guard hostU == domain || hostU.hasSuffix("." + domain) else { return false }
            } else {
                guard hostU == host else { return false }
            }
        }
        // path (+ query を path に含めるのが Chrome の挙動)
        var target = url.path.isEmpty ? "/" : url.path
        if let q = url.query, !q.isEmpty { target += "?" + q }
        return MatchPattern.glob(pattern: path, value: target)
    }

    /// * のみをワイルドカードとする glob マッチ
    static func glob(pattern: String, value: String) -> Bool {
        // 動的計画法で単純に処理（パターンは短い前提）
        let p = Array(pattern), v = Array(value)
        var dp = Array(repeating: Array(repeating: false, count: v.count + 1), count: p.count + 1)
        dp[0][0] = true
        for i in 1...max(p.count, 1) where i <= p.count {
            if p[i - 1] == "*" { dp[i][0] = dp[i - 1][0] }
        }
        if p.isEmpty { return v.isEmpty }
        for i in 1...p.count {
            for j in 1...v.count {
                if p[i - 1] == "*" {
                    dp[i][j] = dp[i - 1][j] || dp[i][j - 1]
                } else if p[i - 1] == v[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                }
            }
        }
        return dp[p.count][v.count]
    }
}
