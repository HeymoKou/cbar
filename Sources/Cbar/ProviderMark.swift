import AppKit
import SwiftUI

/// Official product marks, shipped as PNGs in the app bundle. Fallback is a
/// tinted rounded square so a missing resource still occupies the same slot.
struct ProviderMark: View {
    enum Kind {
        case claude, openai, antigravity, grok, gemini

        static func card(_ provider: String) -> Kind {
            switch provider {
            case "codex": return .openai
            case "antigravity": return .antigravity
            case "grok": return .grok
            default: return .claude
            }
        }

        static func meter(_ id: String) -> Kind? {
            if id.hasPrefix("Gem") { return .gemini }
            if id.hasPrefix("Cl") { return .claude }
            return nil
        }

        var accessibilityName: String {
            switch self {
            case .claude: return "Claude"
            case .openai: return "OpenAI"
            case .antigravity: return "Antigravity"
            case .grok: return "Grok"
            case .gemini: return "Gemini"
            }
        }

        var resource: String {
            switch self {
            case .claude: return "icon-claude"
            case .openai: return "icon-openai"
            case .antigravity: return "icon-antigravity"
            case .grok: return "icon-grok"
            case .gemini: return "icon-gemini"
            }
        }
    }

    let kind: Kind
    var size: CGFloat = 22
    var dimmed = false

    var body: some View {
        Group {
            if let ns = Self.nsImage(kind) {
                Image(nsImage: ns)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(Color.secondary.opacity(0.35))
            }
        }
        .frame(width: size, height: size)
        .opacity(dimmed ? 0.55 : 1)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .stroke(Color.primary.opacity(0.12), lineWidth: 1))
        .accessibilityLabel(kind.accessibilityName)
    }

    /// PNGs live in the app's `Contents/Resources`. Do not touch
    /// `Bundle.module`: SPM's accessor `fatalError`s when that .bundle is not
    /// next to the binary, which is how the .app is laid out, and the first
    /// popover open aborted on click (2026-09-17).
    static func nsImage(_ kind: Kind) -> NSImage? {
        let name = kind.resource
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        return nil
    }
}
