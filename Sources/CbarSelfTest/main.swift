import Foundation
import CbarCore

// `--autoswitch-test` used to live here: it switched the real login to a
// hardcoded slot #2 ("teamacct, the maxed one" — an artifact of the author's
// machine), rotated, then best-effort restored. Harmless to run here, and a
// live-credential mutation for anyone else who found it in a public repo. The
// pure decision logic it exercised is covered by the `autoSwitchTarget` asserts
// below; the switching itself needs a fake store, not the user's account.

// One-shot: exercise the native UsageService against the real store.
if CommandLine.arguments.contains("--service") {
    let svc = UsageService()
    for pass in 1...2 {
        let start = Date()
        let accts = try svc.accounts()
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("PASS \(pass) (\(ms)ms):")
        for a in accts {
            let mstr = a.meters.map { "\($0.id)=\(Int($0.pct))%" }.joined(separator: " ")
            print("  #\(a.number) \(a.email) active=\(a.isActive) status=\(a.status) age=\(a.ageSeconds.map { "\(Int($0))s" } ?? "-") [\(mstr)]")
        }
    }
    exit(0)
}

// One-shot: import cswap accounts into cbar's real store, then exit.
if CommandLine.arguments.contains("--import-cswap") {
    let store = AccountStore()
    let n = try CswapImport.importAll(into: store)
    print("IMPORTED \(n) accounts; store now: \(store.list().map { "#\($0.number) \($0.email)" }.joined(separator: ", ")); active=\(store.activeNumber().map(String.init) ?? "nil")")
    exit(0)
}

// Everything past here is the offline assert suite: it drives real code paths
// against throwaway stores, so keep its side effects out of the one log the
// README points you at for diagnosing real switches. The one-shot modes above
// run against the REAL store and must keep logging.
setenv("CBAR_LOG_SILENT", "1", 1)

// health rules + aggregation (Accounts built directly; no cswap)
assert(healthLevel(pct: 100, status: "ok") == .crit)
assert(healthLevel(pct: 70, status: "ok") == .warn)
assert(healthLevel(pct: 10, status: "ok") == .healthy)
assert(healthLevel(pct: 10, status: "rate_limited") == .crit)
let ha = [
    Account(id: "a", number: 1, email: "a", org: "", isActive: false, status: "ok",
            meters: [Meter(id: "5h", pct: 100, countdown: nil)], ageSeconds: 5, provider: "claude"),
    Account(id: "b", number: 2, email: "b", org: "", isActive: true, status: "ok",
            meters: [Meter(id: "5h", pct: 10, countdown: nil)], ageSeconds: 5, provider: "claude"),
]
assert(overallHealth(ha) == .crit, "worst account at 100% -> crit")
// icon uses ACTIVE account only: #1 (100%) inactive, #2 (10%) active → healthy
assert(activeHealth(ha) == .healthy, "icon = active(#2 10%) health, ignores maxed inactive #1")
let haCrit = [
    Account(id: "a", number: 1, email: "a", org: "", isActive: false, status: "ok", meters: [Meter(id: "5h", pct: 5, countdown: nil)], ageSeconds: 5, provider: "claude"),
    Account(id: "b", number: 2, email: "b", org: "", isActive: true, status: "ok", meters: [Meter(id: "5h", pct: 90, countdown: nil)], ageSeconds: 5, provider: "claude"),
]
assert(activeHealth(haCrit) == .crit, "active at 90% → crit")
assert(anyStale(ha) == false, "fresh")
assert(anyStale([Account(id: "c", number: 3, email: "c", org: "", isActive: false, status: "ok",
                         meters: [], ageSeconds: 700, provider: "claude")]) == true, "stale > 600")
print("HEALTH OK")

// Codex session rate-limit parsing (local jsonl, no API).
let codexLine = #"{"timestamp":"2026-07-09T16:37:40.997Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":5.0,"window_minutes":300,"resets_at":2000003600},"secondary":{"used_percent":12.0,"window_minutes":10080,"resets_at":2000090000},"plan_type":"team"}}}"#
let cx = CodexProvider.parse(codexLine, now: 2000000000)
assert(cx != nil, "codex parse returned nil")
assert(cx!.provider == "codex" && cx!.switchable == false)
assert(cx!.meters.count == 2)
assert(Int(cx!.meters[0].pct) == 5 && cx!.meters[0].id == "5h")
assert(Int(cx!.meters[1].pct) == 12 && cx!.meters[1].id == "7d")
assert(cx!.meters[0].countdown == "1h 0m", "5h countdown: \(cx!.meters[0].countdown ?? "nil")")
assert(cx!.org == "OpenAI · team")
// Codex's post-2026-07-13 shape: one WEEKLY window in `primary`, `secondary`
// null. Labelled by position this read as "5h", four times smaller than the
// figure it claimed to be.
let codexWeeklyOnly = #"{"timestamp":"2026-07-30T00:55:50.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":2.0,"window_minutes":10080,"resets_at":2000090000},"secondary":null,"plan_type":"team"}}}"#
let cxWeek = CodexProvider.parse(codexWeeklyOnly, now: 2000000000)
assert(cxWeek?.meters.count == 1, "one window in, one meter out")
assert(cxWeek?.meters[0].id == "7d", "a 10080-minute window is 7d wherever it sits: \(cxWeek?.meters[0].id ?? "nil")")
assert(Int(cxWeek?.meters[0].pct ?? -1) == 2)
// Length wins over position, and a missing length falls back to position.
assert(CodexProvider.windowLabel(300) == "5h" && CodexProvider.windowLabel(10080) == "7d")
assert(CodexProvider.windowLabel(1440) == "1d" && CodexProvider.windowLabel(60) == "1h")
assert(CodexProvider.windowLabel(30) == "30m", "sub-hour windows must not floor to 0h")
assert(CodexProvider.windowLabel(Int?.none) == nil && CodexProvider.windowLabel(0) == nil)
print("CODEX OK: \(cx!.meters.map { "\($0.id)=\(Int($0.pct))%" }.joined(separator: " ")) | weekly-only: \(cxWeek!.meters.map { "\($0.id)=\(Int($0.pct))%" }.joined(separator: " "))")

// The sessions tree walk is memoised for `walkTTL`; the file it found is still
// re-read every pass, and a file that disappears forces a fresh walk.
let cxDir = NSTemporaryDirectory() + "cbar-selftest-codex-\(getpid())"
try! FileManager.default.createDirectory(atPath: cxDir, withIntermediateDirectories: true)
func cxWrite(_ name: String, pct: Int, mtime: Double) {
    let line = codexLine.replacingOccurrences(of: "\"used_percent\":5.0", with: "\"used_percent\":\(pct).0")
    try! line.write(toFile: cxDir + "/" + name, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)],
                                           ofItemAtPath: cxDir + "/" + name)
}
func cxPct(_ p: CodexProvider) -> Int { Int((try! p.accounts()).first!.meters[0].pct) }
cxWrite("a.jsonl", pct: 5, mtime: 1_000)
let cxCached = CodexProvider(sessionsDir: cxDir)
assert(cxPct(cxCached) == 5, "first pass reads the only session")
cxWrite("b.jsonl", pct: 77, mtime: 2_000)
assert(cxPct(cxCached) == 5, "a newer session inside walkTTL waits for the next walk")
assert(cxPct(CodexProvider(sessionsDir: cxDir, walkTTL: 0)) == 77, "expired walkTTL finds the newer session")
try! FileManager.default.removeItem(atPath: cxDir + "/a.jsonl")
assert(cxPct(cxCached) == 77, "a cached file that vanished forces a walk")
try? FileManager.default.removeItem(atPath: cxDir)
print("CODEX WALK CACHE OK")

