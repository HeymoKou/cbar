import Foundation

/// The `claudeAiOauth` object inside Claude Code's credential blob.
public struct ClaudeAiOauth: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Double          // epoch milliseconds
    public var scopes: [String]?
    public init(accessToken: String, refreshToken: String, expiresAt: Double, scopes: [String]?) {
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.scopes = scopes
    }
}

/// Reads/writes the ACTIVE account's OAuth credentials. Keychain wins over the
/// plaintext file; writes go to the keychain and only rewrite the file if it
/// already exists (never creates it).
public enum Credentials {
    static var user: String { ProcessInfo.processInfo.environment["USER"] ?? "claude-code-user" }
    static let service = "Claude Code-credentials"
    static var filePath: String { "\(NSHomeDirectory())/.claude/.credentials.json" }

    struct Wrapper: Codable { var claudeAiOauth: ClaudeAiOauth }

    public static func parse(_ json: String) -> ClaudeAiOauth? {
        guard let d = json.data(using: .utf8),
              let w = try? JSONDecoder().decode(Wrapper.self, from: d) else { return nil }
        return w.claudeAiOauth
    }

    public static func serialize(_ o: ClaudeAiOauth) -> String {
        // Single-line (compact) on purpose: the value passes through
        // `security -i`, a line-based parser — a newline splits the write into
        // garbage commands and destroys the item. CC's own format is compact too.
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(Wrapper(claudeAiOauth: o))) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func readActive() throws -> ClaudeAiOauth? {
        if let s = try Keychain.get(service: service, account: user), let o = parse(s) { return o }
        if let s = try? String(contentsOfFile: filePath, encoding: .utf8), let o = parse(s) { return o }
        return nil
    }

    public static func writeActive(_ o: ClaudeAiOauth) throws {
        let s = serialize(o)
        // Plain JSON, matching Claude Code's own format — CC reads this item
        // back on startup and cannot parse a base64-encoded one.
        try Keychain.setRaw(service: service, account: user, value: s)
        if FileManager.default.fileExists(atPath: filePath) {
            try? s.write(toFile: filePath, atomically: true, encoding: .utf8)
        }
    }
}
