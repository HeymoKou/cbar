import SwiftUI
import AppKit
import CbarCore

/// SwiftUI's `State` property wrapper, under a name that cannot resolve to the
/// `@State` MACRO. From the macOS 27 SDK the attribute `@State` picks the macro,
/// which expands through `SwiftUIMacros` — a compiler plugin that ships with
/// Xcode but not the Command Line Tools. On a CLT-only Mac, which is all the
/// README asks for and what Homebrew builds with, every `@State` stopped
/// compiling. The wrapper type is unchanged and still in the SDK; only the
/// attribute lookup moved, so a typealias reaches it on every SDK.
typealias ViewState = SwiftUI.State

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
        @ViewState private var hovering = false
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
    /// 48pt of ramp an end, as a fraction of the panel width.
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
            .font(.system(size: 11, weight: .bold))
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
    static let panelWidth: CGFloat = 400

    /// Header + footer + the two rules, measured off the rendered panel. Only used
    /// to work out how much of the screen is left for the list.
    private let chrome: CGFloat = 118

    /// The list scrolls only when it would otherwise run off the bottom of the
    /// screen — the panel hangs from the menu bar, so the screen is the real
    /// limit. A fixed 470pt cap scrolled at four accounts on a display with room
    /// for ten, which put the last card behind a scroll gesture for no reason.
    private var listCap: CGFloat {
        let usable = (NSScreen.main?.visibleFrame.height ?? 800) - chrome - 32
        return max(240, usable)
    }
    @ViewState private var listHeight: CGFloat = 0

    /// Claude active first, then other Claude accounts, then Codex, Grok,
    /// Antigravity — monitor-only cards stay below anything switchable.
    private var sortedAccounts: [Account] {
        func rank(_ a: Account) -> Int {
            switch a.provider {
            case "claude": return a.isActive ? 0 : 1
            case "codex": return 2
            case "grok": return 3
            case "antigravity": return 4
            default: return 5
            }
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
    private var nextCodexTarget: Int? {
        guard store.config.codexAutoSwitchEnabled else { return nil }
        return codexAutoSwitchTarget(accounts: store.accounts, threshold: store.config.autoSwitchThreshold)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            FadingRule()
            ScrollView {
                VStack(spacing: 4) {
                    if let error = store.lastError { errorBanner(error) }
                    if let notice = store.notice { noticeBanner(notice) }
                    switchSettings
                    // Any row, not just Claude: Grok/Antigravity snapshots and
                    // a Codex-only store would otherwise never appear.
                    if store.accounts.isEmpty {
                        emptyState
                    } else {
                        ForEach(sortedAccounts) { acc in card(for: acc) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
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
        let codex = acc.provider == "codex"
        let cfg = store.config
        let armed: Double? = (codex ? cfg.codexAutoSwitchEnabled : cfg.autoSwitchEnabled) ? cfg.autoSwitchThreshold : nil
        let isNext = acc.number == (codex ? nextCodexTarget : nextTarget) && acc.switchable
        let canRemove = acc.switchable && !acc.isActive
        // Not the session-file Codex card: its numbers are as old as the last
        // Codex run and no poll can make them fresher, so "40 minutes old" is its
        // resting state, not a fault — hatching it would cry wolf every time. Its
        // age still shows in the card header. Stored Codex accounts ARE polled, so
        // for them an old reading is a real fault, same as Claude's.
        // Session-file Codex is as old as the last run and no poll can freshen
        // it, so hatching that card would cry wolf. Everything else is polled.
        let isStale = !(acc.provider == "codex" && !acc.switchable) && (acc.ageSeconds ?? 0) > 600
        // Manual switches take the same viability gate as the automatic one, minus
        // the threshold: a click may pick a busy account, not a dead one.
        let canSwitch = codex ? codexIsSwitchTarget(acc, threshold: 100) : isSwitchTarget(acc)
        return AccountCard(acc: acc,
                           stale: isStale,
                           threshold: armed,
                           switchMeter: codex ? (codexSwitchMeter(acc)?.id ?? "5h") : "5h",
                           isNextTarget: isNext,
                           canSwitch: canSwitch,
                           switchAction: { store.switchTo(acc) },
                           removeAction: canRemove ? { store.remove(acc) } : nil)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            // Same circular-swap mark as the menu-bar template extra.
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Noct.ink)
            Text("cbar").font(.system(size: 16, weight: .medium)).foregroundStyle(Noct.ink)
            Rectangle().fill(Noct.hairline).frame(width: 1, height: 12)
            Text(stale ? "data \(store.cacheAgeShort) old"
                 : (store.accounts.isEmpty ? "Claude usage" : "\(store.accounts.count) account\(store.accounts.count == 1 ? "" : "s")"))
                .font(.system(size: 13))
                .foregroundStyle(stale ? Noct.ink5 : Noct.ink4)
            Spacer(minLength: 4)
            statusPill
            Button { store.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 16))
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
        let warm = store.config.preWarmEnabled
        // Either mode rewrites the live login on its own, so the pill has to read
        // as "armed" for both — pre-warm alone used to look identical to a passive
        // monitor while it was switching accounts underneath.
        let armed = auto || warm
        let empty = claudeAccounts.isEmpty
        let text: String
        if auto && warm { text = "AUTO \(Int(store.config.autoSwitchThreshold))% · WARM" }
        else if auto { text = "AUTO ON · \(Int(store.config.autoSwitchThreshold))%" }
        else if warm { text = "PRE-WARM ON" }
        else { text = "\(claudeAccounts.count) ACCOUNT\(claudeAccounts.count == 1 ? "" : "S")" }
        return Text(text)
            .font(.system(size: 12, weight: .medium))
            .tracking(0.6)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .overlay(Capsule().stroke(armed ? Noct.accentLine : (empty ? Noct.hairlineSoft : Noct.hairline),
                                      lineWidth: 1))
            .foregroundStyle(armed ? Noct.accentText : (empty ? Noct.ink5 : Noct.ink4))
    }

    private var switchSettings: some View {
        VStack(spacing: 6) {
            switchPicker("Claude auto-switch", setting: .claude)
            switchPicker("Codex auto-switch", setting: .codex)
            switchPicker("Claude pre-warm", setting: .preWarm)
            Text("Pre-warm can switch Claude accounts independently.")
                .font(.system(size: 11))
                .foregroundStyle(Noct.ink4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
    }

    private func switchPicker(_ title: String, setting: CbarConfig.SwitchSetting) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12))
            Spacer()
            Picker(title, selection: Binding(
                get: { store.config.isEnabled(setting) },
                set: { store.setEnabled($0, for: setting) }
            )) {
                Text("On").tag(true)
                Text("Off").tag(false)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
            .fixedSize()
        }
        .foregroundStyle(Noct.ink3)
    }

    // MARK: body pieces

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Noct.critIcon)
            Text(message)
                .font(.system(size: 12))
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

    /// What the last click did, when that is an instruction rather than a failure
    /// — above all the Codex login command, which has to stay readable until it
    /// has been run. Dismissed by hand for that reason, not by the next poll.
    private func noticeBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Noct.accentText)
            Text(message)
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundStyle(Noct.ink2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { store.dismissNotice() } label: { Image(systemName: "xmark").font(.system(size: 12)) }
                .buttonStyle(HoverButtonStyle(compact: true))
                .foregroundStyle(Noct.ink5)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Noct.accentFill))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Noct.accentLine, lineWidth: 1))
    }

    /// Nothing tracked yet. The dashed outline says "this is where accounts will
    /// be", which an empty solid card does not.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("No accounts tracked yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Noct.ink2)
            Text("Log into an account in Claude Code, then Claude. Repeat per account.")
                .font(.system(size: 12))
                .lineSpacing(4)
                .foregroundStyle(Noct.ink4)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                Button { store.addCurrent() } label: {
                    Label("Claude", systemImage: "plus.circle")
                }
                .buttonStyle(HoverButtonStyle(font: .system(size: 13)))
                .foregroundStyle(Noct.accentText)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Noct.accentLine, lineWidth: 1))
                if store.canImportCswap {
                    Button { store.importCswap() } label: {
                        Label("Import from cswap", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(HoverButtonStyle(font: .system(size: 13)))
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

    /// One row of actions so the scan list is the whole panel. Refresh lives in
    /// the header — it acts on the panel, not a list item.
    private var footer: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                Button { store.switchToBest() } label: {
                    Label("Switch to best", systemImage: "bolt.fill")
                }
                .foregroundStyle(canSwitchToBest ? Noct.accentText : Noct.ink6)
                .overlay(canSwitchToBest
                         ? RoundedRectangle(cornerRadius: 7).stroke(Noct.accentLine, lineWidth: 1)
                         : nil)
                .disabled(!canSwitchToBest)
                Spacer(minLength: 4)
                Button { store.addCurrent() } label: {
                    Label("Claude", systemImage: "plus")
                }
                .foregroundStyle(Noct.ink3)
                Button { store.addCodexAccount() } label: {
                    Label("Codex", systemImage: "plus")
                }
                .foregroundStyle(Noct.ink3)
                if store.canImportCswap {
                    Button { store.importCswap() } label: {
                        Label("cswap", systemImage: "square.and.arrow.down")
                    }
                    .foregroundStyle(Noct.ink3)
                }
                Button { NSApp.terminate(nil) } label: { Text("Quit") }
                    .foregroundStyle(Noct.ink3)
            }
            Text(statusLine)
                .font(.system(size: 12))
                .foregroundStyle(stale ? Noct.critText : Noct.ink5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
        }
        .buttonStyle(HoverButtonStyle(font: .system(size: 13)))
        .padding(.horizontal, 8)
        .padding(.top, 8)
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
        let auto = store.config.autoSwitchEnabled, warm = store.config.preWarmEnabled
        if auto && warm { return "\(age) · auto-switch + pre-warm on" }
        if auto { return "\(age) · auto-switch cooldown 120s" }
        if warm { return "\(age) · pre-warm on · opening idle 5h windows" }
        return "\(age) · polls every 60s"
    }
}

