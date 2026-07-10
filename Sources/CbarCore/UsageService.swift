import Foundation

/// Native replacement for the cswap CLI: paced per-account usage fetch backed by
/// a persisted cache. Rate-limit safe (fetch active + ≤1 stalest alternate per
/// TTL, per-account backoff). Refreshes tokens as needed, but NEVER rotates the
/// active account's token while Claude Code is running.
public final class UsageService: Provider {
    public let name = "claude"
    private let store: AccountStore
    private let oauth: OAuthClient
    private let cachePath: String

    public init(store: AccountStore = AccountStore(),
                oauth: OAuthClient = OAuthClient(),
                cachePath: String = "\(NSHomeDirectory())/.cbar/usage-cache.json") {
        self.store = store; self.oauth = oauth; self.cachePath = cachePath
    }

    struct Row: Codable {
        var meters: [Meter] = []
        var fetchedAt: Double? = nil
        var lastAttemptAt: Double? = nil
        var backoffUntil: Double? = nil
        var failures: Int = 0
        var lastError: String? = nil
        var needsReauth: Bool = false
    }

    private func loadCache() -> [Int: Row] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
              let raw = try? JSONDecoder().decode([String: Row].self, from: d) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
    }
    private func saveCache(_ c: [Int: Row]) {
        let raw = Dictionary(uniqueKeysWithValues: c.map { (String($0.key), $0.value) })
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(raw) else { return }
        try? FileManager.default.createDirectory(
            atPath: (cachePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? d.write(to: URL(fileURLWithPath: cachePath))
    }

    /// Creds to fetch with: the LIVE keychain for the slot the live token is
    /// PROFILE-VERIFIED to belong to (CC keeps it fresh; the slot copy goes
    /// stale the moment CC refreshes, which froze usage at 76% for 140 min on
    /// 2026-07-10), slot copy otherwise. `liveOwner` — not the active pointer —
    /// gates live use, so an unverified/mismatched token can never poison a row.
    public static func fetchCreds(n: Int, liveOwner: Int?, live: ClaudeAiOauth?, slot: ClaudeAiOauth?) -> ClaudeAiOauth? {
        (n == liveOwner ? live : nil) ?? slot
    }

    public func accounts() throws -> [Account] {
        let now = Date().timeIntervalSince1970
        let list = store.list()
        let active = store.syncActive(live: try? ClaudeConfig.readAccount())
        var cache = loadCache()

        let rows = list.map { a in
            PaceRow(number: a.number, fetchedAt: cache[a.number]?.fetchedAt,
                    backoffUntil: cache[a.number]?.backoffUntil, lastAttemptAt: cache[a.number]?.lastAttemptAt)
        }
        let ccRunning = Self.claudeCodeRunning()

        // Live creds are used/healed ONLY for the slot matching the token's
        // PROFILE-API identity — never attributed by pointer or .claude.json
        // (non-atomic /login writes poisoned slot creds AND usage rows on
        // 2026-07-10). Profile unreachable → liveOwner nil → slot copies only.
        let liveCreds = (try? Credentials.readActive()) ?? nil
        let liveOwner: Int? = liveCreds.flatMap { c in
            (try? oauth.fetchProfile(accessToken: c.accessToken)).flatMap { matchSlot(list, live: $0) }
        }

        for n in fetchPlan(now: now, active: active, rows: rows) {
            var row = cache[n] ?? Row()
            row.lastAttemptAt = now                      // claim
            let slotCreds = (try? store.creds(n)) ?? nil
            guard var creds = Self.fetchCreds(n: n, liveOwner: liveOwner, live: liveCreds, slot: slotCreds) else {
                row.lastError = "no credentials"; cache[n] = row; continue
            }
            // Heal the slot backup whenever the live token has moved on —
            // only into the profile-verified owner slot.
            if n == liveOwner, creds.accessToken != slotCreds?.accessToken {
                try? store.setCreds(n, creds)
                CbarLog.write("slot #\(n) creds healed from live keychain (profile-verified)")
            }
            if isExpired(expiresAt: creds.expiresAt) {
                if n == liveOwner && ccRunning {
                    // Claude Code is using this token — serve cache, don't rotate it.
                } else {
                    do {
                        let r = try oauth.refresh(refreshToken: creds.refreshToken)
                        creds.accessToken = r.access; creds.expiresAt = r.expiresAt
                        if let rt = r.refresh { creds.refreshToken = rt }
                        if let sc = r.scopes { creds.scopes = sc }
                        try? store.setCreds(n, creds)
                        // Rotation invalidates the old refresh token — the live
                        // keychain must get the new one or CC's next refresh 401s.
                        // Only for the verified owner of the live item.
                        if n == liveOwner { try? Credentials.writeActive(creds) }
                        row.needsReauth = false
                    } catch OAuthError.needsReauth {
                        row.needsReauth = true; row.lastError = "needs re-login"; cache[n] = row; continue
                    } catch {
                        row.failures += 1
                        row.backoffUntil = now + backoff(failures: row.failures, retryAfter: nil)
                        row.lastError = "refresh: \(error)"; cache[n] = row; continue
                    }
                }
            }
            do {
                let data = try oauth.fetchUsageRaw(accessToken: creds.accessToken)
                row.meters = try UsageMapper.meters(from: data)
                row.fetchedAt = now; row.failures = 0; row.backoffUntil = nil; row.lastError = nil
            } catch OAuthError.http(429, let ra) {
                row.failures += 1
                row.backoffUntil = now + backoff(failures: row.failures, retryAfter: ra)
                row.lastError = "rate limited"
            } catch {
                row.failures += 1
                row.backoffUntil = now + backoff(failures: row.failures, retryAfter: nil)
                row.lastError = "\(error)"
            }
            cache[n] = row
        }
        saveCache(cache)

        return list.map { a in
            let row = cache[a.number]
            return Account(id: "claude:\(a.number)", number: a.number, email: a.email,
                           org: a.organizationName ?? "",
                           isActive: a.number == active,
                           status: (row?.needsReauth ?? false) ? "needs-reauth" : "ok",
                           meters: row?.meters ?? [],
                           ageSeconds: row?.fetchedAt.map { now - $0 },
                           provider: "claude")
        }
    }

    public func switchTo(_ account: Account) throws {}   // handled by Switcher
    public func switchToBest() throws {}

    static func claudeCodeRunning() -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "claude"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }
}
