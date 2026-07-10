import Foundation

/// macOS Keychain via `/usr/bin/security` — no CoreFoundation, so no manual
/// memory management (leak-free by construction). The value is base64-encoded
/// (single safe token: no quotes/newlines/spaces) and fed through interactive
/// stdin (`security -i`), so the secret never appears in argv.
public enum Keychain {
    public enum KErr: Error { case failed(Int32, String) }
    private static let bin = "/usr/bin/security"

    /// Returns nil when the item is absent (security rc 44).
    public static func get(service: String, account: String) throws -> String? {
        let (rc, out, err) = run(["find-generic-password", "-a", account, "-w", "-s", service])
        if rc == 44 { return nil }
        if rc != 0 { throw KErr.failed(rc, "get \(service): \(err)") }
        let b64 = out.hasSuffix("\n") ? String(out.dropLast()) : out
        guard let d = Data(base64Encoded: b64), let s = String(data: d, encoding: .utf8) else {
            throw KErr.failed(rc, "get \(service): value not valid base64")
        }
        return s
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
