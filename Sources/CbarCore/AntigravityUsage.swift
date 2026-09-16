import Foundation

/// What `AntigravityUsageService` needs from the network.
public protocol AntigravityAPI {
    func loadCodeAssist(accessToken: String) throws -> Data
    func quotaSummary(accessToken: String, project: String?) throws -> Data
    func fetchAvailableModels(accessToken: String) throws -> Data
    func refresh(refreshToken: String, clientID: String, clientSecret: String) throws -> (access: String, expiresIn: Double)
}

/// Cloud Code Assist internals the Antigravity desktop app and `agy` use for
/// the grouped Weekly / Five Hour readouts. Undocumented; Google can change
/// them. The `daily-` host is the one that returns real Gemini remaining
/// fractions — the unprefixed host reports 1.0 for those models.
public struct AntigravityClient: AntigravityAPI {
    static let loadURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    static let quotaURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!
    static let modelsURL = URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    /// Cloud Code 403s `cbar/1.0`; the daily host fingerprints this UA.
    static let ua = "antigravity/darwin/arm64"
    public init() {}

    public func loadCodeAssist(accessToken: String) throws -> Data {
        try post(Self.loadURL, token: accessToken, body: ["metadata": ["ideType": "ANTIGRAVITY"]])
    }

    public func quotaSummary(accessToken: String, project: String?) throws -> Data {
        var body: [String: Any] = [:]
        if let project, !project.isEmpty { body["project"] = project }
        return try post(Self.quotaURL, token: accessToken, body: body)
    }

    /// Per-model `quotaInfo`. Consumer accounts often 403 on the grouped
    /// summary; this is the endpoint `agy` itself loads on startup.
    public func fetchAvailableModels(accessToken: String) throws -> Data {
        try post(Self.modelsURL, token: accessToken, body: [:])
    }

    public func refresh(refreshToken: String, clientID: String, clientSecret: String) throws -> (access: String, expiresIn: Double) {
        var r = URLRequest(url: Self.tokenURL, timeoutInterval: 10)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue(OAuthClient.ua, forHTTPHeaderField: "User-Agent")
        let form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "client_secret": clientSecret,
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
        return (access, expiresIn)
    }

    private func post(_ url: URL, token: String, body: [String: Any]) throws -> Data {
        var r = URLRequest(url: url, timeoutInterval: 5)
        r.httpMethod = "POST"
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, code, retryAfter) = try OAuthClient().send(r)
        if code == 429 { throw OAuthError.http(429, retryAfter: retryAfter) }
        if code >= 400 { throw OAuthError.http(code, retryAfter: nil) }
        return data
    }
}

public struct AntigravityCreds: Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiry: Date
    public let email: String

    public init(accessToken: String, refreshToken: String, expiry: Date, email: String) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiry = expiry; self.email = email
    }

    public func isExpired(now: Date = Date()) -> Bool {
        now.addingTimeInterval(60) >= expiry
    }
}

/// Live Antigravity / `agy` login. On macOS `agy` stores this in the Keychain
/// (`service=gemini`, `account=antigravity`) as a `go-keyring-base64:` blob.
/// cbar reads it and never writes it back — a `security` rewrite would change
/// the item ACL the way it does for Claude Code, and this path is monitor-only.
public enum AntigravityAuth {
    public static let keychainService = "gemini"
    public static let keychainAccount = "antigravity"

    public static func read(raw: String? = nil) -> AntigravityCreds? {
        let blob = raw ?? ((try? Keychain.getRaw(service: keychainService, account: keychainAccount)) ?? nil)
        guard let blob, let data = decodeKeyring(blob),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let token = o["token"] as? [String: Any]
        let access = (token?["access_token"] as? String) ?? (o["access_token"] as? String)
        let refresh = (token?["refresh_token"] as? String) ?? (o["refresh_token"] as? String)
        guard let access, !access.isEmpty, let refresh, !refresh.isEmpty else { return nil }
        let expiryISO = (token?["expiry"] as? String) ?? (o["expiry"] as? String)
        let expiry = expiryISO.flatMap(UsageMapper.parseISO) ?? .distantPast
        let email = jwtEmail(o["id_token"] as? String)
            ?? jwtEmail(token?["id_token"] as? String)
            ?? "Antigravity"
        return AntigravityCreds(accessToken: access, refreshToken: refresh,
                                expiry: expiry, email: email)
    }

