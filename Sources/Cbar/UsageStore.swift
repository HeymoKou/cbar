import AppKit
import Foundation
import CbarCore

@Observable
final class UsageStore {
    private(set) var accounts: [Account] = []
    private(set) var lastError: String?
    private(set) var lastUpdated: Date?
    /// Last config the poll read. Published so the header can show the armed
    /// threshold and the plots can draw it — no extra file read, this is the
    /// value `maybeAutoSwitch` already loads on every pass.
    private(set) var config = CbarConfig()

    var onUpdate: (() -> Void)?

    private let store = AccountStore()
    private let usage: UsageService
    private let switcher: Switcher
    private let codex = CodexProvider()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let interval: TimeInterval = 60   // pacing gates the actual network hits
    private var lastAutoSwitchAt: Date?
    private let autoSwitchCooldown: TimeInterval = 120

    /// EVERY credential mutation runs here, one at a time. These paths used to
    /// take independent global-queue slots: the 60 s timer, opening the popover,
    /// the Refresh button, a manual switch, and auto-switch could all be in
    /// flight together. Two of them matter together — `UsageService.accounts()`
    /// rotates refresh tokens, and `Switcher.switchTo` rewrites the live keychain
    /// item and `~/.claude.json`. Interleaved, they can submit the same rotating
    /// refresh token twice (which revokes the token family) or leave credentials
    /// and account metadata describing different accounts. Serial is fast enough:
    /// a pass is one network fetch, and a queued click waits under a second.
    private let work = DispatchQueue(label: "com.heymo.cbar.mutations", qos: .userInitiated)

    /// Run a mutation on the serial queue and put its failure where the user can
    /// see it. These were `try?` — a switch or a capture could fail with no
    /// message, no log line, and no visible change, so the only symptom was the
    /// menu not doing anything.
    private func mutate(_ what: String, _ body: @escaping () throws -> Void) {
        work.async { [weak self] in
            var err: String?
            do { try body() } catch {
                err = "\(what): \(error)"
                CbarLog.write("\(what) FAILED: \(error)")
            }
            // Hand the message to the refresh rather than setting it here: the
            // refresh that follows every mutation assigns `lastError` itself, so
            // setting it first just means the user never sees it.
            self?.refresh(carrying: err)
        }
    }

    init() {
        usage = UsageService(store: store)
        switcher = Switcher(store: store)
    }

    /// True when there are no accounts yet but a cswap backup exists to import.
    var canImportCswap: Bool { store.list().isEmpty && CswapImport.available() }

