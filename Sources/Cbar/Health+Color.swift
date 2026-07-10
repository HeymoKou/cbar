import SwiftUI
import AppKit
import CbarCore

private func nsHex(_ v: Int) -> NSColor {
    NSColor(srgbRed: Double((v >> 16) & 0xff) / 255,
            green: Double((v >> 8) & 0xff) / 255,
            blue: Double(v & 0xff) / 255, alpha: 1)
}

/// Auto light/dark NSColor.
private func dynamic(light: Int, dark: Int) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? nsHex(dark) : nsHex(light)
    })
}

/// Status color for the MENU-BAR ICON only (green/orange/red). Deliberately kept
/// off the popover bars, which are colored by metric instead (see `Metric`).
extension Health {
    var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .healthy: return (0x34 / 255.0, 0xA8 / 255.0, 0x53 / 255.0)  // Google green, not neon
        case .warn:    return (0.90, 0.52, 0.05)
        case .crit:    return (0.86, 0.18, 0.16)
        }
    }
    var nsColor: NSColor { NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1) }
    var color: Color { Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b) }
}

/// Comfortable "active account" accent — Google-logo green (#34A853), not the
/// neon status green. Used for the ACTIVE badge, dot, and card border.
let activeGreen = dynamic(light: 0x1E8E3E, dark: 0x34A853)   // Google's deep green (less fluorescent)

/// Categorical palette for usage bars — one comfortable hue PER METRIC so 5h /
/// 7d / Fable read as distinct (validated via dataviz: CVD ΔE 47/41, light+dark).
/// Same mapping for Claude and Codex so a metric's color is consistent everywhere.
enum Metric {
    static func color(for id: String) -> Color {
        switch id {
        case "5h":  return dynamic(light: 0x2a78d6, dark: 0x3987e5)   // blue
        case "7d":  return dynamic(light: 0x1baf7a, dark: 0x199e70)   // aqua
        case "Fbl": return dynamic(light: 0xeda100, dark: 0xc98500)   // yellow
        default:    return dynamic(light: 0x4a3aa7, dark: 0x9085e9)   // violet (fallback)
        }
    }
}