    /// `go-keyring` prefixes the item with `go-keyring-base64:` then standard
    /// base64 of the JSON. A bare JSON blob (Linux token file) is accepted too.
    public static func decodeKeyring(_ raw: String) -> Data? {
        let prefix = "go-keyring-base64:"
        if raw.hasPrefix(prefix) {
            var b64 = String(raw.dropFirst(prefix.count))
            let pad = (4 - b64.count % 4) % 4
            b64 += String(repeating: "=", count: pad)
            return Data(base64Encoded: b64)
        }
        return raw.data(using: .utf8)
    }

    public static func jwtEmail(_ jwt: String?) -> String? {
        guard let jwt else { return nil }
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let pad = (4 - b64.count % 4) % 4
        b64 += String(repeating: "=", count: pad)
        guard let data = Data(base64Encoded: b64),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let email = o["email"] as? String, !email.isEmpty else { return nil }
        return email
    }
}

/// OAuth client id/secret the `agy` binary embeds. Not hardcoded: a CLI update
/// can rotate them, and putting the secret in cbar's source would publish it.
public enum AntigravityOAuth {
    private static var cached: (id: String, secret: String)?
    private static var scanned = false

    public static func client(agyPath: String? = nil) -> (id: String, secret: String)? {
        if let c = cached { return c }
        if scanned, agyPath == nil { return nil }
        let path = agyPath ?? findAgy()
        scanned = agyPath == nil
        guard let path, let pair = extract(from: path) else { return nil }
        if agyPath == nil { cached = pair }
        return pair
    }

    public static func findAgy() -> String? {
        let home = NSHomeDirectory()
        for p in ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Chunked scan so a 180 MB binary never lands in one Data. Overlap is
    /// bigger than either token so a match that straddles a chunk is still
    /// found. Prefers the client id that starts with `1071` (the Antigravity
    /// CLI app); any `GOCSPX-` secret pairs with it.
    public static func extract(from path: String) -> (id: String, secret: String)? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        var ids: [String] = []
        var secret: String?
        var carry = Data()
        let chunk = 1024 * 1024
        let overlap = 96
        while true {
            let data = fh.readData(ofLength: chunk)
            if data.isEmpty && carry.isEmpty { break }
            let buf = carry + data
            if secret == nil { secret = firstMatch(buf, prefix: "GOCSPX-", charset: charsetSecret) }
            ids.append(contentsOf: allClientIDs(in: buf))
            if data.isEmpty { break }
            carry = Data(buf.suffix(overlap))
        }
        guard let secret else { return nil }
        let preferred = ids.first { $0.hasPrefix("1071") } ?? ids.first
        guard let preferred else { return nil }
        return (preferred, secret)
    }

    private static let charsetSecret = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-".utf8)
    private static let charsetID = Set("abcdefghijklmnopqrstuvwxyz0123456789-".utf8)

    private static func firstMatch(_ data: Data, prefix: String, charset: Set<UInt8>) -> String? {
        guard let p = data.range(of: Data(prefix.utf8)) else { return nil }
        var i = p.upperBound
        while i < data.count, charset.contains(data[i]) { i += 1 }
        return String(data: data[p.lowerBound..<i], encoding: .utf8)
    }

    private static func allClientIDs(in data: Data) -> [String] {
        let needle = Data(".apps.googleusercontent.com".utf8)
        var found: [String] = []
        var search = data.startIndex
        while let r = data[search...].range(of: needle) {
            var i = r.lowerBound
            while i > data.startIndex {
                let prev = data.index(before: i)
                guard charsetID.contains(data[prev]) else { break }
                i = prev
            }
            if let s = String(data: data[i..<r.upperBound], encoding: .utf8),
               let id = s.range(of: #"[0-9]{10,}-[a-z0-9]+\.apps\.googleusercontent\.com"#,
                                options: .regularExpression) {
                found.append(String(s[id]))
            }
            search = r.upperBound
        }
        return found
    }
}

