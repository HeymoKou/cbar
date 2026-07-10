import Foundation
import CbarCore

@Observable
final class UsageStore {
    private(set) var accounts: [Account] = []
    private(set) var lastError: String?
    private(set) var lastUpdated: Date?

    var onUpdate: (() -> Void)?

    private let store = AccountStore()
    private let usage: UsageService
    private let switcher: Switcher
    private let codex = CodexProvider()
    private var timer: Timer?
    private let interval: TimeInterval = 60   // pacing gates the actual network hits
    private var lastAutoSwitchAt: Date?
    private let autoSwitchCooldown: TimeInterval = 120

    init() {
        usage = UsageService(store: store)
        switcher = Switcher(store: store)
    }

    /// True when there are no accounts yet but a cswap backup exists to import.
    var canImportCswap: Bool { store.list().isEmpty && CswapImport.available() }

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var accs: [Account] = []
            var err: String?
            do { accs = try self.usage.accounts() } catch { err = "\(error)" }
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
        guard cfg.autoSwitchEnabled else { return }
        // Observability: log the active account's switch-usage + decision each poll,
        // so it's visible in Console why auto-switch does or doesn't fire.
        if let active = accounts.first(where: { $0.isActive && $0.provider == "claude" }) {
            let err = active.meters.isEmpty ? " (no usage data — stale/rate-limited/expired token)" : ""
            CbarLog.write("auto-switch check active #\(active.number) \(active.email) 5h/7d=\(Int(switchPct(active)))% thr=\(Int(cfg.autoSwitchThreshold))%\(err)")
        }
        guard let target = autoSwitchTarget(accounts: accounts, threshold: cfg.autoSwitchThreshold) else { return }
        if let last = lastAutoSwitchAt, Date().timeIntervalSince(last) < autoSwitchCooldown {
            CbarLog.write("auto-switch WANTED → #\(target) but in cooldown")
            return
        }
        guard let acc = accounts.first(where: { $0.number == target && $0.provider == "claude" }) else { return }
        lastAutoSwitchAt = Date()   // prevent re-entry while the async switch runs
        CbarLog.write("auto-switch triggered → #\(target) \(acc.email) (active ≥ \(Int(cfg.autoSwitchThreshold))%)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? self?.switcher.switchTo(account.number)
            self?.refresh()
        }
    }

    func switchToBest() {
        let candidates = accounts.filter { $0.provider == "claude" && $0.switchable && !$0.isActive && !$0.meters.isEmpty }
        guard let best = candidates.min(by: { $0.maxPct < $1.maxPct }) else { return }
        switchTo(best)
    }

    func addCurrent() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = try? self?.store.addCurrent()
            self?.refresh()
        }
    }

    func remove(_ number: Int) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? self?.store.remove(number)
            self?.refresh()
        }
    }

    func importCswap() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            _ = try? CswapImport.importAll(into: self.store)
            self.refresh()
        }
    }

    var cacheAgeText: String {
        let ages = accounts.filter { $0.provider == "claude" }.compactMap(\.ageSeconds)
        guard let age = ages.max() else { return "—" }
        return "cached \(Int(age))s ago"
    }
}
