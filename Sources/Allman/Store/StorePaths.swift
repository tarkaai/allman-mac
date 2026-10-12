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

    /// The Settings override, only when it names an existing directory (a stray
    /// keystroke in that field must not point the app at an empty store).
    static var validOverride: URL? {
        guard let custom = UserDefaults.standard.string(forKey: storeOverrideKey), !custom.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let path = (custom.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static var overrideIsInvalid: Bool {
        guard let custom = UserDefaults.standard.string(forKey: storeOverrideKey), !custom.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return validOverride == nil
    }

    static var storeURL: URL {
        if let custom = validOverride { return custom }
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
        // ALLMAN_APPSUPPORT: the harness and UI tests keep their labels/pins/read state
        // out of the real Application Support folder.
        if let env = ProcessInfo.processInfo.environment["ALLMAN_APPSUPPORT"], !env.isEmpty {
            let dir = URL(fileURLWithPath: env, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Allman", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
