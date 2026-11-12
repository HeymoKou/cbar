import AppKit
import Foundation
import CbarCore

@Observable
final class UsageStore {
    private(set) var accounts: [Account] = []
    private(set) var lastError: String?
    /// A non-error message from the last user action — the Codex login command
    /// that was just copied, or the account that was just added. Cleared by the
    /// next action, not the next poll: it carries an instruction to follow.
    private(set) var notice: String?
    private(set) var lastUpdated: Date?
    /// Last config the poll read. Published so the header can show the armed
    /// threshold and the plots can draw it — no extra file read, this is the
    /// value `maybeAutoSwitch` already loads on every pass.
    private(set) var config = CbarConfig()
    /// Jobs queued or running on `work`. A count, not a flag, so one finishing
    /// does not clear another's spinner. Main thread only.
    private var pendingJobs = 0
    /// Something is queued or running on `work`: the panel spins Refresh and
    /// holds the buttons that would queue more behind it.
    var busy: Bool { pendingJobs > 0 }

    var onUpdate: (() -> Void)?

    private let store = AccountStore()
    private let usage: UsageService
    private let switcher: Switcher
    /// Session-file Codex card, shown only until a Codex account is stored.
    private let codex = CodexProvider()
    private let codexStore = CodexAccountStore()
    private let codexUsage: CodexUsageService
    private let codexSwitcher: CodexSwitcher
    private let codexInbox = CodexLoginInbox()
    /// Live-login snapshots only: no stored slots, no switch.
    private let grok = GrokUsageService()
    private let antigravity = AntigravityUsageService()
    /// Separate from Claude's: the two rewrite different logins, and one
    /// provider's switch must not hold the other's escape in cooldown.
    private var lastCodexSwitchAt: Date?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let interval: TimeInterval = 60   // pacing gates the actual network hits
    private var lastAutoSwitchAt: Date?
    /// Hand-picked Claude slot that pre-warm must leave alone (see `manualPin`).
    private var manualClaudeSlot: Int?
    private let autoSwitchCooldown: TimeInterval = 120
    /// Display asleep, not the machine. Gates the timer tick rather than stopping
    /// it — see `pollsWhileDark`.
    private var screensAsleep = false
    /// Watches the Codex login inbox so a finished `codex login` is imported
    /// now rather than at the next poll (see `watchCodexInbox`).
    private var inboxWatch: DispatchSourceFileSystemObject?
    private var inboxDebounce: DispatchWorkItem?

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
        enqueue { [weak self] in
            var err: String?
            do { try body() } catch {
                // Words for the banner; the raw form, which names the type and
                // code, is for the log.
                err = "Couldn't \(what): \(describeError(error))"
                CbarLog.write("\(what) FAILED: \(error)")
            }
            // Hand the message to the refresh rather than setting it here: the
            // refresh that follows every mutation assigns `lastError` itself, so
            // setting it first just means the user never sees it.
            self?.refresh(carrying: err)
        }
    }

    /// Every job goes on `work` through here, so `busy` sees it from the moment
    /// it is queued. Callable from any thread; the count only moves on main.
    private func enqueue(_ job: @escaping () -> Void) {
        if Thread.isMainThread { pendingJobs += 1 } else {
            DispatchQueue.main.async { [weak self] in self?.pendingJobs += 1 }
        }
        work.async { [weak self] in
            job()
            // Lands after anything `job` put on main — the UI update, and a
            // follow-up refresh's own +1 — so the count never dips to zero
            // between a mutation and the refresh it hands off to.
            DispatchQueue.main.async { self?.pendingJobs -= 1 }
        }
    }

    init() {
        usage = UsageService(store: store)
        switcher = Switcher(store: store)
        codexUsage = CodexUsageService(store: codexStore)
        codexSwitcher = CodexSwitcher(store: codexStore)
    }

    func setEnabled(_ enabled: Bool, for setting: CbarConfig.SwitchSetting) {
        do {
            try CbarConfig.setEnabled(enabled, for: setting)
            config = CbarConfig.load()
            lastError = nil
            CbarLog.write("\(setting.rawValue) = \(enabled)")
        } catch {
            lastError = "Couldn't save the setting: \(describeError(error))"
            CbarLog.write("save \(setting.rawValue) FAILED: \(error)")
        }
        onUpdate?()
    }

    /// True when there are no accounts yet but a cswap backup exists to import.
    var canImportCswap: Bool { store.list().isEmpty && CswapImport.available() }

    func start() {
        SecureFile.tightenAll(dir: "\(NSHomeDirectory())/.cbar")
        OAuthClient.purgeLegacyHTTPStorage()
        // First run writes the config, so what cbar is armed to do is a file the
        // user can read — not a default they have to find in the source. Before
        // the first refresh, so pass one already sees the real settings.
        if CbarConfig.seedIfMissing() {
            CbarLog.write("wrote default ~/.cbar/config.json (auto-switch on, pre-warm on)")
            // Once by construction: the seed only happens when there is no
            // config. Both defaults rewrite the live login unasked, which a new
            // user should hear from the app, not only from the README.
            notice = "Auto-switch and pre-warm are on: cbar changes which account Claude Code is logged into, on its own. Click the AUTO pill at the top to turn them off."
        }
        config = CbarConfig.load()
        refresh()
        startTimer()
        watchCodexInbox()

        // A dark display means nobody can read the icon, so a pass behind it is a
        // network request, four process spawns and a tree walk spent on nothing —
        // UNLESS a Claude Code session is running, which is exactly when a 5h
        // window is filling in the dark and rotating off it is the whole job.
        // `pollsWhileDark` is that rule; the timer keeps ticking either way and
        // the tick decides, so an idle dark machine costs one config read per
        // minute instead of a full pass.
        //
        // This used to hard-stop the timer on screen sleep. Cheaper, and wrong
        // once auto-switch became the default: it meant a long unattended session
        // rode its account straight into the wall while cbar sat next to it with
        // the answer.
        //
        // Screen sleep, not system sleep: the system kind stops the timer for us
        // by stopping the machine, and cbar will not hold a power assertion to
        // prevent that. This is the case that runs for hours on battery with the
        // lid open and the display off.
        let nc = NSWorkspace.shared.notificationCenter
        observers = [
            nc.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                           object: nil, queue: .main) { [weak self] _ in self?.screensAsleep = true },
            nc.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                           object: nil, queue: .main) { [weak self] _ in
                self?.screensAsleep = false
                // Refresh on the way back: the cache is as stale as the last dark
                // tick that decided to skip, and the user is looking at the icon
                // right now. `startTimer` is belt-and-braces — nothing stops the
                // timer any more, and it no-ops if one is already running.
                self?.startTimer()
                self?.refresh()
            },
        ]
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        observers.forEach { nc.removeObserver($0) }
        // Screen sleep no longer stops the timer, so this is the only place left
        // that does. The closure captures `self` weakly, so a surviving timer
        // would not leak — it would just fire into nothing once a minute.
        stopTimer()
        inboxDebounce?.cancel()
        inboxWatch?.cancel()
    }

    /// `codex login` into the inbox used to wait for the next poll — up to 60 s
    /// with a live token sitting in a plaintext file. A directory source fires
    /// when an entry is added or removed; Codex creates `auth.json` and writes
    /// it in one go, so a 1 s debounce lands after the write. The directory is
    /// created here (0700, as `CodexLoginInbox.prepare` would) so there is
    /// something to watch before the first Add.
    private func watchCodexInbox() {
        inboxWatch?.cancel()
        inboxWatch = nil
        let dir = codexInbox.dir
        try? SecureFile.ensureDir(dir)
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else {
            CbarLog.write("codex login inbox: cannot watch \(dir) (errno \(errno)) — imports wait for the poll")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
                                                            eventMask: [.write, .delete, .rename],
                                                            queue: .main)
        src.setEventHandler { [weak self, weak src] in
            guard let self, let src else { return }
            // Deleted or moved: the fd now watches a directory nobody uses.
            // Re-arm on a fresh one at the same path.
            if !src.data.isDisjoint(with: [.delete, .rename]) { self.watchCodexInbox(); return }
            self.inboxDebounce?.cancel()
            let item = DispatchWorkItem { [weak self] in
                // Only when there is a login to take. Importing empties the
                // directory, which fires this again; that pass must not refresh.
                guard let self, FileManager.default.fileExists(atPath: "\(dir)/auth.json") else { return }
                self.refresh()
            }
            self.inboxDebounce = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        inboxWatch = src
    }

    private func startTimer() {
        guard timer == nil else { return }   // waking twice must not stack timers
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard !self.screensAsleep || self.worthPollingInTheDark() else { return }
            self.refresh()
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

    /// Re-reads the config rather than using the published `config`: that copy is
    /// only refreshed by a poll, and a run of skipped dark ticks is precisely when
    /// it would go stale — arming cbar with the screen off would then never take
    /// effect. The read is one small file; the pgrep behind it only happens when
    /// cbar is armed.
    ///
    /// ponytail: this runs pgrep on the main thread, once a minute, only while the
    /// display is asleep and cbar is armed. Same shape as the one in
    /// `maybeAutoSwitch`; move both off-main together if the poll ever gets hot.
    private func worthPollingInTheDark() -> Bool {
        let cfg = CbarConfig.load()
        return pollsWhileDark(autoSwitchEnabled: cfg.autoSwitchEnabled,
                              preWarmEnabled: cfg.preWarmEnabled,
                              claudeCodeRunning: UsageService.claudeCodeRunning())
    }

    /// `carrying` is a mutation's failure message, which outranks anything the
    /// refresh itself hits — the user clicked a thing and it didn't work, and
    /// that is what they need told. Cleared by the next ordinary poll.
    func refresh(carrying: String? = nil) {
        enqueue { [weak self] in
            guard let self else { return }
            var accs: [Account] = []
            var err: String? = carrying
            var added: String?
            do { accs = try self.usage.accounts() } catch {
                err = err ?? "Couldn't read Claude usage: \(describeError(error))"
                CbarLog.write("refresh FAILED: \(error)")
            }
            // A login finished in the inbox since the last pass (see `addCodexAccount`).
            do {
                if let n = try self.codexInbox.importIfPresent(into: self.codexStore) {
                    self.codexUsage.clearFailureState(n)
                    let email = self.codexStore.list().first { $0.number == n }?.email ?? "#\(n)"
                    added = "Codex account \(email) added"
                    CbarLog.write("codex account #\(n) \(email) imported from login inbox")
                }
            } catch {
                err = err ?? "Couldn't import the Codex login: \(describeError(error))"
                CbarLog.write("import Codex login FAILED: \(error)")
            }
            accs += self.codexStore.list().isEmpty ? ((try? self.codex.accounts()) ?? []) : self.codexUsage.accounts()
            accs += self.grok.accounts()
            accs += self.antigravity.accounts()
            DispatchQueue.main.async {
                self.accounts = accs
                self.lastError = err
                if let added { self.notice = added }
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
        let activeClaude = accounts.first(where: { $0.isActive && $0.provider == "claude" })
        manualClaudeSlot = manualPin(manualClaudeSlot, active: activeClaude?.number)
        // Before Claude's guard: Codex has its own switch, independent of Claude's two.
        if cfg.codexAutoSwitchEnabled { maybeAutoSwitchCodex(threshold: cfg.autoSwitchThreshold) }
        guard cfg.autoSwitchEnabled || cfg.preWarmEnabled else { return }
        // Observability: log the active account's switch-usage + decision each poll,
        // so it's visible in Console why auto-switch does or doesn't fire.
        if let active = activeClaude {
            let err = active.meters.isEmpty ? " (no usage data — stale/rate-limited/expired token)" : ""
            let held = manualClaudeSlot != nil ? " (picked by hand: no pre-warm)" : ""
            CbarLog.write("auto-switch check active #\(active.number) \(active.email) 5h=\(Int(switchPct(active)))% thr=\(Int(cfg.autoSwitchThreshold))% 7d=\(Int(sevenDayPct(active)))%/\(Int(sevenDayCeiling))%\(err)\(held)")
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
        } else if cfg.preWarmEnabled, manualClaudeSlot == nil, UsageService.claudeCodeRunning(),
                  let active = activeClaude?.number,
                  let t = preWarmMove(accounts: accounts, active: active, escapeThreshold: cfg.autoSwitchThreshold) {
            let home = burnHome(accounts, escapeThreshold: cfg.autoSwitchThreshold)
            reason = t == home ? "pre-warm return to burn account" : "pre-warm excursion (open idle 5h)"
            target = t
        }
        guard let target else { return }
        if let last = lastAutoSwitchAt, Date().timeIntervalSince(last) < autoSwitchCooldown {
            CbarLog.write("auto-switch WANTED → #\(target) (\(reason)) but in cooldown")
            return
        }
        guard let acc = accounts.first(where: { $0.number == target && $0.provider == "claude" }) else { return }
        lastAutoSwitchAt = Date()   // prevent re-entry while the async switch runs
        CbarLog.write("auto-switch triggered → #\(target) \(acc.email) (\(reason))")
        enqueue { [weak self] in
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

    /// Codex's escape: the active slot's switch window hit the threshold. Lands on
    /// the next `codex` started — a running one keeps its account — so there is
    /// nothing to gain from switching faster than the cooldown.
    private func maybeAutoSwitchCodex(threshold: Double) {
        guard let target = codexAutoSwitchTarget(accounts: accounts, threshold: threshold) else { return }
        if let last = lastCodexSwitchAt, Date().timeIntervalSince(last) < autoSwitchCooldown {
            CbarLog.write("codex auto-switch WANTED → #\(target) but in cooldown")
            return
        }
        let active = accounts.first { $0.provider == "codex" && $0.isActive }
        let pct = active.flatMap(codexSwitchMeter).map { "\($0.id)=\(Int($0.pct))%" } ?? "?"
        lastCodexSwitchAt = Date()
        CbarLog.write("codex auto-switch triggered #\(active?.number ?? 0) (\(pct)) → #\(target)")
        enqueue { [weak self] in
            guard let self else { return }
            do {
                try self.codexSwitcher.switchTo(target)
                if CodexLive.daemonRunning() {
                    CbarLog.write("codex auto-switch wrote #\(target) to auth.json, but the app-server daemon is running — NOT applied until it restarts")
                } else {
                    CbarLog.write("codex auto-switch OK → #\(target) (new codex sessions only)")
                }
            } catch {
                CbarLog.write("codex auto-switch FAILED → #\(target): \(error) (retry after cooldown)")
            }
            self.refresh()
        }
    }

    func switchTo(_ account: Account) {
        guard account.switchable else { return }
        if account.provider == "codex" {
            lastCodexSwitchAt = Date()
            mutate("switch Codex to account #\(account.number)") { [weak self, codexSwitcher] in
                try codexSwitcher.switchTo(account.number)
                let daemon = CodexLive.daemonRunning()
                CbarLog.write("codex manual switch → #\(account.number)"
                              + (daemon ? " — app-server daemon running, NOT applied until it restarts" : ""))
                DispatchQueue.main.async {
                    self?.notice = daemon
                        ? "Codex login set to \(account.email), but the Codex daemon is running and keeps its account — run `codex app-server daemon stop`"
                        : "Codex switched to \(account.email) — applies to the next codex you start"
                }
            }
            return
        }
        // Arm the shared cooldown so the next poll's auto-switch/pre-warm doesn't
        // reverse a hand-picked account a second later — the auto path only wrote
        // this timestamp itself, so a manual switch used to be fair game to undo.
        lastAutoSwitchAt = Date()
        mutate("switch to account #\(account.number)") { [weak self, switcher] in
            try switcher.switchTo(account.number)
            CbarLog.write("manual switch → #\(account.number) \(account.email)")
            // Main, like every other read of it; queued ahead of the refresh
            // `mutate` runs next, so that pass already sees the pin.
            DispatchQueue.main.async { self?.manualClaudeSlot = account.number }
        }
    }

    func switchToBest() {
        // Same viability gate as auto-switch — "best" must not mean "the dead one
        // whose 11-day-old cache looks empty" (2026-07-25).
        let candidates = accounts.filter { $0.provider == "claude" && !$0.isActive && isSwitchTarget($0) }
        guard let best = candidates.min(by: { switchPct($0) < switchPct($1) }) else { return }
        switchTo(best)
    }

    func dismissNotice() { notice = nil }

    func addCurrent() {
        // Clear the slot's stale failure state after capturing fresh creds — this
        // IS the "fix a dead slot" path, and its backoff/needs-reauth must not
        // outlive the re-login (credsChanged can't see it, slot == live).
        mutate("add the Claude account") { [store, usage] in
            let n = try store.addCurrent()
            usage.clearFailureState(n)
        }
    }

    func remove(_ account: Account) {
        guard account.switchable else { return }
        if account.provider == "codex" {
            mutate("remove Codex account #\(account.number)") { [codexStore, codexUsage] in
                try codexStore.remove(account.number)
                codexUsage.forget(account.number)
            }
        } else {
            mutate("remove account #\(account.number)") { [store, usage] in
                try store.remove(account.number)
                usage.forget(account.number)
            }
        }
    }

    /// One button, two steps. While the live Codex login is one cbar hasn't saved,
    /// save it. Once it has, the next account has to be logged into somewhere
    /// OTHER than `~/.codex` — `codex login` there would revoke the one just
    /// saved — so hand over the inbox command and import on a later poll.
    func addCodexAccount() {
        mutate("add the Codex account") { [weak self, codexStore, codexInbox, codexUsage] in
            if let mode = CodexLive.credentialsStore(), mode != "file" {
                throw CodexSwitcher.SwitchErr.unsupportedStore(mode)
            }
            if case .login(let live) = CodexLive.read(), codexStore.slot(for: live) == nil {
                let n = try codexStore.add(live)
                codexUsage.clearFailureState(n)
                DispatchQueue.main.async { self?.notice = "Saved current Codex login (\(live.email ?? "#\(n)")). Choose Add account › Codex again to add another." }
                return
            }
            try codexInbox.prepare(importingInto: codexStore)
            let cmd = codexInbox.command
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
                self?.notice = """
                Copied. Add another Codex account:
                1. Paste in Terminal (not plain `codex login` — that revokes the saved one):
                \(cmd)
                2. Log into the other ChatGPT account
                3. cbar imports it as soon as the login finishes
                """
            }
        }
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
