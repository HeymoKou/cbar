import Foundation

/// The `claudeAiOauth` object inside Claude Code's credential blob.
///
/// Only the token fields are modelled; `original` is the blob as read, and
/// `Credentials.serialize` writes it back with just those fields replaced. It
/// used to be decoded into these four and re-encoded, which dropped
/// `subscriptionType`, `rateLimitTier`, `refreshTokenExpiresAt` and every
/// other key on each refresh and switch. Nil for creds built in code, which
/// serialize as the four fields — as do slot copies written before this.
public struct ClaudeAiOauth: Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Double          // epoch milliseconds
    public var scopes: [String]?
    let original: Data?
    public init(accessToken: String, refreshToken: String, expiresAt: Double, scopes: [String]?) {
        self.init(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt,
                  scopes: scopes, original: nil)
    }
    init(accessToken: String, refreshToken: String, expiresAt: Double, scopes: [String]?, original: Data?) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.scopes = scopes; self.original = original
    }
}

/// Reads/writes the ACTIVE account's OAuth credentials. Keychain wins over the
/// plaintext file; writes go to the keychain and only rewrite the file if it
/// already exists (never creates it).
public enum Credentials {
    // Public so a caller (Switcher) can default to them and a test can point
    // elsewhere — never at the real login.
    public static var user: String { ProcessInfo.processInfo.environment["USER"] ?? "claude-code-user" }
    public static let service = "Claude Code-credentials"
    public static var filePath: String { "\(NSHomeDirectory())/.claude/.credentials.json" }

    public static func parse(_ json: String) -> ClaudeAiOauth? {
        guard let d = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let o = root["claudeAiOauth"] as? [String: Any],
              let access = o["accessToken"] as? String,
              let refresh = o["refreshToken"] as? String,
              let exp = (o["expiresAt"] as? NSNumber)?.doubleValue else { return nil }
        return ClaudeAiOauth(accessToken: access, refreshToken: refresh, expiresAt: exp,
                             scopes: o["scopes"] as? [String], original: d)
    }

    /// The blob as read, token fields replaced. `full: false` keeps only
    /// `claudeAiOauth` — see `writeFitting`.
    public static func serialize(_ o: ClaudeAiOauth, full: Bool = true) -> String {
        var root = o.original.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var inner = root["claudeAiOauth"] as? [String: Any] ?? [:]
        if !full { root = [:] }
        inner["accessToken"] = o.accessToken
        inner["refreshToken"] = o.refreshToken
        // Integral, as Claude Code writes it — not 1.78e12.
        let e = o.expiresAt
        inner["expiresAt"] = e.rounded() == e && abs(e) < 1e18 ? Int64(e) as Any : e as Any
        inner["scopes"] = o.scopes
        root["claudeAiOauth"] = inner
        // Single-line (compact) on purpose: the value passes through
        // `security -i`, a line-based parser — a newline splits the write into
        // garbage commands and destroys the item. CC's own format is compact too.
        let data = (try? JSONSerialization.data(withJSONObject: root,
                                                options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Write the full blob, or — when it is past `security -i`'s line limit —
    /// the login alone. Claude Code keeps other tokens (MCP servers) in the same
    /// item, and they can be large; refusing the write would lose a rotated
    /// token, which is worse than dropping keys every write dropped before.
    static func writeFitting(_ o: ClaudeAiOauth, _ put: (String) throws -> Void) throws -> String {
        let s = serialize(o)
        do { try put(s); return s } catch Keychain.KErr.failed(let rc, _) where rc == Keychain.tooLarge {
            CbarLog.write("credential blob too large for the keychain write — kept only claudeAiOauth")
            let small = serialize(o, full: false)
            try put(small)
            return small
        }
    }

    public static func readActive(service: String = service, account: String = user,
                                  file: String = filePath) throws -> ClaudeAiOauth? {
        if let s = try Keychain.get(service: service, account: account), let o = parse(s) { return o }
        if let s = try? String(contentsOfFile: file, encoding: .utf8), let o = parse(s) { return o }
        return nil
    }

    public static func writeActive(_ o: ClaudeAiOauth, service: String = service, account: String = user,
                                   file: String = filePath) throws {
        // Plain JSON, matching Claude Code's own format — CC reads this item
        // back on startup and cannot parse a base64-encoded one.
        let s = try writeFitting(o) { try Keychain.setRaw(service: service, account: account, value: $0) }
        if FileManager.default.fileExists(atPath: file) {
            try? s.write(toFile: file, atomically: true, encoding: .utf8)
        }
    }
}
