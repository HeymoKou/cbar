# cbar — native menu-bar monitor for cswap accounts

- **Date:** 2026-07-10
- **Status:** draft (awaiting approval)
- **Author:** heymo (with Claude)

## Goal

A native macOS menu-bar app that shows the progress of **all** cswap-managed
Claude accounts at a glance and lets you switch between them. It replaces the
current SwiftBar plugin (`~/project/cswap-bar`), whose ASCII rendering the
owner dislikes.

The menu-bar shows a single color-coded icon; clicking it opens a native
SwiftUI popover with real progress bars per account.

### North star (not v1 scope)

If it turns out well it should be able to replace ClaudeBar (tddworks), which
monitors multiple providers. So the data model is kept provider-generic, and
**Codex is a planned second provider — added later, not now.**

## Non-goals (v1)

- Any provider other than cswap (Codex, Bedrock, Cursor, …). Model leaves room;
  code ships cswap only.
- Preferences/settings UI. Constants live in source.
- Code signing, notarization, distribution. Local build only.
- Feature parity with ClaudeBar. That is the direction, not the v1 bar.

## Background

- **Data source:** `cswap` (`~/.local/bin/cswap`, a `uv` tool `claude-swap`).
  It manages multiple Claude Code accounts and reports per-account usage.
- **Current UI:** `cswap-bar` SwiftBar plugin renders the same data as ASCII
  text rows in a SwiftBar dropdown. Works, but not the owner's taste.
- **Reference:** ClaudeBar.app (`com.tddworks.claudebar`, v0.4.70) is a native
  SwiftUI menu-bar app monitoring several AI-coding providers. It does **not**
  do cswap multi-account switching — that gap is why cbar exists. Used only as
  a look-and-feel reference.

## cswap CLI contract

Commands cbar calls (all via `Process`):

| Purpose        | Command                                   |
|----------------|-------------------------------------------|
| Read accounts  | `cswap --list --json`                     |
| Switch to N    | `cswap --switch-to <number>`              |
| Switch to best | `cswap --switch --strategy best`          |
| Open TUI       | `cswap --tui` (in a terminal)             |

`--list --json` output (observed, `schemaVersion: 1`):

```jsonc
{
  "schemaVersion": 1,
  "activeAccountNumber": 2,
  "accounts": [
    {
      "number": 1,
      "email": "user1@example.com",
      "organizationName": "Example Org",
      "active": false,
      "usageStatus": "ok",
      "usage": {
        "fiveHour": { "pct": 96.0, "countdown": "1h 15m", "resetsAt": "…", "clock": "02:50" },
        "sevenDay": { "pct": 82.0, "countdown": "1d 22h", "resetsAt": "…", "clock": "…" },
        "scoped":  [ { "pct": 100.0, "countdown": "1d 22h", "name": "Fable", "resetsAt": "…", "clock": "…" } ]
      },
      "usageFetchedAt": "2026-07-09T16:34:11Z",
      "usageAgeSeconds": 11.2
    }
    // …
  ]
}
```

Field notes that drive decoding:

- A usage window may carry only `pct` (e.g. an account whose 5h window is idle).
  So every field except `pct` is optional.
- **Fable** = the `scoped` entry with `name == "Fable"`.
- **Max pct** for an account = `max(fiveHour.pct, sevenDay.pct, max(scoped[].pct))`
  — the same rule the SwiftBar plugin uses for its headline number/color.

## Architecture

Small units, each with one job:

| Unit             | Responsibility                                             | Depends on        |
|------------------|------------------------------------------------------------|-------------------|
| `CswapClient`    | Run cswap commands, decode `--list --json` into models.    | Foundation only   |
| `Account`/`Meter`| Provider-generic value types (see model below).            | —                 |
| `UsageStore`     | `@Observable`. Poll every 30 s + manual refresh; publish.  | `CswapClient`     |
| `StatusItemController` | Own the `NSStatusItem`; render color-coded icon.     | `UsageStore`      |
| `PopoverView`    | SwiftUI: active summary + account list + actions.          | `UsageStore`, `MeterBar` |
| `MeterBar`       | Reusable SwiftUI progress bar (pct → width + color, countdown label). | —        |
| `AppDelegate`/`main` | Wire status item ↔ popover; `.accessory` activation.   | above             |

### Provider-generic model (the only seam for Codex-later)

Deliberately thin — one protocol, one implementation in v1. No plugin registry,
no dynamic loading. Codex slots in by adding a second `Provider` and merging its
accounts into the store.

```swift
struct Meter: Identifiable {          // one usage window
    let id: String                    // "5h" | "7d" | "Fable"
    let pct: Double
    let countdown: String?            // "1h 15m" or nil
}

struct Account: Identifiable {
    let id: String                    // "cswap:2"
    let number: Int                   // cswap slot
    let email: String
    let org: String
    let isActive: Bool
    let status: String                // "ok" | other
    let meters: [Meter]
    let ageSeconds: Double?
    var maxPct: Double { meters.map(\.pct).max() ?? 0 }
}

protocol Provider {                   // cswap is the sole conformer in v1
    var name: String { get }
    func accounts() throws -> [Account]
    func switchTo(_ account: Account) throws
    func switchToBest() throws
}
```

`ponytail:` this protocol has one implementation on purpose — the owner asked
for Codex later, so the seam is cheap insurance, not speculation. If Codex never
lands, delete the protocol and inline `CswapClient`.

## Menu-bar label

