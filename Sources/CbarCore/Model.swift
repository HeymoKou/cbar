import Foundation

public struct Meter: Identifiable, Sendable, Codable {
    public let id: String          // "5h" | "7d" | "Fbl" | other scoped name
    public let pct: Double
    public let countdown: String?
    /// Absolute reset (epoch seconds). Preferred over `countdown`, which is a
    /// string baked at fetch and goes stale between polls.
    public let resetsAt: Double?
    public init(id: String, pct: Double, countdown: String?, resetsAt: Double? = nil) {
        self.id = id; self.pct = pct; self.countdown = countdown; self.resetsAt = resetsAt
    }
}

public struct Account: Identifiable, Sendable {
    public let id: String          // "claude:2" | "codex:1" | "codex" (session-file card)
    public let number: Int
    public let email: String
    public let org: String
    public let isActive: Bool
    public let status: String      // "ok" | other
    public let meters: [Meter]
    public let ageSeconds: Double?
    public let provider: String    // "claude" | "codex" | "grok" | "antigravity"
    public var maxPct: Double { meters.map(\.pct).max() ?? 0 }
    /// Only Claude slots and stored Codex slots (number ≥ 1) can be switched.
    /// Grok / Antigravity cards, and the session-file Codex card (number 0),
    /// are the live login's current snapshot — monitor only.
    public var switchable: Bool {
        switch provider {
        case "claude": return true
        case "codex": return number > 0
        default: return false
        }
    }
    public init(id: String, number: Int, email: String, org: String,
                isActive: Bool, status: String, meters: [Meter], ageSeconds: Double?,
                provider: String = "cswap") {
        self.id = id; self.number = number; self.email = email; self.org = org
        self.isActive = isActive; self.status = status; self.meters = meters
        self.ageSeconds = ageSeconds; self.provider = provider
    }
}

public enum Health: Sendable, Equatable { case healthy, warn, crit }

public func healthLevel(pct: Double, status: String) -> Health {
    if status != "ok" { return .crit }
    if pct > 85 { return .crit }
    if pct >= 60 { return .warn }
    return .healthy
}

public func overallHealth(_ accounts: [Account]) -> Health {
    var worst = Health.healthy
    for a in accounts {
        switch healthLevel(pct: a.maxPct, status: a.status) {
        case .crit: return .crit
        case .warn: worst = .warn
        case .healthy: break
        }
    }
    return worst
}

public func anyStale(_ accounts: [Account], threshold: Double = 600) -> Bool {
    accounts.contains { ($0.ageSeconds ?? 0) > threshold }
}

/// Health of the ACTIVE account only (its tightest window). The menu-bar icon
/// uses this so a maxed NON-active account doesn't redden the icon — the color
/// reflects the account you're actually using.
public func activeHealth(_ accounts: [Account]) -> Health {
    guard let active = accounts.first(where: { $0.isActive && $0.provider == "claude" }) else { return .healthy }
    return healthLevel(pct: active.maxPct, status: active.status)
}

/// Whether the active account's usage is stale (icon dims).
public func activeStale(_ accounts: [Account], threshold: Double = 600) -> Bool {
    guard let active = accounts.first(where: { $0.isActive && $0.provider == "claude" }) else { return false }
    return (active.ageSeconds ?? 0) > threshold
}

public protocol Provider {
    var name: String { get }
    func accounts() throws -> [Account]
    func switchTo(_ account: Account) throws
    func switchToBest() throws
}
