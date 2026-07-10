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

/// Which accounts a single refresh pass hits the network for: EVERY account
/// that is stale (older than `serveTTL`), not backing off, and not just claimed.
/// At the 60 s poll this syncs all accounts each cycle; per-account backoff (on
/// 429) is the burst safety-net, so it self-regulates near the sustainable rate.
/// Active first, then stalest.
/// ponytail: full pass is fine for a handful of accounts; if someone ever runs
/// dozens, cap the non-active count here and rotate.
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
    let others = rows.filter { $0.number != active && eligible($0) }
        .sorted { a, b in
            switch (a.fetchedAt, b.fetchedAt) {
            case (nil, nil): return a.number < b.number
            case (nil, _):   return true          // never-fetched is stalest
            case (_, nil):   return false
            case let (x?, y?): return x < y        // oldest first
            }
        }
    plan.append(contentsOf: others.map(\.number))
    return plan
}