// A child that outlives its deadline gets killed; one that exits first does not.
let hung = Process()
hung.executableURL = URL(fileURLWithPath: "/bin/sleep")
hung.arguments = ["30"]
try! hung.run()
let hungStart = Date()
let hungKiller = hung.killAfter(0.3)
hung.waitUntilExit()
hungKiller.cancel()
assert(hung.wasKilled, "a child past its deadline must be killed")
assert(Date().timeIntervalSince(hungStart) < 5, "the kill must actually unblock the wait")
let quick = Process()
quick.executableURL = URL(fileURLWithPath: "/bin/echo")
quick.standardOutput = Pipe()
try! quick.run()
let quickKiller = quick.killAfter(30)
quick.waitUntilExit()
quickKiller.cancel()
assert(!quick.wasKilled && quick.terminationStatus == 0, "a child that exits first is left alone")
print("PROCESS TIMEOUT OK")

// Keychain round-trip on a throwaway service
let ks = "cbar-selftest", ka = "rt"
try? Keychain.delete(service: ks, account: ka)
assert((try? Keychain.get(service: ks, account: ka)) == .some(nil), "absent should be nil")
try! Keychain.set(service: ks, account: ka, value: "{\"x\":1}")
assert(try! Keychain.get(service: ks, account: ka) == "{\"x\":1}", "keychain roundtrip")
try! Keychain.delete(service: ks, account: ka)
assert(try! Keychain.get(service: ks, account: ka) == nil, "deleted")
// Claude Code stores its credentials as PLAIN JSON (not base64) — cbar must
// read that format (lenient get) and write switches back in it (setRaw), or
// live-creds reads silently die and CC can't parse a cbar-switched item.
let pj = #"{"claudeAiOauth":{"accessToken":"a b\"c","refreshToken":"r/t+x=","expiresAt":1}}"#
try! Keychain.setRaw(service: ks, account: "plain", value: pj)
assert(try! Keychain.getRaw(service: ks, account: "plain") == pj, "raw roundtrip incl. quotes/spaces/backslash")
assert(try! Keychain.get(service: ks, account: "plain") == pj, "get tolerates plain (CC-written) values")
try! Keychain.delete(service: ks, account: "plain")
print("KEYCHAIN OK")

