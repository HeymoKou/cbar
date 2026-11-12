import AppKit
import SwiftUI
import CbarCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore!
    private var statusCtl: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = UsageStore()
        statusCtl = StatusItemController()
        let host = NSHostingController(rootView: PopoverView(store: store, onHeight: { [weak self] h in
            self?.statusCtl.updateContentHeight(h)
        }))
        statusCtl.attach(content: host)
        statusCtl.onPopoverOpen = { [weak self] in self?.store.refresh() }
        store.onUpdate = { [weak self] in
            guard let self else { return }
            let active = self.store.accounts.first { $0.provider == "claude" && $0.isActive }
            let tip = self.store.lastError
                ?? active.map { "\($0.email) · \(Int($0.maxPct.rounded()))%" }
                ?? "cbar"
            let badge = Self.menuBarBadge(active, config: self.store.config)
            self.statusCtl.render(tooltip: tip, title: badge.title, alert: badge.alert)
        }
        store.start()
    }

    /// The number next to the glyph: the active Claude account's 5h percent, or
    /// 7d on a plan without a 5h window — the meter auto-switch watches. Nothing
    /// without an active account or a reading, except "!" for a re-login, which
    /// is the one state worth flagging without a number.
    static func menuBarBadge(_ active: Account?, config: CbarConfig) -> (title: String?, alert: Bool) {
        guard config.menuBarPercent, let active else { return (nil, false) }
        let reauth = active.status == "needs-reauth"
        let meter = active.meters.first { $0.id == "5h" } ?? active.meters.first { $0.id == "7d" }
        let alert = reauth || isExhausted(active) || (meter.map { $0.pct >= config.autoSwitchThreshold } ?? false)
        if let meter { return ("\(Int(meter.pct.rounded()))%", alert) }
        return (reauth ? "!" : nil, alert)
    }
}
