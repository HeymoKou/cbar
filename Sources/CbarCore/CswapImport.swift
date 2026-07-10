import Foundation

/// One-time convenience: import accounts a user already set up in cswap into
/// cbar's own store, by READING cswap's backup files/keychain (cswap itself is
/// not run and is not required afterward).
public enum CswapImport {
    public static var backupRoot: String { "\(NSHomeDirectory())/.claude-swap-backup" }
    public static func available() -> Bool {
        FileManager.default.fileExists(atPath: backupRoot + "/sequence.json")
    }

    /// Returns the number of accounts imported.
    @discardableResult
    public static func importAll(into store: AccountStore) throws -> Int {
        let seqPath = backupRoot + "/sequence.json"
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: seqPath)),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let accts = obj["accounts"] as? [String: Any] else { return 0 }
        var imported = 0
        for (num, meta) in accts {
            guard let m = meta as? [String: Any], let email = m["email"] as? String else { continue }
            // cswap's backup keychain stores the raw creds JSON (service "claude-swap").
            guard let slot = Int(num),
                  let raw = (try? Keychain.getRaw(service: "claude-swap", account: "account-\(num)-\(email)")) ?? nil,
                  let creds = Credentials.parse(raw) else { continue }
            // full oauthAccount from cswap's config backup (all ~20 fields)
            let cfgPath = backupRoot + "/configs/.claude-config-\(num)-\(email).json"
            let oauthJSON = (try? ClaudeConfig.readRawAccount(at: cfgPath)).flatMap { $0 }.flatMap { AccountStore.jsonString($0) }
            try store.upsert(number: slot, email: email, uuid: m["uuid"] as? String,
                             orgUuid: m["organizationUuid"] as? String,
                             orgName: m["organizationName"] as? String, oauthJSON: oauthJSON, creds: creds)
            imported += 1
        }
        if let active = obj["activeAccountNumber"] as? Int { try? store.setActive(active) }
        return imported
    }
}
