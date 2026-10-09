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
assert(cx!.meters[0].resetsAt == 2000003600, "session-file meters keep absolute reset")
assert(cx!.org == "OpenAI · team")
// Codex's post-2026-07-13 shape: one WEEKLY window in `primary`, `secondary`
// null. Labelled by position this read as "5h", four times smaller than the
// figure it claimed to be.
let codexWeeklyOnly = #"{"timestamp":"2026-07-30T00:55:50.000Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":2.0,"window_minutes":10080,"resets_at":2000090000},"secondary":null,"plan_type":"team"}}}"#
let cxWeek = CodexProvider.parse(codexWeeklyOnly, now: 2000000000)
assert(cxWeek?.meters.count == 1, "one window in, one meter out")
assert(cxWeek?.meters[0].id == "7d", "a 10080-minute window is 7d wherever it sits: \(cxWeek?.meters[0].id ?? "nil")")
assert(Int(cxWeek?.meters[0].pct ?? -1) == 2)
// Model-specific allowances are emitted as separate snapshots. Keep both the
// latest base allowance and Astra instead of returning whichever row came last.
let codexMultiLimit = codexLine + "\n" + #"{"timestamp":"2026-07-09T16:37:41.997Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex_astra","limit_name":"GPT-6 Astra","primary":{"used_percent":34.0,"window_minutes":300,"resets_at":2000007200},"secondary":null,"plan_type":"team"}}}"#
let cxMulti = CodexProvider.parse(codexMultiLimit, now: 2000000000)
assert(cxMulti?.meters.map(\.id) == ["5h", "7d", "Astra"], "base + Astra meters: \(cxMulti?.meters.map(\.id) ?? [])")
assert(Int(cxMulti?.meters.last?.pct ?? -1) == 34, "Astra usage")
// A later empty status/reason row cannot erase the last measured bucket.
let codexEmptyTail = codexMultiLimit + "\n" + #"{"timestamp":"2026-07-09T16:37:42.997Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex_astra","limit_name":"GPT-6 Astra","primary":null,"secondary":null,"plan_type":"team"}}}"#
assert(CodexProvider.parse(codexEmptyTail, now: 2000000000)?.meters.map(\.id) == ["5h", "7d", "Astra"])
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

// A session Codex refused at the limit holds only a reason-only `premium` row.
// It must not hide the last session that measured something — that reading is
// the one that says why (2026-09-15: three refused sessions blanked the card).
let cxFbDir = NSTemporaryDirectory() + "cbar-selftest-codex-fallback-\(getpid())"
try! FileManager.default.createDirectory(atPath: cxFbDir, withIntermediateDirectories: true)
func cxPut(_ name: String, _ content: String, mtime: Double) {
    try! content.write(toFile: cxFbDir + "/" + name, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)],
                                           ofItemAtPath: cxFbDir + "/" + name)
}
let codexRefused = #"{"timestamp":"2026-09-15T06:54:44.018Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"premium","limit_name":null,"primary":null,"secondary":null,"plan_type":null}}}"#
cxPut("measured.jsonl", codexLine, mtime: 1_000)
cxPut("refused-1.jsonl", codexRefused, mtime: 2_000)
cxPut("refused-2.jsonl", codexRefused, mtime: 3_000)
let cxFb = CodexProvider(sessionsDir: cxFbDir, walkTTL: 0)
assert(cxPct(cxFb) == 5, "refused sessions fall back to the newest one with a measured window")
assert(cxPct(cxFb) == 5, "a second pass, with the refused files remembered as barren, still finds it")
// Remembered as barren only while unchanged: a live session that starts
// measuring must take over, not stay written off.
cxPut("refused-2.jsonl", codexRefused + "\n" + codexLine.replacingOccurrences(of: "\"used_percent\":5.0", with: "\"used_percent\":77.0"), mtime: 4_000)
assert(cxPct(cxFb) == 77, "a barren session that gains a snapshot is read again")
try! FileManager.default.removeItem(atPath: cxFbDir + "/measured.jsonl")
cxPut("refused-2.jsonl", codexRefused, mtime: 5_000)
assert((try! cxFb.accounts()).isEmpty, "no measured session anywhere → no card, not a made-up one")
try? FileManager.default.removeItem(atPath: cxFbDir)
print("CODEX FALLBACK OK")

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
// `security -i` CUTS a line past 4096 bytes: the head stores a truncated secret,
// the tail comes back on stderr as an "unknown command", secret included. An
// oversized write must fail before `security` sees it, leave no item, and say
// nothing about the value (2026-09-16: a 4 KB Codex login did all three).
let kBig = String(repeating: "s3cr3t", count: 700)   // 4.2 KB, 5.6 KB as base64
var kBigErr = ""
do { try Keychain.set(service: ks, account: "big", value: kBig) } catch { kBigErr = "\(error)" }
assert(kBigErr.contains("too large"), "oversized write refused: \(kBigErr.prefix(120))")
assert(!kBigErr.contains("s3cr3t") && !kBigErr.contains(Data(kBig.utf8).base64EncodedString().prefix(40)),
       "the refusal never quotes the value")
let kBigStored = try? Keychain.get(service: ks, account: "big")
assert(kBigStored == .some(nil), "no truncated item left behind")
var kBigRawErr = ""
do { try Keychain.setRaw(service: ks, account: "big", value: kBig) } catch { kBigRawErr = "\(error)" }
assert(kBigRawErr.contains("too large"), "setRaw has the same guard")
// The largest line that fits still round-trips.
let kEdgeValue = String(repeating: "a", count: 3000)   // base64 4000 + command ≈ 4063 bytes
try! Keychain.set(service: ks, account: "edge", value: kEdgeValue)
assert(try! Keychain.get(service: ks, account: "edge") == kEdgeValue, "a value just under the limit round-trips intact")
try! Keychain.delete(service: ks, account: "edge")
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
let mrEpoch = ISO8601DateFormatter().date(from: "2035-01-02T03:04:05Z")!.timeIntervalSince1970
assert(mr.first?.resetsAt.map { abs($0 - mrEpoch) < 1 } == true, "resets_at lands on the meter as an absolute time")
assert(um.allSatisfy { $0.resetsAt == nil }, "null / missing resets_at -> no absolute reset")
// soonestReset: earliest absolute reset across windows (epoch), nil when none present
let resetJson = #"{"five_hour":{"utilization":50.0,"resets_at":"2035-01-02T03:04:05+00:00"},"seven_day":{"utilization":20.0,"resets_at":"2035-01-01T00:00:00+00:00"}}"#
let sr = UsageMapper.soonestReset(from: Data(resetJson.utf8))
let earliest = ISO8601DateFormatter().date(from: "2035-01-01T00:00:00Z")!.timeIntervalSince1970
assert(sr != nil && abs(sr! - earliest) < 1, "soonestReset returns the earliest window's reset")
assert(UsageMapper.soonestReset(from: Data(#"{"five_hour":{"utilization":1.0,"resets_at":null}}"#.utf8)) == nil,
       "no resets_at → nil")
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
// …and must not do that to a DIRECTORY: 0600 drops the x bit and locks the owner
// out of everything inside (codex/ and codex-login/ lost on every launch).
let secSub = secDir + "/codex"
try FileManager.default.createDirectory(atPath: secSub, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o755])
FileManager.default.createFile(atPath: secSub + "/1.sealed", contents: Data("x".utf8))
SecureFile.tightenAll(dir: secDir)
assert(mode(secSub) == 0o700, "startup sweep gives a subdirectory 0700, got \(mode(secSub).map { String($0, radix: 8) } ?? "nil")")
assert((try? Data(contentsOf: URL(fileURLWithPath: secSub + "/1.sealed"))) != nil, "files inside stay readable")
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

// Hot-reload on reset: a window that rolled over (now past resetsAt, no fetch
// since) outranks a merely-staler alternate AND an aged-out active — a wrong
// number beats an old one. Self-clearing once a fetch lands after the reset.
let rolled = [
    PaceRow(number: 11, fetchedAt: t0 - 500, backoffUntil: nil, lastAttemptAt: nil),                    // staler, no reset
    PaceRow(number: 12, fetchedAt: t0 - 100, backoffUntil: nil, lastAttemptAt: nil, resetsAt: t0 - 10), // rolled 10s ago
    PaceRow(number: 13, fetchedAt: t0 - 300, backoffUntil: nil, lastAttemptAt: nil),                    // active, aged out
]
assert(fetchPlan(now: t0, active: 13, rows: rolled) == [12], "rolled-over window hot-reloads first")
// a fetch that landed after the reset (fetchedAt ≥ resetsAt) no longer fires
let cleared = [
    PaceRow(number: 11, fetchedAt: t0 - 500, backoffUntil: nil, lastAttemptAt: nil),
    PaceRow(number: 12, fetchedAt: t0 - 40, backoffUntil: nil, lastAttemptAt: nil, resetsAt: t0 - 100),
]
assert(fetchPlan(now: t0, active: nil, rows: cleared) == [11], "fetch after reset clears hot-reload → stalest wins")
// a reset still in the future is just a stale row, not a hot-reload
let notYet = [
    PaceRow(number: 11, fetchedAt: t0 - 500, backoffUntil: nil, lastAttemptAt: nil),
    PaceRow(number: 12, fetchedAt: t0 - 100, backoffUntil: nil, lastAttemptAt: nil, resetsAt: t0 + 600),
]
assert(fetchPlan(now: t0, active: nil, rows: notYet) == [11], "future reset does not hot-reload → stalest wins")
// backoff still gates a rolled-over row (don't hammer a failing endpoint)
let rolledBackoff = [PaceRow(number: 14, fetchedAt: t0 - 100, backoffUntil: t0 + 60, lastAttemptAt: nil, resetsAt: t0 - 10)]
assert(fetchPlan(now: t0, active: nil, rows: rolledBackoff).isEmpty, "backoff gates hot-reload too")

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
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 95), mkAcc(2, false, 10, provider: "grok")], threshold: 94) == nil, "grok not a switch target")
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 95), mkAcc(2, false, 10, provider: "antigravity")], threshold: 94) == nil, "antigravity not a switch target")
assert(mkAcc(1, false, 10, provider: "grok").switchable == false)
assert(mkAcc(1, false, 10, provider: "antigravity").switchable == false)
assert(Account(id: "g", number: 1, email: "g", org: "", isActive: true, status: "ok",
               meters: [Meter(id: "7d", pct: 99, countdown: nil)], ageSeconds: 1, provider: "grok").switchable == false)
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

