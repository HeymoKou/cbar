import Foundation

/// What `GrokUsageService` needs from the network — a protocol so token rules
/// (skip-while-running, persist-before-use) can be exercised offline.
public protocol GrokAPI {
    func fetchBillingRaw(accessToken: String) throws -> Data
    func refresh(refreshToken: String, clientID: String) throws -> (access: String, refresh: String?, expiresIn: Double)
}

/// Undocumented Grok Build billing + the public OIDC token endpoint the CLI
/// itself uses. xAI can change either. The `X-XAI-Token-Auth` header is the
/// gate the CLI proxy checks; without it the call 401s even with a valid JWT.
public struct GrokClient: GrokAPI {
    static let billingURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    static let monthlyURL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing")!
    static let tokenURL = URL(string: "https://auth.x.ai/oauth2/token")!
    static let defaultClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    public init() {}

    public func fetchBillingRaw(accessToken: String) throws -> Data {
        let credits = try get(Self.billingURL, token: accessToken)
        // Unified-billing accounts often omit `creditUsagePercent` on the
        // credits payload; the monthly body still has used/limit. Fetch it only
        // when the credits body has no percent to show — one extra GET, and
        // only then, so a normal weekly account stays one request.
        if GrokUsageMapper.percent(in: credits) != nil { return credits }
        if let monthly = try? get(Self.monthlyURL, token: accessToken) {
            return GrokUsageMapper.merge(credits: credits, monthly: monthly)
        }
        return credits
    }

    public func refresh(refreshToken: String, clientID: String) throws -> (access: String, refresh: String?, expiresIn: Double) {
        var r = URLRequest(url: Self.tokenURL, timeoutInterval: 10)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(OAuthClient.ua, forHTTPHeaderField: "User-Agent")
        let form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID.isEmpty ? Self.defaultClientID : clientID,
        ]
        r.httpBody = form.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, code, _) = try OAuthClient().send(r)
        if code >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            if code == 401 || body.contains("invalid_grant") { throw OAuthError.needsReauth }
            throw OAuthError.transient
        }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = o["access_token"] as? String else { throw OAuthError.badResponse }
        let expiresIn = (o["expires_in"] as? Double) ?? (o["expires_in"] as? Int).map(Double.init) ?? 3600
        return (access, o["refresh_token"] as? String, expiresIn)
    }

    private func get(_ url: URL, token: String) throws -> Data {
        var r = URLRequest(url: url, timeoutInterval: 5)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue(OAuthClient.ua, forHTTPHeaderField: "User-Agent")
        let (data, code, retryAfter) = try OAuthClient().send(r)
        if code == 429 { throw OAuthError.http(429, retryAfter: retryAfter) }
        if code >= 400 { throw OAuthError.http(code, retryAfter: nil) }
        return data
    }
}

/// One Grok Build login, as `~/.grok/auth.json` stores it: a single OIDC
/// entry keyed by `issuer::client_id`.
public struct GrokLogin: Sendable {
    public let mapKey: String
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let email: String
    public let clientID: String

    /// Same 5-minute early-refresh buffer Claude Code uses.
    public func isExpired(now: Date = Date()) -> Bool {
        now.addingTimeInterval(300) >= expiresAt
    }
}

public enum GrokAuth {
    public static let defaultPath = "\(NSHomeDirectory())/.grok/auth.json"

