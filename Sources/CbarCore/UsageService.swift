import Foundation

/// Native replacement for the cswap CLI: paced per-account usage fetch backed by
/// a persisted cache. Rate-limit safe (fetch active + ≤1 stalest alternate per
/// TTL, per-account backoff). Refreshes tokens as needed, but NEVER rotates the
/// active account's token while Claude Code is running.
public final class UsageService: Provider {
    public let name = "claude"
    private let store: AccountStore
    private let oauth: OAuthClient
    private let cachePath: String

    public init(store: AccountStore = AccountStore(),
                oauth: OAuthClient = OAuthClient(),
                cachePath: String = "\(NSHomeDirectory())/.cbar/usage-cache.json") {
        self.store = store; self.oauth = oauth; self.cachePath = cachePath
    }

    struct Row: Codable {
        var meters: [Meter] = []
        var fetchedAt: Double? = nil
        /// Soonest absolute reset (epoch) across this row's windows — the scheduler
        /// hot-reloads once `now` passes it. Absent on rows written before it
        /// existed or with no reset time; then hot-reload simply doesn't fire.
        var resetsAt: Double? = nil
        var lastAttemptAt: Double? = nil
        var backoffUntil: Double? = nil
        var failures: Int = 0
        var lastError: String? = nil
        var needsReauth: Bool = false
    }

