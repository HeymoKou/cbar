import Foundation

/// Switches the active Claude account by writing the target's credentials to the
/// active keychain and splicing its FULL oauthAccount into `~/.claude.json`.
/// Backs up the current active first and rolls back on any error, so a failed
/// switch never leaves a corrupt login.
public struct Switcher {
    public enum SwitchErr: Error { case noCredentials(Int), noOAuthAccount(Int) }
    let store: AccountStore
    // Where the live login lives, and how to ask whose token it is. Injectable
    // so the rollback can be tested against throwaway items; the defaults are
    // Claude Code's real ones.
    let liveService: String, liveAccount: String, credsFile: String
    let configPath: String?
    let profile: (String) throws -> ClaudeConfig.OAuthAccount

    public init(store: AccountStore,
                liveService: String = Credentials.service, liveAccount: String = Credentials.user,
                credsFile: String = Credentials.filePath, configPath: String? = nil,
                profile: @escaping (String) throws -> ClaudeConfig.OAuthAccount = {
                    try OAuthClient().fetchProfile(accessToken: $0)
                }) {
        self.store = store
        self.liveService = liveService; self.liveAccount = liveAccount; self.credsFile = credsFile
        self.configPath = configPath; self.profile = profile
    }

    private func readLive() throws -> ClaudeAiOauth? {
        try Credentials.readActive(service: liveService, account: liveAccount, file: credsFile)
    }
    private func writeLive(_ o: ClaudeAiOauth) throws {
        try Credentials.writeActive(o, service: liveService, account: liveAccount, file: credsFile)
    }

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
        if let curCreds = (try? readLive()) ?? nil {
            if let ident = try? profile(curCreds.accessToken),
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
        let originalCreds = try? readLive()
        let originalConfig = try? ClaudeConfig.rawConfig(at: configPath)

        do {
            try writeLive(targetCreds)
            try ClaudeConfig.spliceRawAccount(targetOAuth, at: configPath)
            try store.setActive(number)
        } catch {
            if let oc = originalCreds { try? writeLive(oc) }
            if let cfg = originalConfig { try? ClaudeConfig.writeRaw(cfg, at: configPath) }
            throw error
        }
    }
}
