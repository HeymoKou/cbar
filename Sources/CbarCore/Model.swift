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

/// How a card lays its meters out, as rows of indices into `ids`; nil is an
/// empty cell that keeps a short row's columns the width of a full one.
///
/// Up to three meters share one row, as they always did. Past that they were
/// squeezed into one row of equal cells — four pools on an Antigravity card, or
/// a Codex account with a model allowance — and the two numbers that decide a
/// switch were no bigger than the rest. So: the plain duration windows (5h,
/// 7d, 30d) get the first row to themselves and the rest follow three to a
/// row; a card with no plain window (pools named "Gem 5h", "Cl 5h", …) pairs
/// up instead, which keeps each pool's two windows side by side.
public func meterRows(_ ids: [String]) -> [[Int?]] {
    let all = Array(ids.indices)
    guard all.count > 3 else { return all.isEmpty ? [] : [all] }
    func chunks(_ xs: [Int], _ n: Int) -> [[Int?]] {
        stride(from: 0, to: xs.count, by: n).map { i in
            let row: [Int?] = Array(xs[i..<min(i + n, xs.count)])
            return row + Array(repeating: nil, count: n - row.count)
        }
    }
    let plain = all.filter { ["5h", "7d", "30d"].contains(ids[$0]) }
    guard !plain.isEmpty else { return chunks(all, 2) }
    return [plain] + chunks(all.filter { !plain.contains($0) }, 3)
}