/// One account as a scan row: icon · email · badges / Switch over a row of
/// 4pt meters. Tall 22pt plots made five accounts taller than the screen.
struct AccountCard: View {
    let acc: Account
    var stale = false
    /// Auto-switch threshold when it is armed, drawn on the active account's
    /// switch window.
    var threshold: Double? = nil
    /// The meter that threshold acts on: 5h for Claude; for Codex the 5h window
    /// where the plan has one, else the weekly.
    var switchMeter = "5h"
    var isNextTarget = false
    /// Whether the Switch button may show — decided by the panel, because the
    /// gate differs per provider.
    var canSwitch = false
    let switchAction: () -> Void
    var removeAction: (() -> Void)? = nil
    @ViewState private var hovering = false

    private var exhausted: Bool {
        if acc.switchable { return isExhausted(acc) }
        return acc.meters.contains { $0.id.contains("7d") && $0.pct >= 99 }
    }
    private var reauthHint: String {
        switch acc.provider {
        case "codex":
            return acc.isActive ? "Re-login needed (run codex login)" : "Re-login needed (Add Codex)"
        case "grok": return "Re-login needed (run grok login)"
        case "antigravity": return "Re-login needed (run agy)"
        default: return "Re-login needed (run Claude Code login)"
        }
    }

    /// Only when the age is the point — stale, or Codex, whose numbers are as old
    /// as the last Codex run and have no fresher source to poll.
    private var ageText: String? {
        guard stale || (acc.provider == "codex" && !acc.switchable), let a = acc.ageSeconds, a > 90 else { return nil }
        if a >= 3600 { return "\(Int(a / 3600))h ago" }
        return "\(Int(a / 60))m ago"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderMark(kind: .card(acc.provider), size: 22, dimmed: stale)
            VStack(alignment: .leading, spacing: 7) {
                headerRow
                if acc.meters.isEmpty { statusNote } else { meters }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background {
            if acc.isActive && !stale {
                LinearGradient(stops: [.init(color: Noct.accent.opacity(0.14), location: 0),
                                       .init(color: Noct.accent.opacity(0), location: 0.72)],
                               startPoint: .leading, endPoint: .trailing)
            } else if hovering {
                Color.primary.opacity(0.04)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(border, lineWidth: acc.isActive || acc.status == "needs-reauth" ? 1 : 0))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }

    private var border: Color {
        if acc.status == "needs-reauth" { return Noct.crit.opacity(0.35) }
        if acc.isActive { return stale ? Noct.accentFill : Noct.accentLine }
        return .clear
    }

    private var headerRow: some View {
        HStack(spacing: 6) {
            Text(acc.email)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(acc.isActive && !stale ? Noct.ink : Noct.ink2)
                .lineLimit(1)
            if let ageText {
                Text(ageText).font(.system(size: 12)).foregroundStyle(Noct.ink5).lineLimit(1)
            }
            if exhausted {
                Badge(text: "EXH", fg: Noct.critIcon, bg: Noct.crit.opacity(0.16))
            }
            if acc.status == "needs-reauth" {
                Badge(text: "RE-LOGIN", fg: Noct.critIcon, bg: Noct.crit.opacity(0.16))
            }
            if isNextTarget && !acc.isActive {
                Badge(text: "NEXT",
                      fg: Metric.number(for: "5h"), bg: Metric.color(for: "5h").opacity(0.16))
            }
            Spacer(minLength: 4)
            trailingControls
        }
    }

    @ViewBuilder private var statusNote: some View {
        Text(acc.status == "needs-reauth"
             ? reauthHint
             : acc.status == "ok" ? "no data yet" : acc.status)
            .font(.system(size: 12))
            .foregroundStyle(Noct.ink5)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
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
                if canSwitch {
                    Button("Switch", action: switchAction)
                        .buttonStyle(HoverButtonStyle(compact: true, font: .system(size: 13)))
                        .foregroundStyle(Noct.accentText)
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Noct.accentLine, lineWidth: 1))
                }
                if let removeAction {
                    Button(action: removeAction) { Image(systemName: "xmark").font(.system(size: 12)) }
                        .buttonStyle(HoverButtonStyle(compact: true))
                        .foregroundStyle(hovering ? Noct.ink3 : Noct.ink5)
                }
            }
        }
    }

    private var meters: some View {
        HStack(spacing: 12) {
            ForEach(acc.meters) { m in
                ScanMeter(label: meterLabel(m.id),
                          pct: m.pct,
                          caption: caption(for: m),
                          captionColor: captionColor(for: m),
                          mark: ProviderMark.Kind.meter(m.id),
                          color: Metric.color(for: m.id),
                          numberColor: acc.isActive ? Metric.number(for: m.id) : Noct.ink2,
                          threshold: m.id == switchMeter && acc.isActive ? threshold : nil,
                          stale: stale)
            }
        }
    }

    /// Strip the pool prefix ("Gem 7d" → "7d"); the meter icon names the pool.
    private func meterLabel(_ id: String) -> String {
        if id.hasPrefix("Gem ") { return String(id.dropFirst(4)) }
        if id.hasPrefix("Cl ") { return String(id.dropFirst(3)) }
        return id
    }

    /// Reset remaining first — that is why the row exists. Switch notes used to
    /// replace it on the active switch window, which hid the countdown on a full
    /// Codex week (prolite at 100% showed "over 93%" and nothing about when it
    /// comes back). Prefer `resetsAt` so the string is not a snapshot from fetch.
    private func caption(for m: Meter) -> String? {
        let remain = CodexProvider.countdown(m.resetsAt, now: Date().timeIntervalSince1970)
            ?? m.countdown
        if let c = remain { return "reset in \(c)" }
        if m.id == switchMeter, acc.isActive, let t = threshold, m.pct >= t {
            return "over \(Int(t))%"
        }
        if m.id == switchMeter, isNextTarget, !acc.isActive { return "most headroom" }
        if m.pct >= 99 { return "exhausted" }
        if stale, let a = acc.ageSeconds { return "as of \(Int(a / 60))m ago" }
        return nil
    }

    private func captionColor(for m: Meter) -> Color? {
        if stale { return nil }
        if m.pct >= 99 { return Noct.critText }
        if m.id == switchMeter, acc.isActive, let t = threshold, m.pct >= t { return Noct.critText }
        if m.id == switchMeter, isNextTarget, !acc.isActive { return Metric.number(for: "5h") }
        return nil
    }
}
