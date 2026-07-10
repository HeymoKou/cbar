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

/// Usage % that drives switching — max of the 5h and 7d windows ONLY, matching
/// cswap (`headroom = 100 - max(five_hour, seven_day)`; Fable/scoped and spend
/// are deliberately excluded from switch decisions).
public func switchPct(_ a: Account) -> Double {
    a.meters.filter { $0.id == "5h" || $0.id == "7d" }.map(\.pct).max() ?? 0
}

/// The account number to auto-switch TO, or nil. Like `cswap auto`: fires only
/// when the ACTIVE Claude account's 5h/7d usage has reached `threshold` AND a
/// switchable account with more headroom exists (returns the one with the most
/// 5h/7d headroom).
public func autoSwitchTarget(accounts: [Account], threshold: Double) -> Int? {
    let claude = accounts.filter { $0.provider == "claude" }
    guard let active = claude.first(where: { $0.isActive }), switchPct(active) >= threshold else { return nil }
    let candidates = claude.filter { !$0.isActive && $0.switchable && !$0.meters.isEmpty && switchPct($0) < switchPct(active) }
    return candidates.min(by: { switchPct($0) < switchPct($1) })?.number
}
