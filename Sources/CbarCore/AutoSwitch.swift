import Foundation

/// Minimal config, read from `~/.cbar/config.json` (edit the file to change).
/// Lenient: missing keys keep defaults.
public struct CbarConfig {
    /// OFF by default, deliberately. Auto-switch rewrites the live Claude Code
    /// keychain item and `~/.claude.json` on its own schedule; someone who
    /// installed what the README calls a usage monitor must not get that without
    /// asking for it. Opting in is one line in `~/.cbar/config.json`.
    public var autoSwitchEnabled: Bool = false
    public var autoSwitchThreshold: Double = 93   // switch when active account's 5h hits this %

    /// OFF by default, same reasoning as auto-switch: it rewrites the live login on
    /// its own. When on, cbar diverts the live account through idle slots to open
    /// (pre-warm) their 5h windows with the user's real traffic. Independent of
    /// `autoSwitchEnabled` — you can pre-warm without the 93% escape, or both.
    public var preWarmEnabled: Bool = false

    /// Defaults, for holding a value before the first poll has read the file.
    public init() {}

    public static func load(dir: String = "\(NSHomeDirectory())/.cbar") -> CbarConfig {
        var c = CbarConfig()
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/config.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return c }
        if let e = o["autoSwitchEnabled"] as? Bool { c.autoSwitchEnabled = e }
        if let t = (o["autoSwitchThreshold"] as? Double) ?? (o["autoSwitchThreshold"] as? Int).map(Double.init) {
            c.autoSwitchThreshold = t
        }
        if let p = o["preWarmEnabled"] as? Bool { c.preWarmEnabled = p }
        return c
    }
}

/// Usage % that drives switching — the **5h window only**.
///
/// 7d used to be folded in via `max(5h, 7d)` (cswap's rule). It made cbar switch
/// away from a perfectly usable account: on 2026-07-25 slot #1 sat at 5h=3% /
/// 7d=91% and every single poll wanted to rotate, because the weekly figure was
/// over threshold while the account had a nearly empty 5-hour window. The 5h
/// window is what actually blocks you right now, so that's what we switch on.
/// Fable/scoped limits and spend were never in scope.
public func switchPct(_ a: Account) -> Double {
    a.meters.first { $0.id == "5h" }?.pct ?? 0
}

/// The 7d window, used as a hard ceiling only — never as a ranking input.
///
/// Below the ceiling 7d is ignored (a 91% week with a 3% 5h window is still a
/// perfectly usable account). At the ceiling the weekly limit blocks you no
/// matter how empty the 5h window is, so an exhausted account both forces a
/// switch AWAY and is disqualified as a target — otherwise cbar would move the
/// live login into an account it can never automatically escape (its 5h reads
/// 0%, so the 5h trigger never fires again).
public let sevenDayCeiling: Double = 99

public func sevenDayPct(_ a: Account) -> Double {
    a.meters.first { $0.id == "7d" }?.pct ?? 0
}
public func isExhausted(_ a: Account) -> Bool { sevenDayPct(a) >= sevenDayCeiling }

/// Whether cbar may switch INTO this slot: a real, currently-readable, usable
/// Claude login. Dead accounts kept qualifying because a failed fetch left the
/// last-good meters in the cache — slot #2's 11-day-stale 60% read as headroom
/// and cbar wrote its expired, `invalid_grant` token into the live keychain four
/// times (2026-07-25). Four independent gates: status (re-login/no-creds), age
/// (unreachable long enough that the number is fiction), a REAL 5h meter (a
/// missing one reads as 0% via `switchPct`, i.e. unknown headroom would rank
/// best), and the 7d ceiling.
/// `maxAge` matches `UsageService.status`'s freshness window on purpose. A tighter
/// one silently disabled auto-switch during exactly the situation that needs it:
/// a 429 storm hits every account at once, backoff runs to 600 s, so every
/// alternate ages past a 300 s gate and the user rides the active account into
/// the wall. A stale 5h reading also errs safe — usage only climbs, so an old
/// number understates it.
public func isSwitchTarget(_ a: Account, maxAge: Double = 600) -> Bool {
    a.switchable && a.status == "ok" && (a.ageSeconds ?? .infinity) <= maxAge
        && a.meters.contains { $0.id == "5h" } && !isExhausted(a)
}

