# cbar standalone — full Swift-native design (drop cswap)

- **Date:** 2026-07-10
- **Status:** draft (awaiting approval)
- **Supersedes:** the cswap-CLI data layer in `2026-07-10-cbar-design.md` (UI/packaging from that spec still hold)

## Goal

Make cbar **fully self-contained in Swift**: capture accounts, fetch per-account
Claude usage, and switch the active account — all natively, with **no cswap, no
TUI, no Rust, no Python**. Codex stays as-is (local session files). The app must
be **sound** (never corrupt the user's live Claude login), **complete** (handle
expiry, rate limits, errors), and **leak-free**.

## Why this is feasible & validated

The Anthropic OAuth usage API is undocumented; the exact protocol was extracted
from `claude-swap`'s source and **live-verified** on 2026-07-10:

- `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer`,
  `anthropic-beta: oauth-2025-04-20`, `User-Agent` → returned **HTTP 429**
  (not 401/404), i.e. **auth + endpoint + headers are correct**; the 429 was
  self-inflicted rate-limiting from the old 30 s full-pass polling.
- Reading the active token from Keychain (`Claude Code-credentials` / `$USER`)
  works.

**Critical lesson:** the usage endpoint **rate-limits per account**. Naïve
polling (our old 30 s `cswap list` full pass, and any "fetch every 60 s") trips
it (`retry-after: 0` = sustained edge). Paced fetching is mandatory, not
optional.

## Protocol (exact, from cswap source)

### Usage — `GET api.anthropic.com/api/oauth/usage`
Headers: `Authorization: Bearer <access>`, `anthropic-beta: oauth-2025-04-20`,
`User-Agent: cbar/1.0`. No `anthropic-version`. 5 s timeout.
Response mapping:
- `five_hour.utilization` → 5h `pct`; `seven_day.utilization` → 7d `pct`
  (field is **`utilization`**), each with optional ISO `resets_at`.
- `limits[]`: each has **`percent`** (not utilization) and
  `scope.model.display_name` (e.g. `"Fable"`) + optional `resets_at` → scoped.
- `extra_usage` (spend) optional — out of scope for v1.

### Token refresh — `POST platform.claude.com/v1/oauth/token`
JSON body `{grant_type:"refresh_token", refresh_token, client_id:"9d1c250a-e61b-44d9-88ed-5944d1962f5e"}`,
headers `Content-Type: application/json`, `User-Agent`. 10 s timeout. Response:
`access_token`, `expires_in` (s), optional rotated `refresh_token`, optional
`scope`. Store `expiresAt = now_ms + expires_in*1000` (epoch **ms**). Refresh
early when `now_ms + 5*60*1000 >= expiresAt`. Body containing `invalid_grant`/
`invalid_client` → dead lineage (needs re-login); else transient.

### Credentials (active account)
macOS Keychain via `/usr/bin/security` (leak-free, no CoreFoundation):
- service `Claude Code-credentials`, account `$USER` (fallbacks: euid name,
  `claude-code-user`). Value = JSON `{"claudeAiOauth":{accessToken, refreshToken,
  expiresAt(ms), scopes[]}}`.
- Read order: Keychain wins → file `~/.claude/.credentials.json` fallback.
- Write: Keychain when usable; also rewrite `.credentials.json` **only if it
  already exists** (bumps mtime so a running Claude Code hot-reloads); never
  create it. Keychain-unusable → write file + delete stale keychain item.

### `~/.claude.json` (note: at `$HOME`, not in `~/.claude/`)
`oauthAccount = {emailAddress, accountUuid, organizationUuid, organizationName}`.
Identity = `(emailAddress, organizationUuid)`. Switch **splices only
`oauthAccount`**, preserving every other key.

## Architecture (Swift)

`CbarCore` holds pure + boundary logic (testable); the app wires UI.