// Credentials parse/serialize round-trip
let credJson = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1783672677350,"scopes":["user:inference"]}}"#
let cred = Credentials.parse(credJson)!
assert(cred.accessToken == "a" && cred.refreshToken == "r" && Int(cred.expiresAt) == 1783672677350)
assert(Credentials.parse(Credentials.serialize(cred))!.refreshToken == "r", "creds roundtrip")
// `security -i` is a LINE-based command parser: a multi-line serialized blob
// splits into garbage commands — on 2026-07-10 this DESTROYED the live login
// item mid-switch (first JSON line overwrote it with "{"). serialize must stay
// single-line; setRaw must refuse newlines BEFORE touching the keychain.
assert(!Credentials.serialize(cred).contains("\n"), "serialize must be single-line for security -i")
try! Keychain.setRaw(service: ks, account: "nl", value: "precious")
do {
    try Keychain.setRaw(service: ks, account: "nl", value: "{\n  \"a\": 1\n}")
    assert(false, "setRaw must throw on multi-line value")
} catch {}
assert(try! Keychain.getRaw(service: ks, account: "nl") == "precious",
       "failed setRaw must NOT corrupt the existing item")
try? Keychain.delete(service: ks, account: "nl")
print("CREDS OK")

// Token identity from the profile API — the ONLY trustworthy owner-of-token
// source. Local (.claude.json, keychain) pairs are written non-atomically by
// /login; trusting their instantaneous coherence cross-contaminated slot creds
// on 2026-07-10. Any creds write into a slot must match PROFILE identity.
let profJson = #"{"account":{"uuid":"AU1","email_address":"p@x.com","full_name":"P"},"organization":{"uuid":"OU1","name":"POrg"}}"#
let prof = ProfileMapper.account(from: Data(profJson.utf8))
assert(prof?.emailAddress == "p@x.com" && prof?.accountUuid == "AU1", "profile account fields")
assert(prof?.organizationUuid == "OU1" && prof?.organizationName == "POrg", "profile org fields")
assert(ProfileMapper.account(from: Data("{}".utf8)) == nil, "empty profile -> nil, never a guessed identity")
// The live endpoint stopped returning email_address (2026-07-25). uuid is the
// identity; requiring email made every profile call fail, so liveOwner was
// permanently nil and slot copies drifted until usage went unreadable.
let noEmail = #"{"account":{"uuid":"AU1"},"organization":{"uuid":"OU1","name":"POrg"}}"#
let profNE = ProfileMapper.account(from: Data(noEmail.utf8))
assert(profNE?.accountUuid == "AU1" && profNE?.emailAddress == nil, "missing email must NOT fail the mapping")
assert(matchSlot([sa(1, "a@x.com", "AU1", "OU1")], live: profNE) == 1, "uuid alone still matches a slot")
assert(ProfileMapper.account(from: Data(#"{"account":{"email_address":"p@x.com"}}"#.utf8)) == nil,
       "no uuid -> nil (email alone is not an identity)")
print("PROFILE MAP OK")

// ClaudeConfig splice preserves all other keys
let tmp = NSTemporaryDirectory() + "cbar-cfg-\(ProcessInfo.processInfo.processIdentifier).json"
let original = #"{"numStartups":42,"oauthAccount":{"emailAddress":"old@x.com","organizationUuid":"O1"},"projects":{"/a":{"x":1}},"telemetry":true}"#
try! original.write(toFile: tmp, atomically: true, encoding: .utf8)
try! ClaudeConfig.spliceAccount(.init(emailAddress: "new@y.com", accountUuid: "U2", organizationUuid: "O2", organizationName: "Org"), at: tmp)
let after = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: tmp))) as! [String: Any]
assert((after["numStartups"] as? Int) == 42, "preserve numStartups")
assert((after["telemetry"] as? Bool) == true, "preserve telemetry")
assert(((after["projects"] as? [String: Any])?["/a"] as? [String: Any])?["x"] as? Int == 1, "preserve projects")
let oa = after["oauthAccount"] as! [String: Any]
assert((oa["emailAddress"] as? String) == "new@y.com" && (oa["organizationUuid"] as? String) == "O2", "spliced")
let reread = try! ClaudeConfig.readAccount(at: tmp)!
assert(reread.emailAddress == "new@y.com" && reread.accountUuid == "U2")
// Identical byte count, different identity: `readAccount` caches its parse, and
// keying that cache on size alone would serve the previous account here — which
// on a real switch means cbar reconciling against the login it just replaced.
try! ClaudeConfig.spliceAccount(.init(emailAddress: "new@z.com", accountUuid: "U3", organizationUuid: "O3", organizationName: "Org"), at: tmp)
let sameSize = try! ClaudeConfig.readAccount(at: tmp)!
assert(sameSize.emailAddress == "new@z.com" && sameSize.accountUuid == "U3", "equal-size rewrite must invalidate the read cache")
// full oauthAccount splice preserves other top-level keys + replaces all oauth fields
try! ClaudeConfig.spliceRawAccount(["accountUuid": "U9", "emailAddress": "z@z.com", "billingType": "pro", "seatTier": "x"], at: tmp)
let after2 = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: tmp))) as! [String: Any]
assert((after2["numStartups"] as? Int) == 42 && (after2["telemetry"] as? Bool) == true, "raw splice preserves keys")
let oa2 = after2["oauthAccount"] as! [String: Any]
assert((oa2["billingType"] as? String) == "pro" && (oa2["seatTier"] as? String) == "x" && oa2.count == 4, "full oauth replaced")
try? FileManager.default.removeItem(atPath: tmp)
print("CONFIG SPLICE OK")

