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

/// Which account a single refresh pass hits the network for: exactly ONE, from
/// those that are stale (older than `serveTTL`), not backing off, and not just
/// claimed.
///
/// It used to be every eligible account, active first, on the theory that
/// per-account backoff would regulate the rate. It cannot: the 429 the usage
/// endpoint returns is about the CLIENT, not the account, so recording it
/// per-account regulates the wrong thing. The active slot was always first in
/// the plan, so it always got the one request the budget allowed and never
/// recorded a failure; every other slot was always behind it, always got the
/// 429, and backed off 30→60→…→600 s. That is starvation, not pacing — measured
/// 2026-07-25, active re-read every 11 s while #1 sat 191 s stale.
///
/// So: one request per pass, and no standing priority for the active slot.
/// Round-robin falls out of "stalest wins" for free — whatever was just fetched
/// is now the freshest, so the next pass picks someone else. No rotation cursor
/// to keep.
///
/// `activeMaxAge` is the one exception: auto-switch reads the active account's
/// 5 h meter to decide when to leave, so it may not lag arbitrarily. At the
/// default 180 s with 2–3 accounts this settles into a clean uniform rotation
/// (everyone every ~N minutes) and keeps every slot inside the 300 s window
/// `isSwitchTarget` requires of a switch destination.
/// ponytail: that window is what breaks first as accounts are added — at ~1
/// request/minute, 5+ accounts cannot all stay under 300 s no matter how they
/// are ordered. Raise the poll rate or widen the window then, not this.
///
/// `credsChanged` lists slots whose credentials no longer match what the last
/// failure was recorded against — a `/login` outside cbar. Backoff exists to stop
/// hammering an endpoint that keeps refusing; a new credential means the refusal
/// no longer applies, and waiting it out is self-defeating. Slot #2 proved it:
/// 125 accumulated failures pinned backoff at the 600 s cap, so after a re-login
/// the fetch was skipped, the skip meant the dead slot copy was never healed from
/// the live keychain, and the un-healed copy produced the next failure — the
/// ACTIVE account showed no usage at all, indefinitely. Such a slot outranks even
/// the active one: it is the only case where a single pass repairs a broken
/// account rather than just refreshing a number.
public func fetchPlan(now: Double, active: Int?, rows: [PaceRow],
                      serveTTL: Double = 30, claimTTL: Double = 10,
                      credsChanged: Set<Int> = [],
                      activeMaxAge: Double = 180) -> [Int] {
    func eligible(_ r: PaceRow) -> Bool {
        if let f = r.fetchedAt, now - f < serveTTL { return false }        // fresh
        // claimTTL still applies below: ignoring backoff must not become a
        // per-poll retry storm if the new credential also fails.
        if !credsChanged.contains(r.number), let b = r.backoffUntil, now < b { return false }
        if let a = r.lastAttemptAt, now - a < claimTTL { return false }     // just claimed
        return true
    }
    func age(_ r: PaceRow) -> Double { r.fetchedAt.map { now - $0 } ?? .infinity }

    let ready = rows.filter(eligible).sorted { a, b in
        switch (a.fetchedAt, b.fetchedAt) {
        case (nil, nil): return a.number < b.number
        case (nil, _):   return true          // never-fetched is stalest
        case (_, nil):   return false
        case let (x?, y?): return x < y        // oldest first
        }
    }
    if let healed = ready.first(where: { credsChanged.contains($0.number) }) { return [healed.number] }
    if let active, let ar = ready.first(where: { $0.number == active }), age(ar) >= activeMaxAge {
        return [active]
    }
    return ready.first.map { [$0.number] } ?? []
}
