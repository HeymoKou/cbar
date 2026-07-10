# cbar

Native macOS menu-bar monitor for your Claude accounts' usage — 5h / 7d / Fable
per account, one-click switching, and a color-coded icon. **Fully self-contained
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

A source-build Homebrew tap is the intended package route (builds locally, so no
Gatekeeper/notarization needed):

```bash
brew install heymo/tap/cbar   # once the tap is published
```

(Until then, use `./install.sh`.)

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

## How it stays safe

- **Rate-limit safe:** the usage endpoint is per-account rate-limited, so cbar
  paces fetches (active account + at most one stalest alternate per 30 s) with
  per-account backoff honoring `Retry-After`.
- **Never breaks your login:** switching backs up the current account and rolls
  back on any error; the active account's token is never refreshed while Claude
  Code is running.
- **Leak-free:** Keychain access via `/usr/bin/security` (no CoreFoundation),
  URLSession over a released semaphore, ARC throughout.

## Verify

```bash
swift run CbarSelfTest            # offline: keychain, creds, config splice, oauth mapping, pacing
swift run CbarSelfTest --service  # exercises the paced UsageService against your store
swift run CbarSelfTest --live     # live OAuth fetch for the active account + Codex
```

## Icon colors

Reflect the **worst** Claude account: green `<60%`, orange `60–85%`, red `>85%`
or any error. Dimmed = data older than 10 min.

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
Apple Developer signing/notarization. Share the repo; they run `./install.sh` and
add their own accounts. Before making the repo **public**, scrub any real emails
from the design docs.

## Roadmap

Codex live API (currently local-file), spend/extra-usage display, more providers,
a published Homebrew tap.

## License

MIT — see [LICENSE](LICENSE).
