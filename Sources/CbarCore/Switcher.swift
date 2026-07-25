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
        // Best-effort, but say so when it doesn't happen: an auto-switch during a
        // 429 storm (when it's most likely to fire) can't reach the profile API, so
        // the backup is skipped and the outgoing slot keeps a stale, already-rotated
        // token — that account then needs a manual /login and nothing said why.
        if let curCreds = (try? Credentials.readActive()) ?? nil {
            if let ident = try? OAuthClient().fetchProfile(accessToken: curCreds.accessToken),
               let real = matchSlot(store.list(), live: ident) {
                do { try store.setCreds(real, curCreds) } catch {
                    CbarLog.write("switch #\(number): backing up outgoing creds into slot #\(real) FAILED: \(error)")
                }
            } else {
                CbarLog.write("switch #\(number): outgoing creds NOT backed up (identity unverifiable) — that slot may need re-login")
            }
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
