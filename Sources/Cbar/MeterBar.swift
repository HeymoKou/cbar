import SwiftUI

/// One horizontal usage bar: label · metric-colored bar · % · countdown.
/// Bar color identifies the metric (5h/7d/Fable); text stays in ink tokens.
struct MeterBar: View {
    let label: String
    let pct: Double
    let countdown: String?
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(color)
                        .frame(width: max(8, geo.size.width * min(max(pct, 0), 100) / 100))
                }
            }
            .frame(height: 14)

            Text("\(Int(pct.rounded()))%")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .frame(width: 42, alignment: .trailing)

            Text(countdown ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
        }
    }
}