    func start() {
        SecureFile.tightenAll(dir: "\(NSHomeDirectory())/.cbar")
        refresh()
        startTimer()

        // A dark display means nobody can read the icon, so every pass behind it
        // is a network request, four process spawns and a tree walk spent on
        // nothing. Auto-switch is off by default, so on most machines the whole
        // pass exists only to paint a status item that isn't on screen.
        //
        // Screen sleep, not system sleep: the system kind stops the timer for us
        // by stopping the machine. This is the case that runs for hours on
        // battery with the lid open and the display off.
        let nc = NSWorkspace.shared.notificationCenter
        observers = [
            nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in self?.stopTimer() },
            nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
                // Refresh on the way back: the cache is as stale as the sleep was
                // long, and the user is looking at the icon right now.
                self?.startTimer()
                self?.refresh()
            },
        ]
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        observers.forEach { nc.removeObserver($0) }
    }

    private func startTimer() {
        guard timer == nil else { return }   // waking twice must not stack timers
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Nothing here is deadline-sensitive — a poll arriving 6 s late is
        // invisible. Without a tolerance the timer demands an exact wakeup every
        // minute for the life of the app; with one, macOS coalesces it into
        // wakeups it was going to make anyway. Pure battery, no behaviour change.
        t.tolerance = interval * 0.1
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// `carrying` is a mutation's failure message, which outranks anything the
    /// refresh itself hits — the user clicked a thing and it didn't work, and
    /// that is what they need told. Cleared by the next ordinary poll.
    func refresh(carrying: String? = nil) {
        work.async { [weak self] in
            guard let self else { return }
            var accs: [Account] = []
            var err: String? = carrying
            do { accs = try self.usage.accounts() } catch { err = err ?? "\(error)" }
            accs += (try? self.codex.accounts()) ?? []
            DispatchQueue.main.async {
                self.accounts = accs
                self.lastError = err
                self.lastUpdated = Date()
                self.onUpdate?()
                self.maybeAutoSwitch()
            }
        }
    }

    /// Auto-switch when the active account hits the configured threshold and a
    /// better account exists (cooldown-guarded). Native replacement for `cswap auto`.
    private func maybeAutoSwitch() {
        let cfg = CbarConfig.load()
        config = cfg          // publish before the guard: the header shows it either way
        guard cfg.autoSwitchEnabled || cfg.preWarmEnabled else { return }
        // Observability: log the active account's switch-usage + decision each poll,
        // so it's visible in Console why auto-switch does or doesn't fire.
        if let active = accounts.first(where: { $0.isActive && $0.provider == "claude" }) {
            let err = active.meters.isEmpty ? " (no usage data — stale/rate-limited/expired token)" : ""
            CbarLog.write("auto-switch check active #\(active.number) \(active.email) 5h=\(Int(switchPct(active)))% thr=\(Int(cfg.autoSwitchThreshold))% 7d=\(Int(sevenDayPct(active)))%/\(Int(sevenDayCeiling))%\(err)")
        }
        // The 93%/exhaustion escape outranks pre-warm: leaving a blocked account is
        // mandatory, priming an idle one is opportunistic. Pre-warm only diverts
        // when Claude Code is actually running — without a live session there is no
        // traffic to open the target's window, so the switch would just park the
        // login on an idle slot.
        // ponytail: claudeCodeRunning() spawns pgrep on the main thread. It runs at
        // most once per 60s poll and only when the escape didn't fire; the same
        // pgrep already runs each pass inside accounts(). Move it off-main if the
        // poll ever gets hot.
        var target: Int?
        var reason = ""
        if cfg.autoSwitchEnabled, let t = autoSwitchTarget(accounts: accounts, threshold: cfg.autoSwitchThreshold) {
            target = t; reason = "active ≥ \(Int(cfg.autoSwitchThreshold))% or exhausted"
        } else if cfg.preWarmEnabled, UsageService.claudeCodeRunning(), let t = preWarmTarget(accounts: accounts) {
            target = t; reason = "pre-warm 5h to 5%"
        }
        guard let target else { return }
        if let last = lastAutoSwitchAt, Date().timeIntervalSince(last) < autoSwitchCooldown {
            CbarLog.write("auto-switch WANTED → #\(target) (\(reason)) but in cooldown")
            return
        }
        guard let acc = accounts.first(where: { $0.number == target && $0.provider == "claude" }) else { return }
        lastAutoSwitchAt = Date()   // prevent re-entry while the async switch runs
        CbarLog.write("auto-switch triggered → #\(target) \(acc.email) (\(reason))")
        work.async { [weak self] in
            guard let self else { return }
            do {
                try self.switcher.switchTo(target)
                CbarLog.write("auto-switch OK → #\(target)")
            } catch {
                // Keep the cooldown: resetting it here turned one failure into
                // a 5+/sec retry storm (2026-07-10) that kept corrupting the
                // live login and rotated the log over its own evidence.
                CbarLog.write("auto-switch FAILED → #\(target): \(error) (retry after cooldown)")
            }
            self.refresh()
        }
    }

    func switchTo(_ account: Account) {
        // Arm the shared cooldown so the next poll's auto-switch/pre-warm doesn't
        // reverse a hand-picked account a second later — the auto path only wrote
        // this timestamp itself, so a manual switch used to be fair game to undo.
        lastAutoSwitchAt = Date()
        mutate("switch to #\(account.number)") { [switcher] in try switcher.switchTo(account.number) }
    }

    func switchToBest() {
        // Same viability gate as auto-switch — "best" must not mean "the dead one
        // whose 11-day-old cache looks empty" (2026-07-25).
        let candidates = accounts.filter { $0.provider == "claude" && !$0.isActive && isSwitchTarget($0) }
        guard let best = candidates.min(by: { switchPct($0) < switchPct($1) }) else { return }
        switchTo(best)
    }

    func addCurrent() {
        // Clear the slot's stale failure state after capturing fresh creds — this
        // IS the "fix a dead slot" path, and its backoff/needs-reauth must not
        // outlive the re-login (credsChanged can't see it, slot == live).
        mutate("add current account") { [store, usage] in
            let n = try store.addCurrent()
            usage.clearFailureState(n)
        }
    }

    func remove(_ number: Int) {
        mutate("remove #\(number)") { [store] in try store.remove(number) }
    }

    func importCswap() {
        mutate("import from cswap") { [store] in _ = try CswapImport.importAll(into: store) }
    }

    var cacheAgeText: String {
        let ages = accounts.filter { $0.provider == "claude" }.compactMap(\.ageSeconds)
        guard let age = ages.max() else { return "—" }
        if age >= 3600 { return "cached \(Int(age / 3600))h ago" }
        if age >= 90 { return "cached \(Int(age / 60))m ago" }
        return "cached \(Int(age))s ago"
    }

    /// Just the duration, for the header's "data 14m old". The active account's
    /// age, not the list's worst — the header speaks for the account in use.
    var cacheAgeShort: String {
        guard let age = accounts.first(where: { $0.isActive && $0.provider == "claude" })?.ageSeconds
        else { return "—" }
        if age >= 3600 { return "\(Int(age / 3600))h" }
        return "\(Int(age / 60))m"
    }
}