// OAuth usage mapping (utilization vs percent) + expiry math
let usageJson = #"{"five_hour":{"utilization":42.0,"resets_at":null},"seven_day":{"utilization":71},"limits":[{"scope":{"model":{"display_name":"Fable"}},"percent":88.0}]}"#
let um = try UsageMapper.meters(from: Data(usageJson.utf8))
assert(um.count == 3, "usage meters count \(um.count)")
assert(um[0].id == "5h" && Int(um[0].pct) == 42, "5h util")
assert(um[1].id == "7d" && Int(um[1].pct) == 71, "7d util")
assert(um[2].id == "Fbl" && Int(um[2].pct) == 88, "scoped percent")
assert(isExpired(expiresAt: 1000, now_ms: 800_000), "expired")
assert(!isExpired(expiresAt: 10_000_000_000_000, now_ms: 1000), "not expired")
// reset countdown: fractional-seconds resets_at must parse (was the "no reset time" bug)
let usageReset = #"{"five_hour":{"utilization":50.0,"resets_at":"2035-01-02T03:04:05.326186+00:00"}}"#
let mr = try UsageMapper.meters(from: Data(usageReset.utf8))
assert(mr.first?.countdown != nil, "fractional resets_at must yield a countdown (not nil)")
assert(mr.first!.countdown!.contains("d"), "far-future reset → days countdown, got \(mr.first!.countdown!)")
print("OAUTH MAP OK")

// AccountStore on throwaway dir + keychain service
let storeDir = NSTemporaryDirectory() + "cbar-store-\(ProcessInfo.processInfo.processIdentifier)"
let storeSvc = "cbar-selftest-store"
let store = AccountStore(dir: storeDir, keychainService: storeSvc)
let sc = ClaudeAiOauth(accessToken: "AT", refreshToken: "RT", expiresAt: 1783672677350, scopes: ["user:inference"])
let n1 = try store.add(email: "a@x.com", uuid: "U1", orgUuid: "O1", orgName: "Org", creds: sc)
assert(store.list().count == 1 && store.list()[0].email == "a@x.com", "store add")
assert(store.activeNumber() == n1, "first = active")
let c1 = try store.creds(n1)
assert(c1?.accessToken == "AT", "creds back")
let n2 = try store.add(email: "a@x.com", uuid: "U1", orgUuid: "O1", orgName: "Org", creds: sc) // re-capture same identity
assert(n1 == n2 && store.list().count == 1, "re-capture dedup")
try store.remove(n1)
let cAfter = try store.creds(n1)
assert(store.list().isEmpty && cAfter == nil, "removed")
try? Keychain.delete(service: storeSvc, account: "account-\(n1)")
try? FileManager.default.removeItem(atPath: storeDir)
print("STORE OK")

// Everything under ~/.cbar must be owner-only. These files name every account
// and copy Claude Code's oauthAccount verbatim; the mode used to be whatever
// the user's umask gave (0644 in practice).
let secDir = NSTemporaryDirectory() + "cbar-sec-\(getpid())/nested"
let secFile = secDir + "/f.json"
func mode(_ p: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: p))?[.posixPermissions] as? Int
}
try SecureFile.write(Data("{}".utf8), to: secFile)
assert(mode(secFile) == 0o600, "file owner-only, got \(mode(secFile).map { String($0, radix: 8) } ?? "nil")")
assert(mode(secDir) == 0o700, "dir owner-only, got \(mode(secDir).map { String($0, radix: 8) } ?? "nil")")
// A rewrite must not hand the mode back: .atomic renames a fresh temp file over
// the target, so the chmod has to run on every write, not just the first.
try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: secFile)
try SecureFile.write(Data("{\"x\":1}".utf8), to: secFile)
assert(mode(secFile) == 0o600, "rewrite re-tightens")
// Directories left 0755 by earlier versions get tightened in place.
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: secDir)
try SecureFile.ensureDir(secDir)
assert(mode(secDir) == 0o700, "existing loose dir tightened")
// The startup sweep is what upgraders actually depend on: a file nothing
// rewrites (accounts.json between account changes, a rotated log) would keep
// its old 0644 forever without it.
let stale = secDir + "/stale.json"
FileManager.default.createFile(atPath: stale, contents: Data("{}".utf8),
                               attributes: [.posixPermissions: 0o644])
SecureFile.tightenAll(dir: secDir)
assert(mode(stale) == 0o600, "startup sweep tightens files nothing rewrites")
try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "cbar-sec-\(getpid())")
print("SECUREFILE OK")

