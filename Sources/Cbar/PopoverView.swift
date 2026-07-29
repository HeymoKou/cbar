import SwiftUI
import AppKit
import CbarCore

/// Button style with a hover wash + pressed state + pointer cursor.
struct HoverButtonStyle: ButtonStyle {
    var compact = false
    /// Nocturne's footer and card buttons carry their own size and color, so the
    /// style only supplies the wash. `nil` keeps whatever the label set.
    var font: Font? = nil
    func makeBody(configuration: Configuration) -> some View {
        HoverLabel(configuration: configuration, compact: compact, font: font)
    }
    struct HoverLabel: View {
        let configuration: ButtonStyleConfiguration
        let compact: Bool
        let font: Font?
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(font ?? (compact ? .caption : .callout))
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

/// Nocturne's signature rule: a hairline that fades out over the last 48pt at
/// each end instead of stopping against the panel edge. Freestanding rules fade;
/// card outlines and the rules between metric cells stay solid.
private struct FadingRule: View {
    /// 48pt of ramp an end, as a fraction of the panel's fixed 372pt width.
    private let fade = 48.0 / PopoverView.panelWidth
    var body: some View {
        let line = Noct.ink.opacity(0.14)
        return LinearGradient(
            stops: [.init(color: line.opacity(0), location: 0),
                    .init(color: line, location: fade),
                    .init(color: line, location: 1 - fade),
                    .init(color: line.opacity(0), location: 1)],
            startPoint: .leading, endPoint: .trailing)
        .frame(height: 1)
    }
}

/// A small all-caps chip. `ACTIVE`, `NEXT TARGET`, `WEEK EXHAUSTED`, `RE-LOGIN`.
private struct Badge: View {
    let text: String
    let fg: Color
    let bg: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(bg))
            .foregroundStyle(fg)
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

    /// Fixed, and read by `FadingRule` to place its ramps in absolute points.
    static let panelWidth: CGFloat = 372

    /// Header + footer + the two rules, measured off the rendered panel. Only used
    /// to work out how much of the screen is left for the list.
    private let chrome: CGFloat = 142

    /// The list scrolls only when it would otherwise run off the bottom of the
    /// screen — the panel hangs from the menu bar, so the screen is the real
    /// limit. A fixed 470pt cap scrolled at four accounts on a display with room
    /// for ten, which put the last card behind a scroll gesture for no reason.
    private var listCap: CGFloat {
        let usable = (NSScreen.main?.visibleFrame.height ?? 800) - chrome - 32
        return max(240, usable)
    }
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

