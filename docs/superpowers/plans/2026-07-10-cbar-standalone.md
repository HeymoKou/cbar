# cbar standalone (full Swift, drop cswap) — Implementation Plan

> **For agentic workers:** implement task-by-task; build + self-test each; commit per task. Steps use `- [ ]`.

**Goal:** Replace the cswap-CLI data layer with native Swift: capture accounts, fetch per-account Claude usage (paced), and switch — no cswap/Python/Rust. Codex unchanged.

**Architecture:** New `CbarCore` units: `Keychain` (via `/usr/bin/security`), `Credentials`, `ClaudeConfig`, `OAuthClient` (usage GET + refresh POST), `AccountStore` (`~/.cbar/`), paced `UsageService` (Provider), `Switcher`. UI gains add/remove-account. Protocol details in `../specs/2026-07-10-cbar-standalone-design.md`.

## Global Constraints

- Swift 6.3 CLT, `swiftLanguageModes: [.v5]`, platform macOS 14, no external deps.
- Keychain ONLY via `/usr/bin/security` (leak-free; no CoreFoundation).
- OAuth constants: usage `GET https://api.anthropic.com/api/oauth/usage`, header `anthropic-beta: oauth-2025-04-20`; refresh `POST https://platform.claude.com/v1/oauth/token`, `client_id = 9d1c250a-e61b-44d9-88ed-5944d1962f5e`; UA `cbar/1.0`; no `anthropic-version`.
- Active creds: keychain service `Claude Code-credentials`, account `$USER` (fallback file `~/.claude/.credentials.json`), JSON `{claudeAiOauth:{accessToken,refreshToken,expiresAt(ms),scopes[]}}`.
- `~/.claude.json` at `$HOME`; splice only `oauthAccount = {emailAddress,accountUuid,organizationUuid,organizationName}`, preserve all other keys. Identity = `(emailAddress, organizationUuid)`.
- Usage mapping: `five_hour.utilization`/`seven_day.utilization` → pct; `limits[].percent` + `limits[].scope.model.display_name` → scoped. `resets_at` ISO optional.
- Expiry: refresh when `now_ms + 300_000 >= expiresAt`. `invalid_grant`/`invalid_client` → needs re-login.
- Pacing: per refresh fetch active + ≤1 stalest alternate per 30 s (SERVE_TTL). Backoff `min(30·2^(n-1),600)`; `retry-after:0`→`min(computed,120)`; `N>0`→`max(min(N,900),computed)`.
- cbar store: `~/.cbar/accounts.json` + keychain service `cbar`, account `account-{n}`. Usage cache `~/.cbar/usage-cache.json`.
- Soundness: never refresh ACTIVE token while Claude Code process running; switch = backup→write→rollback.

---

### Task 1: Keychain wrapper (`/usr/bin/security`)

**Files:** Create `Sources/CbarCore/Keychain.swift`; extend `Sources/CbarSelfTest/main.swift`.

**Produces:** `enum Keychain { static func get(service:account:) throws -> String?; static func set(service:account:value:) throws; static func delete(service:account:) throws }`

- [ ] **Step 1: Implement**

