// Where the store lives. Always $HOME/.allman unless ALLMAN_STORE (or the
// user's setting) overrides it — never the CLI's cwd-relative default, which
// would scatter data across whatever directory the app happened to launch from.

import Foundation

enum StorePaths {
    static let storeOverrideKey = "storePathOverride"
    static let accountOverrideKey = "accountSlugOverride"

    static var defaultStoreURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".allman", isDirectory: true)
    }

    static var storeURL: URL {
        if let custom = UserDefaults.standard.string(forKey: storeOverrideKey), !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let env = ProcessInfo.processInfo.environment["ALLMAN_STORE"], !env.isEmpty {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return defaultStoreURL
    }

    static var preferredAccountSlug: String? {
        if let s = UserDefaults.standard.string(forKey: accountOverrideKey), !s.isEmpty { return s }
        if let env = ProcessInfo.processInfo.environment["ALLMAN_ACCOUNT"], !env.isEmpty { return env }
        return nil
    }

    /// App-owned state (read watermarks, notified URNs). Kept out of the store so
    /// the CLI's git history never sees app-specific files.
    static var appSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Allman", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