    private var claudeAccounts: [Account] { store.accounts.filter { $0.provider == "claude" } }
    private var stale: Bool { activeStale(claudeAccounts) }
    /// Where auto-switch would go next, so the destination can say so before it
    /// happens instead of the switch appearing out of nowhere.
    private var nextTarget: Int? {
        guard store.config.autoSwitchEnabled else { return nil }
        return autoSwitchTarget(accounts: store.accounts, threshold: store.config.autoSwitchThreshold)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            FadingRule()
            ScrollView {
                VStack(spacing: 12) {
                    if let error = store.lastError { errorBanner(error) }
                    if claudeAccounts.isEmpty {
                        emptyState
                    } else {
                        ForEach(sortedAccounts) { acc in card(for: acc) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ListHeightKey.self, value: g.size.height)
                })
            }
            .frame(height: min(max(listHeight, 1), listCap))
            .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
            FadingRule()
            footer
        }
        .frame(width: Self.panelWidth)
        .background(LinearGradient(colors: [Noct.panelTop, Noct.panelBottom],
                                   startPoint: .top, endPoint: .bottom))
        .background(GeometryReader { g in
            Color.clear.preference(key: TotalHeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(TotalHeightKey.self) { onHeight($0) }
    }

    /// Built statement by statement rather than inline in the `ForEach`: as one
    /// expression the argument list took the type-checker past its budget.
    private func card(for acc: Account) -> AccountCard {
        let armed: Double? = store.config.autoSwitchEnabled ? store.config.autoSwitchThreshold : nil
        let isNext = acc.provider == "claude" && acc.number == nextTarget
        let canRemove = acc.provider == "claude" && !acc.isActive
        // Claude only. Codex numbers are as old as the last Codex run and no poll
        // can make them fresher, so "40 minutes old" is its resting state, not a
        // fault — hatching it would cry wolf on every card, every time. Its age
        // still shows in the card header, which is where it belongs.
        let isStale = acc.provider == "claude" && (acc.ageSeconds ?? 0) > 600
        return AccountCard(acc: acc,
                           stale: isStale,
                           threshold: armed,
                           isNextTarget: isNext,
                           switchAction: { store.switchTo(acc) },
                           removeAction: canRemove ? { store.remove(acc.number) } : nil)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            // Mirrors the menu-bar icon, including its dim-when-stale, so the thing
            // you clicked and the thing that opened are visibly the same object.
            Circle()
                .fill(activeHealth(claudeAccounts).color.opacity(stale ? 0.5 : 1))
                .frame(width: 18, height: 18)
                .overlay(Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Noct.panelBottom))
            Text("cbar").font(.system(size: 14, weight: .medium)).foregroundStyle(Noct.ink)
            Rectangle().fill(Noct.hairline).frame(width: 1, height: 12)
            Text(stale ? "data \(store.cacheAgeShort) old" : "Claude usage")
                .font(.system(size: 11))
                .foregroundStyle(stale ? Noct.ink5 : Noct.ink4)
            Spacer(minLength: 4)
            statusPill
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 14))
            }
            .buttonStyle(HoverButtonStyle(compact: true))
            // Stale is the one time refreshing by hand is worth offering, so the
            // affordance brightens rather than sitting at chrome weight.
            .foregroundStyle(stale ? Noct.accentTextDim : Noct.ink4)
            .help("Refresh")
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .padding(.top, 13)
        .padding(.bottom, 11)
    }

    /// One chip, two jobs: the account count normally, and the armed threshold
    /// when auto-switch is on — because that is the fact that changes what the
    /// panel is about to do on its own.
    private var statusPill: some View {
        let auto = store.config.autoSwitchEnabled
        let empty = claudeAccounts.isEmpty
        let text = auto
            ? "AUTO ON · \(Int(store.config.autoSwitchThreshold))%"
            : "\(claudeAccounts.count) ACCOUNT\(claudeAccounts.count == 1 ? "" : "S")"
        return Text(text)
            .font(.system(size: 10, weight: .medium))
            .tracking(0.6)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(Capsule().stroke(auto ? Noct.accentLine : (empty ? Noct.hairlineSoft : Noct.hairline),
                                      lineWidth: 1))
            .foregroundStyle(auto ? Noct.accentText : (empty ? Noct.ink5 : Noct.ink4))
    }

    // MARK: body pieces

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Noct.critIcon)
            Text(message)
                .font(.system(size: 10))
                .lineSpacing(3)
                .foregroundStyle(Noct.critText)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Noct.crit.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Noct.crit.opacity(0.4), lineWidth: 1))
        // The 2pt bar on the leading edge is what makes this read as an alert
        // rather than another card, at the size where the tint alone is too faint.
        .overlay(alignment: .leading) {
            Rectangle().fill(Noct.crit).frame(width: 2)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    /// Nothing tracked yet. The dashed outline says "this is where accounts will
    /// be", which an empty solid card does not.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("No accounts tracked yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Noct.ink2)
            Text("Log into an account in Claude Code, then Add current account. Repeat per account.")
                .font(.system(size: 10))
                .lineSpacing(4)
                .foregroundStyle(Noct.ink4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Button { store.addCurrent() } label: {
                    Label("Add current account", systemImage: "plus.circle")
                }
                .buttonStyle(HoverButtonStyle(font: .system(size: 11)))
                .foregroundStyle(Noct.accentText)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Noct.accentLine, lineWidth: 1))
                if store.canImportCswap {
                    Button { store.importCswap() } label: {
                        Label("Import from cswap", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(HoverButtonStyle(font: .system(size: 11)))
                    .foregroundStyle(Noct.ink3)
                }
            }
            .padding(.top, 5)
            .padding(.leading, -9)   // pull the buttons' own padding back to the text edge
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 22)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Noct.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    // MARK: footer

    /// Two rows so every item carries a word — Refresh moved up to the header as a
    /// pure icon, because it acts on the whole panel rather than on a list item.
    private var footer: some View {
        VStack(spacing: 5) {
            HStack {
                Button { store.switchToBest() } label: {
                    Label("Switch to best", systemImage: "bolt.fill")
                }
                .foregroundStyle(canSwitchToBest ? Noct.accentText : Noct.ink6)
                .overlay(canSwitchToBest
                         ? RoundedRectangle(cornerRadius: 7).stroke(Noct.accentLine, lineWidth: 1)
                         : nil)
                .disabled(!canSwitchToBest)
                Spacer()
                Button { store.addCurrent() } label: {
                    Label("Add current account", systemImage: "plus.circle")
                }
                .foregroundStyle(Noct.ink3)
            }
            HStack {
                Button { store.importCswap() } label: {
                    Label("Import from cswap", systemImage: "square.and.arrow.down")
                }
                .foregroundStyle(Noct.ink3)
                .disabled(!store.canImportCswap)
                .opacity(store.canImportCswap ? 1 : 0.45)
                Spacer()
                Button { NSApp.terminate(nil) } label: { Text("Quit") }
                    .foregroundStyle(Noct.ink3)
            }
            Text(statusLine)
                .font(.system(size: 10))
                .foregroundStyle(stale ? Noct.critText : Noct.ink5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.top, 2)
        }
        .buttonStyle(HoverButtonStyle(font: .system(size: 11)))
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// Same gate the button itself applies, so a disabled look never lies about
    /// what clicking would do.
    private var canSwitchToBest: Bool {
        store.accounts.contains { $0.provider == "claude" && !$0.isActive && isSwitchTarget($0) }
    }

    /// The cache age, plus the one fact that explains what happens next.
    private var statusLine: String {
        let age = store.cacheAgeText
        if age == "—" { return "—" }
        if stale { return "\(age) · numbers may be behind" }
        if store.config.autoSwitchEnabled { return "\(age) · auto-switch cooldown 120s" }
        return "\(age) · polls every 60s"
    }
}

