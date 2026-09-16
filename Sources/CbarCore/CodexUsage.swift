import Foundation

/// What `CodexUsageService` needs from the network — a protocol so the service's
/// token rules (heal, refresh, skip, backoff) can be exercised offline.
public protocol CodexAPI {
    func fetchUsageRaw(_ login: CodexLogin) throws -> Data
    func refresh(refreshToken: String) throws -> (id: String?, access: String?, refresh: String?)
}

/// The two endpoints the Codex CLI itself uses, both undocumented: `/status`
/// reads `wham/usage`, and its `AuthManager` refreshes against
/// `auth.openai.com/oauth/token` with the CLI's public client id (codex-rs
/// `login/src/auth/manager.rs`, rust-v0.154.0). OpenAI can change either.
public struct CodexClient: CodexAPI {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    public init() {}

    /// Reads usage without spending any: no model request, just the numbers
    /// `/status` shows. Works for an account nobody is using right now, which
    /// is the whole point — session files only ever describe the live one.
    public func fetchUsageRaw(_ login: CodexLogin) throws -> Data {
        // 5 s like Claude's usage fetch: this runs on the serial queue every
        // credential path shares, so a slow OpenAI must not hold up the rest.
        var r = URLRequest(url: Self.usageURL, timeoutInterval: 5)
        r.setValue("Bearer \(login.accessToken)", forHTTPHeaderField: "Authorization")
        r.setValue(login.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        r.setValue(OAuthClient.ua, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, code, retryAfter) = try OAuthClient().send(r)
        if code == 429 { throw OAuthError.http(429, retryAfter: retryAfter) }
        if code >= 400 { throw OAuthError.http(code, retryAfter: nil) }
        return data
    }

    /// ROTATES: the refresh token sent here stops working about an hour later.
    /// The caller must persist whatever comes back before doing anything else.
    public func refresh(refreshToken: String) throws -> (id: String?, access: String?, refresh: String?) {
        var r = URLRequest(url: Self.tokenURL, timeoutInterval: 10)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(OAuthClient.ua, forHTTPHeaderField: "User-Agent")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": Self.clientID, "grant_type": "refresh_token", "refresh_token": refreshToken,
        ])
        let (data, code, _) = try OAuthClient().send(r)
        if code >= 400 {
            if Self.isTerminalRefreshFailure(status: code, body: String(data: data, encoding: .utf8) ?? "") {
                throw OAuthError.needsReauth
            }
            throw OAuthError.transient
        }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.badResponse
        }
        return (o["id_token"] as? String, o["access_token"] as? String, o["refresh_token"] as? String)
    }

    /// Codex's own reading of a failed refresh: a 401, a 400 `invalid_grant`, or
    /// one of the three named refresh-token codes means the login is gone.
    /// Anything else may pass, so it backs off instead of demanding a re-login.
    public static func isTerminalRefreshFailure(status: Int, body: String) -> Bool {
        if status == 401 { return true }
        let named = ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"]
        if named.contains(where: { body.contains($0) }) { return true }
        return status == 400 && body.contains("invalid_grant")
    }
}

