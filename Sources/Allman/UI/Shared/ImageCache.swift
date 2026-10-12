// Images from LinkedIn's CDN (avatars, link previews) cached twice: decoded
// NSImages in memory for scrolling, and bytes on disk under
// ~/Library/Caches/Allman/images so relaunches don't refetch. CDN URLs carry
// an expiring token in the query, so the disk key is the path without it —
// a refreshed URL for the same picture still hits. Files older than 30 days
// are refetched; local files (thread media from `allman media`) are decoded
// once and kept in memory too.

import AppKit
import CryptoKit
import Foundation

@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let memory = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    nonisolated let directory: URL
    static let maxAge: TimeInterval = 30 * 24 * 3600

    init(directory: URL? = nil) {
        memory.countLimit = 1200
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        self.directory = directory ?? base.appendingPathComponent("Allman/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    /// Stable identity for a CDN picture: host + path, never the expiring query.
    nonisolated static func key(for url: URL) -> String {
        let stable = (url.host ?? "") + url.path
        let digest = SHA256.hash(data: Data(stable.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func fileURL(for url: URL) -> URL { directory.appendingPathComponent(Self.key(for: url)) }

    /// A remote image, from memory, then disk, then the network (written to disk).
    func image(for url: URL) async -> NSImage? {
        if url.isFileURL { return local(url) }
        let key = Self.key(for: url)
        if let hit = memory.object(forKey: key as NSString) { return hit }
        if let t = inflight[key] { return await t.value }
        let file = fileURL(for: url)
        let task = Task<NSImage?, Never> {
            if let data = try? Data(contentsOf: file), Self.isFresh(file), let img = NSImage(data: data) { return img }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let img = NSImage(data: data) else {
                // Network failed: a stale file beats nothing.
                if let data = try? Data(contentsOf: file), let img = NSImage(data: data) { return img }
                return nil
            }
            try? data.write(to: file, options: .atomic)
            return img
        }
        inflight[key] = task
        let img = await task.value
        inflight[key] = nil
        if let img { memory.setObject(img, forKey: key as NSString) }
        return img
    }

    /// A file already on disk (thread media), decoded once.
    func local(_ url: URL) -> NSImage? {
        let key = "file:" + url.path
        if let hit = memory.object(forKey: key as NSString) { return hit }
        guard let img = NSImage(contentsOf: url) else { return nil }
        memory.setObject(img, forKey: key as NSString)
        return img
    }

    nonisolated static func isFresh(_ file: URL) -> Bool {
        guard let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
        return Date().timeIntervalSince(mod) < maxAge
    }

    /// Bytes on disk, for Settings.
    nonisolated func diskUsage() -> (count: Int, bytes: Int64) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return (0, 0) }
        let bytes = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        return (files.count, bytes)
    }

    func clearDisk() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