```swift
import Foundation

public enum Keychain {
    public enum KErr: Error { case failed(Int32, String) }
    private static let bin = "/usr/bin/security"

    /// Returns nil when the item is absent (security rc 44).
    public static func get(service: String, account: String) throws -> String? {
        let (rc, out, _) = run(["find-generic-password", "-a", account, "-w", "-s", service])
        if rc == 0 { return out.hasSuffix("\n") ? String(out.dropLast()) : out }
        if rc == 44 { return nil }
        throw KErr.failed(rc, "get \(service)")
    }

    public static func set(service: String, account: String, value: String) throws {
        // hex payload via stdin so the secret never appears in argv
        let hex = value.utf8.map { String(format: "%02x", $0) }.joined()
        let cmd = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \(hex)\n"
        let (rc, _, err) = run([], stdin: cmd)
        if rc != 0 { throw KErr.failed(rc, "set \(service): \(err)") }
    }

    public static func delete(service: String, account: String) throws {
        let (rc, _, _) = run(["delete-generic-password", "-a", account, "-s", service])
        if rc != 0 && rc != 44 { throw KErr.failed(rc, "delete \(service)") }
    }

    private static func run(_ args: [String], stdin: String? = nil) -> (Int32, String, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: bin); p.arguments = args
        let o = Pipe(); let e = Pipe(); p.standardOutput = o; p.standardError = e
        var inPipe: Pipe?
        if let s = stdin { let i = Pipe(); p.standardInput = i; inPipe = i
            // security reads commands from stdin when invoked with no verb args
            p.arguments = []
            _ = s // written after run() starts
        }
        do { try p.run() } catch { return (-1, "", "\(error)") }
        if let s = stdin, let i = inPipe {
            i.fileHandleForWriting.write(Data(s.utf8)); i.fileHandleForWriting.closeFile()
        }
        let out = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (p.terminationStatus, out, err)
    }
}
```

- [ ] **Step 2: Self-test round-trip** — append to selftest:

```swift
// Keychain round-trip on a throwaway service
let ks = "cbar-selftest", ka = "rt"
try? Keychain.delete(service: ks, account: ka)
assert((try? Keychain.get(service: ks, account: ka)) == .some(nil), "absent should be nil")
try! Keychain.set(service: ks, account: ka, value: "{\"x\":1}")
assert(try! Keychain.get(service: ks, account: ka) == "{\"x\":1}", "roundtrip")
try! Keychain.delete(service: ks, account: ka)
assert(try! Keychain.get(service: ks, account: ka) == nil, "deleted")
print("KEYCHAIN OK")
```

- [ ] **Step 3: Run** `swift run CbarSelfTest` → expect `KEYCHAIN OK` (may prompt keychain access once; allow).
- [ ] **Step 4: Commit** `feat(core): keychain wrapper via /usr/bin/security`

> NOTE (implementer): the stdin-command form of `security` is finicky; if Step 3 fails, fall back to argv form for `set`: `["add-generic-password","-U","-a",account,"-s",service,"-w",value]` (secret in argv is acceptable for a local personal tool; document the trade-off with a `ponytail:` comment).

---

### Task 2: Credentials + ClaudeConfig

**Files:** Create `Sources/CbarCore/Credentials.swift`, `Sources/CbarCore/ClaudeConfig.swift`; extend selftest.

**Produces:**
- `struct ClaudeAiOauth: Codable { var accessToken, refreshToken: String; var expiresAt: Double; var scopes: [String]? }`
- `enum Credentials { static func readActive() throws -> ClaudeAiOauth?; static func writeActive(_:) throws; static func parse(_ json: String) -> ClaudeAiOauth?; static func serialize(_:) -> String }`
- `enum ClaudeConfig { struct OAuthAccount: Codable { var emailAddress: String?; var accountUuid: String?; var organizationUuid: String?; var organizationName: String? }; static func readAccount() throws -> OAuthAccount?; static func spliceAccount(_:) throws; static func rawConfig() throws -> String; static func writeRaw(_:) throws }`

- [ ] **Step 1: Credentials.swift**

