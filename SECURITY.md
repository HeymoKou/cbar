# Security

cbar handles live Claude Code OAuth credentials and, once you add Codex
accounts, live Codex (ChatGPT) logins. Please read this before
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
| Per-account Codex logins (a full `auth.json` each) | `~/.cbar/codex/{n}.sealed`, AES-GCM | `0600` |
| The key those are sealed with | Keychain, service `cbar-codex`, account `codex-key` | Keychain ACL |
| The live Codex login cbar reads and rewrites | `~/.codex/auth.json` (Codex's own file) | `0600` |
| A Codex login being added, until the next poll imports it | `~/.cbar/codex-login/auth.json` (written by `codex login`) | `0600` |
| Codex account emails, plans, identities; usage history | `~/.cbar/codex-accounts.json`, `~/.cbar/codex-usage-cache.json` | `0600` |
| Grok Build usage history | `~/.cbar/grok-usage-cache.json` | `0600` |
| Antigravity usage history | `~/.cbar/antigravity-usage-cache.json` | `0600` |
| The live Grok Build login cbar reads (and rewrites only to persist a token it just rotated, and only while `grok` is not running) | `~/.grok/auth.json` (Grok's own file) | `0600` |
| The live Antigravity / `agy` login | Keychain, service `gemini`, account `antigravity` | Keychain ACL |

No Claude token is ever written outside the Keychain. Codex logins are ~4 KB,
too big for `security -i` (next section), so they are sealed on disk under a
Keychain-held key instead: the files are useless without the key, and anyone
who can read the key can read the logins — the same exposure the
`security`-created items already have.

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
- **`security -i` cuts lines at 4096 bytes.** A longer command is not rejected:
  its head runs and stores a truncated secret, and its tail comes back on stderr
  as an "unknown command" — secret included. `Keychain` refuses such a value
  before `security` runs, and never puts `security`'s stderr into a write error.
- **Codex's live login belongs to Codex.** cbar never refreshes the token in
  `~/.codex/auth.json`; it copies it back into that account's slot whenever Codex
  has rotated it. Idle accounts exist only in cbar's store, so cbar refreshes
  those itself and persists the rotation before using it. A switch saves the
  outgoing login first and refuses to overwrite a login it cannot restore.
- **Grok's live login belongs to Grok while `grok` is running.** cbar reads
  `~/.grok/auth.json` for a usage snapshot and will not refresh that token if a
  `grok` process is alive. When grok is not running, an expired token is
  refreshed against `auth.x.ai` and the rotation is written back before use —
  same persist-before-use rule as an idle Codex slot. Grok and Antigravity
  cards cannot switch accounts.
- **Antigravity's Keychain item is read-only.** cbar never writes the
  `gemini`/`antigravity` item (a `security` rewrite would change its ACL). An
  expired Google access token is refreshed in memory with the OAuth client
  extracted from the `agy` binary; the new access token is not persisted.

## Contributing safely

If you touch credential paths, the bar is:

- Never interpolate a credential, or a value derived from one, into a log line,
  an error, or a user-visible string. `CbarLog.write` takes arbitrary strings and
  errors are routinely interpolated — that is the easiest way to introduce a
  leak here.
- Never pass a secret in `argv`. Use stdin, as `Keychain.setRaw` does.
- Never surface `security`'s stderr from a write — it can quote the secret back.
- Never persist a rotated token with `try?`. The rotation already killed the old
  one, so a dropped write is a permanently dead account.
- Run `swift run CbarSelfTest` and keep it green.
