import Foundation

/// Reliable file log at `~/.cbar/cbar.log` — NSLog from a hand-assembled .app
/// does not reliably reach the unified log, so auto-switch decisions etc. are
/// written here where they can actually be read (`tail -f ~/.cbar/cbar.log`).
public enum CbarLog {
    static var path: String { "\(NSHomeDirectory())/.cbar/cbar.log" }
    private static let cap = 262_144   // 256 KB; reset past this

    public static func write(_ msg: String) {
        let f = ISO8601DateFormatter()
        let line = "\(f.string(from: Date())) \(msg)\n"
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: path)
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > cap {
            // Rotate, don't truncate — truncation destroyed the evidence of the
            // 2026-07-10 retry storm mid-incident.
            try? FileManager.default.removeItem(atPath: path + ".1")
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
            try? Data(line.utf8).write(to: url)
            return
        }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
