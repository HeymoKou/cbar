import Foundation

/// Everything cbar writes under `~/.cbar` lands here, so the permissions are
/// decided in one place instead of inherited from whatever umask the user's
/// shell happens to have.
///
/// No OAuth tokens live in these files — those are Keychain-only — but the
/// contents are still worth keeping to the owner: `accounts.json` holds every
/// account's email, organization name and UUIDs plus a verbatim copy of Claude
/// Code's `oauthAccount` object, `usage-cache.json` holds per-account usage
/// history, and `cbar.log` names an account on every poll. Blindly copying a
/// third-party JSON blob is also exactly the kind of thing that grows a secret
/// later without anyone re-auditing the file mode.
public enum SecureFile {
    /// Directory, owner-only (0700). Also tightens an existing directory —
    /// the 0755 one left behind by earlier versions is the common case.
    public static func ensureDir(_ path: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            return
        }
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    /// Write owner-only (0600), creating the parent directory 0700.
    ///
    /// `.atomic` writes via a temp file and renames, which drops the mode of any
    /// existing file, so the chmod has to come after the write every time — not
    /// only when the file is new.
    public static func write(_ data: Data, to path: String) throws {
        try ensureDir((path as NSString).deletingLastPathComponent)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// Tighten a file cbar appends to rather than rewrites (the log).
    public static func tighten(_ path: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// One-shot sweep at startup. Files written by an earlier version keep their
    /// 0644 until something rewrites them, and `accounts.json` is only rewritten
    /// when accounts change — so an upgrader could sit at the old mode forever,
    /// which is the exact population this is for. Rotated logs (`cbar.log.1`)
    /// have the same problem and hold the same content.
    public static func tightenAll(dir: String) {
        try? ensureDir(dir)
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            tighten("\(dir)/\(name)")
        }
    }
}