/// `retrieveUserQuotaSummary` JSON → meters. Groups are Gemini vs Claude/GPT
/// pools; each carries a Five Hour and a Weekly bucket. `remainingFraction`
/// is remaining, so used = (1 − fraction) × 100.
public enum AntigravityUsageMapper {
    public static func meters(from data: Data, now: Double = Date().timeIntervalSince1970) throws -> [Meter] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = o["groups"] as? [[String: Any]] else { throw OAuthError.badResponse }
        let named = groups.compactMap { group -> (prefix: String, meters: [Meter])? in
            let buckets = (group["buckets"] as? [[String: Any]]) ?? []
            let ms = buckets.compactMap { bucket -> Meter? in
                guard let frac = num(bucket["remainingFraction"]) else { return nil }
                let window = windowID(bucket["displayName"] as? String, bucket["window"] as? String)
                let reset = (bucket["resetTime"] as? String) ?? (bucket["reset_time"] as? String)
                return Meter(id: window, pct: clamp((1 - frac) * 100),
                             countdown: reset.flatMap(UsageMapper.parseISO)
                                .flatMap { CodexProvider.countdown($0.timeIntervalSince1970, now: now) })
            }
            guard !ms.isEmpty else { return nil }
            return (groupPrefix(group["displayName"] as? String), ms)
        }
        let multi = named.count > 1
        var out: [Meter] = []
        var seen = Set<String>()
        for (prefix, ms) in named {
            for m in ms {
                var id = multi ? "\(prefix) \(m.id)" : m.id
                if seen.contains(id) { id = "\(prefix) \(m.id)" }
                seen.insert(id)
                out.append(Meter(id: id, pct: m.pct, countdown: m.countdown))
            }
        }
        out.sort { meterOrder($0.id) < meterOrder($1.id) }
        return out
    }

    /// `fetchAvailableModels` fallback: group by Gemini vs Claude/GPT and by
    /// reset horizon (≤12 h → 5h, else 7d). Worst remainingFraction in the
    /// group is the pool. Internal / unnamed models are skipped.
    public static func metersFromModels(from data: Data, now: Double = Date().timeIntervalSince1970) throws -> [Meter] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = o["models"] as? [String: Any] else { throw OAuthError.badResponse }
        var best: [String: (frac: Double, reset: Double?)] = [:]
        for (_, raw) in models {
            guard let m = raw as? [String: Any], m["isInternal"] as? Bool != true,
                  let name = m["displayName"] as? String, !name.isEmpty,
                  let q = m["quotaInfo"] as? [String: Any],
                  let frac = num(q["remainingFraction"]) else { continue }
            let prefix = groupPrefix(name)
            let reset = (q["resetTime"] as? String).flatMap(UsageMapper.parseISO)?.timeIntervalSince1970
            let window: String
            if let reset {
                window = (reset - now) <= 12 * 3600 ? "5h" : "7d"
            } else {
                window = "7d"
            }
            let id = "\(prefix) \(window)"
            if let cur = best[id], cur.frac <= frac { continue }
            best[id] = (frac, reset)
        }
        let multi = Set(best.keys.map { $0.split(separator: " ").first.map(String.init) ?? "" }).count > 1
        return best.keys.sorted { meterOrder($0) < meterOrder($1) }.map { id in
            let v = best[id]!
            let label = multi ? id : (id.split(separator: " ").last.map(String.init) ?? id)
            return Meter(id: label, pct: clamp((1 - v.frac) * 100),
                         countdown: CodexProvider.countdown(v.reset, now: now))
        }
    }

    public static func soonestResetFromModels(_ data: Data) -> Double? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = o["models"] as? [String: Any] else { return nil }
        var soonest: Double?
        for (_, raw) in models {
            guard let m = raw as? [String: Any], m["isInternal"] as? Bool != true,
                  let q = m["quotaInfo"] as? [String: Any],
                  let e = (q["resetTime"] as? String).flatMap(UsageMapper.parseISO)?.timeIntervalSince1970
            else { continue }
            soonest = soonest.map { min($0, e) } ?? e
        }
        return soonest
    }

    public static func soonestReset(from data: Data) -> Double? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = o["groups"] as? [[String: Any]] else { return nil }
        var soonest: Double?
        for g in groups {
            for b in (g["buckets"] as? [[String: Any]]) ?? [] {
                let iso = (b["resetTime"] as? String) ?? (b["reset_time"] as? String)
                guard let e = iso.flatMap(UsageMapper.parseISO)?.timeIntervalSince1970 else { continue }
                soonest = soonest.map { min($0, e) } ?? e
            }
        }
        return soonest
    }

    public static func project(from load: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: load) as? [String: Any] else { return nil }
        if let s = o["cloudaicompanionProject"] as? String, !s.isEmpty { return s }
        if let p = o["cloudaicompanionProject"] as? [String: Any] {
            return (p["id"] as? String) ?? (p["name"] as? String)
        }
        return nil
    }

    public static func plan(from load: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: load) as? [String: Any] else { return nil }
        if let name = tierName(o["paidTier"]) { return name }
        return tierName(o["currentTier"])
    }

    public static func groupPrefix(_ name: String?) -> String {
        let n = (name ?? "").lowercased()
        if n.contains("gemini") { return "Gem" }
        if n.contains("claude") || n.contains("gpt") { return "Cl" }
        if let first = name?.split(separator: " ").first, !first.isEmpty {
            return String(first.prefix(3))
        }
        return "M"
    }

    static func windowID(_ display: String?, _ window: String?) -> String {
        let s = ((display ?? "") + " " + (window ?? "")).lowercased()
        if s.contains("five") || s.contains("5h") || s.contains("5 hour") || s.contains("hour") { return "5h" }
        if s.contains("week") || s.contains("7d") { return "7d" }
        return display.map { String($0.prefix(6)) } ?? "lim"
    }

    private static func meterOrder(_ id: String) -> (Int, Int) {
        let gem = id.hasPrefix("Cl") ? 1 : 0
        let week = id.contains("7d") ? 1 : 0
        return (gem, week)
    }
    private static func tierName(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        if let o = v as? [String: Any] {
            if let n = o["name"] as? String, !n.isEmpty { return n }
            if let i = o["id"] as? String, !i.isEmpty { return i }
        }
        return nil
    }
    private static func num(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) }
    private static func clamp(_ p: Double) -> Double { min(100, max(0, p)) }
}

