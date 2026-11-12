import AppKit

/// Owns the menu-bar status item and a custom borderless panel that is placed
/// at an ABSOLUTE screen position derived from the status item's frame — top
/// edge just below the menu bar, growing downward. Re-anchored on every resize
/// so it can never drift off the top of the screen.
final class StatusItemController: NSObject {
    private let item: NSStatusItem
    private var content: NSViewController?
    private var panel: NSPanel?
    private var monitor: Any?
    private var keyMonitor: Any?

    /// Taken from the view rather than restated: these drifted apart once already
    /// (the panel stayed 340 when the popover went to 372) and the panel silently
    /// clipped 32pt off the right of every card. Width follows `PopoverView`.
    private let width = PopoverView.panelWidth
    private var contentHeight: CGFloat = 420

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        render(tooltip: "cbar")
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
        // Key, so Esc reaches us (see `KeyPanel`). A LOCAL monitor because the
        // key event is now delivered to this app: a global one only sees events
        // bound for other apps, and for keys it needs Accessibility permission.
        panel.makeKey()
        removeMonitors()
        // Close on any click outside our app (status-item clicks stay local and
        // do not trigger this, so toggle keeps working without a reopen loop).
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // kVK_Escape
            self?.close()
            return nil
        }
    }

    private func close() {
        panel?.orderOut(nil)
        removeMonitors()
    }

    private func removeMonitors() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
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
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: contentHeight),
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

    /// `title` is the active account's percent ("42%"), nil for the bare glyph.
    /// `alert` reddens it: re-login needed, or at the switch threshold.
    func render(tooltip: String, title: String? = nil, alert: Bool = false) {
        guard let button = item.button else { return }
        // Template: system paints it white on a dark menu bar, black on light.
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let img = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                          accessibilityDescription: "cbar")?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        button.image = img
        button.toolTip = tooltip
        // Monospaced digits so the item does not change width as the number moves.
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        if let title {
            button.imagePosition = .imageLeading
            if alert {
                // systemRed resolves against the menu bar's own appearance, so it
                // reads on a light and a dark bar alike.
                button.attributedTitle = NSAttributedString(string: title, attributes: [
                    .font: font, .foregroundColor: NSColor.systemRed])
            } else {
                // A plain title, not an attributed one without a color: that
                // would draw black on a dark menu bar. This keeps the bar's own
                // text color, the way the template image keeps its.
                button.font = font
                button.title = title
            }
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }
}

/// Borderless panels refuse key status by default, and a panel that is never
/// key gets no key events — Esc went to whatever app was frontmost. Being a
/// non-activating panel, it takes the keyboard while open without activating
/// cbar or bringing anything forward, the way Spotlight's panel does.
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