    public static func read(path: String = defaultPath) -> GrokLogin? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        for (key, value) in root {
            guard let o = value as? [String: Any],
                  let access = o["key"] as? String, !access.isEmpty,
                  let refresh = o["refresh_token"] as? String, !refresh.isEmpty else { continue }
            let clientID = (o["oidc_client_id"] as? String) ?? GrokClient.defaultClientID
            let email = (o["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "Grok"
            let expiresAt = (o["expires_at"] as? String).flatMap(UsageMapper.parseISO) ?? .distantPast
            return GrokLogin(mapKey: key, accessToken: access, refreshToken: refresh,
                             expiresAt: expiresAt, email: email.isEmpty ? "Grok" : email,
                             clientID: clientID)
        }
        return nil
    }

    /// Persist a rotation into the live file. The refresh already spent the old
    /// token, so a dropped write is a dead login — callers must not `try?`.
    public static func persistRefresh(access: String, refresh: String?, expiresAt: Date,
                                      path: String = defaultPath) throws {
        let url = URL(fileURLWithPath: path)
        guard let d = try? Data(contentsOf: url),
              var root = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let key = root.keys.first, var entry = root[key] as? [String: Any] else {
            throw OAuthError.badResponse
        }
        entry["key"] = access
        if let refresh { entry["refresh_token"] = refresh }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        entry["expires_at"] = fmt.string(from: expiresAt)
        root[key] = entry
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        // Don't SecureFile.ensureDir the parent: that's `~/.grok`, which grok
        // owns. Atomic replace + 0600 on the file itself is the whole write.
        try out.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}

/// `billing?format=credits` JSON → meters. Percent from `creditUsagePercent`
/// when present; otherwise monthly used/limit, then on-demand used/cap. An
/// absent percent is NOT treated as 0 — that lied on unified-billing accounts.
public enum GrokUsageMapper {
    public static func percent(in data: Data) -> Double? {
        guard let cfg = config(data) else { return nil }
        return num(cfg["creditUsagePercent"])
    }

    public static func meters(from data: Data, now: Double = Date().timeIntervalSince1970) throws -> [Meter] {
        guard let cfg = config(data) else { throw OAuthError.badResponse }
        let period = cfg["currentPeriod"] as? [String: Any]
        let type = ((period?["type"] as? String) ?? "").uppercased()
        let id = meterID(periodType: type)
        let endISO = (period?["end"] as? String) ?? (cfg["billingPeriodEnd"] as? String)
        let countdown = endISO.flatMap(UsageMapper.parseISO)
            .flatMap { CodexProvider.countdown($0.timeIntervalSince1970, now: now) }

        if let pct = num(cfg["creditUsagePercent"]) {
            return [Meter(id: id, pct: clamp(pct), countdown: countdown)]
        }
        // Monthly absolute, on the credits body or merged in from GET /billing.
        if let used = val(cfg["used"]) ?? val(cfg["totalUsed"]) ?? nestedUsed(cfg),
           let limit = val(cfg["monthlyLimit"]), limit > 0 {
            return [Meter(id: id == "5h" ? "7d" : id, pct: clamp(used / limit * 100), countdown: countdown)]
        }
        if let cap = val(cfg["onDemandCap"]), cap > 0 {
            let used = val(cfg["onDemandUsed"]) ?? 0
            return [Meter(id: "OD", pct: clamp(used / cap * 100), countdown: countdown)]
        }
        return []
    }

    public static func soonestReset(from data: Data) -> Double? {
        guard let cfg = config(data) else { return nil }
        let period = cfg["currentPeriod"] as? [String: Any]
        let iso = (period?["end"] as? String) ?? (cfg["billingPeriodEnd"] as? String)
        return iso.flatMap(UsageMapper.parseISO)?.timeIntervalSince1970
    }

    public static func plan(from data: Data) -> String? {
        guard let cfg = config(data) else { return nil }
        if let s = cfg["subscriptionTierDisplay"] as? String, !s.isEmpty { return s }
        if let s = cfg["subscriptionTier"] as? String, !s.isEmpty { return s }
        return nil
    }

    /// Stitch the monthly body's used/limit onto a credits payload that had a
    /// period but no percent, so `meters` can read one blob.
    public static func merge(credits: Data, monthly: Data) -> Data {
        guard var cfg = config(credits),
              let m = config(monthly) else { return credits }
        for key in ["used", "monthlyLimit", "totalUsed"] where cfg[key] == nil && m[key] != nil {
            cfg[key] = m[key]
        }
        if let usage = m["usage"] as? [String: Any] { cfg["usage"] = usage }
        let wrapped: [String: Any] = ["config": cfg]
        return (try? JSONSerialization.data(withJSONObject: wrapped)) ?? credits
    }

    static func meterID(periodType: String) -> String {
        if periodType.contains("MONTH") { return "30d" }
        if periodType.contains("HOUR") || periodType.contains("5H") { return "5h" }
        return "7d"
    }

    private static func config(_ data: Data) -> [String: Any]? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (o["config"] as? [String: Any]) ?? o
    }
    private static func nestedUsed(_ cfg: [String: Any]) -> Double? {
        let u = cfg["usage"] as? [String: Any]
        return val(u?["totalUsed"]) ?? val(u?["includedUsed"])
    }
    private static func val(_ v: Any?) -> Double? {
        if let n = num(v) { return n }
        if let o = v as? [String: Any] { return num(o["val"]) }
        return nil
    }
    private static func num(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) }
    private static func clamp(_ p: Double) -> Double { min(100, max(0, p)) }
}

/// Read-only Grok Build usage for the live `~/.grok/auth.json` login. No
/// switching, no extra stored accounts. Refreshing rotates, so cbar only does
/// it when grok itself is not running — otherwise grok owns the token, the
/// way Codex owns `auth.json`.
public final class GrokUsageService {
    private let client: GrokAPI
    private let authPath: String
    private let cachePath: String
    private let grokRunning: () -> Bool