| Unit | Responsibility | Notes |
|---|---|---|
| `Keychain` | get/set/delete generic-password via `/usr/bin/security` | rc 44 = not-found; secret via `-w`/hex stdin; **no CF memory** |
| `Credentials` | `ClaudeAiOauth` model; read/write active creds (keychain→file) | |
| `ClaudeConfig` | read/write `~/.claude.json` oauthAccount splice | preserve other keys |
| `OAuthClient` | async usage GET + token refresh POST (URLSession) | maps utilization/percent → pct |
| `AccountStore` | cbar's own store: `~/.cbar/accounts.json` + keychain svc `cbar`/`account-{n}` | add(capture)/remove/list/setActive |
| `UsageService` | **paced** fetch → `[Account]`; in-mem cache persisted `~/.cbar/usage-cache.json` | replaces `CswapClient` as Provider |
| `Switcher` | switch-to: backup→write creds→splice config→set active; rollback | never break login |
| `CodexProvider` | unchanged (local session files) | |

### Pacing (SnapshotSource-equivalent) — mandatory
Per refresh: fetch the **active account** + **at most one stalest alternate per
30 s** (SERVE_TTL); everything else served from cache. Result = O(1) requests
per TTL regardless of account count. Per-account backoff: base `30·2^(n-1)`
cap 600 s; `retry-after: 0` → cap 120 s (sustained edge); `retry-after: N>0` →
honor N, cap 900 s. Stagger parallel fetches 0.25 s. Poll cadence 60 s + on
popover open (both gated by the pacing rules, so they cannot over-fetch).

## Soundness / safety guarantees (the explicit ask)

- **Never corrupts the live login.** Switch runs backup → write → rollback-on-
  error, and **never refreshes the ACTIVE account's token while Claude Code is
  running** (detect a running `claude` process; if the active token is expired
  and Claude Code is up, serve cached usage instead of rotating the token out
  from under it). Writes are atomic; original creds+config restored on any
  failure.
- **Rate-limit safe.** Paced fetch + per-account backoff honoring `Retry-After`.
- **Leak-free.** Swift ARC; Keychain via subprocess (zero CoreFoundation manual
  memory); URLSession `async/await` (no callback retain cycles); `[weak self]`
  in every timer/closure; timers invalidated on teardown; no long-lived Python.
  Bundle stays ~1 MB.
- **Complete.** Handles: token expiry (refresh w/ 5-min buffer), `invalid_grant`
  (flag account "re-login needed", don't crash), 429/backoff, missing/empty
  creds, keychain-unusable → file fallback, no accounts yet, active account not
  managed.

## Account lifecycle (no cswap)

- **Add**: user logs into Claude Code as an account, clicks **Add current
  account** → cbar snapshots the live creds (keychain/file) + `~/.claude.json`
  `oauthAccount` into its own store (keychain svc `cbar`). Repeat per account.
- **Switch**: pick a stored account → cbar backs up the current active into its
  slot, writes the target's creds to the active keychain + splices its
  `oauthAccount` into `~/.claude.json`, marks it active. New Claude sessions use
  it (running sessions unaffected).
- **Remove**: drop the slot + its keychain item.
- **Migration (optional convenience)**: a one-time "Import from cswap" that
  reads `~/.claude-swap-backup` so existing users don't re-add — offered, not
  required.

## Testing & verification

- **Unit (assert, no XCTest):** usage-response parsing (utilization vs percent,
  scoped display_name, missing keys), expiry math (ms + 5-min buffer),
  backoff math (base/edge/burst caps), config `oauthAccount` splice preserves
  other keys, credentials JSON round-trip.
- **Live (gated, respects rate limit):** after the current 429 clears, fetch the
  active account's real usage from Swift and confirm pct/resets parse. Switch
  test uses a backup + restores.
- **Soundness drill:** verify `~/.claude.json` non-`oauthAccount` keys are byte-
  identical before/after a switch; verify rollback restores originals on a
  forced mid-switch error.

## Out of scope (v1)

Spend/`extra_usage` display, API-key (`sk-ant-`) accounts, auto-switch engine,
the interactive OAuth login itself (Claude Code performs login; cbar only
captures/refreshes), Codex live API (stays local-file).

## Phasing (→ plan)

1. Keychain + Credentials + ClaudeConfig + OAuthClient; live-verify active usage
   fetch in Swift (after 429 clears).
2. AccountStore + add-current + multi-account list.
3. Paced UsageService + cache + backoff; replace `CswapClient` as the Provider.
4. Switcher (switch-to, backup, rollback) + soundness drill.
5. add/remove UI + green/hover polish + remove cswap; optional cswap import.
