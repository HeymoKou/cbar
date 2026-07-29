import Foundation

/// Reads Codex (OpenAI) usage from the newest local session rollout file.
/// Codex records a `token_count` event carrying `rate_limits` (primary = 5h,
/// secondary = weekly) into `~/.codex/sessions/**/*.jsonl`. No API/token needed;
/// data is as fresh as the last Codex run (surface the snapshot age).
public final class CodexProvider: Provider {
    public let name = "codex"
    private let sessionsDir: String
    private let walkTTL: TimeInterval

    /// Which file the last tree walk picked, and when it walked. Reached only
    /// from cbar's serial mutation queue (`UsageStore.refresh`), so no lock.
    private var cachedNewest: (url: URL, at: Date)?

    public init(sessionsDir: String = "\(NSHomeDirectory())/.codex/sessions",
                walkTTL: TimeInterval = 300) {
        self.sessionsDir = sessionsDir
        self.walkTTL = walkTTL
    }

    public func accounts() throws -> [Account] {
        guard let url = newestSessionCached(now: Date()),
              let content = try? String(contentsOf: url, encoding: .utf8),
              let acc = Self.parse(content, now: Date().timeIntervalSince1970) else { return [] }
        return [acc]
    }

    /// `newestSession` stats every file in the sessions tree — 6,800 of them on
    /// the machine this was measured on, ~29 ms warm — to answer a question that
    /// only changes when Codex opens a NEW session. Doing that once a minute
    /// forever is the app's single largest idle cost.
    ///
    /// Only the walk is cached. The file it found is re-read and re-parsed every
    /// pass, so a session being written right now stays live at the full poll
    /// cadence, and the snapshot age and reset countdowns keep counting. What
    /// waits for the next walk is strictly the arrival of a brand-new session
    /// file: up to `walkTTL` late, during which the previous session's numbers
    /// keep showing with a visibly growing age.
    private func newestSessionCached(now: Date) -> URL? {
        if let c = cachedNewest, now.timeIntervalSince(c.at) < walkTTL,
           FileManager.default.fileExists(atPath: c.url.path) {
            return c.url
        }
        let found = Self.newestSession(dir: sessionsDir)
        cachedNewest = found.map { (url: $0, at: now) }
        return found
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
