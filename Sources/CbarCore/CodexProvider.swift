import Foundation

/// Reads Codex (OpenAI) usage from the newest local session rollout file.
/// Codex records a `token_count` event carrying `rate_limits` (primary = 5h,
/// secondary = weekly) into `~/.codex/sessions/**/*.jsonl`. No API/token needed;
/// data is as fresh as the last Codex run (surface the snapshot age).
public final class CodexProvider: Provider {
    public let name = "codex"
    private let sessionsDir: String
    private let walkTTL: TimeInterval

    /// Which files the last tree walk picked (newest first), and when it walked.
    /// Reached only from cbar's serial mutation queue (`UsageStore.refresh`), so
    /// no lock — `barren` below likewise.
    private var cachedSessions: (urls: [URL], at: Date)?

    /// Sessions already read and found to hold no usable snapshot, valid while
    /// the file's (mtime, size) is unchanged. A refused session is written once
    /// and never again, so without this every pass would re-read and re-parse
    /// it on the way to the one that has data — ~200 ms for a 14 MB session, and
    /// with an API-key login no session ever has any.
    private var barren: [String: FileStamp] = [:]

    struct FileStamp: Equatable { let mtime: Date; let size: Int }

    /// How many of the newest sessions to try before giving up. Not 1: when an
    /// account is at its limit Codex refuses each new session outright, and the
    /// file it leaves holds only a reason-only `premium` row with both windows
    /// null. Reading just the newest file made the card VANISH at exactly the
    /// moment its 100% mattered — three such sessions in a row did it on
    /// 2026-09-15. Deep enough to ride out a run of retries; the cap is what an
    /// account that never records rate limits costs, once, at launch.
    static let fallbackDepth = 16

    public init(sessionsDir: String = "\(NSHomeDirectory())/.codex/sessions",
                walkTTL: TimeInterval = 300) {
        self.sessionsDir = sessionsDir
        self.walkTTL = walkTTL
    }

    /// The newest session that measured something. An older session's reading
    /// carries its own timestamp, so the card shows its true age rather than
    /// posing as current.
    public func accounts() throws -> [Account] {
        let now = Date()
        for url in sessionsCached(now: now) {
            guard let stamp = Self.stamp(url), barren[url.path] != stamp,
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let acc = Self.parse(content, now: now.timeIntervalSince1970) { return [acc] }
            // Stamped BEFORE the read: a session that grew in between gets a
            // stale stamp and is simply read again next pass.
            barren[url.path] = stamp
        }
        return []
    }