```swift
import Foundation

public struct ClaudeAiOauth: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Double          // epoch ms
    public var scopes: [String]?
}

public enum Credentials {
    static var user: String { ProcessInfo.processInfo.environment["USER"] ?? "claude-code-user" }
    static let service = "Claude Code-credentials"
    static var filePath: String { "\(NSHomeDirectory())/.claude/.credentials.json" }

    struct Wrapper: Codable { var claudeAiOauth: ClaudeAiOauth }

    public static func parse(_ json: String) -> ClaudeAiOauth? {
        guard let d = json.data(using: .utf8),
              let w = try? JSONDecoder().decode(Wrapper.self, from: d) else { return nil }
        return w.claudeAiOauth
    }
    public static func serialize(_ o: ClaudeAiOauth) -> String {
        let w = Wrapper(claudeAiOauth: o)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted]
        return String(data: (try? enc.encode(w)) ?? Data(), encoding: .utf8) ?? "{}"
    }
    /// Keychain wins, then file.
    public static func readActive() throws -> ClaudeAiOauth? {
        if let s = try Keychain.get(service: service, account: user), let o = parse(s) { return o }
        if let s = try? String(contentsOfFile: filePath, encoding: .utf8), let o = parse(s) { return o }
        return nil
    }
    /// Write keychain; also rewrite file IF it already exists (mtime bump), never create.
    public static func writeActive(_ o: ClaudeAiOauth) throws {
        let s = serialize(o)
        try Keychain.set(service: service, account: user, value: s)
        if FileManager.default.fileExists(atPath: filePath) {
            try? s.write(toFile: filePath, atomically: true, encoding: .utf8)
        }
    }
}
```

- [ ] **Step 2: ClaudeConfig.swift**

```swift
import Foundation

public enum ClaudeConfig {
    public struct OAuthAccount: Codable, Sendable {
        public var emailAddress: String?
        public var accountUuid: String?
        public var organizationUuid: String?
        public var organizationName: String?
    }
    static var path: String {
        let legacy = "\(NSHomeDirectory())/.claude/.config.json"
        return FileManager.default.fileExists(atPath: legacy) ? legacy : "\(NSHomeDirectory())/.claude.json"
    }
    public static func rawConfig() throws -> String { try String(contentsOfFile: path, encoding: .utf8) }
    public static func writeRaw(_ s: String) throws { try s.write(toFile: path, atomically: true, encoding: .utf8) }

    public static func readAccount() throws -> OAuthAccount? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let oa = obj["oauthAccount"] as? [String: Any] else { return nil }
        return OAuthAccount(
            emailAddress: oa["emailAddress"] as? String,
            accountUuid: oa["accountUuid"] as? String,
            organizationUuid: oa["organizationUuid"] as? String,
            organizationName: oa["organizationName"] as? String)
    }
    /// Splice only oauthAccount into the live config, preserving every other key + order-insensitive.
    public static func spliceAccount(_ acc: OAuthAccount) throws {
        let d = try Data(contentsOf: URL(fileURLWithPath: path))
        guard var obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw NSError(domain: "cbar", code: 1) }
        obj["oauthAccount"] = [
            "emailAddress": acc.emailAddress as Any,
            "accountUuid": acc.accountUuid as Any,
            "organizationUuid": acc.organizationUuid as Any,
            "organizationName": acc.organizationName as Any,
        ].compactMapValues { $0 is NSNull ? nil : $0 }
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: URL(fileURLWithPath: path))
    }
}
```

- [ ] **Step 3: Self-test** — creds parse/serialize round-trip; splice preserves other keys:

```swift
let credJson = #"{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1783672677350,"scopes":["user:inference"]}}"#
let c = Credentials.parse(credJson)!
assert(c.accessToken == "a" && c.refreshToken == "r" && Int(c.expiresAt) == 1783672677350)
assert(Credentials.parse(Credentials.serialize(c))!.refreshToken == "r", "creds roundtrip")
print("CREDS OK")
```
(Splice is I/O; covered by the Task 7 soundness drill against a temp config file.)

- [ ] **Step 4: Run selftest, expect `CREDS OK`. Commit** `feat(core): active credentials + claude.json oauthAccount splice`

---

### Task 3: OAuthClient (usage + refresh) + mapping

**Files:** Create `Sources/CbarCore/OAuthClient.swift`; extend selftest (mapping + expiry with sample JSON, and a gated `--live` fetch).

**Produces:**
- `struct OAuthClient { func fetchUsageRaw(accessToken:) throws -> Data; func refresh(refreshToken:) throws -> ClaudeAiOauth-fields }`
- `enum UsageMapper { static func meters(from data: Data) throws -> [Meter] }` (pure, testable)
- `static func isExpired(expiresAt: Double, now_ms: Double) -> Bool`
- error enum incl `.rateLimited(retryAfter: Double?)`, `.needsReauth`, `.transient`

