// Locating the `allman` CLI. GUI apps inherit a tiny PATH, so we probe the
// usual install locations explicitly. Order: user override → ALLMAN_BIN →
// the copy embedded in this app bundle → ~/.local/bin → common prefixes → PATH.

import Foundation

enum AllmanBinary {
    static let overrideKey = "allmanBinaryOverride"

    static func resolve() -> URL? {
        for candidate in candidates() where isExecutable(candidate) { return candidate }
        return nil
    }

    static func candidates() -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: overrideKey), !custom.isEmpty {
            out.append(URL(fileURLWithPath: (custom as NSString).expandingTildeInPath))
        }
        if let env = ProcessInfo.processInfo.environment["ALLMAN_BIN"], !env.isEmpty {
            out.append(URL(fileURLWithPath: env))
        }
        if let embedded = Bundle.main.resourceURL?.appendingPathComponent("allman") {
            out.append(embedded)
        }
        let home = fm.homeDirectoryForCurrentUser
        out.append(home.appendingPathComponent(".local/bin/allman"))
        out.append(URL(fileURLWithPath: "/opt/homebrew/bin/allman"))
        out.append(URL(fileURLWithPath: "/usr/local/bin/allman"))
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            out.append(URL(fileURLWithPath: String(dir)).appendingPathComponent("allman"))
        }
        return out
    }

    static func isExecutable(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    static var isEmbedded: Bool {
        guard let r = resolve(), let res = Bundle.main.resourceURL else { return false }
        return r.standardizedFileURL.path.hasPrefix(res.standardizedFileURL.path)
    }
}
