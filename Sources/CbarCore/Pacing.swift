import Foundation

/// Per-account backoff (seconds), matching cswap: base 30·2^(n-1) capped 600;
/// Retry-After 0 = sustained edge (cap 120); Retry-After N>0 = burst (honor N,
/// floor at computed, cap 900).
public func backoff(failures: Int, retryAfter: Double?) -> Double {
    let computed = min(30.0 * pow(2.0, Double(max(0, failures - 1))), 600.0)
    guard let ra = retryAfter else { return computed }
    if ra == 0 { return min(computed, 120.0) }
    return max(min(ra, 900.0), computed)
}

/// Planning view of a cache row.
public struct PaceRow: Sendable {
    public let number: Int
    public let fetchedAt: Double?
    public let backoffUntil: Double?
    public let lastAttemptAt: Double?
    public init(number: Int, fetchedAt: Double?, backoffUntil: Double?, lastAttemptAt: Double?) {
        self.number = number; self.fetchedAt = fetchedAt
        self.backoffUntil = backoffUntil; self.lastAttemptAt = lastAttemptAt
    }
}

/// Which accounts a single refresh pass may hit the network for: the active
/// account (if due) plus AT MOST ONE stalest due alternate. O(1) per TTL.
public func fetchPlan(now: Double, active: Int?, rows: [PaceRow],
                      serveTTL: Double = 30, claimTTL: Double = 10) -> [Int] {
    func eligible(_ r: PaceRow) -> Bool {
        if let f = r.fetchedAt, now - f < serveTTL { return false }        // fresh
        if let b = r.backoffUntil, now < b { return false }                // backing off
        if let a = r.lastAttemptAt, now - a < claimTTL { return false }     // just claimed
        return true
    }
    var plan: [Int] = []
    if let active, let ar = rows.first(where: { $0.number == active }), eligible(ar) {
        plan.append(active)
    }
    let alts = rows.filter { $0.number != active && eligible($0) }
        .sorted { a, b in
            switch (a.fetchedAt, b.fetchedAt) {
            case (nil, nil): return a.number < b.number
            case (nil, _):   return true          // never-fetched is stalest
            case (_, nil):   return false
            case let (x?, y?): return x < y        // oldest first
            }
        }
    if let stalest = alts.first { plan.append(stalest.number) }
    return plan
}
