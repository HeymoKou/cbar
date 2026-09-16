import CryptoKit
import Foundation

public struct CodexSlot: Sendable {
    public let number: Int
    public let identity: String
    public let email: String?
    public let plan: String?
}

/// cbar's Codex accounts: metadata in `~/.cbar/codex-accounts.json`, and each
/// login's full `auth.json` sealed with AES-GCM in `~/.cbar/codex/{n}.sealed`
/// under a key that lives in the Keychain (service `cbar-codex`, account
/// `codex-key`).
///
/// Not the Keychain directly, the way Claude credentials are kept: a Codex
/// login is ~4 KB — three JWTs — and cbar writes Keychain items through
/// `security -i`, which cannot take a line that long (see `Keychain.checkLine`).
/// The 44-byte key fits; the sealed file is useless without it. Anyone who can
/// read the key can read the logins, which is the same exposure the
/// `security`-created items already have (SECURITY.md).
///
/// There is no stored "active" pointer, unlike the Claude store. The live
/// `auth.json` names its own identity in its tokens, so the active slot is
/// simply whichever slot matches it — nothing to resync, nothing to drift.
public final class CodexAccountStore {
    private let dir: String
    private let kcService: String

    public init(dir: String = "\(NSHomeDirectory())/.cbar", keychainService: String = "cbar-codex") {
        self.dir = dir
        self.kcService = keychainService
    }

    private var metaPath: String { "\(dir)/codex-accounts.json" }
    private func sealedPath(_ n: Int) -> String { "\(dir)/codex/\(n).sealed" }
    public static let keyAccount = "codex-key"
    /// Read once per store; every poll opens at least one sealed login, and each
    /// Keychain read is a `security` process.
    private var cachedKey: SymmetricKey?

    struct Row: Codable { var identity: String; var email: String?; var plan: String?; var added: String }
    /// `lastNumber` so a slot number is never handed out twice. Reusing the
    /// number of a removed slot gave the new account the old one's cached usage
    /// — "ok", with someone else's numbers — until its first fetch.
    struct Meta: Codable { var accounts: [String: Row]; var lastNumber: Int? }

    private func loadMeta() -> Meta {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: metaPath)),
              let m = try? JSONDecoder().decode(Meta.self, from: d) else { return Meta(accounts: [:], lastNumber: nil) }
        return m
    }
    private func saveMeta(_ m: Meta) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SecureFile.write(try enc.encode(m), to: metaPath)
    }

    public func list() -> [CodexSlot] {
        loadMeta().accounts.compactMap { key, r in
            Int(key).map { CodexSlot(number: $0, identity: r.identity, email: r.email, plan: r.plan) }
        }.sorted { $0.number < $1.number }
    }

    public func slot(for login: CodexLogin) -> Int? {
        list().first { $0.identity == login.identity }?.number
    }

    /// The sealing key, created on first use. Created and then READ BACK, so if
    /// two writers ever raced to create it, both end up sealing with whichever
    /// one the Keychain kept.
    private func key(create: Bool) throws -> SymmetricKey? {
        if let k = cachedKey { return k }
        if let s = try Keychain.get(service: kcService, account: Self.keyAccount) {
            // Present but not a key: stop. Replacing it would make every login
            // sealed so far unrecoverable, on the strength of one bad read.
            guard let d = Data(base64Encoded: s), d.count == 32 else {
                throw NSError(domain: "cbar", code: 6, userInfo: [NSLocalizedDescriptionKey: "Codex login key in the Keychain is malformed"])
            }
            cachedKey = SymmetricKey(data: d)
            return cachedKey
        }
        guard create else { return nil }
        let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        try Keychain.set(service: kcService, account: Self.keyAccount, value: fresh.base64EncodedString())
        return try key(create: false)
    }

    /// Nil when the slot has no stored login. Throws when one exists but will not
    /// open — a lost or replaced key — because "no credentials" would hide why.
    public func login(_ n: Int) throws -> CodexLogin? {
        // Only a file that isn't there means "no login". Any other read failure —
        // a permission problem, say — must not pass for an empty slot.
        guard FileManager.default.fileExists(atPath: sealedPath(n)) else { return nil }
        let sealed = try Data(contentsOf: URL(fileURLWithPath: sealedPath(n)))
        guard let k = try key(create: false) else {
            throw NSError(domain: "cbar", code: 4, userInfo: [NSLocalizedDescriptionKey: "Codex login key missing from the Keychain — re-add the account"])
        }
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: k)
        return CodexLogin(raw: raw)
    }

    public func setLogin(_ n: Int, _ login: CodexLogin) throws {
        guard let k = try key(create: true),
              let sealed = try AES.GCM.seal(login.raw, using: k).combined else {
            throw NSError(domain: "cbar", code: 3, userInfo: [NSLocalizedDescriptionKey: "could not seal Codex login"])
        }
        try SecureFile.write(sealed, to: sealedPath(n))
    }

    /// Add a login, or re-capture it into its existing slot by identity. Login
    /// first: a slot whose metadata exists without its token would pose as an
    /// account with nothing behind it.
    @discardableResult
    public func add(_ login: CodexLogin) throws -> Int {
        var m = loadMeta()
        let existing = m.accounts.first { $0.value.identity == login.identity }.flatMap { Int($0.key) }
        let n = existing ?? (max(m.lastNumber ?? 0, m.accounts.keys.compactMap(Int.init).max() ?? 0) + 1)
        try setLogin(n, login)
        m.lastNumber = max(m.lastNumber ?? 0, n)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        m.accounts[String(n)] = Row(identity: login.identity, email: login.email, plan: login.plan,
                                    added: f.string(from: Date()))
        try saveMeta(m)
        return n
    }

    public func remove(_ n: Int) throws {
        var m = loadMeta(); m.accounts.removeValue(forKey: String(n))
        try saveMeta(m)
        try? FileManager.default.removeItem(atPath: sealedPath(n))
    }
}

