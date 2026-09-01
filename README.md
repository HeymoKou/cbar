# cbar

A native macOS menu-bar monitor for your Claude accounts — 5h / 7d / Fable usage
per account, a color-coded icon, and **automatic switching** between accounts.
Pure Swift, no runtime dependencies: it talks to Claude's OAuth usage API
directly and keeps credentials in the macOS Keychain. Codex usage is shown too,
read from local session files.

**macOS 14+ only.** It uses the macOS Keychain and reads Claude Code's local
config, so there is no Linux or Windows build.

## Disclaimer — read before installing

Unofficial, unaffiliated, not from or endorsed by Anthropic.

- **Undocumented endpoints.** Usage and token refresh go to
  `api.anthropic.com/api/oauth/*` and `platform.claude.com/v1/oauth/token` with
  the OAuth client ID that ships inside Claude Code. Anthropic can change or
  revoke any of it without notice.
- **Rotating between subscription accounts may violate the
  [Consumer Terms](https://www.anthropic.com/legal/consumer-terms),** which
  restrict automated access and circumventing usage limits. Accounts have been
  suspended for less. **Auto-switch and pre-warm are on by default** — the first
  launch writes `~/.cbar/config.json` with both enabled and cbar starts rotating
  your live login on its own. Set them to `false` there, or don't install cbar.
- **It writes your live credentials.** Switching rewrites the
  `Claude Code-credentials` Keychain item and `~/.claude.json`.

That risk is yours. The MIT license covers cbar's own code; it grants no right to
use Anthropic's service, OAuth client, or trademarks.

## Install

```bash
brew install heymokou/tap/cbar
brew services start heymokou/tap/cbar   # run now + start at login
```

Or without Homebrew: `./install.sh` builds `Cbar.app`, copies it to
`~/Applications` and starts it at login. (`./build.sh` alone just produces the
bundle.) Either way it builds from source on your machine, so nothing needs Apple
signing or notarization. Needs the Swift toolchain — `xcode-select --install` is
enough, full Xcode is not required.

## Accounts

Log into an account in Claude Code, then click **Add current account**; cbar
snapshots its credentials and profile. Repeat per account. Click an account to
switch to it, or use the ✕ to remove one. If you already used cswap, cbar offers
a one-time import from `~/.claude-swap-backup`.

## Auto-switch

cbar switches away from the **active** account when either is true:

- its **5h** usage reaches `autoSwitchThreshold`, or
- its **7d** usage reaches **99%** — a hard ceiling, not a ranking input.

It moves to the account with the most **5h** headroom. A target must be provably
alive: status ok, a real 5h meter, data no older than the freshness window, 7d
under the ceiling. An account needing re-login is never chosen no matter how much
headroom its stale cache shows, and Codex is never a target. 120 s cooldown.

## Pre-warm

A 5h window doesn't start counting down until you use the account, so an idle
account's window is *closed* — switching to it at 93% buys a full 5 hours instead
of a window that may already be half spent.

Pre-warm opens them ahead of time, and costs no extra quota: it sends no requests
of its own, it only re-points where your **own** traffic lands. Brief excursions
onto a cold idle account to start its timer, then back to the burn account. It
acts only while Claude Code is running. The 93% escape outranks it.

## Config

`~/.cbar/config.json`, re-read every poll — no restart needed:

```json
{
  "autoSwitchEnabled": true,
  "autoSwitchThreshold": 93,
  "preWarmEnabled": true
}
```

That is exactly what the first launch writes. Deleting the file does *not*
disable anything — the defaults are on and the next launch writes it back; set
the key to `false` instead. Every decision is logged: `tail -f ~/.cbar/cbar.log`.

## Behavior notes

- **Icon colors** track the active Claude account: green `<60%`, orange
  `60–85%`, red `>85%` or any error. Dimmed means its data is over 10 min old.
- **Rate limits.** The usage endpoint's budget is client-wide, not per-account,
  so each 60 s poll fetches exactly one account — the stalest. Backoff is
  per-account and honors `Retry-After`.
- **Sleep.** cbar keeps polling behind a sleeping *display* when it's armed and a
  Claude Code session is running; otherwise it idles there. If the whole machine
  sleeps, nothing fires — cbar won't hold a power assertion to prevent that.
- **Switching is not a transaction.** It snapshots credentials and config first
  and rolls back on failure, but the Keychain write lands before the config
  write. A crash between the two can leave them disagreeing; recovery is
  `/login` in Claude Code, then *Add current account*.

Where tokens live, why cbar refuses to refresh one Claude Code might hold, and
what `~/.cbar` exposes: **[SECURITY.md](SECURITY.md)**.

## Verify

```bash
swift run CbarSelfTest            # offline assert suite
swift run CbarSelfTest --service  # paced UsageService against your store
swift run CbarSelfTest --live     # live OAuth fetch + Codex
```

"Offline" means no network, not no side effects — the default run creates and
deletes throwaway login-Keychain items (`cbar-selftest*`) and temp dirs, and
never touches your real Claude Code login.

## Uninstall

```bash
brew services stop heymokou/tap/cbar && brew uninstall heymokou/tap/cbar
rm -rf ~/.cbar                                    # metadata, usage cache, log
security delete-generic-password -s cbar          # once per stored account
```

Non-Homebrew installs also need the launch agent gone
(`launchctl unload ~/Library/LaunchAgents/com.heymo.cbar.plist`, then remove it
and `~/Applications/Cbar.app`).

Uninstalling does **not** restore your Claude Code login — whichever account cbar
selected last stays active. Switch to the one you want first, or run `/login`
afterwards.

## Credits

An independent Swift reimplementation, not a fork — no code copied, and
unaffiliated with either project it learned from:
[ClaudeBar](https://github.com/tddworks/ClaudeBar) by tddworks for the menu-bar
look and feel, and [claude-swap](https://github.com/realiti4/claude-swap) by
realiti4 for the multi-account model and the OAuth protocol cbar reimplements.

MIT — see [LICENSE](LICENSE).
