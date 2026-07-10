import Foundation

public struct StoredAccount: Sendable {
    public let number: Int
    public let email: String
    public let uuid: String?
    public let organizationUuid: String?
    public let organizationName: String?
}

/// cbar's own managed-account store: metadata JSON in `~/.cbar/accounts.json`,
/// per-account OAuth credentials in the Keychain (service `cbar`, account
/// `account-{n}`). No cswap.
public final class AccountStore {
    private let dir: String
    private let kcService: String

    public init(dir: String = "\(NSHomeDirectory())/.cbar", keychainService: String = "cbar") {
        self.dir = dir
        self.kcService = keychainService
    }

    private var metaPath: String { "\(dir)/accounts.json" }
    private func kcAccount(_ n: Int) -> String { "account-\(n)" }

    // MARK: metadata model
    struct Row: Codable {
        var email: String; var uuid: String?; var organizationUuid: String?
        var organizationName: String?; var added: String
        var oauthJSON: String?   // full oauthAccount object, for verbatim splice on switch
    }
    struct Meta: Codable { var activeAccountNumber: Int?; var accounts: [String: Row] }

    private func loadMeta() -> Meta {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: metaPath)),
              let m = try? JSONDecoder().decode(Meta.self, from: d) else {
            return Meta(activeAccountNumber: nil, accounts: [:])
        }
        return m
    }
    private func saveMeta(_ m: Meta) throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(m).write(to: URL(fileURLWithPath: metaPath))
    }

    // MARK: reads
    public func list() -> [StoredAccount] {
        loadMeta().accounts.compactMap { key, r in
            Int(key).map { StoredAccount(number: $0, email: r.email, uuid: r.uuid,
                                         organizationUuid: r.organizationUuid, organizationName: r.organizationName) }
        }.sorted { $0.number < $1.number }
    }
    public func activeNumber() -> Int? { loadMeta().activeAccountNumber }

    public func creds(_ n: Int) throws -> ClaudeAiOauth? {
        guard let s = try Keychain.get(service: kcService, account: kcAccount(n)) else { return nil }
        return Credentials.parse(s)
    }
    /// The stored full oauthAccount object for slot `n`.
    public func oauthAccount(_ n: Int) -> [String: Any]? {
        guard let s = loadMeta().accounts[String(n)]?.oauthJSON,
              let d = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return obj
    }
    static func jsonString(_ obj: [String: Any]) -> String? {
        (try? JSONSerialization.data(withJSONObject: obj)).flatMap { String(data: $0, encoding: .utf8) }
    }
    public func setCreds(_ n: Int, _ o: ClaudeAiOauth) throws {
        try Keychain.set(service: kcService, account: kcAccount(n), value: Credentials.serialize(o))
    }

    // MARK: writes
    /// Add (or re-capture) an account by identity (email, organizationUuid).
    /// Returns its slot number.
    @discardableResult
    public func add(email: String, uuid: String?, orgUuid: String?, orgName: String?, oauthJSON: String? = nil, creds: ClaudeAiOauth) throws -> Int {
        var m = loadMeta()
        let existing = m.accounts.first { $0.value.email == email && ($0.value.organizationUuid ?? "") == (orgUuid ?? "") }
        let num = existing.flatMap { Int($0.key) } ?? ((m.accounts.keys.compactMap(Int.init).max() ?? 0) + 1)
        m.accounts[String(num)] = Row(email: email, uuid: uuid, organizationUuid: orgUuid,
                                      organizationName: orgName, added: timestamp(), oauthJSON: oauthJSON)
        if m.activeAccountNumber == nil { m.activeAccountNumber = num }
        try saveMeta(m)
        try setCreds(num, creds)
        return num
    }

    /// Insert/replace an account at an EXPLICIT slot number (used by import to
    /// preserve cswap's numbering so the active pointer stays correct).
    public func upsert(number: Int, email: String, uuid: String?, orgUuid: String?, orgName: String?, oauthJSON: String? = nil, creds: ClaudeAiOauth) throws {
        var m = loadMeta()
        m.accounts[String(number)] = Row(email: email, uuid: uuid, organizationUuid: orgUuid,
                                        organizationName: orgName, added: timestamp(), oauthJSON: oauthJSON)
        if m.activeAccountNumber == nil { m.activeAccountNumber = number }
        try saveMeta(m)
        try setCreds(number, creds)
    }

    /// Capture the CURRENT live Claude login as a managed account (full oauthAccount).
    @discardableResult
    public func addCurrent() throws -> Int {
        guard let creds = try Credentials.readActive() else {
            throw NSError(domain: "cbar", code: 2, userInfo: [NSLocalizedDescriptionKey: "no active Claude login found"])
        }
        let acc = try ClaudeConfig.readAccount()
        let oauthJSON = (try? ClaudeConfig.readRawAccount()).flatMap { $0 }.flatMap { Self.jsonString($0) }
        return try add(email: acc?.emailAddress ?? "(unknown)", uuid: acc?.accountUuid,
                       orgUuid: acc?.organizationUuid, orgName: acc?.organizationName,
                       oauthJSON: oauthJSON, creds: creds)
    }

    public func setActive(_ n: Int) throws {
        var m = loadMeta(); m.activeAccountNumber = n; try saveMeta(m)
    }

    public func remove(_ n: Int) throws {
        var m = loadMeta(); m.accounts.removeValue(forKey: String(n))
        if m.activeAccountNumber == n { m.activeAccountNumber = m.accounts.keys.compactMap(Int.init).min() }
        try saveMeta(m)
        try Keychain.delete(service: kcService, account: kcAccount(n))
    }

    private func timestamp() -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }
}