// Pre-warm scheduler: burn ONE account, take excursions to open COLD idles' 5h
// windows, then RETURN to the burn account. `active` is passed as a slot number.
func warm7d(_ n: Int, active: Bool, fiveH: Double, sevenD: Double, status: String = "ok", age: Double = 1) -> Account {
    Account(id: "\(n)", number: n, email: "e\(n)", org: "", isActive: active, status: status,
            meters: [Meter(id: "5h", pct: fiveH, countdown: nil), Meter(id: "7d", pct: sevenD, countdown: nil)],
            ageSeconds: age, provider: "claude")
}

// --- burnHome: soonest 7d reset among healthy slots below the escape threshold;
// with no reset known it falls back to the highest 5h ---
assert(burnHome([acc7d(1, false, fiveH: 40, sevenD: 10),
                 acc7d(2, false, fiveH: 61, sevenD: 20),
                 acc7d(3, false, fiveH: 55, sevenD: 20)]) == 2, "burn home = highest 5h under threshold")
assert(burnHome([acc7d(1, false, fiveH: 95, sevenD: 10),      // over threshold -> excluded
                 acc7d(2, false, fiveH: 40, sevenD: 20)]) == 2, "burn home excludes >= escape threshold")

// The 2026-10-05 state: both just pre-warmed, #2 a point higher, but #1's week
// resets in 16h against #2's 5 days -> burn #1.
func accReset(_ n: Int, _ active: Bool, fiveH: Double, sevenD: Double, resetIn: Double?) -> Account {
    Account(id: "\(n)", number: n, email: "e\(n)", org: "", isActive: active, status: "ok",
            meters: [Meter(id: "5h", pct: fiveH, countdown: nil),
                     Meter(id: "7d", pct: sevenD, countdown: nil, resetsAt: resetIn.map { 1000 + $0 })],
            ageSeconds: 1, provider: "claude")
}
assert(burnHome([accReset(1, false, fiveH: 5, sevenD: 31, resetIn: 16 * 3600),
                 accReset(2, true, fiveH: 6, sevenD: 34, resetIn: 5 * 86400)], now: 1000) == 1, "burn home = soonest 7d reset, not highest 5h")
assert(preWarmMove(accounts: [accReset(1, false, fiveH: 5, sevenD: 31, resetIn: 16 * 3600),
                              accReset(2, true, fiveH: 6, sevenD: 34, resetIn: 5 * 86400)], active: 2, now: 1000) == 1, "return to the soonest-reset account")
assert(preWarmMove(accounts: [accReset(1, true, fiveH: 5, sevenD: 31, resetIn: 16 * 3600),
                              accReset(2, false, fiveH: 60, sevenD: 34, resetIn: 5 * 86400)], active: 1, now: 1000) == nil, "on the soonest-reset account -> stay, however high the other's 5h")
// soonest-reset slot over the threshold -> the next one is home.
assert(burnHome([accReset(1, false, fiveH: 95, sevenD: 31, resetIn: 16 * 3600),
                 accReset(2, false, fiveH: 6, sevenD: 34, resetIn: 5 * 86400)], now: 1000) == 2, "soonest reset over threshold is excluded")
// unknown or already-passed reset ranks behind a known one.
assert(burnHome([accReset(1, false, fiveH: 60, sevenD: 31, resetIn: nil),
                 accReset(2, false, fiveH: 6, sevenD: 34, resetIn: 5 * 86400)], now: 1000) == 2, "unknown reset ranks last")
assert(burnHome([accReset(1, false, fiveH: 60, sevenD: 31, resetIn: -60),
                 accReset(2, false, fiveH: 6, sevenD: 34, resetIn: 5 * 86400)], now: 1000) == 2, "a reset in the past is unknown")
// same reset -> highest 5h, then lowest number.
assert(burnHome([accReset(1, false, fiveH: 6, sevenD: 31, resetIn: 3600),
                 accReset(2, false, fiveH: 40, sevenD: 34, resetIn: 3600)], now: 1000) == 2, "reset tie -> highest 5h")
assert(burnHome([accReset(1, false, fiveH: 6, sevenD: 31, resetIn: 3600),
                 accReset(2, false, fiveH: 6, sevenD: 34, resetIn: 3600)], now: 1000) == 1, "full tie -> lowest number")

// --- excursion: prime a COLD idle while burning #1(60%) ---
// two cold idles -> the cheapest weekly one.
assert(preWarmMove(accounts: [acc7d(1, true, fiveH: 60, sevenD: 30),
                              acc7d(2, false, fiveH: 0, sevenD: 85),
                              acc7d(3, false, fiveH: 0, sevenD: 20)], active: 1) == 3, "excursion primes lowest-weekly cold idle")
// weekly beats 5h: #2 5h0/7d85 vs #3 5h3/7d20 -> #3, though #2 has the lower 5h.
assert(preWarmMove(accounts: [acc7d(1, true, fiveH: 60, sevenD: 30),
                              acc7d(2, false, fiveH: 0, sevenD: 85),
                              acc7d(3, false, fiveH: 3, sevenD: 20)], active: 1) == 3, "excursion weekly beats 5h")
// weekly tie -> freshest 5h; lower 5h on the HIGHER slot number kills number-first.
assert(preWarmMove(accounts: [acc7d(1, true, fiveH: 60, sevenD: 10),
                              acc7d(2, false, fiveH: 3, sevenD: 50),
                              acc7d(3, false, fiveH: 0, sevenD: 50)], active: 1) == 3, "excursion weekly tie -> lowest 5h")
// dead idle (needs-reauth), cheapest weekly, is skipped for the healthy one.
assert(preWarmMove(accounts: [acc7d(1, true, fiveH: 60, sevenD: 30),
                              warm7d(2, active: false, fiveH: 0, sevenD: 10, status: "needs-reauth"),
                              acc7d(3, false, fiveH: 0, sevenD: 40)], active: 1) == 3, "dead cheap idle skipped for healthy")
// ≥95% weekly idle isn't primed; nothing else cold -> stay on the burn account.
assert(preWarmMove(accounts: [acc7d(1, true, fiveH: 60, sevenD: 30),
                              acc7d(2, false, fiveH: 0, sevenD: 97)], active: 1) == nil, "don't prime a ≥95% weekly idle")
// ...but that idle is NOT stranded: escape still uses it when it's the only
// capacity left (7d<99).
assert(autoSwitchTarget(accounts: [acc7d(1, true, fiveH: 10, sevenD: 100),
                                   acc7d(2, false, fiveH: 40, sevenD: 95)], threshold: 93) == 2,
       "escape still uses a 95% slot when everything else is exhausted")
// exhausted idle (7d99) is never primed.
assert(preWarmMove(accounts: [acc7d(1, true, fiveH: 60, sevenD: 10),
                              acc7d(2, false, fiveH: 0, sevenD: 99)], active: 1) == nil, "exhausted idle is not primed")
// idle with NO 7d meter is not treated as 0% weekly (not primed).
let idleNo7d = Account(id: "2", number: 2, email: "e2", org: "", isActive: false, status: "ok",
                       meters: [Meter(id: "5h", pct: 0, countdown: nil)], ageSeconds: 1, provider: "claude")
assert(preWarmMove(accounts: [acc7d(1, true, fiveH: 60, sevenD: 30), idleNo7d], active: 1) == nil, "idle w/o 7d meter not primed")

// --- keep warming / advance ---
// a low healthy active is used until it crosses target — don't abandon it for
// another cold idle mid-warm.
assert(preWarmMove(accounts: [acc7d(1, true, fiveH: 2, sevenD: 20),
                              acc7d(2, false, fiveH: 0, sevenD: 30)], active: 1) == nil, "keep warming the low active")
// once warmed, move on to the next cold idle.
assert(preWarmMove(accounts: [acc7d(1, true, fiveH: 5, sevenD: 20),
                              acc7d(2, false, fiveH: 0, sevenD: 40)], active: 1) == 2, "warmed active -> excursion to next cold idle")

// --- RETURN to the burn account (the fix) ---
// parked on a just-warmed idle #1(23%) with no cold idle left -> hand the login
// back to the burn account #2(61%). An earlier design stayed and burned the wrong
// account.
assert(preWarmMove(accounts: [acc7d(1, true, fiveH: 23, sevenD: 3),
                              acc7d(2, false, fiveH: 61, sevenD: 78)], active: 1) == 2, "return to the burn account")
// on the burn account with nothing cold -> stay (home == active).
assert(preWarmMove(accounts: [acc7d(1, true, fiveH: 61, sevenD: 78),
                              acc7d(2, false, fiveH: 23, sevenD: 3)], active: 1) == nil, "on burn account, nothing cold -> stay")

// --- active-reading guards ---
// stale / re-auth active -> stay put (don't churn on an unknown reading). 5h=60 so
// only the freshness guard can hold it.
assert(preWarmMove(accounts: [warm7d(1, active: true, fiveH: 60, sevenD: 20, status: "needs-reauth"),
                              acc7d(2, false, fiveH: 0, sevenD: 20)], active: 1) == nil, "re-auth active -> stay")
assert(preWarmMove(accounts: [warm7d(1, active: true, fiveH: 60, sevenD: 20, age: 700),
                              acc7d(2, false, fiveH: 0, sevenD: 20)], active: 1) == nil, "stale active -> stay")