/// Points the live `auth.json` at another stored Codex login.
///
/// The outgoing login is copied back into ITS slot first. Codex rotates its
/// refresh token roughly every ten days and a used one dies about an hour later,
/// so the copy cbar took at capture time can be a dead token; the file on disk
/// is the only current one. Skip that step and the account you switch back to
/// needs a fresh login.
public struct CodexSwitcher {
    public enum SwitchErr: Error, CustomStringConvertible {
        case noCredentials(Int)
        case unsupportedStore(String)
        case unmanagedLogin
        case notATokenLogin
        case liveChanged
        case liveRefreshing
        public var description: String {
            switch self {
            case .noCredentials(let n): return "Codex slot #\(n) has no stored login"
            case .unsupportedStore(let m): return "Codex keeps its login in \"\(m)\" storage, not auth.json — cbar can't switch it"
            case .unmanagedLogin: return "the current Codex login isn't one cbar has saved — add it first, or it would be lost"
            case .notATokenLogin: return "~/.codex/auth.json isn't a usable ChatGPT login (API key, mid-write, or mixed) — left untouched"
            case .liveChanged: return "Codex rewrote its login during the switch — try again"
            case .liveRefreshing: return "a running Codex is due to refresh its login — switch deferred"
            }
        }
    }

    let store: CodexAccountStore
    let home: String
    let codexRunning: () -> Bool
    public init(store: CodexAccountStore, home: String = CodexLive.defaultHome,
                codexRunning: @escaping () -> Bool = CodexLive.codexRunning) {
        self.store = store; self.home = home; self.codexRunning = codexRunning
    }

    public func switchTo(_ n: Int, now: Double = Date().timeIntervalSince1970) throws {
        if let mode = CodexLive.credentialsStore(home: home), mode != "file" {
            throw SwitchErr.unsupportedStore(mode)
        }
        guard let target = try store.login(n) else { throw SwitchErr.noCredentials(n) }
        switch CodexLive.read(home: home) {
        case .missing:
            break
        case .notTokenLogin, .unusable:
            // An API key the user set up, Codex mid-write, or a mixed file. None is
            // cbar's to overwrite, and none could be restored afterwards.
            throw SwitchErr.notATokenLogin
        case .login(let current):
            guard let owner = store.slot(for: current) else { throw SwitchErr.unmanagedLogin }
            if owner == n { return }
            // A running Codex refreshes a login inside five minutes of expiry, and
            // its `persist_tokens` writes the rotated tokens into whatever file is
            // there when the response lands — the target's, if cbar switched
            // during the round-trip. The re-read below can't see a refresh that
            // hasn't been written yet. So while one could be in flight, wait: the
            // login is due for refresh and something may be holding it.
            if current.isExpired(now: now + 60), codexRunning() { throw SwitchErr.liveRefreshing }
            // Not best-effort, unlike the Claude backup: nothing has been written
            // yet, so failing here costs one retry after the cooldown, while
            // proceeding can cost the outgoing account its only live token.
            try store.setLogin(owner, current)
            // Codex finishing a refresh between that read and the write below would
            // have its rotated token overwritten; checking narrows that to the
            // rename itself.
            guard case .login(let again) = CodexLive.read(home: home), again.raw == current.raw else {
                throw SwitchErr.liveChanged
            }
        }
        try CodexLive.write(target, home: home)
    }
}
