import SwiftUI
import AppKit
import CbarCore

/// Button style with a hover wash + pressed state + pointer cursor.
struct HoverButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View { HoverLabel(configuration: configuration, compact: compact) }
    struct HoverLabel: View {
        let configuration: ButtonStyleConfiguration
        let compact: Bool
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(compact ? .caption : .callout)
                .padding(.horizontal, compact ? 7 : 9)
                .padding(.vertical, compact ? 3 : 5)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.18 : (hovering ? 0.10 : 0))))
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .onHover { h in
                    hovering = h
                    if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

private struct ListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct TotalHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PopoverView: View {
    let store: UsageStore
    /// Reports the view's total measured height so the panel can size + re-anchor
    /// itself absolutely below the menu bar.
    var onHeight: (CGFloat) -> Void = { _ in }

    /// Account list scrolls only past this; below it the list is its exact
    /// height (no slack). ~4 sections fit before scrolling kicks in.
    private let listCap: CGFloat = 470
    @State private var listHeight: CGFloat = 0

    /// cswap active first, then other cswap accounts, then Codex last.
    private var sortedAccounts: [Account] {
        func rank(_ a: Account) -> Int {
            if a.provider == "codex" { return 2 }
            return a.isActive ? 0 : 1
        }
        return store.accounts.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    if let error = store.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Health.crit.color)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(sortedAccounts) { acc in
                        AccountCard(acc: acc,
                                    switchAction: { store.switchTo(acc) },
                                    removeAction: (acc.provider == "claude" && !acc.isActive) ? { store.remove(acc.number) } : nil)
                    }
                }
                .padding(12)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ListHeightKey.self, value: g.size.height)
                })
            }
            .frame(height: min(max(listHeight, 1), listCap))
            .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            Divider()
            footer
        }
        .frame(width: 340)
        .background(.regularMaterial)
        .background(GeometryReader { g in
            Color.clear.preference(key: TotalHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(TotalHeightKey.self) { onHeight($0) }
    }

    private var claudeAccounts: [Account] { store.accounts.filter { $0.provider == "claude" } }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right.circle.fill")
                .font(.title3)
                .foregroundStyle(overallHealth(claudeAccounts).color)
            VStack(alignment: .leading, spacing: 0) {
                Text("cbar").font(.headline)
                Text("Claude usage").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(claudeAccounts.count) account\(claudeAccounts.count == 1 ? "" : "s")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                Button { store.addCurrent() } label: { Label("Add current account", systemImage: "plus.circle") }
                Spacer()
                if store.canImportCswap {
                    Button { store.importCswap() } label: { Label("Import from cswap", systemImage: "square.and.arrow.down") }
                }
            }
            HStack(spacing: 4) {
                Button { store.switchToBest() } label: { Label("Switch to best", systemImage: "bolt.fill") }
                Spacer()
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            HStack {
                Text(store.cacheAgeText).font(.caption2).foregroundStyle(.secondary).padding(.leading, 6)
                Spacer()
                Button { NSApp.terminate(nil) } label: { Text("Quit") }
            }
        }
        .buttonStyle(HoverButtonStyle())
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }
}

/// One account: header row (dot · email · ACTIVE badge / Switch) + its meters.
struct AccountCard: View {
    let acc: Account
    let switchAction: () -> Void
    var removeAction: (() -> Void)? = nil
    @State private var hovering = false

    private var ageText: String? {
        guard acc.provider == "codex", let a = acc.ageSeconds, a > 90 else { return nil }
        if a >= 3600 { return "cached \(Int(a / 3600))h ago" }
        return "cached \(Int(a / 60))m ago"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle()
                    .fill(acc.isActive ? activeGreen : Color.secondary.opacity(0.35))
                    .frame(width: 8, height: 8)
                Text(acc.email)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                if let ageText {
                    Text("· \(ageText)").font(.caption2).foregroundStyle(.secondary)
                }
                if acc.status == "needs-reauth" {
                    Text("RE-LOGIN")
                        .font(.system(.caption2, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Health.crit.color.opacity(0.18)))
                        .foregroundStyle(Health.crit.color)
                }
                Spacer(minLength: 6)
                if acc.isActive {
                    Text("ACTIVE")
                        .font(.system(.caption2, weight: .heavy))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(activeGreen.opacity(0.16)))
                        .foregroundStyle(activeGreen)
                } else if acc.switchable {
                    Button("Switch", action: switchAction).buttonStyle(HoverButtonStyle(compact: true))
                    if let removeAction {
                        Button(action: removeAction) { Image(systemName: "xmark") }
                            .buttonStyle(HoverButtonStyle(compact: true))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(acc.meters) { m in
                MeterBar(label: m.id, pct: m.pct, countdown: m.countdown,
                         color: Metric.color(for: m.id))
            }
            if acc.meters.isEmpty {
                Text(acc.status == "needs-reauth" ? "Re-login needed (run Claude Code login)" : "no data yet")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(Color.primary.opacity(hovering && !acc.isActive ? 0.07 : 0.04)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(acc.isActive ? activeGreen.opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