// Pacing: backoff caps + fetch plan
assert(backoff(failures: 1, retryAfter: nil) == 30, "backoff n1")
assert(backoff(failures: 5, retryAfter: nil) == 480, "backoff n5")
assert(backoff(failures: 10, retryAfter: nil) == 600, "backoff cap")
assert(backoff(failures: 1, retryAfter: 0) == 30, "edge min(30,120)")
assert(backoff(failures: 10, retryAfter: 0) == 120, "edge cap 120")
assert(backoff(failures: 1, retryAfter: 500) == 500, "burst honor")
assert(backoff(failures: 1, retryAfter: 5000) == 900, "burst cap 900")
let t0 = 1_000_000.0
let pr = [
    PaceRow(number: 1, fetchedAt: t0 - 5, backoffUntil: nil, lastAttemptAt: nil),   // fresh (<30s) → skip
    PaceRow(number: 2, fetchedAt: nil, backoffUntil: nil, lastAttemptAt: nil),        // active, never fetched
    PaceRow(number: 3, fetchedAt: t0 - 100, backoffUntil: nil, lastAttemptAt: nil),   // stale → fetch
    PaceRow(number: 4, fetchedAt: t0 - 500, backoffUntil: t0 + 60, lastAttemptAt: nil), // backing off → skip
    PaceRow(number: 5, fetchedAt: t0 - 80, backoffUntil: nil, lastAttemptAt: nil),    // stale → fetch
]
let plan = fetchPlan(now: t0, active: 2, rows: pr)
assert(plan == [2], "never-fetched active is stalest of all → wins")
// One request per pass. The old full pass spent the whole rate budget on the
// active slot and starved every other one behind it (see `fetchPlan`).
assert(plan.count <= 1, "one account per pass")
assert(!plan.contains(1) && !plan.contains(4), "skip fresh + backoff")

// Rotation: whatever was just fetched becomes freshest, so the next pass moves
// on by itself — no cursor. #9 active and recent, so it must not hog the slot.
var rot = [
    PaceRow(number: 8, fetchedAt: t0 - 100, backoffUntil: nil, lastAttemptAt: nil),
    PaceRow(number: 9, fetchedAt: t0 - 60, backoffUntil: nil, lastAttemptAt: nil),   // active, fresh enough
    PaceRow(number: 10, fetchedAt: t0 - 200, backoffUntil: nil, lastAttemptAt: nil),
]
assert(fetchPlan(now: t0, active: 9, rows: rot) == [10], "stalest wins, active has no standing priority")
rot[2] = PaceRow(number: 10, fetchedAt: t0, backoffUntil: nil, lastAttemptAt: t0 - 20)
assert(fetchPlan(now: t0, active: 9, rows: rot) == [8], "next pass rotates to the new stalest")
// ...but the active slot may not lag past what auto-switch can tolerate.
let staleActive = [
    PaceRow(number: 8, fetchedAt: t0 - 300, backoffUntil: nil, lastAttemptAt: nil),
    PaceRow(number: 9, fetchedAt: t0 - 200, backoffUntil: nil, lastAttemptAt: nil),   // active, past 180 s
]
assert(fetchPlan(now: t0, active: 9, rows: staleActive) == [9], "aged-out active preempts a staler alternate")
// A re-login must break out of backoff. Slot #2 accumulated 125 failures, so
// backoff sat at its 600 s cap; the skip meant the dead slot copy was never
// healed from the live keychain, and the un-healed copy caused the next failure.
let backedOff = [PaceRow(number: 7, fetchedAt: t0 - 900, backoffUntil: t0 + 500, lastAttemptAt: t0 - 600)]
assert(fetchPlan(now: t0, active: 7, rows: backedOff).isEmpty, "backoff normally wins, even for active")
assert(fetchPlan(now: t0, active: 7, rows: backedOff, credsChanged: [7]) == [7], "new credential overrides backoff")
// But claimTTL must still hold, or ignoring backoff becomes a per-poll storm.
let justTried = [PaceRow(number: 7, fetchedAt: t0 - 900, backoffUntil: t0 + 500, lastAttemptAt: t0 - 2)]
assert(fetchPlan(now: t0, active: 7, rows: justTried, credsChanged: [7]).isEmpty, "claim window still applies")

