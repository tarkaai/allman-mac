// FSEvents watcher over one account directory. Catches every write to the
// store — our own `allman listen`/`sync` subprocesses as well as the user
// running the CLI or TUI in a terminal — and reports which conversations
// changed, debounced so a sync burst becomes one reload.

import Foundation
import os

private let watchLog = Logger(subsystem: "sh.allman.mac", category: "store")

final class StoreWatcher {
    struct Change {
        var convIds: Set<String> = []
        var authChanged = false
        var structural = false // conversation dir added/removed, symlinks, etc.
        var connectionsChanged = false // connections/, invitations/, companies/ (allman connections / enrich / connect)
    }

    private let root: URL
    private let onChange: (Change) -> Void
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "sh.allman.mac.fsevents")
    private var pending = Change()
    private var debounce: DispatchWorkItem?

    init(accountDir: URL, onChange: @escaping (Change) -> Void) {
        // FSEvents reports real paths (/private/var/…); a store reached through a symlink
        // (/var/…, or a linked ~/.allman) would otherwise never match.
        self.root = accountDir.resolvingSymlinksInPath().standardizedFileURL
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<StoreWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            var list: [String] = []
            list.reserveCapacity(count)
            for i in 0..<count { if let p = array[i] as? String { list.append(p) } }
            watcher.ingest(list)
        }
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        guard let s = FSEventStreamCreate(
            nil, callback, &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4, flags
        ) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, queue)
        let started = FSEventStreamStart(s)
        watchLog.notice("watching \(self.root.path, privacy: .public) started=\(started)")
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private func ingest(_ paths: [String]) {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for raw in paths {
            // Foundation strips "/private" from /var, /tmp and /etc paths; FSEvents keeps it. Compare like with like.
            let p = raw.hasPrefix("/private/") && !rootPath.hasPrefix("/private/") ? String(raw.dropFirst("/private".count)) : raw
            guard p.hasPrefix(rootPath) else { continue }
            let rel = p.dropFirst(rootPath.count)
            let first = rel.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if first.hasPrefix("2-") {
                pending.convIds.insert(first)
            } else if first == "AUTH.json" {
                pending.authChanged = true
            } else if ["connections", "connections-salesnav", "connections-of", "invitations", "companies"].contains(first) {
                pending.connectionsChanged = true
            } else if first.isEmpty || first.hasPrefix("ACo") || !first.contains(".") {
                // account dir itself, a profile-id/slug symlink, or a new directory
                pending.structural = true
            }
        }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let change = self.pending
            self.pending = Change()
            guard !change.convIds.isEmpty || change.authChanged || change.structural || change.connectionsChanged else { return }
            watchLog.notice("store changed: \(change.convIds.count) conversation(s) structural=\(change.structural) auth=\(change.authChanged)")
            DispatchQueue.main.async { self.onChange(change) }
        }
        debounce = work
        queue.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}
