import CryptoKit
import XCTest

@testable import MacClippyCore

final class MacClippyThumbnailDiskCacheTests: XCTestCase {
    func testStoreThenReadReturnsTheSamePNGBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyThumbs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = MacClippyThumbnailDiskCache(
            directoryURL: directory,
            key: SymmetricKey(data: Data(repeating: 3, count: 32))
        )
        let id = RecordID.generate()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        XCTAssertNil(cache.pngData(id: id, maxPixelSize: 480))
        try cache.store(png, id: id, maxPixelSize: 480)
        XCTAssertEqual(cache.pngData(id: id, maxPixelSize: 480), png)
        XCTAssertNil(cache.pngData(id: id, maxPixelSize: 32))
    }

    func testRemoveDeletesThePersistedThumbnail() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyThumbs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = MacClippyThumbnailDiskCache(
            directoryURL: directory,
            key: SymmetricKey(data: Data(repeating: 3, count: 32))
        )
        let id = RecordID.generate()
        try cache.store(Data("png".utf8), id: id, maxPixelSize: 480)
        cache.remove(id: id, maxPixelSize: 480)
        XCTAssertNil(cache.pngData(id: id, maxPixelSize: 480))
    }
}
