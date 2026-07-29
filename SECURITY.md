# Security

cbar handles live Claude Code OAuth credentials. Please read this before
reporting an issue or contributing.

## Reporting a vulnerability

Report privately via GitHub's [Report a
vulnerability](https://github.com/HeymoKou/cbar/security/advisories/new) form.
Do not open a public issue for anything involving credentials. This is a hobby
project maintained by one person: expect a reply in days, not hours, and no
bounty.

## Where credentials live

| What | Where | Mode |
|---|---|---|
| Per-account OAuth access + refresh tokens | Keychain, service `cbar`, account `account-{n}` | Keychain ACL |
| The live Claude Code credential cbar reads and rewrites | Keychain, service `Claude Code-credentials` | Keychain ACL |
| Emails, org names, account UUIDs, copied `oauthAccount` | `~/.cbar/accounts.json` | `0600` |
| Per-account usage history | `~/.cbar/usage-cache.json` | `0600` |
| Switch/auto-switch decisions, naming accounts by email | `~/.cbar/cbar.log` | `0600` |

No token value is ever written outside the Keychain.

## Known properties worth understanding

- **Keychain items are written with `/usr/bin/security`.** After cbar rewrites
  the `Claude Code-credentials` item, that item's creating application is
  `security` rather than Claude Code. Two consequences: Claude Code may prompt
  for Keychain access once afterwards, and the item becomes readable by any
  process running as you via the `security` CLI without a prompt. This is the
  same trade every `security`-based account switcher makes; it is not a bug, but
  it is a real change to your local threat model. A `security` invocation that
  sits unanswered — a locked keychain, or that access prompt on a machine nobody
  is at — is killed after 30 s, so an unattended prompt fails the read with a
  logged error instead of stalling every credential path behind it.
- **cbar refuses to refresh a token Claude Code might also hold.** A refresh
  rotates: the old token dies immediately and reuse detection can revoke the
  whole family. When ownership of the live token cannot be established, cbar
  serves cached data rather than guessing. See `UsageService.shouldSkipRefresh`.
- **All credential mutations are serialized** on one queue, so a refresh cannot
  interleave with a switch.

## Contributing safely

If you touch credential paths, the bar is:

- Never interpolate a credential, or a value derived from one, into a log line,
  an error, or a user-visible string. `CbarLog.write` takes arbitrary strings and
  errors are routinely interpolated — that is the easiest way to introduce a
  leak here.
- Never pass a secret in `argv`. Use stdin, as `Keychain.setRaw` does.
- Never persist a rotated token with `try?`. The rotation already killed the old
  one, so a dropped write is a permanently dead account.
- Run `swift run CbarSelfTest` and keep it green.
