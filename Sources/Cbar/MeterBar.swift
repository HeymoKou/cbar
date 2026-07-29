import SwiftUI

/// One metric as its own framed plot: legend mark · label · big percentage ·
/// ticked bar · caption. Hue lives in the bar, the legend mark, and the numeral —
/// never in the chrome, so a card full of plots still reads as one card.
///
/// The 25/50/75 ticks are what this earns over a plain bar: they make a length
/// readable as a QUANTITY on its own, not just against its neighbours. That
/// matters here because the three windows are different lengths and their fills
/// never line up.
struct MeterPlot: View {
    let label: String
    let pct: Double
    /// The line under the bar — a reset countdown normally, or the threshold /
    /// headroom note when this metric is the reason something is about to happen.
    let caption: String?
    var captionColor: Color? = nil
    let color: Color
    let numberColor: Color
    /// Auto-switch threshold, drawn as a gate across the bar. Only ever set on the
    /// active account's 5h plot — the one window the threshold acts on.
    var threshold: Double? = nil
    /// Stale: these are the last numbers fetched, not the current ones. The fill
    /// goes hatched rather than merely dim, because dim reads as "smaller".
    var stale = false

    private var clamped: Double { min(max(pct, 0), 100) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color.opacity(stale ? 0.55 : 1))
                    .frame(width: 8, height: 3)
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.7)
                    .foregroundStyle(stale ? Noct.ink5 : Noct.ink2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text("\(Int(pct.rounded()))")
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(stale ? Noct.ink4 : numberColor)
                Text("%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(stale ? Noct.ink5 : Noct.ink4)
            }
            bar
            Text(caption ?? "—")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(captionColor ?? (stale ? Noct.ink5 : Noct.ink4))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.top, 11)
        .padding(.bottom, 12)
    }

    private var bar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(color.opacity(stale ? 0.10 : 0.14))
                // Ticks at 25/50/75 fall out of four equal spacers — no arithmetic,
                // and they stay put at whatever width the grid hands this cell.
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { _ in
                        Spacer(minLength: 0)
                        // Translucent ink, not a ramp step: the ticks have to read
                        // over the track AND over the fill that crosses them, and
                        // any opaque color is invisible against one or the other.
                        Rectangle().fill(Noct.ink.opacity(0.14)).frame(width: 1)
                    }
                    Spacer(minLength: 0)
                }
                RoundedRectangle(cornerRadius: 2)
                    .fill(fill)
                    .frame(width: max(0, g.size.width * clamped / 100))
                if let threshold, threshold > 0, threshold < 100 {
                    Rectangle()
                        .fill(Noct.crit)
                        .frame(width: 1, height: 13)
                        .offset(x: g.size.width * threshold / 100)
                }
            }
        }
        .frame(height: 7)
    }

    /// Hatched when stale. A flat dim fill would read as a smaller number; the
    /// hatch says the length is real but no longer being measured.
    private var fill: AnyShapeStyle {
        guard stale else { return AnyShapeStyle(color) }
        return AnyShapeStyle(LinearGradient(
            stops: [.init(color: color.opacity(0.75), location: 0),
                    .init(color: color.opacity(0.75), location: 0.5),
                    .init(color: color.opacity(0.35), location: 0.5),
                    .init(color: color.opacity(0.35), location: 1)],
            startPoint: .topLeading, endPoint: UnitPoint(x: 0.05, y: 1)))
    }
}