/// Read-only Antigravity usage for the live Keychain login. Google refresh
/// tokens do not rotate on this client, so a refresh is safe even while `agy`
/// is running — cbar still never writes the Keychain item.
public final class AntigravityUsageService {
    private let client: AntigravityAPI
    private let creds: () -> AntigravityCreds?
    private let oauthClient: () -> (id: String, secret: String)?
    private let cachePath: String

    public init(client: AntigravityAPI = AntigravityClient(),
                creds: @escaping () -> AntigravityCreds? = { AntigravityAuth.read() },
                oauthClient: @escaping () -> (id: String, secret: String)? = { AntigravityOAuth.client() },
                cachePath: String = "\(NSHomeDirectory())/.cbar/antigravity-usage-cache.json") {
        self.client = client; self.creds = creds
        self.oauthClient = oauthClient; self.cachePath = cachePath
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
        var email: String? = nil
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

    public func accounts(now: Double = Date().timeIntervalSince1970) -> [Account] {
        guard let live = creds() else { return [] }
        var row = loadCache() ?? Row()
        row.email = live.email
        if let b = row.backoffUntil, now < b {
            return [account(live, row, now: now)]
        }
        row.lastAttemptAt = now

        var token = live.accessToken
        if live.isExpired(now: Date(timeIntervalSince1970: now)) {
            if let next = tryRefresh(live) {
                token = next
            } else if row.lastError == "needs re-login" || row.needsReauth {
                saveCache(row)
                return [account(live, row, now: now)]
            }
            // Stale access token may still work; try the fetch either way.
        }

        do {
            try fetch(token: token, live: live, row: &row, now: now)
        } catch OAuthError.http(401, retryAfter: _) {
            if let next = tryRefresh(live), next != token {
                do {
                    try fetch(token: next, live: live, row: &row, now: now)
                } catch {
                    applyFetchError(error, to: &row, now: now)
                }
            } else {
                row.needsReauth = true; row.meters = []
                row.failures += 1
                row.backoffUntil = now + backoff(failures: row.failures, retryAfter: nil)
                row.lastError = "unauthorized"
            }
        } catch {
            applyFetchError(error, to: &row, now: now)
        }
        saveCache(row)
        return [account(live, row, now: now)]
    }

    private func fetch(token: String, live: AntigravityCreds, row: inout Row, now: Double) throws {
        let load = try? client.loadCodeAssist(accessToken: token)
        row.plan = load.flatMap { AntigravityUsageMapper.plan(from: $0) }
        do {
            let quota = try client.quotaSummary(accessToken: token,
                                                project: load.flatMap { AntigravityUsageMapper.project(from: $0) })
            let meters = try AntigravityUsageMapper.meters(from: quota, now: now)
            if !meters.isEmpty {
                row.meters = meters
                row.resetsAt = AntigravityUsageMapper.soonestReset(from: quota)
                row.fetchedAt = now; row.failures = 0; row.backoffUntil = nil
                row.needsReauth = false; row.lastError = nil; row.email = live.email
                return
            }
        } catch OAuthError.http(403, retryAfter: _), OAuthError.http(400, retryAfter: _) {
            // Consumer accounts 403 the grouped summary ("no valid license").
            // fetchAvailableModels is what agy itself uses.
        }
        let models = try client.fetchAvailableModels(accessToken: token)
        row.meters = try AntigravityUsageMapper.metersFromModels(from: models, now: now)
        row.resetsAt = AntigravityUsageMapper.soonestResetFromModels(models)
        row.fetchedAt = now; row.failures = 0; row.backoffUntil = nil
        row.needsReauth = false; row.lastError = nil; row.email = live.email
    }

    private func tryRefresh(_ live: AntigravityCreds) -> String? {
        guard let pair = oauthClient() else { return nil }
        do {
            let r = try client.refresh(refreshToken: live.refreshToken,
                                       clientID: pair.id, clientSecret: pair.secret)
            return r.access
        } catch OAuthError.needsReauth {
            return nil
        } catch {
            return nil
        }
    }

    private func applyFetchError(_ error: Error, to row: inout Row, now: Double) {
        if case OAuthError.http(429, let ra) = error {
            row.failures += 1
            let wait = backoff(failures: row.failures, retryAfter: ra)
            row.backoffUntil = now + wait
            row.lastError = "rate limited"
            CbarLog.write("antigravity fetch 429 — retry-after=\(ra.map { String(Int($0)) } ?? "-") failures=\(row.failures) backoff=\(Int(wait))s")
            return
        }
        if case OAuthError.needsReauth = error {
            row.needsReauth = true; row.meters = []
            row.failures += 1
            row.backoffUntil = now + backoff(failures: row.failures, retryAfter: nil)
            row.lastError = "needs re-login"
            return
        }
        row.failures += 1
        row.backoffUntil = now + backoff(failures: row.failures, retryAfter: nil)
        row.lastError = "\(error)"
    }

    private func account(_ live: AntigravityCreds, _ row: Row, now: Double) -> Account {
        Account(id: "antigravity", number: 0, email: live.email,
                org: row.plan.map { "Google · \($0)" } ?? "Google",
                isActive: false,
                status: UsageService.status(needsReauth: row.needsReauth,
                                            meters: row.meters, fetchedAt: row.fetchedAt,
                                            lastError: row.lastError, now: now),
                meters: row.meters,
                ageSeconds: row.fetchedAt.map { now - $0 },
                provider: "antigravity")
    }
}