/// The account number to auto-switch TO, or nil. Fires when the ACTIVE Claude
/// account's 5h usage has reached `threshold` OR its 7d window is exhausted, AND
/// a live, verifiably healthy account with more 5h headroom exists (returns the
/// most headroom).
public func autoSwitchTarget(accounts: [Account], threshold: Double) -> Int? {
    let claude = accounts.filter { $0.provider == "claude" }
    guard let active = claude.first(where: { $0.isActive }),
          switchPct(active) >= threshold || isExhausted(active) else { return nil }
    // "More headroom than the active one" is the wrong test when the active
    // account is weekly-exhausted: its 5h reads 0%, so nothing could ever beat
    // it and cbar would sit on a blocked account forever. Any non-exhausted
    // candidate (isSwitchTarget already rejects exhausted ones) is better.
    let candidates = claude.filter {
        !$0.isActive && isSwitchTarget($0)
            && (isExhausted(active) || switchPct($0) < switchPct(active))
    }
    return candidates.min(by: { switchPct($0) < switchPct($1) })?.number
}

/// Whether an account carries a real 7d meter, so `sevenDayPct` reflects fetched
/// data rather than a missing-window 0. Without this a slot whose weekly figure
/// is simply absent reads as "0% used" — maximum headroom — and would be chosen
/// first, defeating the weekly guard on an account whose real 7d could be ≥95%.
public func hasSevenDay(_ a: Account) -> Bool { a.meters.contains { $0.id == "7d" } }

/// A current, trustworthy reading of the ACTIVE account: real status, fresh
/// enough that the numbers aren't fiction, and a real 5h meter to decide on.
/// Deliberately NOT `isSwitchTarget`: that also rejects a weekly-EXHAUSTED
/// account, and an exhausted active is a known-good reading pre-warm should act
/// on (divert away from it), not freeze on. Pre-warm gates on this so it never
/// switches on a stale / re-auth reading (which would abandon a half-warmed slot
/// or churn the live login during a 429 storm).
public func freshActiveReading(_ a: Account) -> Bool {
    a.status == "ok" && (a.ageSeconds ?? .infinity) <= 600
        && a.meters.contains { $0.id == "5h" } && hasSevenDay(a)
}

/// Pre-warm: the idle account to divert the live login INTO so the user's real
/// traffic opens its 5h window and starts its reset timer. `nil` when nothing
/// should be warmed right now.
///
/// Un-warmed = a valid switch target whose 5h sits below `target` (5%), i.e. no
/// window opened since its last reset. Among those, prefer the one with the MOST
/// weekly headroom (lowest 7d) — the scarce resource is the 7-day limit, not the
/// 5-hour one, so spend the cheapest weekly quota first. Skip any at/above
/// `weeklySkip` (95%): priming a nearly-exhausted weekly account burns the last
/// of its quota for a window it can barely use. That account is NOT stranded —
/// the exhaustion-escape path (`autoSwitchTarget`/`switchToBest`, via
/// `isSwitchTarget`'s 7d<99 gate) still switches into it when it is the only
/// capacity left, so declining to PRE-WARM one never lets its quota go unused.
///
/// While the active account is itself still warming (a warm candidate below
/// `target`), returns nil so the caller stays put until it reaches `target`. That
/// dwell is what produces the 5%→5%→5% round-robin: hold on each slot until its
/// window is open, then move to the next.
public func preWarmTarget(accounts: [Account], target: Double = 5, weeklySkip: Double = 95) -> Int? {
    let claude = accounts.filter { $0.provider == "claude" }
    guard let active = claude.first(where: { $0.isActive }) else { return nil }
    // Decide only on a trustworthy active reading (see `freshActiveReading`). A
    // stale / re-auth active → stay put, never advance on unknown data.
    guard freshActiveReading(active) else { return nil }
    // Still warming the active slot (window not open, weekly not tight) → hold
    // until it crosses `target`. This dwell is the 5%→5%→5% round-robin: an
    // exhausted or weekly-tight active is NOT held, so we divert off it.
    if switchPct(active) < target, sevenDayPct(active) < weeklySkip { return nil }
    // Un-warmed idle slots with weekly headroom; a real 7d meter is required so a
    // missing-window 0 can't masquerade as the cheapest weekly. Lowest weekly
    // first, tie-break lowest 5h (freshest reset), then number for a stable order.
    let candidates = claude.filter {
        !$0.isActive && isSwitchTarget($0) && hasSevenDay($0)
            && switchPct($0) < target && sevenDayPct($0) < weeklySkip
    }
    return candidates.min(by: {
        (sevenDayPct($0), switchPct($0), Double($0.number))
            < (sevenDayPct($1), switchPct($1), Double($1.number))
    })?.number
    // ponytail: no "settle" step. Cheapest-first warming ends the round parked on
    // the highest-weekly of the warmed slots, and continued traffic burns it. A
    // return-to-lowest-weekly step was tried and REVERTED — under live usage the
    // slots' 7d equalise and it oscillated at the cooldown floor (cfr round2).
    // The exhaustion escape (`autoSwitchTarget`/`switchToBest`, when auto-switch
    // is on) is the safety net for a slot that climbs toward its weekly limit;
    // pre-warm pairs with auto-switch for exactly this reason.
}
