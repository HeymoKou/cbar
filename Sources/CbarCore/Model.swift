import Foundation

public struct Meter: Identifiable, Sendable, Codable {
    public let id: String          // "5h" | "7d" | "Fbl" | other scoped name
    public let pct: Double
    /// Absolute reset (epoch seconds); the UI formats the countdown from it at
    /// draw time. A string baked at fetch went stale between polls. Cache files
    /// from older versions still carry a `countdown` key; decoding ignores it.
    public let resetsAt: Double?
    public init(id: String, pct: Double, resetsAt: Double? = nil) {
        self.id = id; self.pct = pct; self.resetsAt = resetsAt
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
                provider: String) {
        self.id = id; self.number = number; self.email = email; self.org = org
        self.isActive = isActive; self.status = status; self.meters = meters
        self.ageSeconds = ageSeconds; self.provider = provider
    }
}

/// Whether the active account's usage is stale.
public func activeStale(_ accounts: [Account], threshold: Double = 600) -> Bool {
    guard let active = accounts.first(where: { $0.isActive && $0.provider == "claude" }) else { return false }
    return (active.ageSeconds ?? 0) > threshold
}
