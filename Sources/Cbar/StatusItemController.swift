import AppKit
import CbarCore

/// Owns the menu-bar status item and a custom borderless panel that is placed
/// at an ABSOLUTE screen position derived from the status item's frame — top
/// edge just below the menu bar, growing downward. Re-anchored on every resize
/// so it can never drift off the top of the screen.
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private var content: NSViewController?
    private var panel: NSPanel?
    private var monitor: Any?

    private let width: CGFloat = 340
    private var contentHeight: CGFloat = 420

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        render(overall: .healthy, stale: false, tooltip: "cbar")
    }

    /// Attach the SwiftUI-hosting content (created after init to break the
    /// content↔controller wiring cycle).
    func attach(content: NSViewController) { self.content = content }

    var onPopoverOpen: (() -> Void)?

    /// Called by the SwiftUI content when its measured height changes.
    func updateContentHeight(_ h: CGFloat) {
        guard h > 1 else { return }
        contentHeight = h
        if let p = panel, p.isVisible { resizeAndAnchor(p) }
    }

    @objc private func toggle() {
        if let p = panel, p.isVisible { close() } else { open() }
    }

    private func open() {
        guard item.button?.window != nil, let content else { return }
        onPopoverOpen?()
        let panel = self.panel ?? makePanel(content: content)
        self.panel = panel
        resizeAndAnchor(panel)
        panel.orderFrontRegardless()
        // Close on any click outside our app (status-item clicks stay local and
        // do not trigger this, so toggle keeps working without a reopen loop).
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func close() {
        panel?.orderOut(nil)
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func resizeAndAnchor(_ panel: NSPanel) {
        guard let statusWin = item.button?.window else { return }
        let size = NSSize(width: width, height: max(contentHeight, 80))
        panel.setContentSize(size)

        let slot = statusWin.frame            // the menu-bar slot holding our button
        let gap: CGFloat = 6
        var x = slot.midX - size.width / 2
        var y = slot.minY - gap - size.height // top edge just below the menu bar
        if let screen = statusWin.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
            if y < vf.minY + 8 { y = vf.minY + 8 }
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func makePanel(content: NSViewController) -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: contentHeight),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        p.contentViewController = content
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.backgroundColor = .clear
        p.hasShadow = true
        content.view.wantsLayer = true
        content.view.layer?.cornerRadius = 12
        content.view.layer?.masksToBounds = true
        return p
    }

    func render(overall: Health, stale: Bool, tooltip: String) {
        var color = overall.nsColor
        if stale { color = color.withAlphaComponent(0.5) }
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            .applying(.init(paletteColors: [color]))
        let img = NSImage(systemSymbolName: "arrow.left.arrow.right.circle.fill",
                          accessibilityDescription: "cbar")?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = false
        item.button?.image = img
        item.button?.toolTip = tooltip
    }
}
