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
