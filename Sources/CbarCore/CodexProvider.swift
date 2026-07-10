import Foundation

/// Reads Codex (OpenAI) usage from the newest local session rollout file.
/// Codex records a `token_count` event carrying `rate_limits` (primary = 5h,
/// secondary = weekly) into `~/.codex/sessions/**/*.jsonl`. No API/token needed;
/// data is as fresh as the last Codex run (surface the snapshot age).
public struct CodexProvider: Provider {
    public let name = "codex"
    private let sessionsDir: String

    public init(sessionsDir: String = "\(NSHomeDirectory())/.codex/sessions") {
        self.sessionsDir = sessionsDir
    }

    public func accounts() throws -> [Account] {
        guard let url = Self.newestSession(dir: sessionsDir),
              let content = try? String(contentsOf: url, encoding: .utf8),
              let acc = Self.parse(content, now: Date().timeIntervalSince1970) else { return [] }
        return [acc]
    }

    // Read-only provider: switching is a cswap-only concept.
    public func switchTo(_ account: Account) throws {}
    public func switchToBest() throws {}

    /// Newest `.jsonl` under the sessions tree, by file modification date.
    static func newestSession(dir: String) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: URL(fileURLWithPath: dir),
                                     includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var best: (url: URL, date: Date)?
        for case let u as URL in en where u.pathExtension == "jsonl" {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if best == nil || d > best!.date { best = (u, d) }
        }
        return best?.url
    }

    /// Parse the LAST `rate_limits` snapshot in a session's jsonl content.
    /// `now` = seconds since epoch, injected for testability.
    public static func parse(_ content: String, now: Double) -> Account? {
        let dec = JSONDecoder()
        for line in content.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let row = try? dec.decode(Row.self, from: data),
                  let rl = row.payload?.rate_limits else { continue }
            var meters: [Meter] = []
            if let p = rl.primary {
                meters.append(Meter(id: "5h", pct: p.used_percent ?? 0, countdown: countdown(p.resets_at, now: now)))
            }
            if let s = rl.secondary {
                meters.append(Meter(id: "7d", pct: s.used_percent ?? 0, countdown: countdown(s.resets_at, now: now)))
            }
            guard !meters.isEmpty else { continue }
            let age = row.timestamp.flatMap { ageSeconds($0, now: now) }
            return Account(id: "codex", number: 0, email: "Codex",
                           org: (rl.plan_type.map { "OpenAI · \($0)" }) ?? "OpenAI",
                           isActive: false, status: "ok", meters: meters,
                           ageSeconds: age, provider: "codex")
        }
        return nil
    }

    /// "1h 15m" / "6d 7h" / "12m" from a reset unix timestamp.
    static func countdown(_ resetsAt: Double?, now: Double) -> String? {
        guard let r = resetsAt else { return nil }
        let secs = Int(r - now)
        if secs <= 0 { return "now" }
        let d = secs / 86400, h = (secs % 86400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func ageSeconds(_ iso: String, now: Double) -> Double? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return now - d.timeIntervalSince1970 }
        let f2 = ISO8601DateFormatter()
        if let d = f2.date(from: iso) { return now - d.timeIntervalSince1970 }
        return nil
    }

    struct Row: Decodable {
        let timestamp: String?
        let payload: Payload?
    }
    struct Payload: Decodable { let rate_limits: RateLimits? }
    struct RateLimits: Decodable {
        let primary: Window?
        let secondary: Window?
        let plan_type: String?
    }
    struct Window: Decodable { let used_percent: Double?; let resets_at: Double? }
}