    public init(client: GrokAPI = GrokClient(),
                authPath: String = GrokAuth.defaultPath,
                cachePath: String = "\(NSHomeDirectory())/.cbar/grok-usage-cache.json",
                grokRunning: @escaping () -> Bool = { GrokUsageService.grokRunning() }) {
        self.client = client; self.authPath = authPath
        self.cachePath = cachePath; self.grokRunning = grokRunning
    }

    struct Row: Codable {
        var meters: [Meter] = []
        var fetchedAt: Double? = nil
        var resetsAt: Double? = nil
        var lastAttemptAt: Double? = nil
        var backoffUntil: Double? = nil
        var failures: Int = 0
        var lastError: String? = nil
        var needsReauth: Bool = false
        var plan: String? = nil
    }

    private func loadCache() -> Row? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: cachePath)) else { return nil }
        return try? JSONDecoder().decode(Row.self, from: d)
    }
    private func saveCache(_ row: Row) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(row) else { return }
        try? SecureFile.write(d, to: cachePath)
    }

    public static func grokRunning() -> Bool {
        UsageService.pgrepMatches(["-x", "grok"])
    }

    /// Refreshing rotates. Skip when grok is alive — a false negative here is
    /// the expensive direction (revoking the family grok still holds).
    public static func shouldSkipRefresh(grokRunning: Bool) -> Bool { grokRunning }

    public func accounts(now: Double = Date().timeIntervalSince1970) -> [Account] {
        guard var login = GrokAuth.read(path: authPath) else { return [] }
        var row = loadCache() ?? Row()
        if let b = row.backoffUntil, now < b {
            return [account(login, row, now: now)]
        }
        row.lastAttemptAt = now

        if login.isExpired(now: Date(timeIntervalSince1970: now)) {
            if Self.shouldSkipRefresh(grokRunning: grokRunning()) {
                row.lastError = "token expired (Grok owns it)"
                row.backoffUntil = now + CodexUsageService.skipBackoff
                saveCache(row)
                return [account(login, row, now: now)]
            }
            do {
                let r = try client.refresh(refreshToken: login.refreshToken, clientID: login.clientID)
                let exp = Date(timeIntervalSince1970: now + r.expiresIn)
                do {
                    try GrokAuth.persistRefresh(access: r.access, refresh: r.refresh,
                                                expiresAt: exp, path: authPath)
                } catch {
                    CbarLog.write("grok FAILED to persist rotated login: \(error) — needs re-login")
                    row.needsReauth = true; row.meters = []; row.lastError = "creds write failed"
                    saveCache(row)
                    return [account(login, row, now: now)]
                }
                login = GrokLogin(mapKey: login.mapKey, accessToken: r.access,
                                  refreshToken: r.refresh ?? login.refreshToken,
                                  expiresAt: exp, email: login.email, clientID: login.clientID)
                row.needsReauth = false
            } catch OAuthError.needsReauth {
                row.needsReauth = true; row.meters = []
                row.failures += 1
                row.backoffUntil = now + backoff(failures: row.failures, retryAfter: nil)
                row.lastError = "needs re-login"
                saveCache(row)
                return [account(login, row, now: now)]
            } catch {
                row.failures += 1
                row.backoffUntil = now + backoff(failures: row.failures, retryAfter: nil)
                row.lastError = "refresh: \(error)"
                saveCache(row)
                return [account(login, row, now: now)]
            }
        }

        do {
            let data = try client.fetchBillingRaw(accessToken: login.accessToken)
            row.meters = try GrokUsageMapper.meters(from: data, now: now)
            row.resetsAt = GrokUsageMapper.soonestReset(from: data)
            row.plan = GrokUsageMapper.plan(from: data)
            row.fetchedAt = now; row.failures = 0; row.backoffUntil = nil
            row.needsReauth = false; row.lastError = nil
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
            CbarLog.write("grok fetch 429 — retry-after=\(ra.map { String(Int($0)) } ?? "-") failures=\(row.failures) backoff=\(Int(wait))s")
        } catch {
            row.failures += 1
            row.backoffUntil = now + backoff(failures: row.failures, retryAfter: nil)
            row.lastError = "\(error)"
        }
        saveCache(row)
        return [account(login, row, now: now)]
    }

    private func account(_ login: GrokLogin, _ row: Row, now: Double) -> Account {
        return Account(id: "grok", number: 0, email: login.email,
                       org: row.plan.map { "xAI · \($0)" } ?? "xAI",
                       isActive: false,
                       status: UsageService.status(needsReauth: row.needsReauth,
                                                   meters: row.meters, fetchedAt: row.fetchedAt,
                                                   lastError: row.lastError, now: now),
                       meters: row.meters,
                       ageSeconds: row.fetchedAt.map { now - $0 },
                       provider: "grok")
    }
}