- [ ] **Step 1: OAuthClient.swift** (sync via semaphore; usage GET + refresh POST; map utilization/percent)

```swift
import Foundation

public enum OAuthError: Error { case http(Int, retryAfter: Double?), needsReauth, transient, badResponse, network }

public func isExpired(expiresAt: Double, now_ms: Double) -> Bool { now_ms + 300_000 >= expiresAt }

public struct OAuthClient {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let beta = "oauth-2025-04-20"
    static let ua = "cbar/1.0"
    public init() {}

    public func fetchUsageRaw(accessToken: String) throws -> Data {
        var r = URLRequest(url: Self.usageURL, timeoutInterval: 5)
        r.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        r.setValue(Self.beta, forHTTPHeaderField: "anthropic-beta")
        r.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        return try send(r).0
    }

    /// Returns refreshed fields; caller merges into stored creds.
    public func refresh(refreshToken: String) throws -> (access: String, expiresAt: Double, refresh: String?, scopes: [String]?) {
        var r = URLRequest(url: Self.tokenURL, timeoutInterval: 10)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        r.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": Self.clientID])
        let (data, code) = try send(r)
        if code >= 400 {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("invalid_grant") || body.contains("invalid_client") { throw OAuthError.needsReauth }
            throw OAuthError.transient
        }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = o["access_token"] as? String,
              let expiresIn = (o["expires_in"] as? Double) ?? (o["expires_in"] as? Int).map(Double.init)
        else { throw OAuthError.badResponse }
        let now_ms = Date().timeIntervalSince1970 * 1000
        let scope = (o["scope"] as? String)?.split(separator: " ").map(String.init)
        return (access, now_ms + expiresIn * 1000, o["refresh_token"] as? String, scope)
    }

    private func send(_ req: URLRequest) throws -> (Data, Int) {
        var out: Data?; var status = 0; var err: Error?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, resp, e in
            out = d; status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 {
                let ra = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                err = OAuthError.http(429, retryAfter: ra)
            }
            if e != nil { err = OAuthError.network }
            sem.signal()
        }.resume()
        sem.wait()
        if let err { throw err }
        return (out ?? Data(), status)
    }
}

public enum UsageMapper {
    public static func meters(from data: Data) throws -> [Meter] {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OAuthError.badResponse }
        var m: [Meter] = []
        func win(_ key: String, _ id: String) {
            if let w = o[key] as? [String: Any], let u = (w["utilization"] as? Double) ?? (w["utilization"] as? Int).map(Double.init) {
                m.append(Meter(id: id, pct: u, countdown: countdown(w["resets_at"] as? String)))
            }
        }
        win("five_hour", "5h"); win("seven_day", "7d")
        if let limits = o["limits"] as? [[String: Any]] {
            for lim in limits {
                let name = ((lim["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String
                let pct = (lim["percent"] as? Double) ?? (lim["percent"] as? Int).map(Double.init)
                if let name, let pct { m.append(Meter(id: name == "Fable" ? "Fbl" : name, pct: pct, countdown: countdown(lim["resets_at"] as? String))) }
            }
        }
        return m
    }
    static func countdown(_ iso: String?) -> String? {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return nil }
        let s = Int(d.timeIntervalSinceNow); if s <= 0 { return "now" }
        let dd = s/86400, h = (s%86400)/3600, mn = (s%3600)/60
        if dd > 0 { return "\(dd)d \(h)h" }; if h > 0 { return "\(h)h \(mn)m" }; return "\(mn)m"
    }
}
```

- [ ] **Step 2: Self-test mapping + expiry** (sample usage JSON):