// Starvation is a property of the SEQUENCE of passes, not of any one plan, so
// single-pass asserts cannot see it — the shipped bug passed every assert above.
// Drive an hour of 60 s polls over 3 accounts and check what each one actually
// gets. The old "active first, then everyone" plan pinned #2 at every pass and
// left #1/#3 to the 429 backoff.
var simFetched: [Int: Double] = [:]
var picks: [Int: Int] = [:]
var worstAge: [Int: Double] = [:]
for tick in 0..<60 {
    let now = t0 + Double(tick) * 60
    for n in [1, 2, 3] {
        worstAge[n] = max(worstAge[n] ?? 0, simFetched[n].map { now - $0 } ?? 0)
    }
    let rows = [1, 2, 3].map {
        PaceRow(number: $0, fetchedAt: simFetched[$0], backoffUntil: nil, lastAttemptAt: nil)
    }
    let p = fetchPlan(now: now, active: 2, rows: rows)
    assert(p.count <= 1, "budget is one request per pass")
    if let n = p.first { simFetched[n] = now; picks[n, default: 0] += 1 }
}
assert(picks.count == 3, "every account gets served — none starves")
// `isSwitchTarget` demands 600 s of a switch destination; a slot that ages past
// it silently stops being selectable. Asserted at 300 s, half the real gate, so
// this fails while there is still margin rather than at the cliff.
assert(worstAge.values.allSatisfy { $0 <= 300 }, "no slot ages out of switch eligibility: \(worstAge)")
assert((picks[2] ?? 0) >= (picks[1] ?? 0), "active served at least as often as an alternate")
print("PACING OK (rotation over 60 passes: \(picks.sorted { $0.key < $1.key }.map { "#\($0.key)×\($0.value)" }.joined(separator: " ")), worst staleness \(Int(worstAge.values.max() ?? 0))s)")

// Auto-switch target selection
func mkAcc(_ n: Int, _ active: Bool, _ pct: Double, provider: String = "claude") -> Account {
    Account(id: "\(n)", number: n, email: "e\(n)", org: "", isActive: active, status: "ok",
            meters: [Meter(id: "5h", pct: pct, countdown: nil)], ageSeconds: 1, provider: provider)
}
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 95), mkAcc(2, false, 10), mkAcc(3, false, 50)], threshold: 94) == 2, "switch to most headroom")
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 50), mkAcc(2, false, 10)], threshold: 94) == nil, "below threshold -> no switch")
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 95), mkAcc(2, false, 96)], threshold: 94) == nil, "no better account -> no switch")
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 95), mkAcc(2, false, 10, provider: "codex")], threshold: 94) == nil, "codex not a switch target")
// Only the 5h window triggers. Fable and 7d are both excluded: the real
// 2026-07-25 state was 5h=3% / 7d=91%, which wanted to rotate every poll off an
// account with a nearly empty 5-hour window.
let busy7d = Account(id: "1", number: 1, email: "e1", org: "", isActive: true, status: "ok",
                     meters: [Meter(id: "5h", pct: 3, countdown: nil), Meter(id: "7d", pct: 91, countdown: nil), Meter(id: "Fbl", pct: 99, countdown: nil)],
                     ageSeconds: 1, provider: "claude")
assert(switchPct(busy7d) == 3, "switchPct is 5h only (ignores 7d and Fable)")
assert(autoSwitchTarget(accounts: [busy7d, mkAcc(2, false, 5)], threshold: 93) == nil, "7d 91% / Fable 99% must not trigger when 5h is low")
assert(switchPct(mkAcc(1, true, 93)) == 93 && autoSwitchTarget(accounts: [mkAcc(1, true, 93), mkAcc(2, false, 5)], threshold: 93) == 2, "5h at threshold triggers")

// Dead accounts must never be switch targets, however good their stale cache
// looks (slot #2: needs-reauth, 11-day-old 60%, picked 4× on 2026-07-25).
func deadAcc(_ n: Int, _ pct: Double, status: String = "ok", age: Double? = 1, meters: [Meter]? = nil) -> Account {
    Account(id: "\(n)", number: n, email: "e\(n)", org: "", isActive: false, status: status,
            meters: meters ?? [Meter(id: "5h", pct: pct, countdown: nil)], ageSeconds: age, provider: "claude")
}
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 95), deadAcc(2, 10, status: "needs-reauth")], threshold: 93) == nil, "needs-reauth is not a switch target")
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 95), deadAcc(2, 10, status: "no credentials")], threshold: 93) == nil, "no-credentials is not a switch target")
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 95), deadAcc(2, 10, age: 982_740)], threshold: 93) == nil, "11-day-stale cache is not a switch target")
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 95), deadAcc(2, 0, meters: [])], threshold: 93) == nil, "no meters is not a switch target")
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 95), deadAcc(2, 10, status: "needs-reauth"), deadAcc(3, 40)], threshold: 93) == 3, "picks the healthy one, not the emptier dead one")

// status(): only fresh, real data is "ok" — slot #3 reported ok + 0% with no
// keychain item and kept the icon green for 17 h (2026-07-25).
let m5 = [Meter(id: "5h", pct: 3, countdown: nil)]
func st(_ meters: [Meter], _ fetchedAt: Double?, _ err: String?, reauth: Bool = false) -> String {
    UsageService.status(needsReauth: reauth, meters: meters, fetchedAt: fetchedAt, lastError: err, now: 1000)
}
assert(st([], nil, nil) == "no data", "never fetched -> no data")
assert(st([], nil, "no credentials") == "no credentials", "missing creds must not read ok")
assert(st(m5, 20, "rate limited") == "rate limited", "stale reading surfaces its error")
assert(st(m5, 990, "rate limited") == "ok", "fresh reading survives a transient error")
assert(st(m5, 990, nil, reauth: true) == "needs-reauth", "reauth wins over freshness")
assert(st(m5, 400, "rate limited") == "ok", "at the 600s freshness boundary a backing-off row is still ok")
assert(st(m5, 399, "rate limited") == "rate limited", "one second past it surfaces the error")