    /// `newestSessions` stats every file in the sessions tree — 6,800 of them on
    /// the machine this was measured on, ~29 ms warm — to answer a question that
    /// only changes when Codex opens a NEW session. Doing that once a minute
    /// forever is the app's single largest idle cost.
    ///
    /// Only the walk is cached. The files it found are re-read and re-parsed
    /// every pass (bar the known-barren ones), so a session being written right
    /// now stays live at the full poll cadence, and the snapshot age and reset
    /// countdowns keep counting. What waits for the next walk is strictly the
    /// arrival of a brand-new session file: up to `walkTTL` late, during which
    /// the previous session's numbers keep showing with a visibly growing age.
    private func sessionsCached(now: Date) -> [URL] {
        if let c = cachedSessions, now.timeIntervalSince(c.at) < walkTTL,
           c.urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
            return c.urls
        }
        let found = Self.newestSessions(dir: sessionsDir, limit: Self.fallbackDepth)
        cachedSessions = found.isEmpty ? nil : (urls: found, at: now)
        let kept = Set(found.map(\.path))
        barren = barren.filter { kept.contains($0.key) }
        return found
    }

    static func stamp(_ url: URL) -> FileStamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
              let m = a[.modificationDate] as? Date, let s = a[.size] as? NSNumber else { return nil }
        return FileStamp(mtime: m, size: s.intValue)
    }

    // Read-only provider: switching is a cswap-only concept.
    public func switchTo(_ account: Account) throws {}
    public func switchToBest() throws {}

    /// The `limit` newest `.jsonl` files under the sessions tree, newest first, by
    /// file modification date.
    static func newestSessions(dir: String, limit: Int) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: URL(fileURLWithPath: dir),
                                     includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var all: [(url: URL, date: Date)] = []
        for case let u as URL in en where u.pathExtension == "jsonl" {
            let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            all.append((u, d))
        }
        return all.sorted { $0.date > $1.date }.prefix(limit).map(\.url)
    }

    /// Parse the latest usable snapshot for every rate-limit bucket in a
    /// session. Codex now emits the normal allowance and model-specific limits
    /// (for example Astra) as separate `token_count` rows. Looking at only the
    /// final row made whichever bucket happened to be written first disappear.
    /// `now` = seconds since epoch, injected for testability.
    public static func parse(_ content: String, now: Double) -> Account? {
        let dec = JSONDecoder()
        var seen = Set<String>()
        var meters: [Meter] = []
        var newestTimestamp: String?
        var planType: String?
        for line in content.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let row = try? dec.decode(Row.self, from: data),
                  let rl = row.payload?.rate_limits else { continue }
            let bucket = rl.limit_id ?? "codex"
            guard !seen.contains(bucket) else { continue }

            let windows = [(rl.primary, "5h"), (rl.secondary, "7d")].compactMap { w, positional -> Meter? in
                guard let w else { return nil }
                let window = Self.windowLabel(w.window_minutes) ?? positional
                let label = Self.meterLabel(limitID: bucket, limitName: rl.limit_name,
                                            window: window, hasSecondary: rl.secondary != nil)
                return Meter(id: label, pct: w.used_percent ?? 0,
                             countdown: countdown(w.resets_at, now: now))
            }
            // A terminal reason-only snapshot (for example `premium` with both
            // windows null) must not shadow the last snapshot that measured it.
            guard !windows.isEmpty else { continue }
            seen.insert(bucket)
            meters.append(contentsOf: windows)
            if newestTimestamp == nil { newestTimestamp = row.timestamp }
            if planType == nil { planType = rl.plan_type }
        }
        guard !meters.isEmpty else { return nil }
        // Reversed traversal discovers newest buckets first. Put the ordinary
        // duration meters first, followed by named/model-specific allowances.
        meters.sort { Self.meterOrder($0.id) < Self.meterOrder($1.id) }
        let age = newestTimestamp.flatMap { ageSeconds($0, now: now) }
        return Account(id: "codex", number: 0, email: "Codex",
                       org: (planType.map { "OpenAI · \($0)" }) ?? "OpenAI",
                       isActive: false, status: "ok", meters: meters,
                       ageSeconds: age, provider: "codex")
    }

    static func meterLabel(limitID: String, limitName: String?, window: String,
                           hasSecondary: Bool) -> String {
        guard limitID != "codex" else { return window }
        let raw = limitName ?? limitID.replacingOccurrences(of: "_", with: " ")
        let name = raw.localizedCaseInsensitiveContains("astra") ? "Astra" : raw
        return hasSecondary ? "\(name) \(window)" : name
    }

    private static func meterOrder(_ id: String) -> Int {
        if id == "5h" { return 0 }
        if id == "7d" { return 1 }
        return 2
    }

    /// Name a window by its length, because Codex does not name them and which
    /// slot holds which length has already moved once: through 2026-07-12
    /// `primary` was the 5 h window with the weekly one in `secondary`; from
    /// 2026-07-13 there is a single weekly window in `primary` and `secondary` is
    /// null. Labelling by position meant cbar displayed that weekly figure as
    /// "5h" — a number four times smaller than the 5 h reading it claimed to be.
    ///
    /// Falls back to the positional label when the field is missing, so an older
    /// session file still reads the way it always did.
    public static func windowLabel(_ minutes: Int?) -> String? {
        guard let m = minutes, m > 0 else { return nil }
        if m % 1440 == 0 { return "\(m / 1440)d" }
        if m >= 60 { return "\(m / 60)h" }
        return "\(m)m"
    }

    /// "1h 15m" / "6d 7h" / "12m" from a reset unix timestamp.
    public static func countdown(_ resetsAt: Double?, now: Double) -> String? {
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
        let limit_id: String?
        let limit_name: String?
        let primary: Window?
        let secondary: Window?
        let plan_type: String?
    }
    struct Window: Decodable {
        let used_percent: Double?
        let resets_at: Double?
        let window_minutes: Int?
    }
}