```swift
let usageJson = #"{"five_hour":{"utilization":42.0,"resets_at":null},"seven_day":{"utilization":71},"limits":[{"scope":{"model":{"display_name":"Fable"}},"percent":88.0}]}"#
let um = try UsageMapper.meters(from: Data(usageJson.utf8))
assert(um.count == 3 && um[0].id=="5h" && Int(um[0].pct)==42 && um[2].id=="Fbl" && Int(um[2].pct)==88, "usage map")
assert(isExpired(expiresAt: 1000, now_ms: 800_000) && !isExpired(expiresAt: 10_000_000_000_000, now_ms: 1000), "expiry")
print("OAUTH MAP OK")
```

- [ ] **Step 3: Gated live fetch** (`--live`, only meaningful once the 429 clears):

```swift
// inside --live:
if let cred = try Credentials.readActive() {
    do { let d = try OAuthClient().fetchUsageRaw(accessToken: cred.accessToken)
         print("OAUTH LIVE:", try UsageMapper.meters(from: d).map{ "\($0.id)=\(Int($0.pct))%" }.joined(separator: " ")) }
    catch { print("OAUTH LIVE err:", error) }
}
```

- [ ] **Step 4: Run** `swift run CbarSelfTest` (→ `OAUTH MAP OK`) and, when rate-limit clears, `--live`. **Commit** `feat(core): OAuth usage fetch + token refresh + mapping`

---

### Task 4: AccountStore (`~/.cbar/`)

**Files:** Create `Sources/CbarCore/AccountStore.swift`; extend selftest.

**Produces:** `struct AccountStore { func list() -> [StoredAccount]; func activeNumber() -> Int?; func addCurrent() throws -> Int; func remove(_ n: Int) throws; func creds(_ n: Int) throws -> ClaudeAiOauth?; func setCreds(_ n: Int, _:) throws; func setActive(_ n: Int) }` where `StoredAccount = {number,email,uuid,orgUuid,orgName}`.

- [ ] **Step 1: Implement** — metadata JSON at `~/.cbar/accounts.json`, per-account creds in keychain `cbar`/`account-{n}`. `addCurrent()` reads `Credentials.readActive()` + `ClaudeConfig.readAccount()`, allocates next number, stores. (Full code: metadata Codable {activeAccountNumber:Int?, accounts:[String:Row]}, Row {email,uuid,organizationUuid,organizationName,added}. Dir created with `FileManager.createDirectory`. Creds via `Keychain.set(service:"cbar",account:"account-\(n)",value:Credentials.serialize(o))`.)

- [ ] **Step 2: Self-test** — write a StoreImpl pointed at a temp dir + temp keychain service; add a synthetic account, list, read creds, remove. `print("STORE OK")`.

- [ ] **Step 3: Commit** `feat(core): cbar account store (~/.cbar + keychain)`

> Implementer: inject dir + keychain service via init params so the self-test uses throwaways (never touches the real `~/.cbar` or real keychain items).

---

### Task 5: Backoff + paced planner + UsageService

**Files:** Create `Sources/CbarCore/Pacing.swift` (pure), `Sources/CbarCore/UsageService.swift`; extend selftest.

**Produces:**
- pure `func backoff(failures:Int, retryAfter:Double?) -> Double` (spec formula) + `func fetchPlan(now:Double, active:Int?, rows:[Int:CacheRow], serveTTL:Double=30) -> [Int]` (active if due + ≤1 stalest alt).
- `final class UsageService: Provider` producing `[Account]` from store+cache, refreshing tokens as needed (skip active refresh if Claude Code running), persisting cache `~/.cbar/usage-cache.json`.

- [ ] **Step 1: Pacing.swift (pure) + self-test** the backoff caps (base/edge/burst) and the plan (active always; only 1 alt; skips fresh/backed-off). `print("PACING OK")`.

