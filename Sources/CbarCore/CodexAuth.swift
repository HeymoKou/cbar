import Foundation

/// One Codex CLI ChatGPT login: the contents of an `auth.json`.
///
/// `raw` is the file verbatim, and it is what gets written back on a switch —
/// Codex keeps more in that file than cbar reads (`auth_mode`, agent identity,
/// fields added since), and re-serializing a partial model would drop them.
/// Everything else is parsed out of the tokens, which are JWTs: identity comes
/// from the claims themselves, so unlike Claude there is no profile API to ask
/// and no second file that can disagree with the token.
public struct CodexLogin: Sendable {
    public let raw: Data
    public let accountId: String
    /// `chatgpt_user_id` (or the JWT `sub`). A Team workspace shares one
    /// `account_id` across all its members, so the account id alone is not a
    /// person — Codex itself compares both before trusting a login is the one it
    /// started with.
    public let userId: String
    public let accessToken: String
    public let refreshToken: String
    public let email: String?
    public let plan: String?
    /// The access token's `exp`, epoch seconds. About ten days after issue.
    public let expiresAt: Double?
    /// The access token's `iat`. Orders two copies of one login: the newer one
    /// is the one whose refresh token still works.
    public let issuedAt: Double?

    /// (user, account) — what makes two logins the same login.
    public var identity: String { "\(userId)|\(accountId)" }

    /// Nil for anything that is not a usable ChatGPT token login: an API-key
    /// `auth.json` (`tokens: null`), a half-written file, or a MIXED one.
    ///
    /// Mixed: Codex's `persist_tokens` re-reads the file after a refresh
    /// round-trip and overwrites the three tokens without checking whose file it
    /// now is. A switch landing inside that round-trip leaves account B's
    /// `account_id` wrapped around account A's tokens. Trusting either half
    /// would attribute one account's tokens to the other's slot, so identity
    /// comes from the access token and a disagreeing `account_id` rejects the
    /// whole file.
    public init?(raw: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let t = o["tokens"] as? [String: Any],
              let access = t["access_token"] as? String, !access.isEmpty,
              let refresh = t["refresh_token"] as? String, !refresh.isEmpty else { return nil }
        let ac = Self.claims(access)
        let acAuth = ac?["https://api.openai.com/auth"] as? [String: Any]
        let id = (t["id_token"] as? String).flatMap(Self.claims)
        let idAuth = id?["https://api.openai.com/auth"] as? [String: Any]
        guard let account = (acAuth?["chatgpt_account_id"] as? String) ?? (t["account_id"] as? String),
              (t["account_id"] as? String).map({ $0 == account }) ?? true,
              let user = (acAuth?["chatgpt_user_id"] as? String) ?? (ac?["sub"] as? String)
        else { return nil }
        self.raw = raw
        accountId = account
        userId = user
        accessToken = access
        refreshToken = refresh
        email = (id?["email"] as? String)
            ?? ((ac?["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String)
        plan = (acAuth?["chatgpt_plan_type"] as? String) ?? (idAuth?["chatgpt_plan_type"] as? String)
        expiresAt = (ac?["exp"] as? Double) ?? (ac?["exp"] as? Int).map(Double.init)
        issuedAt = (ac?["iat"] as? Double) ?? (ac?["iat"] as? Int).map(Double.init)
    }

    /// Expired, or inside the five minutes before it — the same window Codex
    /// refreshes in, so cbar never sends a token Codex already considers spent.
    public func isExpired(now: Double = Date().timeIntervalSince1970) -> Bool {
        guard let e = expiresAt else { return false }   // unknown → let the fetch's 401 decide
        return now + 300 >= e
    }

    /// This login with a refresh response folded in, the way Codex's own
    /// `persist_tokens` does it: replace only the tokens that came back, stamp
    /// `last_refresh`, keep every other key.
    public func refreshed(idToken: String?, accessToken: String?, refreshToken: String?,
                          now: Date = Date()) -> CodexLogin? {
        guard var o = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              var t = o["tokens"] as? [String: Any] else { return nil }
        if let v = idToken { t["id_token"] = v }
        if let v = accessToken { t["access_token"] = v }
        if let v = refreshToken { t["refresh_token"] = v }
        o["tokens"] = t
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        o["last_refresh"] = f.string(from: now)
        guard let d = try? JSONSerialization.data(withJSONObject: o,
                                                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return CodexLogin(raw: d)
    }

    /// A JWT's payload. No signature check: these tokens come from files the user
    /// owns, and they are only read for what they say about themselves.
    static func claims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let d = Data(base64Encoded: b64) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
}

/// The LIVE Codex login: `~/.codex/auth.json`, which every newly started Codex
/// process reads. A running process does NOT follow a change to it — Codex
/// holds its login in memory and refuses a token for a different account — so a
/// switch lands on the next `codex` launched, not the one already open.
public enum CodexLive {
    public enum State {
        /// No `auth.json` at all: logged out.
        case missing
        case login(CodexLogin)
        /// A well-formed file with no ChatGPT tokens in it — an API-key login.
        /// Holds no token of cbar's, so it blocks switching (it can't be put
        /// back) but not refreshing idle slots.
        case notTokenLogin
        /// Tokens cbar can't trust: Codex halfway through rewriting the file (its
        /// save truncates, then writes), or a mixed file (see `CodexLogin.init`).
        /// Whose tokens are live is unknowable, so nothing may touch any.
        case unusable
    }

    public static let defaultHome = "\(NSHomeDirectory())/.codex"

    public static func read(home: String = defaultHome) -> State {
        let path = "\(home)/auth.json"
        guard FileManager.default.fileExists(atPath: path) else { return .missing }
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return .unusable }
        if o["tokens"] == nil || o["tokens"] is NSNull { return .notTokenLogin }
        return CodexLogin(raw: d).map(State.login) ?? .unusable
    }

    /// Owner-only from the first byte, then renamed over the old file. Not
    /// `Data.write(.atomic)` + chmod: the temp file it creates takes the umask's
    /// mode, and `~/.codex` is usually world-readable, so the tokens would sit
    /// readable to other users until the chmod landed. Not `SecureFile.write`
    /// either: that tightens `~/.codex` itself, which is Codex's directory.
    /// A symlinked `auth.json` is written through, not replaced.
    public static func write(_ login: CodexLogin, home: String = defaultHome) throws {
        let path = URL(fileURLWithPath: "\(home)/auth.json").resolvingSymlinksInPath().path
        let tmp = "\(path).cbar-\(getpid())"
        unlink(tmp)   // a leftover from a crash would fail O_EXCL
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "could not create \(tmp)"])
        }
        let written = login.raw.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n <= 0 { return false }
                off += n
            }
            return fsync(fd) == 0
        }
        close(fd)
        guard written else {
            unlink(tmp)
            throw NSError(domain: "cbar", code: 5, userInfo: [NSLocalizedDescriptionKey: "could not write \(tmp)"])
        }
        guard rename(tmp, path) == 0 else {
            let e = errno
            try? FileManager.default.removeItem(atPath: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e),
                          userInfo: [NSLocalizedDescriptionKey: "rename into \(path) failed"])
        }
    }

    /// Whether a Codex process is running — the CLI, `codex app-server`, or an
    /// app bundling the same binary; all run as `codex`. Asked only before a
    /// switch, where a false negative costs the rare race `CodexSwitcher`
    /// guards and a false positive costs a retry after the cooldown.
    public static func codexRunning() -> Bool {
        UsageService.pgrepMatches(["-ix", "codex"])
    }

    /// `cli_auth_credentials_store` from `config.toml`, or nil when unset (the
    /// default, `file`). Anything but `file` means Codex may read its login from
    /// the Keychain instead — `auto` tries the Keychain FIRST — so rewriting
    /// `auth.json` would silently switch nothing. cbar refuses to manage those.
    public static func credentialsStore(home: String = defaultHome) -> String? {
        guard let toml = try? String(contentsOfFile: "\(home)/config.toml", encoding: .utf8) else { return nil }
        let header = try! NSRegularExpression(pattern: #"^\[\[?[^\[\]"]*("[^"]*"[^\[\]"]*)*\]\]?$"#)
        for line in toml.components(separatedBy: .newlines) {
            let s = line.trimmingCharacters(in: .whitespaces)
            // Top-level keys only: a table header ends the section they live in.
            // A header, not any line starting with "[" — a multi-line array's
            // rows can too.
            if header.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { break }
            let kv = s.split(separator: "=", maxSplits: 1)
            guard kv.count == 2,
                  kv[0].trimmingCharacters(in: .whitespaces) == "cli_auth_credentials_store" else { continue }
            return kv[1].split(separator: "#").first?
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        }
        return nil
    }
}

