import Foundation

/// Minimal config, read from `~/.cbar/config.json` (edit the file to change).
/// Lenient: missing keys keep defaults.
public struct CbarConfig {
    public var autoSwitchEnabled: Bool = true
    public var autoSwitchThreshold: Double = 93   // switch when active account's 5h hits this %

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