// exhausted / weekly-tight active is a GOOD reading -> divert off it to a healthy
// idle (kills the 7d<95 leg and confirms exhausted isn't frozen).
assert(preWarmMove(accounts: [acc7d(1, true, fiveH: 3, sevenD: 99),
                              acc7d(2, false, fiveH: 0, sevenD: 20)], active: 1) == 2, "exhausted active diverts")
assert(preWarmMove(accounts: [acc7d(1, true, fiveH: 2, sevenD: 97),
                              acc7d(2, false, fiveH: 0, sevenD: 20)], active: 1) == 2, "weekly-tight active diverts")
// active missing 5h meter -> stay (undecidable); 7d=97 would wrongly divert if the
// 5h-meter leg were dropped.
let activeNo5h = Account(id: "1", number: 1, email: "e1", org: "", isActive: true, status: "ok",
                         meters: [Meter(id: "7d", pct: 97, countdown: nil)], ageSeconds: 1, provider: "claude")
assert(preWarmMove(accounts: [activeNo5h, acc7d(2, false, fiveH: 0, sevenD: 20)], active: 1) == nil, "active w/o 5h meter -> stay")
// active missing 7d meter -> stay (can't judge weekly).
let activeNo7d = Account(id: "1", number: 1, email: "e1", org: "", isActive: true, status: "ok",
                         meters: [Meter(id: "5h", pct: 2, countdown: nil)], ageSeconds: 1, provider: "claude")
assert(preWarmMove(accounts: [activeNo7d, acc7d(2, false, fiveH: 0, sevenD: 20)], active: 1) == nil, "active w/o 7d meter -> stay")
// freshness boundary: 600s acts, 601s stays.
assert(preWarmMove(accounts: [warm7d(1, active: true, fiveH: 60, sevenD: 20, age: 600),
                              acc7d(2, false, fiveH: 0, sevenD: 20)], active: 1) == 2, "active at 600s still acts")
assert(preWarmMove(accounts: [warm7d(1, active: true, fiveH: 60, sevenD: 20, age: 601),
                              acc7d(2, false, fiveH: 0, sevenD: 20)], active: 1) == nil, "active past 600s -> stay")

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

// ---- pollsWhileDark: keep working behind a sleeping display ------------------
// Armed AND in use. Before this, screen sleep hard-stopped the poll timer, so an
// unattended overnight session rode its account into the wall with cbar sitting
// next to it holding the answer.
assert(pollsWhileDark(autoSwitchEnabled: true, preWarmEnabled: false, claudeCodeRunning: true),
       "armed + session running -> poll in the dark")
assert(pollsWhileDark(autoSwitchEnabled: false, preWarmEnabled: true, claudeCodeRunning: true),
       "pre-warm alone still counts as armed")
assert(!pollsWhileDark(autoSwitchEnabled: true, preWarmEnabled: true, claudeCodeRunning: false),
       "no session -> nothing to rotate, stay dark")
assert(!pollsWhileDark(autoSwitchEnabled: false, preWarmEnabled: false, claudeCodeRunning: true),
       "unarmed -> the answer is unusable, stay dark")

// The arming check must short-circuit BEFORE the running check, because the real
// caller passes a pgrep spawn there and an unarmed cbar should pay nothing per
// dark tick.
var probeCalls = 0
func runningProbe() -> Bool { probeCalls += 1; return true }
_ = pollsWhileDark(autoSwitchEnabled: false, preWarmEnabled: false, claudeCodeRunning: runningProbe())
assert(probeCalls == 0, "unarmed must not spawn the running check, got \(probeCalls) calls")
_ = pollsWhileDark(autoSwitchEnabled: true, preWarmEnabled: false, claudeCodeRunning: runningProbe())
assert(probeCalls == 1, "armed evaluates the running check exactly once, got \(probeCalls)")
print("POLLS WHILE DARK OK")