/// Where a second Codex account gets logged into.
///
/// `codex login` begins by REVOKING whatever login its `CODEX_HOME` already
/// holds (`clear_existing_auth_before_login` → `logout_with_revoke`). Logging
/// into another account in `~/.codex`, Claude-style, would therefore kill the
/// login cbar just captured. Pointed at this empty directory instead there is
/// nothing to revoke; cbar picks the file up on its next poll and empties the
/// directory again.
public struct CodexLoginInbox {
    public let dir: String
    let home: String
    public init(dir: String = "\(NSHomeDirectory())/.cbar/codex-login", home: String = CodexLive.defaultHome) {
        self.dir = dir; self.home = home
    }

    /// The command to run. The directory must exist: Codex treats a
    /// `CODEX_HOME` that points nowhere as fatal.
    public var command: String { "CODEX_HOME=\"\(dir)\" codex login" }

    /// Make the inbox empty and ready. A login still sitting in it is imported
    /// first — clearing it unimported would strand a live token nobody holds.
    @discardableResult
    public func prepare(importingInto store: CodexAccountStore) throws -> Int? {
        try SecureFile.ensureDir(dir)   // first, so a mode problem can't make the import skip a login
        let imported = try importIfPresent(into: store)
        try clear()
        return imported
    }

    /// Import a finished login, then empty the inbox. Nil when there is nothing
    /// complete to import yet (no file, or Codex still writing it).
    ///
    /// A login for the account that is LIVE also replaces `~/.codex/auth.json`.
    /// That is the re-login case — the live token was revoked — and importing
    /// only into the slot lost it straight away: the same poll's heal saw the
    /// slot differ from the dead live file and copied the dead one back. A
    /// Codex process already running on that account is unharmed: before it
    /// refreshes, it reloads the file for the same account and takes the newer
    /// tokens.
    @discardableResult
    public func importIfPresent(into store: CodexAccountStore) throws -> Int? {
        let path = "\(dir)/auth.json"
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)), let login = CodexLogin(raw: d)
        else { return nil }
        let n = try store.add(login)
        if case .login(let live) = CodexLive.read(home: home), live.identity == login.identity,
           (CodexLive.credentialsStore(home: home) ?? "file") == "file" {
            try CodexLive.write(login, home: home)
        }
        try clear()
        return n
    }

    /// Everything Codex left behind goes, the directory stays: the copied
    /// command still has to find it.
    func clear() throws {
        try SecureFile.ensureDir(dir)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            try FileManager.default.removeItem(atPath: "\(dir)/\(name)")
        }
    }
}