/// `wham/usage` JSON → meters. Windows are named by `limit_window_seconds`, for
/// the same reason `CodexProvider` names them by length: which slot holds which
/// window depends on the plan (prolite has only a weekly one, in `primary`).
public enum CodexUsageMapper {
    public static func meters(from data: Data, now: Double = Date().timeIntervalSince1970) throws -> [Meter] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.badResponse
        }
        var m = windows(o["rate_limit"] as? [String: Any], name: nil, now: now)
        // Model-specific allowances (Spark, …) come back for every account whether
        // or not it has ever touched that model. Shown once they are in use — a
        // row of 0% cells for models you don't run would crowd out the two
        // numbers that decide a switch.
        for extra in (o["additional_rate_limits"] as? [[String: Any]]) ?? [] {
            let name = (extra["limit_name"] as? String) ?? "model"
            var ms = windows(extra["rate_limit"] as? [String: Any], name: name, now: now)
            guard ms.contains(where: { $0.pct > 0 }) else { continue }
            // Short names can collide ("…-Spark" twice); meter ids key the UI's
            // cells and must not. Fall back to the full name for a repeat.
            if ms.contains(where: { id in m.contains { $0.id == id.id } }) {
                ms = windows(extra["rate_limit"] as? [String: Any], name: name, now: now, shorten: false)
            }
            m += ms
        }
        return m
    }

    /// Soonest absolute reset across every window, for `fetchPlan`'s hot reload.
    public static func soonestReset(from data: Data) -> Double? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var limits = [o["rate_limit"] as? [String: Any]]
        limits += ((o["additional_rate_limits"] as? [[String: Any]]) ?? []).map { $0["rate_limit"] as? [String: Any] }
        return limits.flatMap { rl -> [Double] in
            ["primary_window", "secondary_window"].compactMap { key in
                (rl?[key] as? [String: Any]).flatMap { resetEpoch($0, now: Date().timeIntervalSince1970) }
            }
        }.min()
    }

    static func windows(_ rl: [String: Any]?, name: String?, now: Double, shorten: Bool = true) -> [Meter] {
        let slots = [("primary_window", "5h"), ("secondary_window", "7d")].compactMap { key, positional in
            (rl?[key] as? [String: Any]).map { ($0, positional) }
        }
        return slots.compactMap { w, positional -> Meter? in
            guard let pct = num(w["used_percent"]) else { return nil }
            let window = num(w["limit_window_seconds"]).flatMap { CodexProvider.windowLabel(Int($0) / 60) } ?? positional
            let id: String
            if let name {
                // "GPT-5.3-Codex-Spark" → "Spark": the cell is a few characters wide.
                let short = shorten ? (name.split(whereSeparator: { $0 == " " || $0 == "-" }).last.map(String.init) ?? name) : name
                id = slots.count > 1 ? "\(short) \(window)" : short
            } else {
                id = window
            }
            let reset = resetEpoch(w, now: now)
            return Meter(id: id, pct: pct,
                         countdown: CodexProvider.countdown(reset, now: now),
                         resetsAt: reset)
        }
    }

    /// `reset_at` is the absolute time; recent `/wham/usage` bodies omit it and
    /// only send `reset_after_seconds`. Either is enough to put a countdown on
    /// the Codex row. JSONSerialization numbers arrive as NSNumber, so `as? Double`
    /// alone misses integer timestamps.
    static func resetEpoch(_ w: [String: Any], now: Double) -> Double? {
        if let r = num(w["reset_at"]) ?? num(w["resets_at"]) { return r }
        if let s = (w["reset_at"] as? String) ?? (w["resets_at"] as? String),
           let d = UsageMapper.parseISO(s) { return d.timeIntervalSince1970 }
        if let after = num(w["reset_after_seconds"]), after > 0 { return now + after }
        return nil
    }

    private static func num(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

/// Paced per-account Codex usage, the counterpart of `UsageService`: one fetch
/// per pass (stalest first, via `fetchPlan`), per-account backoff, a persisted
/// cache. The rules about whose token cbar may touch are Codex's, not Claude's:
///
/// - The LIVE slot's token belongs to Codex. cbar reads it from `auth.json`
///   (always the freshest copy), heals its slot backup from it, and never
///   refreshes it.
/// - Any other slot's token lives only in cbar's store, so when it expires
///   cbar refreshes it and persists the rotation before using it. A Codex
///   process still running on that account can't collide: once `auth.json`
///   names another account, Codex refuses to refresh rather than reuse it.
public final class CodexUsageService {
    private let store: CodexAccountStore
    private let client: CodexAPI
    private let cachePath: String
    private let home: String

    public init(store: CodexAccountStore = CodexAccountStore(), client: CodexAPI = CodexClient(),
                cachePath: String = "\(NSHomeDirectory())/.cbar/codex-usage-cache.json",
                home: String = CodexLive.defaultHome) {
        self.store = store; self.client = client; self.cachePath = cachePath; self.home = home
    }

    typealias Row = UsageService.Row

    private func loadCache() -> [Int: Row] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
              let raw = try? JSONDecoder().decode([String: Row].self, from: d) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
    }
    private func saveCache(_ c: [Int: Row]) {
        let raw = Dictionary(uniqueKeysWithValues: c.map { (String($0.key), $0.value) })
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(raw) else { return }
        try? SecureFile.write(d, to: cachePath)
    }

    /// Whether refreshing slot `n`'s expired token must wait. Refreshing rotates,
    /// so cbar only does it for a token nothing else can be holding:
    ///  - the live slot: Codex refreshes that one itself;
    ///  - an unusable live file (Codex mid-write, or mixed tokens): whose token is
    ///    live can't be known this pass;
    ///  - a refresh token identical to the live one, whatever the slot says.
    /// An API-key or absent live login holds no ChatGPT token, so idle slots are
    /// cbar's alone and may refresh.
    public static func shouldSkipRefresh(n: Int, liveSlot: Int?, live: CodexLive.State,
                                         slotRefresh: String) -> Bool {
        if n == liveSlot { return true }
        switch live {
        case .unusable: return true
        case .login(let l): return l.refreshToken == slotRefresh
        case .missing, .notTokenLogin: return false
        }
    }

    /// A pass that could not fetch a slot for a reason time will fix (Codex owns
    /// its expired token, or there are no credentials) still has to move the slot
    /// out of the way. Without this it stayed the stalest row — and for the live
    /// slot, past `activeMaxAge` — so `fetchPlan` chose it every pass, skipped it,
    /// and never fetched anything else: every idle slot aged out of switchability
    /// while Codex sat unused over a weekend with an expired token.
    static let skipBackoff: Double = 300

    /// Forget a removed slot's cached usage.
    public func forget(_ n: Int) {
        var cache = loadCache()
        guard cache.removeValue(forKey: n) != nil else { return }
        saveCache(cache)
    }

    /// Clear a slot's failure history after a fresh login was captured for it,
    /// for the reason `UsageService.clearFailureState` gives.
    public func clearFailureState(_ n: Int) {
        var cache = loadCache()
        guard var row = cache[n] else { return }
        row.backoffUntil = nil; row.failures = 0
        row.needsReauth = false; row.lastError = nil
        cache[n] = row; saveCache(cache)
    }

    public func accounts(now: Double = Date().timeIntervalSince1970) -> [Account] {
        let live = CodexLive.read(home: home)
        let liveLogin: CodexLogin? = { if case .login(let l) = live { return l }; return nil }()
        let liveSlot = liveLogin.flatMap { store.slot(for: $0) }
        var cache = loadCache()

        // Heal the live slot's backup when the live login is NEWER — Codex rotated
        // it — and take the plan with it (it's in the token, and plans change).
        // Newer, not merely different: a slot can also be ahead of the file (a
        // re-login imported through the inbox), and copying the file over it then
        // would put back the very token the re-login replaced.
        var credsChanged: Set<Int> = []
        if let n = liveSlot, let l = liveLogin {
            let saved = (try? store.login(n)) ?? nil
            let differs = saved?.accessToken != l.accessToken || saved?.refreshToken != l.refreshToken
            if differs, (l.issuedAt ?? 0) >= (saved?.issuedAt ?? 0) {
                do {
                    try store.add(l)
                    credsChanged.insert(n)
                    var row = cache[n] ?? Row()
                    row.failures = 0; row.backoffUntil = nil; row.needsReauth = false; row.lastError = nil
                    cache[n] = row
                    CbarLog.write("codex slot #\(n) healed from live auth.json")
                } catch {
                    CbarLog.write("codex slot #\(n) heal from live auth.json FAILED: \(error)")
                }
            }
        }

        let slots = store.list()
        let rows = slots.map { s in
            PaceRow(number: s.number, fetchedAt: cache[s.number]?.fetchedAt,
                    backoffUntil: cache[s.number]?.backoffUntil, lastAttemptAt: cache[s.number]?.lastAttemptAt,
                    resetsAt: cache[s.number]?.resetsAt)
        }
        for n in fetchPlan(now: now, active: liveSlot, rows: rows, credsChanged: credsChanged) {
            var row = cache[n] ?? Row()
            row.lastAttemptAt = now
            guard var login = (n == liveSlot ? liveLogin : nil) ?? ((try? store.login(n)) ?? nil) else {
                row.meters = []; row.lastError = "no credentials"
                row.backoffUntil = now + Self.skipBackoff
                cache[n] = row; continue
            }
            if login.isExpired(now: now) {
                if Self.shouldSkipRefresh(n: n, liveSlot: liveSlot, live: live, slotRefresh: login.refreshToken) {
                    // Not a failure — nothing is wrong with the account — so no
                    // failure count, just out of the way (see `skipBackoff`).
                    row.lastError = "token expired (Codex owns it)"
                    row.backoffUntil = now + Self.skipBackoff
                    cache[n] = row; continue
                }
                do {
                    let r = try client.refresh(refreshToken: login.refreshToken)
                    guard let next = login.refreshed(idToken: r.id, accessToken: r.access, refreshToken: r.refresh,
                                                     now: Date(timeIntervalSince1970: now)) else {
                        // Unreachable in practice (the raw already parsed once), but the
                        // old refresh token is spent either way — say so.
                        CbarLog.write("codex slot #\(n) refresh response unusable — rotated token LOST, needs re-login")
                        row.needsReauth = true; row.meters = []; row.lastError = "refresh response unusable"
                        cache[n] = row; continue
                    }
                    // Persist before use, and never `try?`: the rotation already
                    // spent the old token, so a dropped write is a dead account.
                    do { try store.setLogin(n, next) } catch {
                        CbarLog.write("codex slot #\(n) FAILED to persist rotated login: \(error) — needs re-login")
                        row.needsReauth = true; row.meters = []; row.lastError = "creds write failed"
                        cache[n] = row; continue
                    }
                    login = next
                    row.needsReauth = false
                } catch OAuthError.needsReauth {
                    row.needsReauth = true; row.meters = []
                    row.failures += 1
                    row.backoffUntil = now + backoff(failures: row.failures, retryAfter: nil)
                    row.lastError = "needs re-login"; cache[n] = row; continue
                } catch {
                    row.failures += 1
                    row.backoffUntil = now + backoff(failures: row.failures, retryAfter: nil)
                    row.lastError = "refresh: \(error)"; cache[n] = row; continue
                }
            }
            do {
                let data = try client.fetchUsageRaw(login)
                row.meters = try CodexUsageMapper.meters(from: data, now: now)
                row.resetsAt = CodexUsageMapper.soonestReset(from: data)
                row.fetchedAt = now; row.failures = 0; row.backoffUntil = nil; row.lastError = nil
                row.needsReauth = false
            } catch OAuthError.http(401, _), OAuthError.http(403, _) {
                row.needsReauth = true; row.meters = []
                row.failures += 1
                row.backoffUntil = now + backoff(failures: row.failures, retryAfter: nil)
                row.lastError = "unauthorized"
            } catch OAuthError.http(429, let ra) {
                row.failures += 1
                let wait = backoff(failures: row.failures, retryAfter: ra)
                row.backoffUntil = now + wait
                row.lastError = "rate limited"
                CbarLog.write("codex fetch #\(n) 429 — retry-after=\(ra.map { String(Int($0)) } ?? "-") failures=\(row.failures) backoff=\(Int(wait))s")
            } catch {
                row.failures += 1
                row.backoffUntil = now + backoff(failures: row.failures, retryAfter: nil)
                row.lastError = "\(error)"
            }
            cache[n] = row
        }
        saveCache(cache)

        return slots.map { s in
            let row = cache[s.number]
            return Account(id: "codex:\(s.number)", number: s.number, email: s.email ?? "Codex #\(s.number)",
                           org: s.plan.map { "OpenAI · \($0)" } ?? "OpenAI",
                           isActive: s.number == liveSlot,
                           status: UsageService.status(needsReauth: row?.needsReauth ?? false,
                                                       meters: row?.meters ?? [], fetchedAt: row?.fetchedAt,
                                                       lastError: row?.lastError, now: now),
                           meters: row?.meters ?? [],
                           ageSeconds: row?.fetchedAt.map { now - $0 },
                           provider: "codex")
        }
    }
}
