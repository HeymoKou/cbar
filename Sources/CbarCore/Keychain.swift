import Foundation

/// macOS Keychain via `/usr/bin/security` — no CoreFoundation, so no manual
/// memory management (leak-free by construction). The value is base64-encoded
/// (single safe token: no quotes/newlines/spaces) and fed through interactive
/// stdin (`security -i`), so the secret never appears in argv.
public enum Keychain {
    public enum KErr: Error { case failed(Int32, String) }
    private static let bin = "/usr/bin/security"

    /// Returns nil when the item is absent (security rc 44). Values are
    /// base64-decoded when possible (cbar's own writes); anything else is
    /// returned verbatim — Claude Code stores its credentials as plain JSON,
    /// and rejecting that silently killed every live-credentials read.
    public static func get(service: String, account: String) throws -> String? {
        let (rc, out, err) = run(["find-generic-password", "-a", account, "-w", "-s", service])
        if rc == 44 { return nil }
        if rc != 0 { throw KErr.failed(rc, "get \(service): \(err)") }
        let raw = out.hasSuffix("\n") ? String(out.dropLast()) : out
        if let d = Data(base64Encoded: raw), let s = String(data: d, encoding: .utf8) { return s }
        return raw
    }

    /// Read a value WITHOUT base64-decoding — for foreign items (e.g. cswap's
    /// backup keychain) that store the raw string.
    public static func getRaw(service: String, account: String) throws -> String? {
        let (rc, out, err) = run(["find-generic-password", "-a", account, "-w", "-s", service])
        if rc == 44 { return nil }
        if rc != 0 { throw KErr.failed(rc, "getRaw \(service): \(err)") }
        return out.hasSuffix("\n") ? String(out.dropLast()) : out
    }

    public static func set(service: String, account: String, value: String) throws {
        let b64 = Data(value.utf8).base64EncodedString()   // no line wrapping
        let cmd = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -w \(b64)\n"
        let (rc, _, err) = run(["-i"], stdin: cmd)
        if rc != 0 { throw KErr.failed(rc, "set \(service): \(err)") }
    }

    /// Write a value VERBATIM (no base64) — for the live Claude Code item,
    /// which CC itself stores as plain JSON and must be able to parse back.
    /// Still stdin-fed (`security -i`), with quotes/backslashes escaped.
    /// `security -i` is LINE-based: a newline in the value would split into
    /// garbage commands after the first line has already OVERWRITTEN the item
    /// (destroyed the live login on 2026-07-10) — refuse before touching it.
    public static func setRaw(service: String, account: String, value: String) throws {
        guard !value.contains("\n"), !value.contains("\r") else {
            throw KErr.failed(-2, "setRaw \(service): value contains newline (would corrupt item via security -i)")
        }
        let esc = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let cmd = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -w \"\(esc)\"\n"
        let (rc, _, err) = run(["-i"], stdin: cmd)
        if rc != 0 { throw KErr.failed(rc, "setRaw \(service): \(err)") }
    }

    public static func delete(service: String, account: String) throws {
        let (rc, _, err) = run(["delete-generic-password", "-a", account, "-s", service])
        if rc != 0 && rc != 44 { throw KErr.failed(rc, "delete \(service): \(err)") }
    }

    private static func run(_ args: [String], stdin: String? = nil) -> (Int32, String, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        let o = Pipe(); let e = Pipe(); let i = Pipe()
        p.standardOutput = o; p.standardError = e
        if stdin != nil { p.standardInput = i }
        do { try p.run() } catch { return (-1, "", "\(error)") }
        if let s = stdin {
            i.fileHandleForWriting.write(Data(s.utf8))
            i.fileHandleForWriting.closeFile()
        }
        let out = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (p.terminationStatus, out, err)
    }
}
