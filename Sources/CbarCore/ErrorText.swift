import Foundation

/// The one place an `Error` becomes words for the panel's banner and the
/// menu-bar tooltip. String interpolation used to put Swift's debug form there —
/// `failed(-3, "…")`, `http(429, retryAfter: nil)`, `Error Domain=cbar Code=2 …`.
/// The log keeps that raw form; this is only what a person reads.
public func describeError(_ error: Error) -> String {
    switch error {
    case OAuthError.needsReauth:
        return "needs re-login"
    case OAuthError.http(429, _):
        return "rate limited — try again in a minute"
    case OAuthError.http(let code, _) where code == 401 || code == 403:
        return "not authorized — log in again"
    case is OAuthError:
        return UsageRow.describe(error)
    case Keychain.KErr.failed(let rc, _):
        // The exit code only, never the message: a read's message is
        // `security`'s stderr, and a write's has to stay scrubbed of the value.
        switch rc {
        case -3: return "the Keychain did not answer within 30 s — is a Keychain prompt waiting?"
        case Keychain.tooLarge: return "the login is too large to store in the Keychain"
        case -2: return "the login contains a line break, so it was not written to the Keychain"
        case -1: return "could not run /usr/bin/security"
        default: return "Keychain error (security exited \(rc))"
        }
    case Switcher.SwitchErr.noCredentials(let n):
        return "account #\(n) has no saved login — add it again"
    case Switcher.SwitchErr.noOAuthAccount(let n):
        return "account #\(n) is missing its Claude Code account details — add it again"
    case let e as CodexSwitcher.SwitchErr:
        return e.description
    default:
        // cbar's own NSErrors carry a sentence here; Cocoa's (file, POSIX) do too.
        return (error as NSError).localizedDescription
    }
}