- [ ] **Step 2: UsageService.swift** — `accounts()`:
  1. read store list + cache rows.
  2. compute `fetchPlan`; for each planned account: get creds; if expired → refresh (UNLESS active && claudeCodeRunning → skip, serve cache); `fetchUsageRaw` → map → update cache row (fetchedAt, lastGood); on 429 set backoff.
  3. build `[Account]` from cache (lastGood) for ALL accounts (active flagged from store.activeNumber), provider "cswap"→rename "claude". Codex appended by store as before (UsageService only does claude).
  - `claudeCodeRunning()` = `pgrep -x claude`/`node .*claude` check via Process (best-effort).

- [ ] **Step 3: Commit** `feat(core): paced UsageService + backoff (rate-limit safe)`

---

### Task 6: Wire into app (replace CswapClient)

**Files:** Modify `Sources/Cbar/UsageStore.swift` (use `UsageService` + `CodexProvider`; switch/add/remove via store), `Sources/Cbar/AppDelegate.swift` (provider filter uses "claude").

- [ ] Replace `CswapClient()` with `UsageService()`; `switchTo`/`switchToBest` route to `Switcher` (Task 7 — stub until then). Build. `open Cbar.app`, confirm monitor shows accounts from native fetch (after 429 clears). Commit `feat(app): use native UsageService`.

---

### Task 7: Switcher + soundness drill

**Files:** Create `Sources/CbarCore/Switcher.swift`; extend selftest (drill against temp files).

**Produces:** `struct Switcher { func switchTo(_ n:Int, store:AccountStore) throws }` — steps: read current active creds+config (backup into current slot via store), read target slot creds+oauthAccount, `Credentials.writeActive(target)`, `ClaudeConfig.spliceAccount(target.oauthAccount)`, `store.setActive(n)`; on throw, restore original creds + config text. Never runs while it would rotate a live active token unexpectedly (switch is user-initiated, so allowed; but back up first).

- [ ] **Step 1: Soundness drill self-test** — temp `claude.json` with extra keys; `spliceAccount`; assert every non-`oauthAccount` key byte-identical, `oauthAccount` replaced. Force an error mid-switch (bad target) → assert original restored. `print("SWITCH OK")`.
- [ ] **Step 2: Live switch test** (guarded, with backup): switch to another real account, confirm `~/.claude.json` oauthAccount changed + other keys intact, switch back.
- [ ] **Step 3: Commit** `feat(core): account switcher with backup/rollback`

---

### Task 8: Account UI + polish + remove cswap

**Files:** Modify `PopoverView.swift` (Add current / Remove; finish green-deepen + hover styles — the parked UI work), delete/deprecate `CswapClient.swift`, update README (no cswap), reload LaunchAgent.

- [ ] **Step 1:** Add "＋ Add current account" (calls `store.addCurrent` via UsageStore) + per-account remove (non-active). 
- [ ] **Step 2:** Finish parked polish: deepen greens (already staged in Health+Color working tree), `HoverButtonStyle` (background wash + pointer cursor + pressed) on all buttons + account-row hover.
- [ ] **Step 3:** Remove `CswapClient.swift` from CbarCore + its selftest lines; ensure build clean. Update README (native, no cswap; keep Codex note).
- [ ] **Step 4:** `./install.sh` (rebuilds + reloads LaunchAgent). Live verify: monitor, add, switch, remove. **Commit** `feat: native account UI + hover polish, remove cswap dependency`.

---

## Self-Review

- Spec coverage: keychain(T1)/creds+config(T2)/oauth(T3)/store(T4)/pacing+service(T5)/wire(T6)/switch+soundness(T7)/UI+remove-cswap(T8). ✓
- Rate-limit safety = T5 pacing+backoff (the validated failure). ✓
- Soundness (splice preserve + rollback + no active-refresh-while-running) = T7 + T5 step2. ✓
- Leak-free = subprocess keychain (T1), sync URLSession w/ semaphore released (T3), existing [weak self] timers. ✓
- Parked green/hover polish folded into T8. ✓
- Type consistency: `Meter`/`Account`(+provider)/`ClaudeAiOauth`/`OAuthError`/`Keychain`/`Credentials`/`ClaudeConfig`/`AccountStore`/`UsageService`/`Switcher` used consistently. ✓
