import Foundation

/// Reads/writes `~/.claude.json`'s `oauthAccount`. On switch, ONLY the
/// `oauthAccount` object is replaced; every other key is preserved.
public enum ClaudeConfig {
    public struct OAuthAccount: Codable, Sendable {
        public var emailAddress: String?
        public var accountUuid: String?
        public var organizationUuid: String?
        public var organizationName: String?
        public init(emailAddress: String?, accountUuid: String?, organizationUuid: String?, organizationName: String?) {
            self.emailAddress = emailAddress; self.accountUuid = accountUuid
            self.organizationUuid = organizationUuid; self.organizationName = organizationName
        }
    }

    /// `.claude.json` sits at $HOME by default (NOT inside ~/.claude/); legacy
    /// `~/.claude/.config.json` wins if present.
    public static var path: String {
        let legacy = "\(NSHomeDirectory())/.claude/.config.json"
        return FileManager.default.fileExists(atPath: legacy) ? legacy : "\(NSHomeDirectory())/.claude.json"
    }

    public static func rawConfig(at file: String? = nil) throws -> String {
        try String(contentsOfFile: file ?? path, encoding: .utf8)
    }
    public static func writeRaw(_ s: String, at file: String? = nil) throws {
        try s.write(toFile: file ?? path, atomically: true, encoding: .utf8)
    }

    /// Last `readAccount` result, keyed on the file identity it was parsed from.
    /// Reached only from cbar's serial mutation queue, so no lock.
    private static var accountCache: (path: String, mtime: Date, size: Int, account: OAuthAccount?)?

    /// `.claude.json` is Claude Code's own state file — 320 KB on the machine
    /// this was measured on, and it grows with project history — but it only
    /// changes on `/login` or a switch. Parsing all of it once a minute to read
    /// four identity fields was pure waste, so the result is cached on
    /// (mtime, size): any writer's change invalidates it, cbar's own splice
    /// included. A miss re-parses, so a stale cache is not representable.
    public static func readAccount(at file: String? = nil) throws -> OAuthAccount? {
        let f = file ?? path
        let attrs = try? FileManager.default.attributesOfItem(atPath: f)
        let stamp = (attrs?[.modificationDate] as? Date).flatMap { m in
            (attrs?[.size] as? NSNumber).map { (mtime: m, size: $0.intValue) }
        }
        if let c = accountCache, let s = stamp, c.path == f, c.mtime == s.mtime, c.size == s.size {
            return c.account
        }
        let parsed: OAuthAccount? = {
            guard let d = try? Data(contentsOf: URL(fileURLWithPath: f)),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let oa = obj["oauthAccount"] as? [String: Any] else { return nil }
            return OAuthAccount(
                emailAddress: oa["emailAddress"] as? String,
                accountUuid: oa["accountUuid"] as? String,
                organizationUuid: oa["organizationUuid"] as? String,
                organizationName: oa["organizationName"] as? String)
        }()
        // Cache the miss too: a config with no `oauthAccount` is a real state
        // (logged out), and re-parsing 320 KB to rediscover it every pass is the
        // same waste as re-parsing a hit.
        if let s = stamp { accountCache = (f, s.mtime, s.size, parsed) }
        return parsed
    }

    /// The FULL `oauthAccount` object (all ~20 fields), for verbatim capture/splice.
    public static func readRawAccount(at file: String? = nil) throws -> [String: Any]? {
        let f = file ?? path
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: f)),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return obj["oauthAccount"] as? [String: Any]
    }

    /// Splice the full `oauthAccount` object verbatim, preserving every other
    /// top-level key. Used on switch so no oauthAccount field is dropped.
    public static func spliceRawAccount(_ oauth: [String: Any], at file: String? = nil) throws {
        let f = file ?? path
        let d = try Data(contentsOf: URL(fileURLWithPath: f))
        guard var obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw NSError(domain: "cbar", code: 1, userInfo: [NSLocalizedDescriptionKey: "config not an object"])
        }
        obj["oauthAccount"] = oauth
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: URL(fileURLWithPath: f), options: .atomic)   // a kill mid-write must not corrupt the login
    }

    /// Replace only `oauthAccount` (4 identity fields), preserving all other keys. Nil fields are
    /// written as JSON null (matching Claude Code's synthesized shape).
    public static func spliceAccount(_ acc: OAuthAccount, at file: String? = nil) throws {
        let f = file ?? path
        let d = try Data(contentsOf: URL(fileURLWithPath: f))
        guard var obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw NSError(domain: "cbar", code: 1, userInfo: [NSLocalizedDescriptionKey: "config not an object"])
        }
        obj["oauthAccount"] = [
            "emailAddress": acc.emailAddress.map { $0 as Any } ?? NSNull(),
            "accountUuid": acc.accountUuid.map { $0 as Any } ?? NSNull(),
            "organizationUuid": acc.organizationUuid.map { $0 as Any } ?? NSNull(),
            "organizationName": acc.organizationName.map { $0 as Any } ?? NSNull(),
        ]
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: URL(fileURLWithPath: f))
    }
}