// 7d is a hard ceiling, not a ranking input.
func acc7d(_ n: Int, _ active: Bool, fiveH: Double, sevenD: Double) -> Account {
    Account(id: "\(n)", number: n, email: "e\(n)", org: "", isActive: active, status: "ok",
            meters: [Meter(id: "5h", pct: fiveH, countdown: nil), Meter(id: "7d", pct: sevenD, countdown: nil)],
            ageSeconds: 1, provider: "claude")
}
assert(!isExhausted(acc7d(1, false, fiveH: 0, sevenD: 98)), "98% is not exhausted")
assert(isExhausted(acc7d(1, false, fiveH: 0, sevenD: 99)), "99% is the ceiling")
// Empty 5h looks like max headroom via switchPct, so the ceiling must veto it.
assert(autoSwitchTarget(accounts: [acc7d(1, true, fiveH: 95, sevenD: 10), acc7d(2, false, fiveH: 2, sevenD: 100)],
                        threshold: 93) == nil, "weekly-exhausted account is not a target")
assert(autoSwitchTarget(accounts: [acc7d(1, true, fiveH: 95, sevenD: 10), acc7d(2, false, fiveH: 2, sevenD: 100), acc7d(3, false, fiveH: 40, sevenD: 50)],
                        threshold: 93) == 3, "skips the exhausted 2% for the healthy 40%")
// Exhausted ACTIVE must escape even though its own 5h reads low — the old
// "more headroom than active" test made that a one-way trap.
assert(autoSwitchTarget(accounts: [acc7d(1, true, fiveH: 10, sevenD: 100), acc7d(2, false, fiveH: 40, sevenD: 50)],
                        threshold: 93) == 2, "exhausted active switches away even to a HIGHER 5h")
assert(autoSwitchTarget(accounts: [acc7d(1, true, fiveH: 10, sevenD: 100), acc7d(2, false, fiveH: 40, sevenD: 99)],
                        threshold: 93) == nil, "but not into another exhausted account")
// A missing 5h meter reads as 0% — unknown headroom must not rank best.
let no5h = Account(id: "2", number: 2, email: "e2", org: "", isActive: false, status: "ok",
                   meters: [Meter(id: "7d", pct: 10, countdown: nil)], ageSeconds: 1, provider: "claude")
assert(switchPct(no5h) == 0 && !isSwitchTarget(no5h), "no 5h meter -> not a target despite reading 0%")
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 95), no5h], threshold: 93) == nil, "unknown 5h is not headroom")
// Staleness boundary (aligned with status freshness so 429 storms don't disable switching).
assert(isSwitchTarget(deadAcc(2, 10, age: 600)), "fresh enough at the boundary")
assert(!isSwitchTarget(deadAcc(2, 10, age: 601)), "one second past it is not a target")

// Refresh-token rotation guard. CC holding the same token, owning the slot,
// pointing at it, or an unknowable identity all mean: do not rotate.
func skip(_ n: Int, active: Int?, liveOwner: Int?, cc: Bool, slotRT: String?, liveRT: String?) -> Bool {
    UsageService.shouldSkipRefresh(n: n, active: active, liveOwner: liveOwner,
                                  ccRunning: cc, slotRefresh: slotRT, liveRefresh: liveRT)
}
assert(!skip(2, active: 1, liveOwner: 1, cc: false, slotRT: "r0", liveRT: "r0"), "CC not running -> refresh freely")
assert(skip(1, active: 1, liveOwner: 1, cc: true, slotRT: "r1", liveRT: "r1"), "verified live owner -> skip")
assert(skip(2, active: 2, liveOwner: 1, cc: true, slotRT: "rX", liveRT: "r1"), "slot the live login points at -> skip")
assert(skip(2, active: 1, liveOwner: 1, cc: true, slotRT: "r1", liveRT: "r1"), "token equals the live one -> skip")
// The case the guard exists for: profile API down, so the slot copy may hold a
// token CC already rotated away from — reusing it can revoke the whole family.
assert(skip(2, active: 1, liveOwner: nil, cc: true, slotRT: "r0", liveRT: "r1"), "drifted copy, identity unknown -> skip")
assert(skip(2, active: 1, liveOwner: nil, cc: true, slotRT: "r0", liveRT: nil), "live keychain unreadable -> skip")
assert(!skip(3, active: 1, liveOwner: 1, cc: true, slotRT: "r9", liveRT: "r1"), "unrelated slot, identity known -> refresh")
print("AUTOSWITCH OK")

// Live-login reconciliation: /login in Claude Code must move cbar's active
// pointer (the 2026-07-10 desync: cbar kept #1 while CC was on #3).
func sa(_ n: Int, _ email: String, _ uuid: String?, _ org: String?) -> StoredAccount {
    StoredAccount(number: n, email: email, uuid: uuid, organizationUuid: org, organizationName: nil)
}
let slots = [sa(1, "a@x.com", "U1", "O1"), sa(2, "b@x.com", "U2", "O2"), sa(3, "c@gmail.com", "U3", "O3")]
assert(matchSlot(slots, live: .init(emailAddress: "c@gmail.com", accountUuid: "U3", organizationUuid: "O3", organizationName: nil)) == 3, "uuid+org match")
assert(matchSlot(slots, live: .init(emailAddress: "b@x.com", accountUuid: nil, organizationUuid: "O2", organizationName: nil)) == 2, "email+org fallback when uuid missing")
assert(matchSlot(slots, live: .init(emailAddress: "new@z.com", accountUuid: "U9", organizationUuid: "O9", organizationName: nil)) == nil, "unknown login -> nil, never guess")
assert(matchSlot(slots, live: nil) == nil, "no live info -> nil")
// same email in two orgs must resolve by org
let dupEmail = [sa(1, "a@x.com", "U1", "O1"), sa(2, "a@x.com", "U1", "O2")]
assert(matchSlot(dupEmail, live: .init(emailAddress: "a@x.com", accountUuid: "U1", organizationUuid: "O2", organizationName: nil)) == 2, "org disambiguates")

