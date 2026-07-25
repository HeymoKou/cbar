# cbar

Native macOS menu-bar monitor for your Claude accounts' usage — 5h / 7d / Fable
per account, one-click **and automatic** switching, and a color-coded icon. **Fully self-contained
Swift**: it talks to Claude's OAuth usage API directly and manages account
credentials in the macOS Keychain. No cswap, no Python, no runtime dependencies.
Codex usage is also shown (read from local Codex session files).

> **macOS only.** cbar is a native AppKit/SwiftUI menu-bar app that talks to the
> macOS Keychain (`/usr/bin/security`) and reads Claude Code's local config
> (`~/.claude.json`, `~/.claude/`). It does not run on Linux or Windows.

## Requirements

- **macOS 14+** (Sonoma or later).
- **Swift toolchain** — Command Line Tools is enough: `xcode-select --install`
  (full Xcode not required).
- **Claude Code** logged in, so there's an account to capture.

## Build & install (no Xcode needed)

```bash
./install.sh   # builds Cbar.app, copies to ~/Applications, starts at login
```

`./build.sh` alone just produces `Cbar.app` in the repo.

### Homebrew

```bash
brew install heymokou/tap/cbar
brew services start heymokou/tap/cbar   # run now + start at login
```

Builds from source on your machine (macOS only), so no Gatekeeper/notarization.
Tap: <https://github.com/HeymoKou/homebrew-tap>. (`./install.sh` is the
alternative if you'd rather not use Homebrew.)

## Accounts

- **Add current account** — log into an account in Claude Code, then click
  *Add current account*. cbar snapshots its credentials (Keychain) + full
  `oauthAccount`. Repeat per account.
- **Import from cswap** — if you already used cswap, cbar offers a one-time
  import from `~/.claude-swap-backup` so you don't re-add. (cswap is only read,
  not run, and isn't needed afterward.)
- **Switch** — click an account to make it active (writes `~/.claude.json` +
  Keychain, with backup + rollback; new Claude sessions pick it up).
- **Remove** — the ✕ on a non-active account.

## Auto-switch

cbar switches away from the **active** account when either is true:

- its **5h** usage reaches `autoSwitchThreshold`, or
- its **7d** usage reaches **99%** — a hard ceiling, not a ranking input.

It moves to the account with the most **5h** headroom. Below the ceiling 7d is
ignored, because it's what you burned this week rather than what blocks you right
now: folding it in via `max(5h, 7d)` rotated away from usable accounts every poll
(5h=3% with 7d=91%). At the ceiling the weekly limit really does block you, so an
exhausted account is both pushed off and refused as a destination — otherwise
cbar would move the login into an account it can never escape, since an unusable
account's 5h reads 0% forever. Fable and spend are never considered.

A switch target must be **provably alive** — status `ok`, a real 5h meter, data
no older than the freshness window, 7d under the ceiling. An account that needs
re-login or has no credentials is never chosen, no matter how much headroom its
last-good cache shows, and its **Switch** button is hidden (✕ still removes it).
Codex is never a target. 120 s cooldown to avoid churn.

Configure via `~/.cbar/config.json` (edit the file; no restart needed to re-read
on the next poll):

```json
{
  "autoSwitchEnabled": true,
  "autoSwitchThreshold": 93
}
```

Defaults: enabled, threshold `93`. Set `autoSwitchEnabled` to `false` for
manual-only. Every check and switch decision is logged to `~/.cbar/cbar.log`
(`tail -f ~/.cbar/cbar.log` to watch why it did or didn't fire).

## How it stays safe

- **Rate-limit safe:** the usage endpoint is per-account rate-limited, so cbar
  paces fetches — each 60 s poll refreshes every account that's stale (>30 s),
  with per-account exponential backoff honoring `Retry-After` on 429.
- **Never breaks your login:** switching backs up the current account and rolls
  back on any error.
- **Never burns a refresh token:** a refresh *rotates* the token — the old one
  dies instantly — so cbar refuses to refresh any token Claude Code also holds
  (whoever went second would get `invalid_grant` and the account would need a
  manual re-login). A rotated token that can't be persisted is reported, never
  swallowed.
- **Leak-free:** Keychain access via `/usr/bin/security` (no CoreFoundation),
  URLSession over a released semaphore, ARC throughout.

## Verify

```bash
swift run CbarSelfTest            # offline: keychain, creds, config splice, oauth mapping, pacing
swift run CbarSelfTest --service  # exercises the paced UsageService against your store
swift run CbarSelfTest --live     # live OAuth fetch for the active account + Codex
```

## Icon colors

Reflect the **active** Claude account (a maxed-out alternate no longer reddens
the icon): green `<60%`, orange `60–85%`, red `>85%` or any error. Dimmed =
active account's data older than 10 min.

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.heymo.cbar.plist
rm ~/Library/LaunchAgents/com.heymo.cbar.plist
rm -rf ~/Applications/Cbar.app
# accounts live in ~/.cbar + Keychain service "cbar"; remove those to fully reset
```

## Sharing with others

Distribute as **source, built locally** (not a prebuilt download): a locally
built `.app` isn't quarantined, so it runs with no Gatekeeper prompt and needs no
Apple Developer signing/notarization. Share the repo (or the Homebrew tap); they
run `./install.sh` and add their own accounts.

## Roadmap

Codex live API (currently local-file), spend/extra-usage display, more providers.

## Credits

cbar isn't a solo idea — it stands on two open-source projects. It's an
**independent Swift reimplementation, not a fork** (no code is copied), and is
not affiliated with either:

- **[ClaudeBar](https://github.com/tddworks/ClaudeBar)** by tddworks — the
  inspiration for the menu-bar usage-monitor look & feel.
- **[claude-swap](https://github.com/realiti4/claude-swap)** by realiti4 — the
  multi-account model and threshold auto-switch idea, and the (undocumented)
  Claude OAuth usage/refresh protocol that cbar reimplements, were learned from
  its open-source code.

Thanks to both.

## License

MIT — see [LICENSE](LICENSE).
