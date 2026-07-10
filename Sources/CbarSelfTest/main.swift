import Foundation
import CbarCore

// One-shot: LIVE end-to-end auto-switch diagnosis against the real store/login.
if CommandLine.arguments.contains("--autoswitch-test") {
    func cfgActive() -> String {
        (try? ClaudeConfig.readAccount())?.flatMap { $0 }?.emailAddress ?? "?"
    }
    let store = AccountStore(); let sw = Switcher(store: store); let svc = UsageService()
    let original = store.activeNumber()
    print("START: config active=\(cfgActive()) store#=\(store.activeNumber().map(String.init) ?? "nil")")

    // 1) switch active -> #2 (teamacct, the maxed one)
    do { try sw.switchTo(2); print("[1] switchTo(#2) OK") }
    catch { print("[1] switchTo(#2) FAILED: \(error)") }
    print("    config active now=\(cfgActive()) store#=\(store.activeNumber().map(String.init) ?? "nil")")

    // 2) build accounts (cache-based meters returned even if refetch 429s)
    let accts = (try? svc.accounts()) ?? []
    let act = accts.first(where: { $0.isActive })
    print("[2] active acct=#\(act?.number ?? -1) \(act?.email ?? "?") maxPct=\(Int(act?.maxPct ?? 0))%")

    // 3) evaluate + perform auto-switch
    let cfg = CbarConfig.load()
    print("[3] config: enabled=\(cfg.autoSwitchEnabled) threshold=\(Int(cfg.autoSwitchThreshold))")
    if let target = autoSwitchTarget(accounts: accts, threshold: cfg.autoSwitchThreshold) {
        print("    autoSwitchTarget=#\(target) → rotating")
        do { try sw.switchTo(target); print("    rotated to #\(target) OK") }
        catch { print("    ROTATE FAILED: \(error)") }
    } else {
        print("    autoSwitchTarget=nil (would NOT rotate)")
    }
    print("    config active after rotate=\(cfgActive())")

    // 4) restore original active
    if let original { try? sw.switchTo(original); print("[4] restored active to #\(original) (\(cfgActive()))") }
    exit(0)
}

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
print("CODEX OK: \(cx!.meters.map { "\($0.id)=\(Int($0.pct))%" }.joined(separator: " "))")

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
assert(plan.first == 2, "active first")
assert(plan.contains(3) && plan.contains(5), "full pass: all stale fetched")
assert(!plan.contains(1) && !plan.contains(4), "skip fresh + backoff")
assert(plan.count == 3, "active + all eligible (not capped at 1)")
print("PACING OK")

// Auto-switch target selection
func mkAcc(_ n: Int, _ active: Bool, _ pct: Double, provider: String = "claude") -> Account {
    Account(id: "\(n)", number: n, email: "e\(n)", org: "", isActive: active, status: "ok",
            meters: [Meter(id: "5h", pct: pct, countdown: nil)], ageSeconds: 1, provider: provider)
}
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 95), mkAcc(2, false, 10), mkAcc(3, false, 50)], threshold: 94) == 2, "switch to most headroom")
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 50), mkAcc(2, false, 10)], threshold: 94) == nil, "below threshold -> no switch")
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 95), mkAcc(2, false, 96)], threshold: 94) == nil, "no better account -> no switch")
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 95), mkAcc(2, false, 10, provider: "codex")], threshold: 94) == nil, "codex not a switch target")
// cswap alignment: Fable/scoped excluded — 5h/7d low → no trigger even if Fable maxed
let fableActive = Account(id: "1", number: 1, email: "e1", org: "", isActive: true, status: "ok",
                          meters: [Meter(id: "5h", pct: 10, countdown: nil), Meter(id: "7d", pct: 20, countdown: nil), Meter(id: "Fbl", pct: 99, countdown: nil)],
                          ageSeconds: 1, provider: "claude")
assert(switchPct(fableActive) == 20, "switchPct ignores Fable")
assert(autoSwitchTarget(accounts: [fableActive, mkAcc(2, false, 5)], threshold: 94) == nil, "Fable 99% must not trigger (5h/7d low)")
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
