import Foundation

/// Minimal config, read from `~/.cbar/config.json` (edit the file to change).
/// Lenient: missing keys keep defaults.
public struct CbarConfig {
    /// ON by default. This was off, on the reasoning that rewriting the live
    /// keychain item and `~/.claude.json` is too much to hand someone who
    /// installed a usage monitor. What that produced instead: no config file was
    /// ever written, so the flag was invisible, and on 2026-09-01 an account sat
    /// at its reset while cbar watched and did nothing — every poll returned at
    /// the `autoSwitchEnabled || preWarmEnabled` guard before it even logged a
    /// decision. Rotating off a blocked account IS the app; a default that
    /// silently disables it is the wrong side to fail on. `seedIfMissing` writes
    /// the file on first run so the setting is a visible line you can flip, not
    /// an undocumented default.
    public var autoSwitchEnabled: Bool = true
    public var autoSwitchThreshold: Double = 93   // switch when active account's 5h hits this %

    /// ON by default, same reasoning. When on, cbar diverts the live account
    /// through idle slots to open (pre-warm) their 5h windows with the user's real
    /// traffic. Independent of `autoSwitchEnabled` — you can pre-warm without the
    /// 93% escape, or both. It also only acts while Claude Code is actually
    /// running, so an idle machine is never churned.
    public var preWarmEnabled: Bool = true

    /// Defaults, for holding a value before the first poll has read the file.
    public init() {}

    /// Write the default config on first run. Two jobs: make the settings that
    /// rewrite your login DISCOVERABLE (a file you can read and edit beats a
    /// default nobody can see), and give "off" somewhere to be recorded.
    ///
    /// No-op once the file exists, so it never overwrites a choice. Deleting the
    /// file is therefore not how you disable cbar — the defaults are on, and the
    /// next launch re-seeds them; set the key to `false` instead.
    ///
    /// Startup only, NOT inside `load()`: `load()` runs every 60 s poll, and
    /// seeding from there would rewrite the file behind a user editing it.
    @discardableResult
    public static func seedIfMissing(dir: String = "\(NSHomeDirectory())/.cbar") -> Bool {
        let path = "\(dir)/config.json"
        guard !FileManager.default.fileExists(atPath: path) else { return false }
        let d = CbarConfig()
        let o: [String: Any] = [
            "autoSwitchEnabled": d.autoSwitchEnabled,
            "autoSwitchThreshold": d.autoSwitchThreshold,
            "preWarmEnabled": d.preWarmEnabled,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: o,
                                                     options: [.prettyPrinted, .sortedKeys]),
              // 0600 like every other file cbar owns: this one decides whether
              // something rewrites the live login, so it is not group-writable.
              (try? SecureFile.write(json, to: path)) != nil
        else { return false }
        return true
    }

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

/// The "burn" account: the one real work should consume toward its 5h limit.
/// Highest 5h among healthy, non-exhausted slots still BELOW the escape threshold
/// — burning it only raises its 5h, so it stays the highest and this choice is
/// stable (no oscillation). The instant it crosses the threshold the escape path
/// (`autoSwitchTarget`) moves off it and the next-highest becomes home, so the
/// two never fight. Derived, not remembered: no state to persist or resync.
public func burnHome(_ accounts: [Account], escapeThreshold: Double = 93) -> Int? {
    accounts.filter { $0.provider == "claude" && isSwitchTarget($0) && switchPct($0) < escapeThreshold }
        .max(by: { a, b in
            switchPct(a) != switchPct(b) ? switchPct(a) < switchPct(b) : a.number > b.number
        })?.number
}

/// Pre-warm, as a scheduler around the burn account: consume ONE account (the
/// burn home) toward its limit, and take brief excursions to open the 5h window
/// of any COLD idle account (start its reset timer), then RETURN to the burn home.
/// `nil` means "stay put". No inference request and no quota beyond the user's own
/// traffic — it only re-points which account that traffic lands on.
///
/// `active` is the currently-live slot number. Returns the slot to switch to next,
/// or nil to stay. Escape (`autoSwitchTarget`) is evaluated by the caller FIRST and
/// outranks this — an over-threshold or exhausted account must leave regardless.
///
/// An earlier design held on each warmed idle and kept burning IT, which stranded
/// the real work account (cfr): pre-warm is meant to prime idles and hand the
/// login back, not to move where you work. The return target is `burnHome`, which
/// is derived (highest-5h healthy), so it can't oscillate the way a
/// lowest-weekly "settle" did.
public func preWarmMove(accounts: [Account], active: Int, target: Double = 5,
                        weeklySkip: Double = 95, escapeThreshold: Double = 93) -> Int? {
    let claude = accounts.filter { $0.provider == "claude" }
    guard let activeAcc = claude.first(where: { $0.number == active }) else { return nil }
    // Decide only on a trustworthy active reading. A stale / re-auth active → stay
    // put: switching on an unknown reading abandons a half-warmed idle or churns
    // the live login during a 429 storm. An EXHAUSTED active passes this (it's a
    // known-good reading) and is diverted off below, not frozen.
    guard freshActiveReading(activeAcc) else { return nil }
    // Keep sending traffic to a low, healthy, weekly-OK active — whether it is an
    // idle we are warming or a burn account freshly entered at low 5h, the action
    // is identical: use it until its window is meaningfully open. An exhausted or
    // weekly-tight active fails the 7d check and falls through to divert off it.
    if switchPct(activeAcc) < target, sevenDayPct(activeAcc) < weeklySkip { return nil }
    // Excursion: prime a COLD idle (window not open) — healthy, real 7d meter,
    // weekly headroom. Cheapest weekly first (protect the scarce 7-day limit), tie
    // freshest 5h, then number. Not `active`, so a just-warmed idle isn't re-picked.
    if let cold = claude.filter({
        $0.number != active && isSwitchTarget($0) && hasSevenDay($0)
            && switchPct($0) < target && sevenDayPct($0) < weeklySkip
    }).min(by: {
        (sevenDayPct($0), switchPct($0), Double($0.number))
            < (sevenDayPct($1), switchPct($1), Double($1.number))
    }) {
        return cold.number
    }
    // Nothing cold left to prime → hand the login back to the burn account.
    if let home = burnHome(accounts, escapeThreshold: escapeThreshold), home != active {
        return home
    }
    return nil
}