/// One account: header row (dot · email · badges · ACTIVE / Switch / ✕) over a
/// row of framed metric plots divided by hairlines.
struct AccountCard: View {
    let acc: Account
    var stale = false
    /// Auto-switch threshold when it is armed, drawn on the active account's 5h.
    var threshold: Double? = nil
    var isNextTarget = false
    let switchAction: () -> Void
    var removeAction: (() -> Void)? = nil
    @State private var hovering = false

    private var exhausted: Bool { acc.provider == "claude" && isExhausted(acc) }
    private var ground: Color { acc.isActive ? (stale ? Noct.cardStale : Noct.cardActive) : Noct.card }
    private var border: Color {
        if acc.status == "needs-reauth" { return Noct.crit.opacity(0.35) }
        if acc.isActive { return stale ? Noct.accentFill : Noct.accentLine }
        return Noct.hairline
    }

    /// Only when the age is the point — stale, or Codex, whose numbers are as old
    /// as the last Codex run and have no fresher source to poll. On a healthy card
    /// this line costs the email its last characters and says nothing the footer
    /// doesn't already say.
    private var ageText: String? {
        guard stale || acc.provider == "codex", let a = acc.ageSeconds, a > 90 else { return nil }
        if a >= 3600 { return "cached \(Int(a / 3600))h ago" }
        return "cached \(Int(a / 60))m ago"
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            // No rule between the header and the plots: the grid's 1pt gaps are
            // the only lines inside a card, and they run vertically. The header's
            // own bottom padding does the separating.
            if !acc.meters.isEmpty { plots }
        }
        .background(ground)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(acc.isActive ? Noct.accent.opacity(stale ? 0.5 : 1) : Noct.ink6)
                .frame(width: 7, height: 7)
                // The halo marks the active account at 7pt, where a colored dot
                // alone is easy to miss against three others.
                .overlay(Circle().stroke(Noct.accent.opacity(acc.isActive && !stale ? 0.2 : 0), lineWidth: 3))
            Text(acc.email)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(acc.isActive && !stale ? Noct.ink : Noct.ink2)
                .lineLimit(1)
            if let ageText {
                Text("· \(ageText)").font(.system(size: 10)).foregroundStyle(Noct.ink5).lineLimit(1)
            }
            if exhausted {
                Badge(text: "WEEK EXHAUSTED", fg: Noct.critIcon, bg: Noct.crit.opacity(0.16))
            }
            if acc.status == "needs-reauth" {
                Badge(text: "RE-LOGIN", fg: Noct.critIcon, bg: Noct.crit.opacity(0.16))
            }
            if isNextTarget && !acc.isActive {
                Badge(text: "NEXT TARGET",
                      fg: Metric.number(for: "5h"), bg: Metric.color(for: "5h").opacity(0.16))
            }
            Spacer(minLength: 6)
            trailingControls
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, acc.meters.isEmpty ? 11 : 10)
        .background(alignment: .leading) {
            // The active card's header carries a short wash of the accent, fading
            // out by 70%. Chrome, not hue on data.
            if acc.isActive && !stale {
                LinearGradient(stops: [.init(color: Noct.accent.opacity(0.14), location: 0),
                                       .init(color: Noct.accent.opacity(0), location: 0.7)],
                               startPoint: .leading, endPoint: .trailing)
            }
        }
        .overlay(alignment: .bottomLeading) { statusNote }
    }

    /// Why a card has no numbers, said in the card. "no data yet" was hiding a
    /// slot with no keychain item at all for 17 h (2026-07-25).
    @ViewBuilder private var statusNote: some View {
        if acc.meters.isEmpty {
            Text(acc.status == "needs-reauth" ? "Re-login needed (run Claude Code login)"
                 : acc.status == "ok" ? "no data yet" : acc.status)
                .font(.system(size: 10))
                .foregroundStyle(Noct.ink5)
                .lineLimit(2)
                .padding(.horizontal, 27)
                .padding(.bottom, -6)
        }
    }

    @ViewBuilder private var trailingControls: some View {
        if acc.isActive {
            Badge(text: "ACTIVE",
                  fg: stale ? Noct.accentTextDim : Noct.accentText,
                  bg: stale ? Noct.accentFillDim : Noct.accentFill)
        } else if acc.switchable {
            HStack(spacing: 4) {
                // No Switch button for a slot cbar can't safely switch into —
                // clicking it wrote a dead token straight into the live keychain,
                // bypassing the auto-switch gate entirely. Remove (✕) stays
                // available: getting rid of a dead slot is the point.
                if isSwitchTarget(acc) {
                    Button("Switch", action: switchAction)
                        .buttonStyle(HoverButtonStyle(compact: true, font: .system(size: 11)))
                        .foregroundStyle(Noct.accentText)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Noct.accentLine, lineWidth: 1))
                }
                if let removeAction {
                    Button(action: removeAction) { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(HoverButtonStyle(compact: true))
                        .foregroundStyle(hovering ? Noct.ink3 : Noct.ink5)
                }
            }
        }
    }

    /// Every metric its own cell, split by 1pt solid rules — solid, because these
    /// divide data rather than sections, and a fading rule between two numbers
    /// reads as decoration.
    private var plots: some View {
        HStack(spacing: 0) {
            ForEach(Array(acc.meters.enumerated()), id: \.element.id) { i, m in
                if i > 0 { Rectangle().fill(Noct.ink.opacity(0.08)).frame(width: 1) }
                MeterPlot(label: m.id,
                          pct: m.pct,
                          caption: caption(for: m),
                          captionColor: captionColor(for: m),
                          color: Metric.color(for: m.id),
                          // A non-active account's numbers stay neutral: hue on
                          // every card at once would make none of them the subject.
                          numberColor: acc.isActive ? Metric.number(for: m.id) : Noct.ink2,
                          threshold: m.id == "5h" && acc.isActive ? threshold : nil,
                          stale: stale)
                .frame(maxWidth: .infinity)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The caption says the most useful thing available, in this order: why this
    /// metric is about to cause a switch, why this account is the destination,
    /// how old the reading is, then the plain reset countdown.
    private func caption(for m: Meter) -> String? {
        if m.id == "5h", acc.isActive, let t = threshold, m.pct >= t {
            return "over thr. \(Int(t))%"
        }
        if m.id == "5h", isNextTarget, !acc.isActive { return "most headroom" }
        // The reset countdown outranks the reading's age, including when the
        // reading is stale. How old the number is already appears in the card
        // header and in the hatched fill; when the window resets appears nowhere
        // else, and it is the fact you act on. This is where 3e is not followed:
        // Codex is ALWAYS minutes behind (its numbers are as old as the last Codex
        // run), so spending its one caption on "as of 35m ago" left the card
        // saying nothing but its own staleness, twice.
        if let c = m.countdown { return "resets \(c)" }
        if stale, let a = acc.ageSeconds { return "as of \(Int(a / 60))m ago" }
        return nil
    }

    private func captionColor(for m: Meter) -> Color? {
        if stale { return nil }
        if m.id == "5h", acc.isActive, let t = threshold, m.pct >= t { return Noct.critText }
        if m.id == "5h", isNextTarget, !acc.isActive { return Metric.number(for: "5h") }
        return nil
    }
}
