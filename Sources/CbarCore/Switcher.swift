import Foundation

/// Switches the active Claude account by writing the target's credentials to the
/// active keychain and splicing its FULL oauthAccount into `~/.claude.json`.
/// Backs up the current active first and rolls back on any error, so a failed
/// switch never leaves a corrupt login.
public struct Switcher {
    public enum SwitchErr: Error { case noCredentials(Int), noOAuthAccount(Int) }
    let store: AccountStore
    public init(store: AccountStore) { self.store = store }

    public func switchTo(_ number: Int) throws {
        // Refresh the backup of the outgoing login before overwriting it — into
        // the slot matching the token's PROFILE-API identity. Never local state:
        // /login writes keychain and .claude.json non-atomically, and trusting
        // their coherence backed one account's creds into another's slot on
        // 2026-07-10. Profile unavailable → skip the backup (it's best-effort).
        if let curCreds = (try? Credentials.readActive()) ?? nil,
           let ident = try? OAuthClient().fetchProfile(accessToken: curCreds.accessToken),
           let real = matchSlot(store.list(), live: ident) {
            try? store.setCreds(real, curCreds)
        }

        guard let targetCreds = try store.creds(number) else { throw SwitchErr.noCredentials(number) }
        guard let targetOAuth = store.oauthAccount(number) else { throw SwitchErr.noOAuthAccount(number) }

        // Snapshot originals for rollback.
        let originalCreds = try? Credentials.readActive()
        let originalConfig = try? ClaudeConfig.rawConfig()

        do {
            try Credentials.writeActive(targetCreds)
            try ClaudeConfig.spliceRawAccount(targetOAuth)
            try store.setActive(number)
        } catch {
            if let oc = originalCreds { try? Credentials.writeActive(oc) }
            if let cfg = originalConfig { try? ClaudeConfig.writeRaw(cfg) }
            throw error
        }
    }
}
