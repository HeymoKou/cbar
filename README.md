# cbar

Native macOS menu-bar monitor for your Claude accounts' usage — 5h / 7d / Fable
per account, one-click **and automatic** switching, and a color-coded icon. **Fully self-contained
Swift**: it talks to Claude's OAuth usage API directly and manages account
credentials in the macOS Keychain. No cswap, no Python, no runtime dependencies.
Codex usage is also shown, read from local Codex session files — a session
already running stays live, but a brand-new one can take a few minutes to appear.

> **macOS only.** cbar is a native AppKit/SwiftUI menu-bar app that talks to the
> macOS Keychain (`/usr/bin/security`) and reads Claude Code's local config
> (`~/.claude.json`, `~/.claude/`). It does not run on Linux or Windows.

## Disclaimer — read before installing

cbar is an unofficial, unaffiliated personal project. It is not from Anthropic,
not endorsed by Anthropic, and not supported by Anthropic.

- **It uses undocumented endpoints.** Usage and token refresh go to
  `api.anthropic.com/api/oauth/*` and `platform.claude.com/v1/oauth/token` using
  the OAuth client ID that ships inside Claude Code. There is no public API for
  this. Anthropic can change or revoke any of it without notice, at which point
  cbar simply stops working.
- **Rotating between multiple subscription accounts may violate Anthropic's
  [Consumer Terms](https://www.anthropic.com/legal/consumer-terms),** which
  restrict automated access and circumventing usage limits. Accounts have been
  suspended for less. That risk is yours, not the author's, and no amount of
  careful engineering in this repo changes it. Auto-switching and pre-warm are
  **on** by default: the first launch writes `~/.cbar/config.json` with both
  enabled, and cbar starts rotating your live login on its own. If that is not
  what you want, set them to `false` in that file (no restart needed) or don't
  install cbar.
- **It writes your live Claude Code credentials.** Switching accounts rewrites
  the `Claude Code-credentials` Keychain item and `~/.claude.json`. A bug here
  costs you a re-login, and in the worst case a revoked token family that needs
  `/login` on every affected account.

Use at your own risk. The MIT license covers cbar's own code; it grants no right
to use Anthropic's service, OAuth client, or trademarks.

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
alternative if you'd rather not use Homebrew.) Sharing with someone else means
sharing the repo or the tap — a locally built `.app` needs no Apple signing.

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

**On by default.** The first launch writes `~/.cbar/config.json` with
auto-switch and pre-warm enabled, and cbar rotates your live login from then on.
See the Disclaimer above. To turn either off, set its key to `false` in that file
— no restart needed, it's re-read on the next poll. (Deleting the file does *not*
disable anything: the defaults are on and the next launch writes it back.)

It used to default to off, which read as safe and behaved as broken — no config
file was ever written, so the flag was invisible and the common outcome was an
account sitting at its limit while cbar watched.

cbar switches away from the **active** account when either is true:

- its **5h** usage reaches `autoSwitchThreshold`, or
- its **7d** usage reaches **99%** — a hard ceiling, not a ranking input.

It moves to the account with the most **5h** headroom. 7d only counts at the
ceiling, where an exhausted account is both pushed off and refused as a
destination. Fable and spend are never considered.

A switch target must be **provably alive** — status `ok`, a real 5h meter, data
no older than the freshness window, 7d under the ceiling. An account that needs
re-login or has no credentials is never chosen, no matter how much headroom its
last-good cache shows, and its **Switch** button is hidden (✕ still removes it).
Codex is never a target. 120 s cooldown to avoid churn.

The whole config file:

```json
{
  "autoSwitchEnabled": true,
  "autoSwitchThreshold": 93,
  "preWarmEnabled": true
}
```

