import Foundation

public enum OAuthError: Error, Sendable {
    case http(Int, retryAfter: Double?)
    case needsReauth
    case transient
    case badResponse
    case network
}

/// Early-refresh when within 5 minutes of expiry (matches Claude Code buffer).
public func isExpired(expiresAt: Double, now_ms: Double = Date().timeIntervalSince1970 * 1000) -> Bool {
    now_ms + 300_000 >= expiresAt
}

/// Synchronous (semaphore) HTTP against the two undocumented OAuth endpoints.
/// Sync so it slots into the existing background-queue fetch path; the task
/// always completes and signals, so no thread/leak is stranded.
public struct OAuthClient {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let beta = "oauth-2025-04-20"
    static let ua = "cbar/1.0"
    public init() {}

    public func fetchUsageRaw(accessToken: String) throws -> Data {
        var r = URLRequest(url: Self.usageURL, timeoutInterval: 5)
        r.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        r.setValue(Self.beta, forHTTPHeaderField: "anthropic-beta")
        r.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        let (data, code, retryAfter) = try send(r)
        if code == 429 { throw OAuthError.http(429, retryAfter: retryAfter) }
        if code >= 400 { throw OAuthError.http(code, retryAfter: nil) }
        return data
    }

    /// WHO owns this token, from the API itself — the only trustworthy identity
    /// source. Local (.claude.json, keychain) pairs are written non-atomically
    /// by /login, so their instantaneous coherence must never be trusted for
    /// creds attribution (2026-07-10 cross-contamination). Cached per token.
    public func fetchProfile(accessToken: String) throws -> ClaudeConfig.OAuthAccount {
        if let hit = Self.profileCache.value(for: accessToken) { return hit }
        var r = URLRequest(url: Self.profileURL, timeoutInterval: 5)
        r.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        r.setValue(Self.beta, forHTTPHeaderField: "anthropic-beta")
        r.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        let (data, code, retryAfter) = try send(r)
        if code == 429 { throw OAuthError.http(429, retryAfter: retryAfter) }
        if code >= 400 { throw OAuthError.http(code, retryAfter: nil) }
        guard let acc = ProfileMapper.account(from: data) else { throw OAuthError.badResponse }
        Self.profileCache.set(acc, for: accessToken)
        return acc
    }

    /// Token → identity cache (tokens rotate ~hourly; polls are 60 s — without
    /// this every poll would burn a profile call). Thread-safe, capped.
    static let profileCache = ProfileCache()
    public final class ProfileCache {
        private var map: [String: ClaudeConfig.OAuthAccount] = [:]
        private let q = DispatchQueue(label: "cbar.profile-cache")
        func value(for token: String) -> ClaudeConfig.OAuthAccount? { q.sync { map[token] } }
        func set(_ v: ClaudeConfig.OAuthAccount, for token: String) {
            q.sync { if map.count > 32 { map.removeAll() }; map[token] = v }
        }
    }

    /// Returns refreshed fields; caller merges into stored creds.
    public func refresh(refreshToken: String) throws
        -> (access: String, expiresAt: Double, refresh: String?, scopes: [String]?) {
        var r = URLRequest(url: Self.tokenURL, timeoutInterval: 10)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": Self.clientID,
        ])
        let (data, code, _) = try send(r)
        if code >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("invalid_grant") || body.contains("invalid_client") { throw OAuthError.needsReauth }
            throw OAuthError.transient
        }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = o["access_token"] as? String,
              let expiresIn = (o["expires_in"] as? Double) ?? (o["expires_in"] as? Int).map(Double.init)
        else { throw OAuthError.badResponse }
        let now_ms = Date().timeIntervalSince1970 * 1000
        let scope = (o["scope"] as? String)?.split(separator: " ").map(String.init)
        return (access, now_ms + expiresIn * 1000, o["refresh_token"] as? String, scope)
    }

    private func send(_ req: URLRequest) throws -> (Data, Int, Double?) {
        var outData: Data?; var status = 0; var retryAfter: Double?; var netErr = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, resp, e in
            outData = d
            if let http = resp as? HTTPURLResponse {
                status = http.statusCode
                retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            }
            if e != nil { netErr = true }
            sem.signal()
        }.resume()
        sem.wait()
        if netErr { throw OAuthError.network }
        return (outData ?? Data(), status, retryAfter)
    }
}