// syncActive: store pointer follows the live login
let syncDir = NSTemporaryDirectory() + "cbar-sync-\(ProcessInfo.processInfo.processIdentifier)"
let syncSvc = "cbar-selftest-sync"
let sst = AccountStore(dir: syncDir, keychainService: syncSvc)
let sn1 = try sst.add(email: "a@x.com", uuid: "U1", orgUuid: "O1", orgName: nil, creds: sc)
let sn2 = try sst.add(email: "b@x.com", uuid: "U2", orgUuid: "O2", orgName: nil, creds: sc)
assert(sst.activeNumber() == sn1, "first added = active")
assert(sst.syncActive(live: .init(emailAddress: "b@x.com", accountUuid: "U2", organizationUuid: "O2", organizationName: nil)) == sn2, "resync returns matched slot")
assert(sst.activeNumber() == sn2, "pointer moved to live login")
assert(sst.syncActive(live: nil) == sn2, "no live info -> pointer kept")
assert(sst.syncActive(live: .init(emailAddress: "new@z.com", accountUuid: "U9", organizationUuid: "O9", organizationName: nil)) == sn2, "unknown login -> pointer kept")
for n in [sn1, sn2] { try? Keychain.delete(service: syncSvc, account: "account-\(n)") }
try? FileManager.default.removeItem(atPath: syncDir)
print("ACTIVE SYNC OK")

// The PROFILE-VERIFIED owner slot fetches with LIVE keychain creds (CC keeps
// them fresh; slot copies go stale — the 2026-07-10 401-freeze bug). Everyone
// else uses their slot copy; an unverified live token is used by NO ONE.
let liveCred = ClaudeAiOauth(accessToken: "LIVE", refreshToken: "r", expiresAt: 9e15, scopes: nil)
let slotCred = ClaudeAiOauth(accessToken: "SLOT", refreshToken: "r", expiresAt: 9e15, scopes: nil)
assert(UsageService.fetchCreds(n: 1, liveOwner: 1, live: liveCred, slot: slotCred)?.accessToken == "LIVE", "verified owner -> live keychain")
assert(UsageService.fetchCreds(n: 1, liveOwner: 1, live: nil, slot: slotCred)?.accessToken == "SLOT", "owner, no live -> slot fallback")
assert(UsageService.fetchCreds(n: 2, liveOwner: 1, live: liveCred, slot: slotCred)?.accessToken == "SLOT", "non-owner -> slot copy")
assert(UsageService.fetchCreds(n: 2, liveOwner: nil, live: liveCred, slot: slotCred)?.accessToken == "SLOT", "unverified live -> slot copy only")
assert(UsageService.fetchCreds(n: 2, liveOwner: 1, live: liveCred, slot: nil) == nil, "non-owner without slot creds -> nil, never live")
print("FETCH CREDS OK")

if CommandLine.arguments.contains("--live") {
    let start = Date()
    let live = try UsageService().accounts()
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    print("USAGE LIVE: \(live.count) accounts in \(ms)ms")
    for a in live {
        let mstr = a.meters.map { "\($0.id)=\(Int($0.pct))%" }.joined(separator: " ")
        print("  #\(a.number) \(a.email) active=\(a.isActive) status=\(a.status) [\(mstr)]")
    }

    let cxStart = Date()
    let cxAccts = try CodexProvider().accounts()
    let cxMs = Int(Date().timeIntervalSince(cxStart) * 1000)
    if let cx = cxAccts.first {
        print("CODEX LIVE: \(cx.email) [\(cx.org)] in \(cxMs)ms — " +
              cx.meters.map { "\($0.id)=\(Int($0.pct))% (\($0.countdown ?? "—"))" }.joined(separator: " ") +
              " age=\(cx.ageSeconds.map { "\(Int($0))s" } ?? "?")")
    } else {
        print("CODEX LIVE: no session rate-limit data found (\(cxMs)ms)")
    }

    // native OAuth usage fetch for the active account (meaningful once 429 clears)
    if let cred = try Credentials.readActive() {
        do {
            let d = try OAuthClient().fetchUsageRaw(accessToken: cred.accessToken)
            print("OAUTH LIVE:", try UsageMapper.meters(from: d).map { "\($0.id)=\(Int($0.pct))%" }.joined(separator: " "))
        } catch { print("OAUTH LIVE err:", error) }
    } else {
        print("OAUTH LIVE: no active credentials found")
    }
}
