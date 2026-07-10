import Foundation

/// Minimal config, read from `~/.cbar/config.json` (edit the file to change).
/// Lenient: missing keys keep defaults.
public struct CbarConfig {
    public var autoSwitchEnabled: Bool = true
    public var autoSwitchThreshold: Double = 94   // switch when active account hits this %

    public static func load(dir: String = "\(NSHomeDirectory())/.cbar") -> CbarConfig {
        var c = CbarConfig()
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/config.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return c }
        if let e = o["autoSwitchEnabled"] as? Bool { c.autoSwitchEnabled = e }
        if let t = (o["autoSwitchThreshold"] as? Double) ?? (o["autoSwitchThreshold"] as? Int).map(Double.init) {
            c.autoSwitchThreshold = t
        }
        return c
    }
}

/// The account number to auto-switch TO, or nil. Fires only when the active
/// Claude account has reached `threshold` AND a switchable account with more
/// headroom exists (returns the one with the most headroom = lowest max %).
public func autoSwitchTarget(accounts: [Account], threshold: Double) -> Int? {
    let claude = accounts.filter { $0.provider == "claude" }
    guard let active = claude.first(where: { $0.isActive }), active.maxPct >= threshold else { return nil }
    let candidates = claude.filter { !$0.isActive && $0.switchable && !$0.meters.isEmpty && $0.maxPct < active.maxPct }
    return candidates.min(by: { $0.maxPct < $1.maxPct })?.number
}
