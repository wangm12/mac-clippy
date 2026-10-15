import CryptoKit
import XCTest

@testable import MacClippyCore

private final class MacClippyThumbnailDiskCacheOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var didClaim = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didClaim else { return false }
        didClaim = true
        return true
    }
}

private struct MacClippyThumbRetirementFixture {
    let root: URL
    let id: RecordID
    let oldCache: MacClippyThumbnailDiskCache
    let ioEntered: DispatchSemaphore
    let releaseIO: DispatchSemaphore
    let admissionClosed: DispatchSemaphore
    let ioFinished: DispatchSemaphore
    let retirementFinished: DispatchSemaphore
}

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

    func testStoreEvictsOldestFilesOnceTheByteLimitIsExceeded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyThumbsCap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = MacClippyThumbnailDiskCache(
            directoryURL: directory,
            key: SymmetricKey(data: Data(repeating: 3, count: 32)),
            byteLimit: 80
        )
        let first = RecordID.generate()
        let second = RecordID.generate()
        try cache.store(Data(repeating: 1, count: 40), id: first, maxPixelSize: 480)
        try cache.store(Data(repeating: 2, count: 40), id: second, maxPixelSize: 480)
        let remaining = (try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "thumb" }
        XCTAssertLessThanOrEqual(remaining.count, 2)
        XCTAssertNotNil(cache.pngData(id: second, maxPixelSize: 480))
    }

    func testRetirementWaitsForAdmittedStoreAndFencesReplacedDirectory() throws {
        try assertRetirementWaitsAndFencesReplacement(blockedOperation: .write)
    }

    func testRetirementWaitsForAdmittedRemoveAndFencesReplacedDirectory() throws {
        try assertRetirementWaitsAndFencesReplacement(blockedOperation: .remove)
    }

    private func assertRetirementWaitsAndFencesReplacement(
        blockedOperation: MacClippyThumbnailDiskCacheTestHooks.FileSystemOperation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let fixture = try makeRetirementFixture(blockedOperation: blockedOperation)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        guard startAndCheckRetirement(fixture, file: file, line: line) else { return }
        assertRetiredCacheRejectsIO(fixture, file: file, line: line)
        finishRetirement(fixture, file: file, line: line)
        let (replacementCache, restoredPNG) = try replaceRetiredDirectory(fixture)
        assertOldCacheCannotDamageReplacement(
            fixture,
            replacementCache: replacementCache,
            restoredPNG: restoredPNG,
            file: file,
            line: line
        )
    }

    private func makeRetirementFixture(
        blockedOperation: MacClippyThumbnailDiskCacheTestHooks.FileSystemOperation
    ) throws -> MacClippyThumbRetirementFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyThumbsRetire-\(UUID().uuidString)", isDirectory: true)
        let ioEntered = DispatchSemaphore(value: 0)
        let releaseIO = DispatchSemaphore(value: 0)
        let admissionClosed = DispatchSemaphore(value: 0)
        let ioFinished = DispatchSemaphore(value: 0)
        let retirementFinished = DispatchSemaphore(value: 0)
        let firstMatchingOperation = MacClippyThumbnailDiskCacheOneShot()
        let id = RecordID.generate()
        let hooks = MacClippyThumbnailDiskCacheTestHooks(
            beforeFileSystemOperation: { operation in
                guard operation == blockedOperation else { return }
                guard firstMatchingOperation.claim() else { return }
                ioEntered.signal()
                releaseIO.wait()
            },
            didCloseAdmission: { admissionClosed.signal() }
        )
        let oldCache = MacClippyThumbnailDiskCache(
            directoryURL: root,
            key: SymmetricKey(data: Data(repeating: 7, count: 32)),
            testHooks: hooks
        )
        if blockedOperation == .remove {
            try oldCache.store(Data("old image".utf8), id: id, maxPixelSize: 480)
        }
        DispatchQueue.global(qos: .utility).async {
            if blockedOperation == .write {
                try? oldCache.store(Data("in-flight old image".utf8), id: id, maxPixelSize: 480)
            } else {
                oldCache.remove(id: id, maxPixelSize: 480)
            }
            ioFinished.signal()
        }
        return MacClippyThumbRetirementFixture(
            root: root,
            id: id,
            oldCache: oldCache,
            ioEntered: ioEntered,
            releaseIO: releaseIO,
            admissionClosed: admissionClosed,
            ioFinished: ioFinished,
            retirementFinished: retirementFinished
        )
    }

    private func startAndCheckRetirement(
        _ fixture: MacClippyThumbRetirementFixture,
        file: StaticString,
        line: UInt
    ) -> Bool {
        let operationStarted = fixture.ioEntered.wait(timeout: .now() + .seconds(2))
        XCTAssertEqual(operationStarted, .success, file: file, line: line)
        guard operationStarted == .success else {
            fixture.releaseIO.signal()
            _ = fixture.ioFinished.wait(timeout: .now() + .seconds(2))
            return false
        }
        DispatchQueue.global(qos: .utility).async {
            fixture.oldCache.retireForRestore()
            // A second call verifies retirement is idempotent.
            fixture.oldCache.retireForRestore()
            fixture.retirementFinished.signal()
        }
        let admissionCloseResult = fixture.admissionClosed.wait(timeout: .now() + .seconds(2))
        XCTAssertEqual(admissionCloseResult, .success, file: file, line: line)
        guard admissionCloseResult == .success else {
            fixture.releaseIO.signal()
            _ = fixture.ioFinished.wait(timeout: .now() + .seconds(2))
            _ = fixture.retirementFinished.wait(timeout: .now() + .seconds(2))
            return false
        }
        XCTAssertEqual(
            fixture.retirementFinished.wait(timeout: .now() + .milliseconds(50)),
            .timedOut,
            "Retirement returned while an admitted filesystem operation was paused",
            file: file,
            line: line
        )
        return true
    }

    private func assertRetiredCacheRejectsIO(
        _ fixture: MacClippyThumbRetirementFixture,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertThrowsError(
            try fixture.oldCache.store(Data("denied".utf8), id: fixture.id, maxPixelSize: 480),
            file: file,
            line: line
        ) {
            XCTAssertEqual($0 as? MacClippyThumbnailDiskCacheError, .retired, file: file, line: line)
        }
        fixture.oldCache.remove(id: fixture.id, maxPixelSize: 480)
        XCTAssertNil(fixture.oldCache.pngData(id: fixture.id, maxPixelSize: 480), file: file, line: line)
    }

    private func finishRetirement(
        _ fixture: MacClippyThumbRetirementFixture,
        file: StaticString,
        line: UInt
    ) {
        fixture.releaseIO.signal()
        XCTAssertEqual(fixture.ioFinished.wait(timeout: .now() + .seconds(2)), .success, file: file, line: line)
        XCTAssertEqual(
            fixture.retirementFinished.wait(timeout: .now() + .seconds(2)),
            .success,
            file: file,
            line: line
        )
    }

    private func replaceRetiredDirectory(
        _ fixture: MacClippyThumbRetirementFixture
    ) throws -> (MacClippyThumbnailDiskCache, Data) {
        // Simulate restore replacing the directory after retirement drained.
        try FileManager.default.removeItem(at: fixture.root)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let replacementCache = MacClippyThumbnailDiskCache(
            directoryURL: fixture.root,
            key: SymmetricKey(data: Data(repeating: 7, count: 32))
        )
        let restoredPNG = Data("restored image".utf8)
        try replacementCache.store(restoredPNG, id: fixture.id, maxPixelSize: 480)
        return (replacementCache, restoredPNG)
    }

    private func assertOldCacheCannotDamageReplacement(
        _ fixture: MacClippyThumbRetirementFixture,
        replacementCache: MacClippyThumbnailDiskCache,
        restoredPNG: Data,
        file: StaticString,
        line: UInt
    ) {
        XCTAssertThrowsError(
            try fixture.oldCache.store(Data("late old image".utf8), id: fixture.id, maxPixelSize: 480),
            file: file,
            line: line
        ) {
            XCTAssertEqual($0 as? MacClippyThumbnailDiskCacheError, .retired, file: file, line: line)
        }
        fixture.oldCache.remove(id: fixture.id, maxPixelSize: 480)
        XCTAssertNil(fixture.oldCache.pngData(id: fixture.id, maxPixelSize: 480), file: file, line: line)
        XCTAssertEqual(
            replacementCache.pngData(id: fixture.id, maxPixelSize: 480),
            restoredPNG,
            file: file,
            line: line
        )
    }
}