Icon only, no text (owner's choice: "color dot"). SF Symbol
`arrow.left.arrow.right.circle.fill` rendered as a **non-template** `NSImage`
tinted by the worst account state:

- **Green** (`systemGreen`): all healthy — top account `maxPct < 60`.
- **Orange** (`#e08600`): `60 ≤ maxPct ≤ 85`.
- **Red** (`#e0332e`): `maxPct > 85`, **or** any account `status != "ok"`.

Rationale for the color source: the owner wants an at-a-glance health signal.
The icon tint reflects the *most-consumed* account so a maxed-out account is
never hidden just because it is not the active one.

Stale data (any account `ageSeconds > 600`) dims the icon to ~50% opacity
instead of adding the `~` glyph the ASCII version used.

Tooltip (hover) = `active-email · maxPct%` so the text is one hover away without
spending menu-bar width.

## Popover UI (SwiftUI, `.window`-style panel)

Matches the approved mock:

```
╭───────────────────────────╮
│ user2@example.com    │   ← active account header (email + org小)
│ 5h  ▓▓▓▓▓▓▓▓░░  96%  1h15m │   ← MeterBar rows, colored by pct
│ 7d  ▓▓▓▓▓▓▓░░░  82%  1d22h │
│ Fbl ██████████ 100% 1d22h │
│───────────────────────────│
│ 1 heymo       [switch]  5% │   ← other accounts, click row = switch
│ 3 user3      [switch] 12% │      (expandable to show their meters)
│───────────────────────────│
│ Switch to best   ↻ Refresh │   ← actions
│ cached 11s ago       Quit  │
╰───────────────────────────╯
```

- Active account: full meters always shown.
- Other accounts: one row each (number, short email, max-pct, colored). Clicking
  the row (or its `[switch]` affordance) switches to it. Optionally expandable to
  show that account's 5h/7d/Fable meters (disclosure).
- `MeterBar` color: same thresholds as the label (green/orange/red).
- Footer: **Switch to best**, **Refresh**, cache-age text, **Quit**. (An
  "Open cswap TUI…" item is optional; include if trivial.)

## Data flow & polling

`Timer (30 s)` → `UsageStore.refresh()` → `CswapClient.accounts()`
→ decoded `[Account]` published → `StatusItemController` re-tints icon and
`PopoverView` re-renders. Refresh also fires when the popover opens.

Switch: row click → `CswapClient.switchTo(account)` → immediate `refresh()`.
"Switch to best" → `switchToBest()` → `refresh()`.

**Risk — does `--list --json` hit the network each call?** The JSON reports
`usageAgeSeconds`/`usageFetchedAt`, which means cswap keeps a usage cache, so
`--list` is *probably* a fast cache read. This must be **measured during
implementation** (time the call; watch for rate-limit errors). If a call turns
out to fetch over the network, raise the poll interval (e.g. 120 s) and lean on
the displayed cache age. All cswap calls run off the main thread; a failed or
slow call leaves the last good data on screen with a visible "stale" state.

Errors (cswap missing, non-zero exit, undecodable output) surface as a red icon
and an error row in the popover, mirroring the SwiftBar plugin's fallbacks — no
silent blank state.

## Build & packaging (no Xcode)

Only Command Line Tools + Swift 6.3 are installed; full Xcode is not. So:

- **SwiftPM package** with an executable target `Cbar` and a self-test target.
  Frameworks (`AppKit`, `SwiftUI`) are system imports — no external deps.
- `swift build -c release` produces the binary.
- `build.sh` wraps the binary into `Cbar.app`:
  - `Cbar.app/Contents/MacOS/Cbar` (the binary)
  - `Cbar.app/Contents/Info.plist` with `LSUIElement = true` (menu-bar accessory,
    no Dock icon), bundle id `com.heymo.cbar`, version, `CFBundleIconFile`.
  - `Cbar.app/Contents/Resources/` (app icon if any).
- The process sets `NSApp.setActivationPolicy(.accessory)` and calls `NSApp.run()`.
- **Launch at login:** a LaunchAgent plist at
  `~/Library/LaunchAgents/com.heymo.cbar.plist` (`RunAtLoad`, `KeepAlive` off),
  loaded with `launchctl bootstrap`/`load`. `install.sh` builds, copies the app,
  and installs the agent.

## Migration from SwiftBar

Once cbar runs correctly, remove the SwiftBar symlink
(`~/.config/swiftbar/cswap.30s.sh`) so the menu bar does not show two items, and
mark `~/project/cswap-bar` deprecated (its README gains a pointer to cbar). Both
can run in parallel during a short trial.

## Testing & verification

- **Decode self-test** (`swift run CbarSelfTest`): decodes a checked-in
  `Sample.json` (the observed 3-account payload) and asserts, with plain
  `assert`/`precondition` (no XCTest — avoids the full-Xcode dependency):
  - 3 accounts parse; active is #2.
  - Account #1 meters: 5h = 96, 7d = 82, Fable = 100; `maxPct == 100`.
  - An account with a pct-only window (no countdown) decodes without error.
- **Label color logic:** unit-asserted (pct → color) in the same self-test.
- **Live run (required before "done"):** build the `.app`, launch it, confirm
  the status item appears, the popover opens with real data, colors match, and
  a switch actually changes the active account (`cswap --list` reflects it).
  The menu-bar dropdown cannot be screenshotted from the CLI, so the final
  visual pass is the owner's — everything up to it is machine-verified.

## Open risks

1. `--list --json` network cost (mitigation above).
2. Running a hand-assembled `.app` (SwiftUI app lifecycle) on macOS 26 — expected
   to work; if `MenuBarExtra`/lifecycle misbehaves, the AppKit `NSStatusItem`
   path chosen here is the robust fallback and is already the primary design.
3. Non-template tinted menu-bar icons in dark/light menu bars — verify contrast
   in both.

## Future (explicitly later)

- Codex provider (second `Provider`; ClaudeBar's `codex.probeMode: "api"` hints
  at how usage is obtained).
- Additional providers toward ClaudeBar replacement.
- Preferences UI (poll interval, which providers, thresholds).