// ---- Codex accounts: login file, store, switch, refresh guard, service -------
// Everything here runs on fake JWTs, temp dirs and throwaway Keychain services —
// never `~/.codex` or the `cbar-codex` items.
let cxNow = 2_000_000_000.0   // 2033-05-18T03:33:20Z
func cxJWT(_ claims: [String: Any]) -> String {
    let b64 = (try! JSONSerialization.data(withJSONObject: claims)).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "eyJhbGciOiJub25lIn0.\(b64).sig"
}
func cxAccessJWT(user: String, account: String, plan: String, exp: Double, iat: Double? = nil, tag: String) -> String {
    // Real Codex JWTs run ~1.8 KB each, which is what broke the first storage
    // design (a Keychain line limit); tokens this size keep that tested.
    cxJWT(["exp": Int(exp), "iat": Int(iat ?? exp - 864_000), "jti": tag, "sub": "sub-\(user)",
           "pad": String(repeating: "p", count: 1400),
           "https://api.openai.com/auth": ["chatgpt_account_id": account, "chatgpt_user_id": user, "chatgpt_plan_type": plan]])
}
func cxAuth(user: String, account: String, email: String, plan: String, exp: Double, iat: Double? = nil,
            tag: String, tokenAccount: String? = nil, extra: [String: Any] = [:]) -> Data {
    var o: [String: Any] = [
        "auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(),
        "tokens": ["id_token": cxJWT(["email": email, "pad": String(repeating: "p", count: 1400)]),
                   "access_token": cxAccessJWT(user: user, account: account, plan: plan, exp: exp, iat: iat, tag: tag),
                   "refresh_token": "rt-\(tag)", "account_id": tokenAccount ?? account],
        "last_refresh": "2026-09-11T02:16:20.537098Z",
    ]
    extra.forEach { o[$0.key] = $0.value }
    return try! JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted])
}
// Hoisted out of every assert below: these attempt real writes, and `assert` is
// compiled out in release.
func cxThrows(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}
let cxAPIKeyFile = Data(#"{"OPENAI_API_KEY":"sk-x","tokens":null}"#.utf8)

let cxA = CodexLogin(raw: cxAuth(user: "user-a", account: "acct-team", email: "a@x.com", plan: "team",
                                 exp: cxNow + 86_400, tag: "a1", extra: ["future_field": "kept"]))!
assert(cxA.accountId == "acct-team" && cxA.userId == "user-a" && cxA.email == "a@x.com" && cxA.plan == "team",
       "identity, email and plan come out of the tokens")
assert(cxA.identity == "user-a|acct-team")
assert(cxA.raw.count > 4096, "fixture is real-sized (\(cxA.raw.count) bytes)")
assert(!cxA.isExpired(now: cxNow) && cxA.isExpired(now: cxNow + 86_400 - 200), "expiry uses Codex's 5-minute window")
assert(CodexLogin(raw: cxAPIKeyFile) == nil, "an API-key login is not a token login")
assert(CodexLogin(raw: Data(#"{"tokens":{"access_to"#.utf8)) == nil, "a half-written auth.json is not a login")
// Same Team workspace, different person: one account id, two identities.
let cxTeammate = CodexLogin(raw: cxAuth(user: "user-b", account: "acct-team", email: "b@x.com", plan: "team",
                                        exp: cxNow + 86_400, tag: "b1"))!
assert(cxTeammate.identity != cxA.identity, "a shared workspace account id does not make two people one login")
// Mixed: B's account_id around A's tokens — what Codex's persist_tokens leaves
// when a switch lands inside its refresh. Neither half may be trusted.
assert(CodexLogin(raw: cxAuth(user: "user-a", account: "acct-team", email: "a@x.com", plan: "team",
                              exp: cxNow + 86_400, tag: "mx", tokenAccount: "acct-pro")) == nil,
       "a file whose account_id disagrees with its access token is rejected")
// No chatgpt_user_id claim: fall back to `sub`, never to an empty user.
let cxNoUserClaims = cxJWT(["exp": Int(cxNow + 86_400), "sub": "sub-z",
                            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-z"]])
let cxNoUser = CodexLogin(raw: try! JSONSerialization.data(withJSONObject: [
    "tokens": ["access_token": cxNoUserClaims, "refresh_token": "rt-z", "account_id": "acct-z"]]))
assert(cxNoUser?.identity == "sub-z|acct-z", "identity falls back to sub: \(cxNoUser?.identity ?? "nil")")

// A refresh replaces only the tokens that came back, like Codex's persist_tokens.
let cxRefreshedAccess = cxAccessJWT(user: "user-a", account: "acct-team", plan: "team", exp: cxNow + 864_000, iat: cxNow, tag: "a2")
let cxA2 = cxA.refreshed(idToken: nil, accessToken: cxRefreshedAccess, refreshToken: "rt-a2",
                         now: Date(timeIntervalSince1970: cxNow))!
assert(cxA2.refreshToken == "rt-a2" && cxA2.accessToken == cxRefreshedAccess && cxA2.identity == cxA.identity)
assert(cxA2.email == "a@x.com", "id token kept when the response carries none")
assert(cxA2.issuedAt == cxNow && (cxA.issuedAt ?? 0) < cxNow, "iat orders two copies of one login")
let cxA2Obj = try! JSONSerialization.jsonObject(with: cxA2.raw) as! [String: Any]
assert(cxA2Obj["future_field"] as? String == "kept", "auth.json keys cbar doesn't model survive a refresh")
assert((cxA2Obj["last_refresh"] as? String)?.hasPrefix("2033-05-18T03:33:20") == true, "last_refresh stamped")

// config.toml: only a TOP-LEVEL cli_auth_credentials_store counts.
let cxHome = NSTemporaryDirectory() + "cbar-selftest-codexhome-\(getpid())"
try! FileManager.default.createDirectory(atPath: cxHome, withIntermediateDirectories: true)
func cxToml(_ s: String) { try! s.write(toFile: cxHome + "/config.toml", atomically: true, encoding: .utf8) }
assert(CodexLive.credentialsStore(home: cxHome) == nil, "no config.toml → default (file)")
cxToml("model = \"x\"\ncli_auth_credentials_store = \"keyring\" # why not\n[projects.\"/a\"]\ntrust_level = \"trusted\"\n")
assert(CodexLive.credentialsStore(home: cxHome) == "keyring")
cxToml("[projects.\"/a\"]\ncli_auth_credentials_store = \"keyring\"\n")
assert(CodexLive.credentialsStore(home: cxHome) == nil, "a key inside a table is not the setting")
cxToml("cli_auth_credentials_store = \"file\"\r\nmodel = \"x\"\r\n")
assert(CodexLive.credentialsStore(home: cxHome) == "file", "CRLF line endings")
cxToml("cli_auth_credentials_store_v2 = \"keyring\"\n")
assert(CodexLive.credentialsStore(home: cxHome) == nil, "a longer key name is a different key")
cxToml("xs = [\n  [1, 2],\n]\ncli_auth_credentials_store = \"keyring\"\n")
assert(CodexLive.credentialsStore(home: cxHome) == "keyring", "an array row starting with [ is not a table header")
try! FileManager.default.removeItem(atPath: cxHome + "/config.toml")

// Live file states.
let cxAuthPath = cxHome + "/auth.json"
if case .missing = CodexLive.read(home: cxHome) {} else { assertionFailure("no auth.json → missing") }
try! cxAPIKeyFile.write(to: URL(fileURLWithPath: cxAuthPath))
if case .notTokenLogin = CodexLive.read(home: cxHome) {} else { assertionFailure("API-key auth.json → notTokenLogin") }
try! Data(#"{"tokens":{"access_to"#.utf8).write(to: URL(fileURLWithPath: cxAuthPath))
if case .unusable = CodexLive.read(home: cxHome) {} else { assertionFailure("half-written auth.json → unusable") }

// Store: add, dedup by identity, sealed round-trip, numbering, remove.
let cxStoreDir = NSTemporaryDirectory() + "cbar-selftest-codexstore-\(getpid())"
let cxSvc = "cbar-selftest-codex-\(getpid())"
let cxStore = CodexAccountStore(dir: cxStoreDir, keychainService: cxSvc)
let cxB = CodexLogin(raw: cxAuth(user: "user-a", account: "acct-pro", email: "a@x.com", plan: "prolite",
                                 exp: cxNow + 86_400, tag: "p1"))!
let cxN1 = try cxStore.add(cxA)
let cxN2 = try cxStore.add(cxB)
assert(cxN1 == 1 && cxN2 == 2 && cxStore.list().count == 2, "two identities, two slots")
let cxN1Again = try cxStore.add(cxA2)
assert(cxN1Again == cxN1 && cxStore.list().count == 2, "re-capturing a login lands in its own slot")
let cxStoredA = try cxStore.login(cxN1)
assert(cxStoredA?.raw == cxA2.raw, "the stored login is the file verbatim")
assert(cxStore.slot(for: cxA) == cxN1 && cxStore.slot(for: cxTeammate) == nil)
assert(cxStore.list().first { $0.number == cxN2 }?.plan == "prolite")
// Sealed on disk, key in the Keychain: a fresh store instance (the next launch)
// opens what this one sealed, and the file itself holds no token text.
let cxReopened = try CodexAccountStore(dir: cxStoreDir, keychainService: cxSvc).login(cxN1)
assert(cxReopened?.raw == cxA2.raw, "another store instance opens the sealed login")
let cxSealedPath = cxStoreDir + "/codex/\(cxN1).sealed"
let cxSealedBytes = try Data(contentsOf: URL(fileURLWithPath: cxSealedPath))
assert(cxSealedBytes.range(of: Data("rt-a2".utf8)) == nil && cxSealedBytes.range(of: Data("acct-team".utf8)) == nil,
       "no token or identity in the sealed file")
let cxSealedMode = (try! FileManager.default.attributesOfItem(atPath: cxSealedPath)[.posixPermissions] as! NSNumber).intValue
assert(cxSealedMode == 0o600, "sealed login is owner-only")
// A sealed login that exists but can't be read is an error, not an empty slot.
try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: cxSealedPath)
let cxUnreadable = cxThrows { _ = try CodexAccountStore(dir: cxStoreDir, keychainService: cxSvc).login(cxN1) }
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cxSealedPath)
assert(cxUnreadable, "an unreadable sealed login throws instead of reading as 'no login'")

// Switcher. The outgoing login goes back into ITS slot before the file changes.
var cxCodexUp = false
let cxSwitcher = CodexSwitcher(store: cxStore, home: cxHome, codexRunning: { cxCodexUp })
let cxALive = CodexLogin(raw: cxAuth(user: "user-a", account: "acct-team", email: "a@x.com", plan: "team",
                                     exp: cxNow + 900_000, iat: cxNow + 36_000, tag: "a9"))!   // Codex refreshed since capture
try! cxALive.raw.write(to: URL(fileURLWithPath: cxAuthPath))
try cxSwitcher.switchTo(cxN2, now: cxNow)
let cxBackedUp = try cxStore.login(cxN1)
assert(cxBackedUp?.refreshToken == "rt-a9", "outgoing slot backed up with the live, newer tokens")
assert((try! Data(contentsOf: URL(fileURLWithPath: cxAuthPath))) == cxB.raw, "live auth.json is now B, byte for byte")
let cxMode = (try! FileManager.default.attributesOfItem(atPath: cxAuthPath)[.posixPermissions] as! NSNumber).intValue
assert(cxMode == 0o600, "auth.json written owner-only, got \(String(cxMode, radix: 8))")
assert((try! FileManager.default.contentsOfDirectory(atPath: cxHome)).allSatisfy { !$0.contains(".cbar-") }, "no temp file left")
try cxSwitcher.switchTo(cxN2, now: cxNow)   // already live: a no-op, not a self-backup loop
// A running Codex due to refresh could write its rotated tokens into the file
// cbar just switched in — so while one might be mid-refresh, wait.
try! cxALive.raw.write(to: URL(fileURLWithPath: cxAuthPath))
cxCodexUp = true
let cxDeferred = cxThrows { try cxSwitcher.switchTo(cxN2, now: cxNow + 900_000 - 200) }
assert(cxDeferred, "live login due for refresh + Codex running → switch deferred")
assert((try! Data(contentsOf: URL(fileURLWithPath: cxAuthPath))) == cxALive.raw, "…and the file untouched")
cxCodexUp = false
try cxSwitcher.switchTo(cxN2, now: cxNow + 900_000 - 200)
assert((try! Data(contentsOf: URL(fileURLWithPath: cxAuthPath))) == cxB.raw, "no Codex running → nothing can be mid-refresh, switch")
// A login cbar never saved is never overwritten — it could not be put back.
try! cxTeammate.raw.write(to: URL(fileURLWithPath: cxAuthPath))
let cxRefusedUnmanaged = cxThrows { try cxSwitcher.switchTo(cxN1, now: cxNow) }
assert(cxRefusedUnmanaged, "unmanaged live login refuses the switch")
assert((try! Data(contentsOf: URL(fileURLWithPath: cxAuthPath))) == cxTeammate.raw, "…and leaves it untouched")
// Neither is an API-key file, nor a mixed one.
try! cxAPIKeyFile.write(to: URL(fileURLWithPath: cxAuthPath))
let cxRefusedAPIKey = cxThrows { try cxSwitcher.switchTo(cxN1, now: cxNow) }
assert(cxRefusedAPIKey, "API-key auth.json refuses the switch")
try! cxAuth(user: "user-a", account: "acct-team", email: "a@x.com", plan: "team", exp: cxNow + 86_400,
            tag: "mx", tokenAccount: "acct-pro").write(to: URL(fileURLWithPath: cxAuthPath))
let cxRefusedMixed = cxThrows { try cxSwitcher.switchTo(cxN1, now: cxNow) }
assert(cxRefusedMixed, "mixed auth.json refuses the switch")
// Logged out: nothing to lose, so write.
try! FileManager.default.removeItem(atPath: cxAuthPath)
try cxSwitcher.switchTo(cxN1, now: cxNow)
let cxWritten = CodexLogin(raw: try Data(contentsOf: URL(fileURLWithPath: cxAuthPath)))
assert(cxWritten?.identity == cxA.identity, "logged out → switch writes")
// Keyring-backed Codex: rewriting auth.json would switch nothing.
cxToml("cli_auth_credentials_store = \"auto\"\n")
let cxRefusedKeyring = cxThrows { try cxSwitcher.switchTo(cxN2, now: cxNow) }
assert(cxRefusedKeyring, "non-file credential store refuses the switch")
try! FileManager.default.removeItem(atPath: cxHome + "/config.toml")

// Refresh guard: cbar refreshes only a token nothing else can hold.
let cxLiveA: CodexLive.State = .login(cxA2)
assert(CodexUsageService.shouldSkipRefresh(n: 1, liveSlot: 1, live: cxLiveA, slotRefresh: "rt-a2"), "live slot: Codex's to refresh")
assert(!CodexUsageService.shouldSkipRefresh(n: 2, liveSlot: 1, live: cxLiveA, slotRefresh: "rt-p1"), "idle slot: cbar's")
assert(CodexUsageService.shouldSkipRefresh(n: 2, liveSlot: nil, live: cxLiveA, slotRefresh: "rt-a2"), "same refresh token as live, whatever the slot")
assert(CodexUsageService.shouldSkipRefresh(n: 2, liveSlot: nil, live: .unusable, slotRefresh: "rt-p1"), "unusable live file: wait")
assert(!CodexUsageService.shouldSkipRefresh(n: 2, liveSlot: nil, live: .notTokenLogin, slotRefresh: "rt-p1"), "API-key live login holds none of cbar's tokens")
assert(!CodexUsageService.shouldSkipRefresh(n: 2, liveSlot: nil, live: .missing, slotRefresh: "rt-p1"), "logged out: nobody holds it")
assert(CodexClient.isTerminalRefreshFailure(status: 401, body: ""))
assert(CodexClient.isTerminalRefreshFailure(status: 400, body: #"{"error":"invalid_grant"}"#))
assert(CodexClient.isTerminalRefreshFailure(status: 400, body: #"{"error":{"code":"refresh_token_reused"}}"#))
assert(!CodexClient.isTerminalRefreshFailure(status: 500, body: "upstream"), "a 5xx backs off, it doesn't demand a login")

// Inbox: `codex login` must find its CODEX_HOME, and must find it EMPTY.
let cxInbox = CodexLoginInbox(dir: NSTemporaryDirectory() + "cbar-selftest-codexinbox-\(getpid())", home: cxHome)
let cxPreparedEmpty = try cxInbox.prepare(importingInto: cxStore)
assert(cxPreparedEmpty == nil)
var cxIsDir: ObjCBool = false
assert(FileManager.default.fileExists(atPath: cxInbox.dir, isDirectory: &cxIsDir) && cxIsDir.boolValue, "prepare creates the directory")
assert(cxInbox.command.contains("CODEX_HOME=") && cxInbox.command.hasSuffix("codex login"))
try! Data(#"{"tokens":{"access_to"#.utf8).write(to: URL(fileURLWithPath: cxInbox.dir + "/auth.json"))
let cxHalf = try cxInbox.importIfPresent(into: cxStore)
assert(cxHalf == nil, "still being written → wait")
let cxC = CodexLogin(raw: cxAuth(user: "user-c", account: "acct-plus", email: "c@x.com", plan: "plus",
                                 exp: cxNow + 86_400, tag: "c1"))!
try! cxC.raw.write(to: URL(fileURLWithPath: cxInbox.dir + "/auth.json"))
try! Data("x".utf8).write(to: URL(fileURLWithPath: cxInbox.dir + "/installation_id"))
// A startup sweep from an older build may have locked the inbox; prepare must
// still import what's in it rather than clear it unread.
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cxInbox.dir)
let cxN3 = try cxInbox.prepare(importingInto: cxStore)
assert(cxN3 == 3 && cxStore.slot(for: cxC) == 3, "a login left in the inbox is imported before it is cleared")
assert((try! FileManager.default.contentsOfDirectory(atPath: cxInbox.dir)).isEmpty, "inbox emptied, directory kept")
// Re-login to the LIVE account through the inbox replaces the live file too —
// importing only into the slot was undone by the same poll's heal.
let cxAReLogin = CodexLogin(raw: cxAuth(user: "user-a", account: "acct-team", email: "a@x.com", plan: "team",
                                        exp: cxNow + 1_000_000, iat: cxNow + 100_000, tag: "a-relogin"))!
try! cxAReLogin.raw.write(to: URL(fileURLWithPath: cxInbox.dir + "/auth.json"))
let cxRelogged = try cxInbox.importIfPresent(into: cxStore)
assert(cxRelogged == cxN1, "re-login lands in the account's slot")
let cxLiveAfterRelogin = CodexLogin(raw: try Data(contentsOf: URL(fileURLWithPath: cxAuthPath)))
assert(cxLiveAfterRelogin?.refreshToken == "rt-a-relogin", "…and replaces the live login it re-logged")

// Numbers are never reused: a removed slot's cached usage must not dress up
// the next account.
try cxStore.remove(cxN3!)
let cxD = CodexLogin(raw: cxAuth(user: "user-d", account: "acct-d", email: "d@x.com", plan: "plus",
                                 exp: cxNow + 86_400, tag: "d1"))!
let cxN4 = try cxStore.add(cxD)
assert(cxN4 == 4, "slot number after removing #3 is 4, got \(cxN4)")

for n in [cxN1, cxN2, cxN4] { try cxStore.remove(n) }
let cxGone = try cxStore.login(cxN1)
assert(cxStore.list().isEmpty && cxGone == nil, "removed")
// A sealed login whose key is gone says so, instead of reading as "no login";
// a malformed key is never silently replaced.
try cxStore.setLogin(9, cxA)
try Keychain.set(service: cxSvc, account: CodexAccountStore.keyAccount, value: "not-a-key")
let cxBadKey = cxThrows { try CodexAccountStore(dir: cxStoreDir, keychainService: cxSvc).setLogin(10, cxA) }
assert(cxBadKey, "a malformed key item stops writes instead of being replaced")
try? Keychain.delete(service: cxSvc, account: CodexAccountStore.keyAccount)
let cxKeyless = cxThrows { _ = try CodexAccountStore(dir: cxStoreDir, keychainService: cxSvc).login(9) }
assert(cxKeyless, "a login that can't be opened throws")
for p in [cxHome, cxStoreDir, cxInbox.dir] { try? FileManager.default.removeItem(atPath: p) }
print("CODEX ACCOUNTS OK")

// CodexUsageService against a fake API: the token rules end to end.
final class FakeCodexAPI: CodexAPI {
    var fetched: [String] = []          // access tokens used, in order
    var refreshedWith: [String] = []
    var usage = Data(#"{"rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":2000090000}}}"#.utf8)
    var fetchError: Error?
    var refreshError: Error?
    var refreshResult: (id: String?, access: String?, refresh: String?) = (nil, nil, nil)
    func fetchUsageRaw(_ login: CodexLogin) throws -> Data {
        fetched.append(login.accessToken)
        if let e = fetchError { throw e }
        return usage
    }
    func refresh(refreshToken: String) throws -> (id: String?, access: String?, refresh: String?) {
        refreshedWith.append(refreshToken)
        if let e = refreshError { throw e }
        return refreshResult
    }
}
let svcRoot = NSTemporaryDirectory() + "cbar-selftest-codexsvc-\(getpid())"
let svcKC = "cbar-selftest-codexsvc-\(getpid())"
func svcFixture(_ name: String) -> (CodexAccountStore, String, String) {
    let dir = svcRoot + "/" + name, home = dir + "/home"
    try! FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    return (CodexAccountStore(dir: dir, keychainService: svcKC), home, dir + "/cache.json")
}
func svcLogin(_ tag: String, account: String, exp: Double, iat: Double? = nil) -> CodexLogin {
    CodexLogin(raw: cxAuth(user: "user-s", account: account, email: "\(account)@x.com", plan: "plus",
                           exp: exp, iat: iat, tag: tag))!
}

// 1. The live slot's token expired while Codex sat unused. Skipping it must not
//    block the other slots: pass one skips it, pass two fetches the idle slot.
do {
    let (st, home, cache) = svcFixture("skip")
    let live = svcLogin("L", account: "acct-live", exp: cxNow - 100)
    let idle = svcLogin("I", account: "acct-idle", exp: cxNow + 86_400)
    _ = try st.add(live); _ = try st.add(idle)
    try! live.raw.write(to: URL(fileURLWithPath: home + "/auth.json"))
    let api = FakeCodexAPI()
    let svc = CodexUsageService(store: st, client: api, cachePath: cache, home: home)
    let p1 = svc.accounts(now: cxNow)
    assert(api.fetched.isEmpty && p1.first { $0.isActive }?.number == 1, "pass 1: live slot chosen, expired, skipped")
    let p2 = svc.accounts(now: cxNow + 60)
    assert(api.fetched == [idle.accessToken], "pass 2 fetches the idle slot instead of re-skipping the live one: \(api.fetched.count)")
    assert(p2.first { $0.number == 2 }?.status == "ok", "idle slot reads ok")
    assert(api.refreshedWith.isEmpty, "the live slot's token is never refreshed by cbar")
}
// 2. An idle slot's expired token: refreshed, persisted BEFORE use, then used.
do {
    let (st, home, cache) = svcFixture("refresh")
    let idle = svcLogin("I", account: "acct-idle", exp: cxNow - 100)
    _ = try st.add(idle)
    try! svcLogin("X", account: "acct-other", exp: cxNow + 86_400).raw.write(to: URL(fileURLWithPath: home + "/auth.json"))
    let api = FakeCodexAPI()
    let newAccess = cxAccessJWT(user: "user-s", account: "acct-idle", plan: "plus", exp: cxNow + 864_000, iat: cxNow, tag: "I2")
    api.refreshResult = (nil, newAccess, "rt-I2")
    let svc = CodexUsageService(store: st, client: api, cachePath: cache, home: home)
    let p = svc.accounts(now: cxNow)
    assert(api.refreshedWith == ["rt-I"], "idle expired token refreshed once")
    let persisted = try st.login(1)
    assert(persisted?.refreshToken == "rt-I2" && persisted?.accessToken == newAccess, "rotation persisted")
    assert(api.fetched == [newAccess], "fetch uses the refreshed token")
    assert(p.first?.status == "ok")
}
// 3. A dead refresh token → needs re-login, meters cleared.
do {
    let (st, home, cache) = svcFixture("dead")
    _ = try st.add(svcLogin("I", account: "acct-idle", exp: cxNow - 100))
    let api = FakeCodexAPI(); api.refreshError = OAuthError.needsReauth
    let p = CodexUsageService(store: st, client: api, cachePath: cache, home: home).accounts(now: cxNow)
    assert(p.first?.status == "needs-reauth" && p.first?.meters.isEmpty == true, "revoked refresh → needs-reauth")
}
// 4. A 401 on the usage fetch → needs re-login.
do {
    let (st, home, cache) = svcFixture("401")
    _ = try st.add(svcLogin("I", account: "acct-idle", exp: cxNow + 86_400))
    let api = FakeCodexAPI(); api.fetchError = OAuthError.http(401, retryAfter: nil)
    let p = CodexUsageService(store: st, client: api, cachePath: cache, home: home).accounts(now: cxNow)
    assert(p.first?.status == "needs-reauth", "401 → needs-reauth")
}
// 5. Heal copies a NEWER live login into its slot, never an older one over a
//    newer slot (a re-login imported through the inbox).
do {
    let (st, home, cache) = svcFixture("heal")
    _ = try st.add(svcLogin("old", account: "acct-live", exp: cxNow + 86_400, iat: cxNow - 1_000))
    let rotated = svcLogin("rot", account: "acct-live", exp: cxNow + 90_000, iat: cxNow)
    try! rotated.raw.write(to: URL(fileURLWithPath: home + "/auth.json"))
    let svc = CodexUsageService(store: st, client: FakeCodexAPI(), cachePath: cache, home: home)
    _ = svc.accounts(now: cxNow)
    let healed = try st.login(1)
    assert(healed?.refreshToken == "rt-rot", "newer live login healed into its slot")
    try st.setLogin(1, svcLogin("fresh", account: "acct-live", exp: cxNow + 100_000, iat: cxNow + 500))
    _ = svc.accounts(now: cxNow + 60)
    let kept = try st.login(1)
    assert(kept?.refreshToken == "rt-fresh", "an older live file never overwrites a newer slot")
}
// 6. A mixed live file blocks refreshing even an unrelated idle slot.
do {
    let (st, home, cache) = svcFixture("mixed")
    _ = try st.add(svcLogin("I", account: "acct-idle", exp: cxNow - 100))
    try! cxAuth(user: "user-s", account: "acct-a", email: "", plan: "plus", exp: cxNow + 86_400,
                tag: "mx", tokenAccount: "acct-b").write(to: URL(fileURLWithPath: home + "/auth.json"))
    let api = FakeCodexAPI()
    _ = CodexUsageService(store: st, client: api, cachePath: cache, home: home).accounts(now: cxNow)
    assert(api.refreshedWith.isEmpty, "unusable live file → no refresh anywhere")
}
try? Keychain.delete(service: svcKC, account: CodexAccountStore.keyAccount)
try? FileManager.default.removeItem(atPath: svcRoot)
print("CODEX SERVICE OK")

// wham/usage → meters. Shapes taken from a real response (prolite at its limit,
// 2026-09-16), identifiers dropped.
let cxProlite = #"{"plan_type":"prolite","rate_limit":{"allowed":false,"limit_reached":true,"primary_window":{"used_percent":100,"limit_window_seconds":604800,"reset_after_seconds":247179,"reset_at":2000247179},"secondary_window":null},"additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","metered_feature":"codex_bengalfox","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":0,"limit_window_seconds":18000,"reset_after_seconds":18000,"reset_at":2000018000},"secondary_window":{"used_percent":0,"limit_window_seconds":604800,"reset_after_seconds":604800,"reset_at":2000604800}}}]}"#
let cxProMeters = try CodexUsageMapper.meters(from: Data(cxProlite.utf8), now: cxNow)
assert(cxProMeters.map(\.id) == ["7d"], "weekly-only plan → one 7d meter, unused Spark hidden: \(cxProMeters.map(\.id))")
assert(cxProMeters[0].pct == 100 && cxProMeters[0].countdown == "2d 20h")
let cxAfterOnly = #"{"rate_limit":{"primary_window":{"used_percent":100,"limit_window_seconds":604800,"reset_after_seconds":90000},"secondary_window":null}}"#
let cxAfterMeters = try CodexUsageMapper.meters(from: Data(cxAfterOnly.utf8), now: cxNow)
assert(cxAfterMeters.count == 1 && cxAfterMeters[0].countdown == "1d 1h",
       "reset_after_seconds alone still yields a countdown: \(cxAfterMeters.first?.countdown ?? "nil")")
assert(cxAfterMeters[0].resetsAt == cxNow + 90_000)
assert(CodexUsageMapper.soonestReset(from: Data(cxProlite.utf8)) == 2000018000, "soonest reset spans every window")
let cxTeamUsage = #"{"rate_limit":{"primary_window":{"used_percent":42.5,"limit_window_seconds":18000,"reset_at":2000003600},"secondary_window":{"used_percent":61,"limit_window_seconds":604800,"reset_at":2000090000}},"additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","rate_limit":{"primary_window":{"used_percent":12,"limit_window_seconds":18000,"reset_at":2000007200},"secondary_window":null}}]}"#
let cxTeamMeters = try CodexUsageMapper.meters(from: Data(cxTeamUsage.utf8), now: cxNow)
assert(cxTeamMeters.map(\.id) == ["5h", "7d", "Spark"], "5h + week, and a model allowance once it's in use: \(cxTeamMeters.map(\.id))")
assert(cxTeamMeters[0].pct == 42.5 && cxTeamMeters[0].countdown == "1h 0m")
let cxTwoSparks = #"{"rate_limit":{"primary_window":{"used_percent":1,"limit_window_seconds":604800}},"additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":18000}}},{"limit_name":"GPT-6-Spark","rate_limit":{"primary_window":{"used_percent":7,"limit_window_seconds":18000}}}]}"#
let cxSparkIds = try CodexUsageMapper.meters(from: Data(cxTwoSparks.utf8), now: cxNow).map(\.id)
assert(Set(cxSparkIds).count == cxSparkIds.count, "meter ids stay unique when short names collide: \(cxSparkIds)")
let cxBadJSON = cxThrows { _ = try CodexUsageMapper.meters(from: Data("<html>".utf8)) }
assert(cxBadJSON, "a non-JSON body is badResponse, not zero meters")
print("CODEX USAGE MAP OK")

// Codex auto-switch targets. The switch window is 5h where the plan has one,
// else the week — the Claude rule would never move off a weekly-only account.
func cxAcc(_ n: Int, _ active: Bool, _ meters: [(String, Double)], status: String = "ok", age: Double = 30) -> Account {
    Account(id: "codex:\(n)", number: n, email: "c\(n)", org: "", isActive: active, status: status,
            meters: meters.map { Meter(id: $0.0, pct: $0.1, countdown: nil) }, ageSeconds: age, provider: "codex")
}
assert(codexAutoSwitchTarget(accounts: [cxAcc(1, true, [("7d", 100)]), cxAcc(2, false, [("5h", 10), ("7d", 40)])],
                             threshold: 93) == 2, "weekly-only account at its limit moves to one with room")
assert(codexAutoSwitchTarget(accounts: [cxAcc(1, true, [("7d", 50)]), cxAcc(2, false, [("7d", 0)])],
                             threshold: 93) == nil, "under threshold → stay")
assert(codexAutoSwitchTarget(accounts: [cxAcc(1, true, [("5h", 95), ("7d", 20)]), cxAcc(2, false, [("7d", 10)])],
                             threshold: 93) == 2, "a 5h plan switches on its 5h window")
assert(codexAutoSwitchTarget(accounts: [cxAcc(1, true, [("5h", 10), ("7d", 99)]), cxAcc(2, false, [("7d", 10)])],
                             threshold: 93) == 2, "an exhausted week forces the move even with an empty 5h")
let cxBusy = cxAcc(1, true, [("7d", 100)])
assert(codexAutoSwitchTarget(accounts: [cxBusy, cxAcc(2, false, [("7d", 10)], age: 700)], threshold: 93) == nil, "stale target")
assert(codexAutoSwitchTarget(accounts: [cxBusy, cxAcc(2, false, [("7d", 10)], status: "needs-reauth")], threshold: 93) == nil, "dead target")
assert(codexAutoSwitchTarget(accounts: [cxBusy, cxAcc(2, false, [("5h", 5), ("7d", 99)])], threshold: 93) == nil, "exhausted week is never a target")
assert(codexAutoSwitchTarget(accounts: [cxBusy, cxAcc(2, false, [("7d", 95)])], threshold: 93) == nil, "a target already over threshold would bounce back")
assert(codexAutoSwitchTarget(accounts: [cxBusy, cxAcc(0, false, [("7d", 0)])], threshold: 93) == nil, "the session-file card is not an account")
assert(codexAutoSwitchTarget(accounts: [cxAcc(1, true, [("5h", 95)]), cxAcc(2, false, [("5h", 3), ("7d", 90)]), cxAcc(3, false, [("7d", 50)])],
                             threshold: 93) == 3, "least spent across windows wins, not the emptiest 5h")
assert(codexAutoSwitchTarget(accounts: [mkAcc(1, true, 99, provider: "claude"), cxAcc(2, false, [("7d", 0)])], threshold: 93) == nil,
       "a Claude account at its limit never moves Codex")
assert(autoSwitchTarget(accounts: [mkAcc(1, true, 99), cxAcc(2, false, [("5h", 0), ("7d", 0)])], threshold: 93) == nil,
       "…and a Codex slot is never a Claude target")
assert(codexIsSwitchTarget(cxAcc(2, false, [("7d", 96)]), threshold: 100), "a manual switch may pick a busy account")
assert(!codexIsSwitchTarget(cxAcc(2, false, [("7d", 99.5)]), threshold: 100), "…but not a spent week")
print("CODEX AUTOSWITCH OK")

// ---- CbarConfig: defaults + first-run seeding -------------------------------
// The bug this covers (2026-09-01): no config file was ever written and both
// flags defaulted off, so cbar watched an account hit its limit and never
// rotated. Defaults are now ON, and the file gets written so the setting is
// visible instead of implied.
assert(CbarConfig().autoSwitchEnabled, "auto-switch defaults ON")
assert(CbarConfig().preWarmEnabled, "pre-warm defaults ON")

let cfgDir = NSTemporaryDirectory() + "cbar-cfg-\(UUID().uuidString)"
defer { try? FileManager.default.removeItem(atPath: cfgDir) }

// Missing file reads as the (on) defaults, so an upgrade with no config still rotates.
assert(CbarConfig.load(dir: cfgDir).autoSwitchEnabled, "no file -> defaults, auto-switch on")

// Hoisted out of the assert deliberately: `assert` is compiled OUT in release,
// so a seed call written inside one never runs there and the rest of this block
// then fails on a file that was never written.
let seededFirst = CbarConfig.seedIfMissing(dir: cfgDir)
assert(seededFirst, "first run seeds the config")
let seededPath = cfgDir + "/config.json"
assert(FileManager.default.fileExists(atPath: seededPath), "seed wrote config.json")
// Round-trip through load(), not just the raw JSON: seeding a file the loader
// can't read back would be the same invisible-default failure in a new costume.
let seeded = CbarConfig.load(dir: cfgDir)
assert(seeded.autoSwitchEnabled && seeded.preWarmEnabled && seeded.autoSwitchThreshold == 93,
       "seeded file round-trips to the defaults")
// 0600: this file decides whether something rewrites the live login.
let mode = (try! FileManager.default.attributesOfItem(atPath: seededPath)[.posixPermissions] as! NSNumber).intValue
assert(mode == 0o600, "seeded config is owner-only, got \(String(mode, radix: 8))")

// Seeding is once-only — it must never overwrite a choice the user made.
try! Data("{\"autoSwitchEnabled\":false,\"autoSwitchThreshold\":80}".utf8).write(to: URL(fileURLWithPath: seededPath))
let seededAgain = CbarConfig.seedIfMissing(dir: cfgDir)
assert(!seededAgain, "seed is a no-op once the file exists")
let edited = CbarConfig.load(dir: cfgDir)
assert(!edited.autoSwitchEnabled, "explicit false survives seeding")
assert(edited.autoSwitchThreshold == 80, "explicit threshold survives seeding")
assert(edited.preWarmEnabled, "key absent from an edited file keeps the default")
assert(!CbarConfig().codexAutoSwitchEnabled, "Codex auto-switch defaults OFF")
assert(!seeded.codexAutoSwitchEnabled, "seeded file carries codexAutoSwitchEnabled: false, visibly")
assert(!edited.codexAutoSwitchEnabled, "absent from an existing config → stays off on upgrade")
try! Data("{\"codexAutoSwitchEnabled\":true}".utf8).write(to: URL(fileURLWithPath: seededPath))
assert(CbarConfig.load(dir: cfgDir).codexAutoSwitchEnabled, "codexAutoSwitchEnabled: true is honored")
// UI setting writes preserve unrelated values and round-trip independently.
try! Data(#"{"autoSwitchThreshold":81,"futureSetting":{"keep":true}}"#.utf8)
    .write(to: URL(fileURLWithPath: seededPath))
for setting in CbarConfig.SwitchSetting.allCases {
    for enabled in [false, true, false] {
        let before = CbarConfig.load(dir: cfgDir)
        try! CbarConfig.setEnabled(enabled, for: setting, dir: cfgDir)
        let after = CbarConfig.load(dir: cfgDir)
        assert(after.isEnabled(setting) == enabled, "radio selection persists")
        assert(after.autoSwitchThreshold == 81, "custom threshold survives")
        for other in CbarConfig.SwitchSetting.allCases where other != setting {
            assert(after.isEnabled(other) == before.isEnabled(other), "settings stay independent")
        }
    }
}
let preserved = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: seededPath))) as! [String: Any]
assert((preserved["futureSetting"] as? [String: Bool])?["keep"] == true, "unknown config survives")
let savedMode = (try! FileManager.default.attributesOfItem(atPath: seededPath)[.posixPermissions] as! NSNumber).intValue
assert(savedMode == 0o600, "settings remain owner-only")
for malformed in ["{broken", "[]"] {
    let data = Data(malformed.utf8)
    try! data.write(to: URL(fileURLWithPath: seededPath))
    var rejected = false
    do { try CbarConfig.setEnabled(false, for: .claude, dir: cfgDir) }
    catch { rejected = true }
    assert(rejected, "invalid config must surface a save error")
    assert(try! Data(contentsOf: URL(fileURLWithPath: seededPath)) == data, "invalid config is not overwritten")
}
try! FileManager.default.removeItem(atPath: seededPath)
try! CbarConfig.setEnabled(false, for: .claude, dir: cfgDir)
assert(!CbarConfig.load(dir: cfgDir).autoSwitchEnabled, "missing config can be created from UI")
print("CONFIG DEFAULTS + SEED OK")

// Grok billing mapper: percent present, percent absent must not become 0,
// monthly used/limit fallback, on-demand cap, period labels.
let grokWeekly = Data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-10T00:00:00Z","end":"2026-09-17T00:00:00Z"},"creditUsagePercent":34.0,"subscriptionTierDisplay":"SuperGrok"}}"#.utf8)
let grokMeters = try GrokUsageMapper.meters(from: grokWeekly, now: 1_747_000_000)
assert(grokMeters.count == 1 && grokMeters[0].id == "7d" && Int(grokMeters[0].pct) == 34, "weekly percent → 7d")
assert(GrokUsageMapper.plan(from: grokWeekly) == "SuperGrok")
assert(GrokUsageMapper.percent(in: grokWeekly) == 34)
let grokNoPct = Data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-09-17T00:00:00Z"},"isUnifiedBillingUser":true}}"#.utf8)
assert(GrokUsageMapper.percent(in: grokNoPct) == nil)
let grokNoPctMeters = try GrokUsageMapper.meters(from: grokNoPct, now: 1_747_000_000)
assert(grokNoPctMeters.count == 1 && grokNoPctMeters[0].id == "7d" && grokNoPctMeters[0].pct == 0,
       "bare weekly window, no percent → 0% (proto3 drops zero)")
// Live shape: zero caps must not win, and used/limit still beats the 0% fallback.
let grokZeroCaps = Data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-09-30T16:25:09.749371+00:00"},"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"isUnifiedBillingUser":true,"monthlyLimit":{"val":0},"used":{"val":32}}}"#.utf8)
let grokZeroCapsM = try GrokUsageMapper.meters(from: grokZeroCaps, now: 1_747_000_000)
assert(grokZeroCapsM.count == 1 && grokZeroCapsM[0].id == "7d" && grokZeroCapsM[0].pct == 0, "zero limits → 0% window")
let grokNoWindow = Data(#"{"config":{"onDemandCap":{"val":0}}}"#.utf8)
let grokNoWindowM = try GrokUsageMapper.meters(from: grokNoWindow, now: 1_747_000_000)
assert(grokNoWindowM.isEmpty, "no window → no meter")
let grokMonthly = Data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","end":"2026-10-01T00:00:00Z"},"monthlyLimit":{"val":10000},"used":{"val":2500}}}"#.utf8)
let grokMo = try GrokUsageMapper.meters(from: grokMonthly, now: 1_747_000_000)
assert(grokMo.count == 1 && grokMo[0].id == "30d" && Int(grokMo[0].pct) == 25, "monthly used/limit")
let grokOD = Data(#"{"config":{"onDemandCap":{"val":100},"onDemandUsed":{"val":40}}}"#.utf8)
let grokOdM = try GrokUsageMapper.meters(from: grokOD, now: 1_747_000_000)
assert(grokOdM.count == 1 && grokOdM[0].id == "OD" && Int(grokOdM[0].pct) == 40, "on-demand fallback")
let grokAuthDir = NSTemporaryDirectory() + "cbar-selftest-grok-\(getpid())"
try! FileManager.default.createDirectory(atPath: grokAuthDir, withIntermediateDirectories: true)
let grokAuthPath = grokAuthDir + "/auth.json"
try! Data(#"{"https://auth.x.ai::abc":{"key":"tok-1","refresh_token":"rt-1","expires_at":"2099-01-01T00:00:00Z","email":"g@x.ai","oidc_client_id":"abc","auth_mode":"oidc"}}"#.utf8).write(to: URL(fileURLWithPath: grokAuthPath))
let grokLogin = GrokAuth.read(path: grokAuthPath)
assert(grokLogin?.email == "g@x.ai" && grokLogin?.accessToken == "tok-1" && grokLogin?.refreshToken == "rt-1")
assert(grokLogin?.isExpired(now: Date(timeIntervalSince1970: 1_700_000_000)) == false)
try GrokAuth.persistRefresh(access: "tok-2", refresh: "rt-2",
                            expiresAt: Date(timeIntervalSince1970: 2_000_000_000), path: grokAuthPath)
let grokAfter = GrokAuth.read(path: grokAuthPath)
assert(grokAfter?.accessToken == "tok-2" && grokAfter?.refreshToken == "rt-2", "rotation persisted")
assert(GrokUsageService.shouldSkipRefresh(grokRunning: true))
assert(!GrokUsageService.shouldSkipRefresh(grokRunning: false))
final class FakeGrokAPI: GrokAPI {
    var fetched: [String] = []
    var refreshedWith: [String] = []
    var usage = grokWeekly
    var fetchError: Error?
    var refreshError: Error?
    var refreshResult: (access: String, refresh: String?, expiresIn: Double) = ("tok-new", "rt-new", 3600)
    func fetchBillingRaw(accessToken: String) throws -> Data {
        fetched.append(accessToken)
        if let e = fetchError { throw e }
        return usage
    }
    func refresh(refreshToken: String, clientID: String) throws -> (access: String, refresh: String?, expiresIn: Double) {
        refreshedWith.append(refreshToken)
        if let e = refreshError { throw e }
        return refreshResult
    }
}
do {
    let cache = grokAuthDir + "/cache-skip.json"
    try! Data(#"{"https://auth.x.ai::abc":{"key":"tok-old","refresh_token":"rt-1","expires_at":"2020-01-01T00:00:00Z","email":"g@x.ai","oidc_client_id":"abc"}}"#.utf8).write(to: URL(fileURLWithPath: grokAuthPath))
    let api = FakeGrokAPI()
    let svc = GrokUsageService(client: api, authPath: grokAuthPath, cachePath: cache, grokRunning: { true })
    let a = svc.accounts(now: 1_800_000_000)
    assert(api.refreshedWith.isEmpty && api.fetched.isEmpty, "grok running: expired token not refreshed")
    assert(a.first?.provider == "grok" && a.first?.switchable == false)
    assert(a.first?.status != "ok", "skipped refresh is not a fresh ok reading")
}
do {
    let cache = grokAuthDir + "/cache-refresh.json"
    try! Data(#"{"https://auth.x.ai::abc":{"key":"tok-old","refresh_token":"rt-1","expires_at":"2020-01-01T00:00:00Z","email":"g@x.ai","oidc_client_id":"abc"}}"#.utf8).write(to: URL(fileURLWithPath: grokAuthPath))
    let api = FakeGrokAPI()
    let svc = GrokUsageService(client: api, authPath: grokAuthPath, cachePath: cache, grokRunning: { false })
    let a = svc.accounts(now: 1_800_000_000)
    assert(api.refreshedWith == ["rt-1"], "idle grok: refresh")
    assert(api.fetched == ["tok-new"], "fetch uses rotated token")
    assert(GrokAuth.read(path: grokAuthPath)?.accessToken == "tok-new", "rotation on disk")
    assert(a.first?.status == "ok" && Int(a.first?.meters.first?.pct ?? 0) == 34)
}
try? FileManager.default.removeItem(atPath: grokAuthDir)
print("GROK USAGE OK")

// Antigravity quota summary + keyring blob + client-id extract.
let agyQuota = Data(#"""
{"groups":[
  {"displayName":"Gemini Models","buckets":[
    {"displayName":"Five Hour Limit","remainingFraction":0.6,"resetTime":"2026-09-17T12:00:00Z"},
    {"displayName":"Weekly Limit","remainingFraction":0.25,"resetTime":"2026-09-20T00:00:00Z"}
  ]},
  {"displayName":"Claude and GPT models","buckets":[
    {"displayName":"Five Hour Limit","remainingFraction":1,"resetTime":"2026-09-17T12:00:00Z"},
    {"displayName":"Weekly Limit","remainingFraction":0.9,"resetTime":"2026-09-20T00:00:00Z"}
  ]}
]}
"""#.utf8)
let agyMeters = try AntigravityUsageMapper.meters(from: agyQuota, now: 1_747_000_000)
assert(agyMeters.map(\.id) == ["Gem 5h", "Gem 7d", "Cl 5h", "Cl 7d"], "group prefixes, 5h then 7d: \(agyMeters.map(\.id))")
assert(Int(agyMeters[0].pct) == 40 && Int(agyMeters[1].pct) == 75, "used = 1 − remaining")
assert(Int(agyMeters[2].pct) == 0, "untouched bucket is 0 used, not missing")
let agyOne = Data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"displayName":"Weekly Limit","remainingFraction":0.5,"resetTime":"2026-09-20T00:00:00Z"}]}]}"#.utf8)
let agyOneM = try AntigravityUsageMapper.meters(from: agyOne, now: 1_747_000_000)
assert(agyOneM.count == 1 && agyOneM[0].id == "7d", "single group keeps the plain window id")
let agyLoad = Data(#"{"cloudaicompanionProject":"proj-1","paidTier":{"id":"ultra","name":"Google AI Ultra"},"currentTier":{"id":"free-tier"}}"#.utf8)
assert(AntigravityUsageMapper.project(from: agyLoad) == "proj-1")
assert(AntigravityUsageMapper.plan(from: agyLoad) == "Google AI Ultra")
assert(AntigravityUsageMapper.groupPrefix("Gemini Models") == "Gem")
assert(AntigravityUsageMapper.groupPrefix("Claude and GPT models") == "Cl")
func agyJWT(_ email: String) -> String {
    let payload = Data("{\"email\":\"\(email)\"}".utf8).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    return "e30.\(payload).x"
}
let agyBlobJSON = "{\"token\":{\"access_token\":\"at-1\",\"refresh_token\":\"rt-1\",\"expiry\":\"2099-01-01T00:00:00Z\"},\"id_token\":\"\(agyJWT("agy@x.com"))\"}"
let agyB64 = Data(agyBlobJSON.utf8).base64EncodedString()
let agyCreds = AntigravityAuth.read(raw: "go-keyring-base64:\(agyB64)")
assert(agyCreds?.accessToken == "at-1" && agyCreds?.refreshToken == "rt-1")
assert(agyCreds?.email == "agy@x.com", "email from id_token: \(agyCreds?.email ?? "nil")")
assert(AntigravityAuth.read(raw: agyBlobJSON)?.email == "agy@x.com", "bare JSON also parses")
let agyBinDir = NSTemporaryDirectory() + "cbar-selftest-agybin-\(getpid())"
try! FileManager.default.createDirectory(atPath: agyBinDir, withIntermediateDirectories: true)
let agyBin = agyBinDir + "/agy"
var agyBinBytes = Data("noise-".utf8)
agyBinBytes += Data("1071006060591-abc123.apps.googleusercontent.com".utf8)
agyBinBytes += Data("-mid-".utf8)
agyBinBytes += Data("GOCSPX-abcdefghijklmnopqrstuv".utf8)
agyBinBytes += Data("-end".utf8)
try! agyBinBytes.write(to: URL(fileURLWithPath: agyBin))
let extracted = AntigravityOAuth.extract(from: agyBin)
assert(extracted?.id == "1071006060591-abc123.apps.googleusercontent.com", "id=\(extracted?.id ?? "nil")")
assert(extracted?.secret.hasPrefix("GOCSPX-abcdefghijklmnopqrstuv") == true, "secret=\(extracted?.secret ?? "nil")")
final class FakeAgyAPI: AntigravityAPI {
    var loaded = 0
    var summarized = 0
    var refreshed = 0
    var quota = agyOne
    var load = agyLoad
    var fetchError: Error?
    var refreshError: Error?
    func loadCodeAssist(accessToken: String) throws -> Data {
        loaded += 1
        if let e = fetchError { throw e }
        return load
    }
    func quotaSummary(accessToken: String, project: String?) throws -> Data {
        summarized += 1
        if let e = fetchError { throw e }
        return quota
    }
    var modelsData = Data(#"{"models":{}}"#.utf8)
    func fetchAvailableModels(accessToken: String) throws -> Data { modelsData }
    func refresh(refreshToken: String, clientID: String, clientSecret: String) throws -> (access: String, expiresIn: Double) {
        refreshed += 1
        if let e = refreshError { throw e }
        return ("at-new", 3600)
    }
}
do {
    let cache = agyBinDir + "/cache.json"
    let api = FakeAgyAPI()
    let cred = AntigravityCreds(accessToken: "at-1", refreshToken: "rt-1",
                                expiry: Date(timeIntervalSince1970: 2_000_000_000), email: "agy@x.com")
    let svc = AntigravityUsageService(client: api, creds: { cred },
                                      oauthClient: { ("id", "secret") }, cachePath: cache)
    let a = svc.accounts(now: 1_800_000_000)
    assert(api.loaded == 1 && api.summarized == 1 && api.refreshed == 0)
    assert(a.first?.provider == "antigravity" && a.first?.switchable == false)
    assert(a.first?.status == "ok" && a.first?.email == "agy@x.com")
    assert(a.first?.org == "Google · Google AI Ultra")
    assert(a.first?.meters.first?.id == "7d")
}
let agyModels = Data(#"""
{"models":{
  "gemini-flash":{"displayName":"Gemini 3 Flash","quotaInfo":{"remainingFraction":0.5,"resetTime":"2026-09-17T06:00:00Z"}},
  "gemini-pro":{"displayName":"Gemini 3.1 Pro (High)","quotaInfo":{"remainingFraction":0.8,"resetTime":"2026-09-24T00:00:00Z"}},
  "claude":{"displayName":"Claude Sonnet 4.6","quotaInfo":{"remainingFraction":0.25,"resetTime":"2026-09-24T00:00:00Z"}},
  "hidden":{"displayName":"Internal","isInternal":true,"quotaInfo":{"remainingFraction":0.1,"resetTime":"2026-09-17T06:00:00Z"}}
}}
"""#.utf8)
let agyFromModels = try AntigravityUsageMapper.metersFromModels(from: agyModels, now: 1_789_617_600) // 2026-09-17T04:00:00Z
assert(agyFromModels.map(\.id) == ["Gem 5h", "Gem 7d", "Cl 7d"], "grouped by pool+window: \(agyFromModels.map(\.id))")
assert(agyFromModels.map { Int($0.pct.rounded()) } == [50, 20, 75], "pcts=\(agyFromModels.map(\.pct))")
try? FileManager.default.removeItem(atPath: agyBinDir)
print("ANTIGRAVITY USAGE OK")

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

    let grokStart = Date()
    let grokAccts = GrokUsageService().accounts()
    let grokMs = Int(Date().timeIntervalSince(grokStart) * 1000)
    if let g = grokAccts.first {
        print("GROK LIVE: \(g.email) [\(g.org)] in \(grokMs)ms status=\(g.status) — " +
              g.meters.map { "\($0.id)=\(Int($0.pct))% (\($0.countdown ?? "—"))" }.joined(separator: " "))
    } else {
        print("GROK LIVE: no ~/.grok/auth.json (\(grokMs)ms)")
    }

    let agyStart = Date()
    let agyAccts = AntigravityUsageService().accounts()
    let agyMs = Int(Date().timeIntervalSince(agyStart) * 1000)
    if let a = agyAccts.first {
        print("ANTIGRAVITY LIVE: \(a.email) [\(a.org)] in \(agyMs)ms status=\(a.status) — " +
              a.meters.map { "\($0.id)=\(Int($0.pct))% (\($0.countdown ?? "—"))" }.joined(separator: " "))
    } else {
        print("ANTIGRAVITY LIVE: no Keychain login (\(agyMs)ms)")
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