/// Maps the profile API response to identity fields. Nil on a missing identity —
/// a guessed one is worse than none.
///
/// `account.uuid` is the required field, NOT the email: as of 2026-07-25 the
/// endpoint stopped returning `email_address` (it comes back absent), and
/// requiring it made every profile call throw `badResponse`. That silently took
/// `liveOwner` to nil forever, which is load-bearing for four things — live creds
/// are used for the owning slot, slot copies get healed from the live keychain,
/// the refresh guard knows whose token is whose, and Switcher backs up the
/// outgoing login. With it nil, slot copies drift until they expire and usage
/// goes unreadable. `matchSlot` prefers uuid anyway; email is only its fallback
/// for slots captured before uuids were stored, so it stays optional here.
public enum ProfileMapper {
    public static func account(from data: Data) -> ClaudeConfig.OAuthAccount? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let acc = o["account"] as? [String: Any],
              let uuid = acc["uuid"] as? String else { return nil }
        let org = o["organization"] as? [String: Any]
        return ClaudeConfig.OAuthAccount(emailAddress: acc["email_address"] as? String,
                                         accountUuid: uuid,
                                         organizationUuid: org?["uuid"] as? String,
                                         organizationName: org?["name"] as? String)
    }
}

/// Maps the raw usage JSON to `[Meter]`. `five_hour`/`seven_day` use the field
/// `utilization`; `limits[]` use `percent` + `scope.model.display_name`.
public enum UsageMapper {
    public static func meters(from data: Data) throws -> [Meter] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.badResponse
        }
        var m: [Meter] = []
        func win(_ key: String, _ id: String) {
            guard let w = o[key] as? [String: Any] else { return }
            guard let u = (w["utilization"] as? Double) ?? (w["utilization"] as? Int).map(Double.init) else { return }
            m.append(Meter(id: id, pct: u, countdown: countdown(w["resets_at"] as? String)))
        }
        win("five_hour", "5h")
        win("seven_day", "7d")
        if let limits = o["limits"] as? [[String: Any]] {
            for lim in limits {
                let name = ((lim["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let pct = (lim["percent"] as? Double) ?? (lim["percent"] as? Int).map(Double.init)
                if let name, let pct {
                    m.append(Meter(id: name == "Fable" ? "Fbl" : name, pct: pct, countdown: countdown(lim["resets_at"] as? String)))
                }
            }
        }
        return m
    }

    /// The soonest absolute reset time (epoch seconds) across every window in the
    /// raw usage JSON, or nil if none carry one. This is the fact `fetchPlan` needs
    /// to hot-reload an account the moment a window rolls over — `Meter.countdown`
    /// is a relative string computed once at fetch and can't be compared to a
    /// later `now`. Kept out of `Meter` on purpose: only the scheduler reads it.
    public static func soonestReset(from data: Data) -> Double? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var soonest: Double?
        func consider(_ iso: String?) {
            guard let iso, let d = parseISO(iso) else { return }
            let e = d.timeIntervalSince1970
            if let s = soonest { soonest = min(s, e) } else { soonest = e }
        }
        consider((o["five_hour"] as? [String: Any])?["resets_at"] as? String)
        consider((o["seven_day"] as? [String: Any])?["resets_at"] as? String)
        for lim in (o["limits"] as? [[String: Any]]) ?? [] {
            consider(lim["resets_at"] as? String)
        }
        return soonest
    }

    static func countdown(_ iso: String?) -> String? {
        guard let iso, let d = parseISO(iso) else { return nil }
        let s = Int(d.timeIntervalSinceNow)
        if s <= 0 { return "now" }
        let dd = s / 86400, h = (s % 86400) / 3600, mn = (s % 3600) / 60
        if dd > 0 { return "\(dd)d \(h)h" }
        if h > 0 { return "\(h)h \(mn)m" }
        return "\(mn)m"
    }

    /// The usage API's `resets_at` carries fractional seconds (e.g.
    /// "2026-07-09T17:50:00.326186+00:00"), which the default ISO8601 parser
    /// rejects — try fractional first, then plain.
    static func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter(); f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter(); f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }
}
