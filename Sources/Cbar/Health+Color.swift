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

/// Nocturne — the design system the popover is drawn from.
///
/// Nocturne publishes DARK values only. The light appearance is derived here, and
/// not by mirroring the neutral ramp end for end: the ramp mirrors fine for
/// grounds and lines, but neutral-600 mirrored is `#b2b6ca`, which as text on a
/// near-white panel is unreadable. So grounds mirror and ink COMPRESSES — every
/// text role keeps its distance from the ground rather than its step number.
/// Roles are named for the job they do, which is what lets the two appearances
/// stay in agreement when either side is retuned.
enum Noct {
    // — grounds —
    /// Panel gradient. Nocturne's own `#191b29 → #161826`, lifted for light.
    static let panelTop = dynamic(light: 0xfbfbfe, dark: 0x191b29)
    static let panelBottom = dynamic(light: 0xf4f4f8, dark: 0x161826)
    /// Active account card — a touch lighter than the panel in the dark, a touch
    /// darker in the light, so it reads as raised in either appearance.
    static let cardActive = dynamic(light: 0xffffff, dark: 0x1c1e2e)
    static let card = dynamic(light: 0xfafaff, dark: 0x1a1c29)
    /// Stale card sits between the two — present, but not asserting.
    static let cardStale = dynamic(light: 0xf7f7fc, dark: 0x1b1d2b)

    // — ink —
    static let ink = dynamic(light: 0x292b31, dark: 0xe9e9ed)
    /// Email on a non-active card, metric legend labels.
    static let ink2 = dynamic(light: 0x4a4e5c, dark: 0xcfd3e5)
    static let ink3 = dynamic(light: 0x6b6f80, dark: 0xb2b6ca)
    /// Captions, "%" signs, reset countdowns.
    static let ink4 = dynamic(light: 0x82869a, dark: 0x9397ab)
    /// Faintest readable step — the footer status line, dimmed numbers.
    static let ink5 = dynamic(light: 0x9397ab, dark: 0x75798c)
    /// Disabled affordances only. Not for anything that must be read.
    static let ink6 = dynamic(light: 0xa8abbb, dark: 0x595d6c)

    // — lines —
    /// Card borders and the panel's own dividers.
    static let hairline = dynamic(light: 0xdcdfe9, dark: 0x3f424d)
    /// The 1pt rules BETWEEN metric cells, and the ticks behind a bar.
    static let hairlineSoft = dynamic(light: 0xe9ebf3, dark: 0x292b31)

    // — accent (Nocturne blurple, `#9184d9`) —
    static let accent = dynamic(light: 0x6f61c4, dark: 0x9184d9)
    /// Text and glyphs ON an accent fill.
    static let accentText = dynamic(light: 0x4b3f96, dark: 0xe7e5fe)
    static let accentTextDim = dynamic(light: 0x5d5294, dark: 0xd2cefd)
    static let accentLine = dynamic(light: 0xc3bcf0, dark: 0x5d5294)
    static let accentFill = dynamic(light: 0xe7e5fe, dark: 0x423a6a)
    /// The same badge one step quieter — ACTIVE once the data has gone stale.
    static let accentFillDim = dynamic(light: 0xf1f0fe, dark: 0x2b2741)

    // — crit (Nocturne `#db2e29`, which `Health.crit` above already is) —
    static let crit = dynamic(light: 0xc42824, dark: 0xdb2e29)
    /// Error prose. Nocturne lightens it for a dark ground; light needs the
    /// opposite move or the text dissolves into the tint behind it.
    static let critText = dynamic(light: 0x8c1512, dark: 0xf5b4b1)
    static let critIcon = dynamic(light: 0xb3211d, dark: 0xf08c88)
}

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

    /// The big percentage reads in its metric's hue pushed AWAY from the ground —
    /// lighter on a dark panel, darker on a light one. Same hue as the bar, so
    /// the number and the plot under it are visibly one object; different
    /// lightness, so a 22pt numeral does not glare at bar saturation.
    static func number(for id: String) -> Color {
        switch id {
        case "5h":  return dynamic(light: 0x1b5aa8, dark: 0x8cc0f5)
        case "7d":  return dynamic(light: 0x127754, dark: 0x5ad0a3)
        case "Fbl": return dynamic(light: 0x8f5e00, dark: 0xe5b64a)
        default:    return dynamic(light: 0x372a86, dark: 0xb5abfc)
        }
    }
}