    private func loadCache() -> [Int: Row] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
              let raw = try? JSONDecoder().decode([String: Row].self, from: d) else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int(k).map { ($0, v) } })
    }
    private func saveCache(_ c: [Int: Row]) {
        let raw = Dictionary(uniqueKeysWithValues: c.map { (String($0.key), $0.value) })
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(raw) else { return }
        try? SecureFile.write(d, to: cachePath)
    }

    /// Creds to fetch with: the LIVE keychain for the slot the live token is
    /// PROFILE-VERIFIED to belong to (CC keeps it fresh; the slot copy goes
    /// stale the moment CC refreshes, which froze usage at 76% for 140 min on
    /// 2026-07-10), slot copy otherwise. `liveOwner` — not the active pointer —
    /// gates live use, so an unverified/mismatched token can never poison a row.
    public static func fetchCreds(n: Int, liveOwner: Int?, live: ClaudeAiOauth?, slot: ClaudeAiOauth?) -> ClaudeAiOauth? {
        (n == liveOwner ? live : nil) ?? slot
    }

    /// Whether refreshing slot `n`'s expired token must be skipped and the cache
    /// served instead. Extracted so the guard is assertable — it used to be inline
    /// in `accounts()`, which is why the case it was written for went untested.
    ///
    /// A refresh ROTATES: the old token dies the instant the new one is issued, and
    /// reuse detection can revoke the whole family. So cbar must never refresh a
    /// token Claude Code might also be using. Four ways that can be true:
    ///  - this slot is the profile-verified owner of the live item, CC running;
    ///  - this slot is where the live login points (`active`), CC running — cheap
    ///    belt for a `.claude.json` / keychain identity disagreement;
    ///  - the token literally equals the live one;
    ///  - identity is unknowable: CC running but the profile API is down or the
    ///    live keychain unreadable, so `liveOwner` is nil. Then any slot copy may
    ///    hold the token CC is about to rotate, OR one CC already rotated away
    ///    from (reusing THAT is what revokes the family). Guessing here is what
    ///    killed an account; wait until identity is knowable again.
    public static func shouldSkipRefresh(n: Int, active: Int?, liveOwner: Int?,
                                         ccRunning: Bool, slotRefresh: String?,
                                         liveRefresh: String?) -> Bool {
        guard ccRunning else { return false }
        if n == liveOwner { return true }
        if n == active { return true }
        if let s = slotRefresh, s == liveRefresh { return true }
        return liveOwner == nil
    }

    public func accounts() throws -> [Account] {
        let now = Date().timeIntervalSince1970
        let list = store.list()
        let active = store.syncActive(live: try? ClaudeConfig.readAccount())
        var cache = loadCache()

        let rows = list.map { a in
            PaceRow(number: a.number, fetchedAt: cache[a.number]?.fetchedAt,
                    backoffUntil: cache[a.number]?.backoffUntil, lastAttemptAt: cache[a.number]?.lastAttemptAt,
                    resetsAt: cache[a.number]?.resetsAt)
        }
        // Two `pgrep` spawns, and only the expired-token branch below ever asks.
        // Tokens last about an hour, so computing this up front paid for ~59 of
        // every 60 passes with a fork+exec pair that nothing read. Memoised, not
        // just deferred: several slots can expire in one pass, and the answer
        // cannot change within a pass that already holds the mutation queue.
        var ccRunningMemo: Bool?
        func ccRunning() -> Bool {
            if let v = ccRunningMemo { return v }
            let v = Self.claudeCodeRunning()
            ccRunningMemo = v
            return v
        }

        // Live creds are used/healed ONLY for the slot matching the token's
        // PROFILE-API identity — never attributed by pointer or .claude.json
        // (non-atomic /login writes poisoned slot creds AND usage rows on
        // 2026-07-10). Profile unreachable → liveOwner nil → slot copies only.
        let liveCreds = (try? Credentials.readActive()) ?? nil
        let liveOwner: Int? = liveCreds.flatMap { c in
            (try? oauth.fetchProfile(accessToken: c.accessToken)).flatMap { matchSlot(list, live: $0) }
        }

        // A re-login gave the owning slot a credential its recorded failures were
        // never about, so its backoff must not outlive them (see `fetchPlan`).
        var credsChanged: Set<Int> = []
        if let owner = liveOwner, let live = liveCreds,
           live.accessToken != ((try? store.creds(owner)) ?? nil)?.accessToken {
            credsChanged.insert(owner)
        }

        for n in fetchPlan(now: now, active: active, rows: rows, credsChanged: credsChanged) {
            var row = cache[n] ?? Row()
            row.lastAttemptAt = now                      // claim
            let slotCreds = (try? store.creds(n)) ?? nil
            guard var creds = Self.fetchCreds(n: n, liveOwner: liveOwner, live: liveCreds, slot: slotCreds) else {
                // Drop the meters too: without credentials there is nothing behind
                // the numbers, and keeping them let a dead slot pose as a switch
                // target (slot #3 had no keychain item at all, 2026-07-25).
                row.meters = []; row.lastError = "no credentials"; cache[n] = row; continue
            }
            // Heal the slot backup whenever the live token has moved on —
            // only into the profile-verified owner slot.
            if n == liveOwner, creds.accessToken != slotCreds?.accessToken {
                try? store.setCreds(n, creds)
                // Reset the failure history with it: the count belongs to the OLD
                // credential. Slot #2 carried 125 failures across a re-login, which
                // put backoff straight back at its 600 s cap on the first hiccup —
                // and `needsReauth` kept the account red and unswitchable until a
                // fetch actually landed.
                row.failures = 0; row.backoffUntil = nil
                row.needsReauth = false; row.lastError = nil
                CbarLog.write("slot #\(n) creds healed from live keychain (profile-verified), failure history cleared")
            }
            if isExpired(expiresAt: creds.expiresAt) {
                if Self.shouldSkipRefresh(n: n, active: active, liveOwner: liveOwner,
                                          ccRunning: ccRunning(), slotRefresh: creds.refreshToken,
                                          liveRefresh: liveCreds?.refreshToken) {
                    // Claude Code may be using this token — don't rotate it, and don't
                    // spend a request on it either. Fetching with a knowingly-expired
                    // access token returns 401, which the handler below reads (rightly,
                    // for a revoked token) as needs-reauth — wiping the meters and
                    // reddening a perfectly healthy account. Serve the cache; the live
                    // keychain gets a fresh token as soon as CC needs one.
                    row.lastError = "token expired (Claude Code owns it)"
                    cache[n] = row; continue
                } else {
                    do {
                        let r = try oauth.refresh(refreshToken: creds.refreshToken)
                        creds.accessToken = r.access; creds.expiresAt = r.expiresAt
                        if let rt = r.refresh { creds.refreshToken = rt }
                        if let sc = r.scopes { creds.scopes = sc }
                        // Persist BEFORE using it, and never swallow the failure: the
                        // rotation already killed the old refresh token, so a lost
                        // write is a permanently dead account (`try?` here rotted
                        // slot #2 for 11 days, 2026-07-25).
                        //
                        // The LIVE keychain goes FIRST when this slot owns it: that
                        // item is what Claude Code authenticates with, so stranding it
                        // on the now-dead old token breaks the user's editor, not just
                        // cbar's reading. Bailing out before this write (as the first
                        // cut of this fix did) is worse than the `try?` it replaced.
                        var liveWritten = false
                        if n == liveOwner {
                            do { try Credentials.writeActive(creds); liveWritten = true } catch {
                                CbarLog.write("live keychain FAILED to take rotated creds for #\(n): \(error)")
                            }
                        }
                        var slotWritten = false
                        do { try store.setCreds(n, creds); slotWritten = true } catch {
                            CbarLog.write("slot #\(n) FAILED to persist rotated creds: \(error)")
                        }
                        // One surviving copy is enough for the live owner — the slot is
                        // re-healed from the live keychain on the next poll. Any other
                        // slot has only its own copy, so its loss is terminal.
                        guard slotWritten || liveWritten else {
                            CbarLog.write("slot #\(n) rotated token LOST (no store took it) — needs re-login")
                            row.needsReauth = true; row.meters = []
                            row.lastError = "creds write failed"; cache[n] = row; continue
                        }
                        row.needsReauth = false
                    } catch OAuthError.needsReauth {
                        row.needsReauth = true; row.meters = []
                        row.lastError = "needs re-login"; cache[n] = row; continue
                    } catch {
                        row.failures += 1
                        row.backoffUntil = now + backoff(failures: row.failures, retryAfter: nil)
                        row.lastError = "refresh: \(error)"; cache[n] = row; continue
                    }
                }
            }
            do {
                let data = try oauth.fetchUsageRaw(accessToken: creds.accessToken)
                row.meters = try UsageMapper.meters(from: data)
                row.resetsAt = UsageMapper.soonestReset(from: data)
                row.fetchedAt = now; row.failures = 0; row.backoffUntil = nil; row.lastError = nil
                // An authenticated fetch just succeeded, so whatever needed a
                // re-login doesn't any more. Without this the flag is sticky: a
                // user who fixes a dead slot with `/login` + Add current account
                // stays "needs-reauth" (red, and barred from switching) until cbar
                // happens to perform a refresh of its own.
                row.needsReauth = false
            } catch OAuthError.http(401, _), OAuthError.http(403, _) {
                // Not transient: an expired token was already refreshed above, so a
                // 401/403 here means the credential was revoked. Demote instead of
                // serving the last-good meters as live — they stayed selectable as a
                // switch target for the whole freshness window.
                row.needsReauth = true; row.meters = []
                row.failures += 1
                row.backoffUntil = now + backoff(failures: row.failures, retryAfter: nil)
                row.lastError = "unauthorized"
            } catch OAuthError.http(429, let ra) {
                row.failures += 1
                let wait = backoff(failures: row.failures, retryAfter: ra)
                row.backoffUntil = now + wait
                row.lastError = "rate limited"
                // The only durable record of pacing pressure: `lastError` lives in
                // the cache and is overwritten next pass, so without this there is
                // no way to tell whether a pacing change worked (2026-07-25).
                CbarLog.write("fetch #\(n) 429 — retry-after=\(ra.map { String(Int($0)) } ?? "-") failures=\(row.failures) backoff=\(Int(wait))s")
            } catch {
                row.failures += 1
                row.backoffUntil = now + backoff(failures: row.failures, retryAfter: nil)
                row.lastError = "\(error)"
            }
            cache[n] = row
        }
        saveCache(cache)

        return list.map { a in
            let row = cache[a.number]
            return Account(id: "claude:\(a.number)", number: a.number, email: a.email,
                           org: a.organizationName ?? "",
                           isActive: a.number == active,
                           status: Self.status(needsReauth: row?.needsReauth ?? false,
                                               meters: row?.meters ?? [], fetchedAt: row?.fetchedAt,
                                               lastError: row?.lastError, now: now),
                           meters: row?.meters ?? [],
                           ageSeconds: row?.fetchedAt.map { now - $0 },
                           provider: "claude")
        }
    }

    /// UI- and switch-facing status. Only fresh, real data earns "ok": the old
    /// mapping returned "ok" for anything short of `needsReauth`, so slot #3 —
    /// with no keychain item at all — reported ok + 0% and kept the menu-bar icon
    /// GREEN for 17 h while it was the active account (2026-07-25). A transient
    /// failure on the newest attempt does not demote a still-fresh reading.
    /// `freshFor` matches the 600 s icon-dim threshold on purpose. At 300 s a
    /// harmless 429 flipped status to non-"ok", and `healthLevel` turns every
    /// non-"ok" into `.crit` — so a rate-limited account showed solid red while
    /// still looking bright and current. `isSwitchTarget` deliberately uses the
    /// same 600 s window, for its own reason (see there): a tighter gate goes
    /// blind during a 429 storm, which is exactly when switching matters.
    public static func status(needsReauth: Bool, meters: [Meter], fetchedAt: Double?,
                              lastError: String?, now: Double, freshFor: Double = 600) -> String {
        if needsReauth { return "needs-reauth" }
        if let f = fetchedAt, now - f <= freshFor, !meters.isEmpty { return "ok" }
        return lastError ?? "no data"
    }

    public func switchTo(_ account: Account) throws {}   // handled by Switcher
    public func switchToBest() throws {}

    /// Is Claude Code running? Gates the refresh guard above, so a FALSE NEGATIVE
    /// is the expensive direction: it lets cbar rotate a token Claude Code still
    /// holds, which is the `invalid_grant`/family-revocation case the whole guard
    /// exists for.
    ///
    /// `pgrep -x claude` alone only sees a native install. An npm install runs as
    /// `node` with the CLI path in its arguments, so the name never matches and
    /// the guard silently stops guarding — invisible on a machine with the native
    /// build, account-killing on someone else's. Match the argument path too.
    ///
    /// Still not authoritative: a future packaging could match neither pattern.
    /// That residual case is covered by `shouldSkipRefresh`'s other three tests
    /// (profile-verified owner, active pointer, identical refresh token).
    static func claudeCodeRunning() -> Bool {
        // Narrow on purpose. A broad `-f claude` would match any shell sitting in
        // a path containing "claude" — including this project's own checkout —
        // and a permanent false positive means no slot ever refreshes, which is
        // how tokens expire into unreadable usage.
        pgrepMatches(["-x", "claude"]) || pgrepMatches(["-f", "@anthropic-ai/claude-code"])
    }

    private static func pgrepMatches(_ args: [String]) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        let killer = p.killAfter(5)
        p.waitUntilExit()
        killer.cancel()
        if p.wasKilled {
            // A killed pgrep knows nothing, and "not running" is the answer that
            // lets cbar rotate a token Claude Code may still be holding — the
            // false negative this whole check exists to avoid. Assume running:
            // the cost is a deferred refresh, not a revoked token family.
            CbarLog.write("pgrep \(args.joined(separator: " ")) timed out — assuming Claude Code IS running")
            return true
        }
        return p.terminationStatus == 0
    }
}
