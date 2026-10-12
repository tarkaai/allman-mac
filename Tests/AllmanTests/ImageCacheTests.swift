import XCTest
@testable import Allman

final class ImageCacheTests: XCTestCase {
    func testKeyIgnoresExpiringQuery() {
        let a = URL(string: "https://media.licdn.com/dms/image/v2/ABC/profile-displayphoto/0/1?e=1788998400&v=beta&t=tok1")!
        let b = URL(string: "https://media.licdn.com/dms/image/v2/ABC/profile-displayphoto/0/1?e=1799999999&v=beta&t=tok2")!
        let c = URL(string: "https://media.licdn.com/dms/image/v2/XYZ/profile-displayphoto/0/1?e=1788998400")!
        XCTAssertEqual(ImageCache.key(for: a), ImageCache.key(for: b))
        XCTAssertNotEqual(ImageCache.key(for: a), ImageCache.key(for: c))
        XCTAssertEqual(ImageCache.key(for: a).count, 32)
    }

    @MainActor
    func testDiskHitServesWithoutNetworkAndLocalDecodesOnce() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("imgcache-\(UUID().uuidString)")
        let cache = ImageCache(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A 1×1 PNG placed where the cache would have written it; the URL itself is unreachable.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
        let url = URL(string: "https://invalid.invalid/pic.png?t=1")!
        try png.write(to: cache.fileURL(for: url))
        let exp = expectation(description: "image")
        Task { @MainActor in
            let img = await cache.image(for: url)
            XCTAssertNotNil(img)
            XCTAssertEqual(cache.diskUsage().count, 1)
            let local = dir.appendingPathComponent("local.png")
            try? png.write(to: local)
            XCTAssertNotNil(cache.local(local))
            let viaImage = await cache.image(for: local)
            XCTAssertNotNil(viaImage)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
    }
}
