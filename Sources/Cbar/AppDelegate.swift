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
            // Menu-bar icon reflects the live-polled Claude accounts only; Codex
            // snapshots can be stale and would otherwise dim/redden the icon.
            let claudeAccts = self.store.accounts.filter { $0.provider == "claude" }
            let overall = overallHealth(claudeAccts)
            let stale = anyStale(claudeAccts)
            let active = claudeAccts.first(where: \.isActive)
            let tip = self.store.lastError
                ?? active.map { "\($0.email) · \(Int($0.maxPct.rounded()))%" }
                ?? "cbar"
            self.statusCtl.render(overall: overall, stale: stale, tooltip: tip)
        }
        store.start()
    }
}
