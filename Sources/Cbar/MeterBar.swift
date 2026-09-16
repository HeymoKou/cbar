import SwiftUI

/// Compact scan-row meter: label · number, a 5pt bar, then when the window
/// resets. The countdown is the fact you act on; dropping it made a full bar
/// unreadable as "used up until when".
struct ScanMeter: View {
    let label: String
    let pct: Double
    /// Reset remaining, or why this meter is about to cause a switch.
    var caption: String? = nil
    var captionColor: Color? = nil
    var mark: ProviderMark.Kind? = nil
    let color: Color
    let numberColor: Color
    var threshold: Double? = nil
    var stale = false

    private var clamped: Double { min(max(pct, 0), 100) }
    private var hot: Bool { pct >= 99 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let mark {
                    ProviderMark(kind: mark, size: 11, dimmed: stale)
                }
                Text(label.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(stale ? Noct.ink5 : Noct.ink4)
                Spacer(minLength: 2)
                Text("\(Int(pct.rounded()))")
                    .font(.system(size: 15, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(stale ? Noct.ink4 : (hot ? Noct.critText : numberColor))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(stale ? 0.05 : 0.08))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(fill)
                        .frame(width: max(0, g.size.width * clamped / 100))
                    if let threshold, threshold > 0, threshold < 100 {
                        Rectangle()
                            .fill(Noct.crit)
                            .frame(width: 1)
                            .offset(x: g.size.width * threshold / 100)
                    }
                }
            }
            .frame(height: 5)
            Text(caption ?? "—")
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(captionColor ?? (stale ? Noct.ink5 : Noct.ink4))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var fill: Color {
        if stale { return color.opacity(0.45) }
        if hot { return Noct.crit }
        return color
    }
}