That is exactly what the first launch writes. Every check and switch decision is
logged to `~/.cbar/cbar.log` (`tail -f ~/.cbar/cbar.log` to watch why it did or
didn't fire).

Both keep working behind a **sleeping display**, but only when there is a reason
to: cbar polls in the dark if it's armed *and* a Claude Code session is actually
running. An unattended overnight run is exactly when an account fills up
unwatched, so that's the case worth the battery; a dark idle machine costs one
config read a minute and nothing else.

If the **whole machine** sleeps, nothing fires — timers don't run there, and cbar
won't hold a power assertion to keep your Mac awake watching a meter. A running
session usually keeps the system awake by itself.

## Pre-warm

Your 5h window doesn't start counting down until you use the account, so an idle
account's window is *closed*: switching to it at 93% buys you a full 5 hours
starting then, instead of a window that could already be half spent. Pre-warm
opens those windows ahead of time.

It costs no extra quota — it sends no requests of its own. All it does is
re-point where your **own** traffic lands: brief excursions onto a cold idle
account to start its reset timer, then back to the "burn" account (the healthy
one with the highest 5h, the one you're meant to consume first). It only acts
while Claude Code is actually running, since with no traffic a switch would just
park your login somewhere idle.

The 93% escape outranks it — leaving a blocked account is mandatory, priming an
idle one is opportunistic. Set `preWarmEnabled` to `false` to keep only the
escape.

## Engineering safeguards

These describe how carefully cbar handles your credentials. They say nothing
about whether using it is permitted — see the Disclaimer.

- **Rate-limit safe:** the usage endpoint's budget is client-wide, not
  per-account, so each 60 s poll fetches exactly **one** account — the stalest
  one. Polling stops while the display is asleep and refreshes on wake, so
  expect gaps in the log rather than an unbroken cadence. Backoff is per-account
  and honors `Retry-After` on 429.
- **Switching tries hard not to break your login:** it snapshots the current
  credentials and config first and restores them if any step fails. It is not a
  transaction, though — the Keychain write lands before the config write, so a
  crash between the two, or a rollback that itself fails, can leave the two
  disagreeing. Recovery is `/login` in Claude Code, then *Add current account*.

Where tokens live, why cbar refuses to refresh one Claude Code might also hold,
how mutations are serialized, and what `~/.cbar` exposes: **[SECURITY.md](SECURITY.md)**.

## Verify

```bash
swift run CbarSelfTest            # offline assert suite (no network)
swift run CbarSelfTest --service  # exercises the paced UsageService against your store
swift run CbarSelfTest --live     # live OAuth fetch for the active account + Codex
```

"Offline" means no network, not no side effects: the default run creates and
deletes throwaway items in your login Keychain (services `cbar-selftest*`) and
temp dirs. It never touches your real Claude Code login. `--service` and
`--live` read your actual store and do hit the network.

## Icon colors

Reflect the **active** Claude account only: green `<60%`, orange `60–85%`, red
`>85%` or any error. Dimmed = active account's data older than 10 min.

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.heymo.cbar.plist
rm ~/Library/LaunchAgents/com.heymo.cbar.plist
rm -rf ~/Applications/Cbar.app
rm -rf ~/.cbar                                    # metadata, usage cache, log
security delete-generic-password -s cbar          # once per stored account
```

Uninstalling does **not** put your Claude Code login back: whichever account cbar
selected last stays active. Switch to the one you want *before* uninstalling, or
run `/login` in Claude Code afterwards.

## Roadmap

Codex live API (currently local-file), spend/extra-usage display, more providers.

## Credits

An **independent Swift reimplementation, not a fork** — no code copied, and
unaffiliated with either project it learned from:

- **[ClaudeBar](https://github.com/tddworks/ClaudeBar)** by tddworks — the
  menu-bar usage-monitor look & feel.
- **[claude-swap](https://github.com/realiti4/claude-swap)** by realiti4 — the
  multi-account model, threshold auto-switch, and the undocumented Claude OAuth
  usage/refresh protocol cbar reimplements.

## License

MIT — see [LICENSE](LICENSE).
