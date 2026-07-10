import Foundation

public struct Meter: Identifiable, Sendable, Codable {
    public let id: String          // "5h" | "7d" | "Fbl" | other scoped name
    public let pct: Double
    public let countdown: String?
    public init(id: String, pct: Double, countdown: String?) {
        self.id = id; self.pct = pct; self.countdown = countdown
    }
}

public struct Account: Identifiable, Sendable {
    public let id: String          // "cswap:2" | "codex"
    public let number: Int
    public let email: String
    public let org: String
    public let isActive: Bool
    public let status: String      // "ok" | other
    public let meters: [Meter]
    public let ageSeconds: Double?
    public let provider: String    // "cswap" | "codex"
    public var maxPct: Double { meters.map(\.pct).max() ?? 0 }
    public var switchable: Bool { provider != "codex" }
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

public protocol Provider {
    var name: String { get }
    func accounts() throws -> [Account]
    func switchTo(_ account: Account) throws
    func switchToBest() throws
}
