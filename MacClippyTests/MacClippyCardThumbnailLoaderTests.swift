import AppKit
import CryptoKit
import ImageIO
import XCTest

@testable import MacClippy
import MacClippyCore

private final class MacClippyLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class MacClippyCardThumbnailLoaderTests: XCTestCase {
    func testLastWaiterCancelsInFlightWorkAndSkipsCache() throws {
        let id = RecordID.generate()
        let started = expectation(description: "thumbnail work started")
        let gate = DispatchSemaphore(value: 0)
        let finished = expectation(description: "thumbnail work finished")
        let loader = makeLoader { _, _, isCancelled in
            started.fulfill()
            gate.wait()
            XCTAssertTrue(isCancelled())
            return isCancelled() ? nil : Self.pngImage()
        }
        loader.onFinish = { _ in finished.fulfill() }

        let first = loader.load(id: id, maxPixelSize: 32) { _ in
            XCTFail("cancelled waiters must not receive a thumbnail")
        }
        let second = loader.load(id: id, maxPixelSize: 32) { _ in
            XCTFail("cancelled waiters must not receive a thumbnail")
        }

        wait(for: [started], timeout: 2)
        first.release()
        XCTAssertNil(loader.cachedImage(id: id, maxPixelSize: 32))
        second.release()
        gate.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertNil(loader.cachedImage(id: id, maxPixelSize: 32))
    }

    func testDecodedThumbnailIsCachedAfterLastWaiterLeaves() throws {
        let id = RecordID.generate()
        let decoded = expectation(description: "thumbnail decoded")
        let continueAfterCancel = DispatchSemaphore(value: 0)
        let finished = expectation(description: "thumbnail work finished")
        let loader = makeLoader { _, _, _ in
            Self.pngImage()
        }
        loader.afterDecode = {
            decoded.fulfill()
            continueAfterCancel.wait()
        }
        loader.onFinish = { image in
            XCTAssertNotNil(image)
            finished.fulfill()
        }

        let waiter = loader.load(id: id, maxPixelSize: 32) { _ in
            XCTFail("cancelled waiters must not receive a thumbnail")
        }
        wait(for: [decoded], timeout: 2)
        waiter.release()
        continueAfterCancel.signal()
        wait(for: [finished], timeout: 2)
        XCTAssertNotNil(loader.cachedImage(id: id, maxPixelSize: 32))
    }

    func testNewWaiterDoesNotJoinCancelledExecutingFlight() throws {
        let id = RecordID.generate()
        let firstStarted = expectation(description: "first thumbnail work started")
        let secondStarted = expectation(description: "second thumbnail work started")
        let secondDone = expectation(description: "second waiter receives thumbnail")
        let releaseFirstDecode = DispatchSemaphore(value: 0)
        let releaseSecondDecode = DispatchSemaphore(value: 0)
        let loadCount = MacClippyLockedCounter()
        let loader = makeLoader { _, _, isCancelled in
            loadCount.increment()
            if loadCount.value == 1 {
                firstStarted.fulfill()
                releaseFirstDecode.wait()
                XCTAssertTrue(isCancelled())
                return nil
            }
            secondStarted.fulfill()
            releaseSecondDecode.wait()
            XCTAssertFalse(isCancelled())
            return Self.pngImage()
        }

        let first = loader.load(id: id, maxPixelSize: 32) { _ in
            XCTFail("cancelled waiter must not receive a thumbnail")
        }
        wait(for: [firstStarted], timeout: 2)
        first.release()

        _ = loader.load(id: id, maxPixelSize: 32) { image in
            XCTAssertNotNil(image)
            secondDone.fulfill()
        }
        releaseFirstDecode.signal()
        wait(for: [secondStarted], timeout: 2)
        releaseSecondDecode.signal()
        wait(for: [secondDone], timeout: 2)
        XCTAssertEqual(loadCount.value, 2)
        XCTAssertNotNil(loader.cachedImage(id: id, maxPixelSize: 32))
    }

    func testSecondWaiterReusesInFlightLoad() throws {
        let id = RecordID.generate()
        let started = expectation(description: "thumbnail work started")
        started.expectedFulfillmentCount = 1
        let gate = DispatchSemaphore(value: 0)
        let firstDone = expectation(description: "first waiter")
        let secondDone = expectation(description: "second waiter")
        let loadCount = MacClippyLockedCounter()
        let loader = makeLoader { _, _, _ in
            loadCount.increment()
            started.fulfill()
            gate.wait()
            return Self.pngImage()
        }

        _ = loader.load(id: id, maxPixelSize: 32) { image in
            XCTAssertNotNil(image)
            firstDone.fulfill()
        }
        _ = loader.load(id: id, maxPixelSize: 32) { image in
            XCTAssertNotNil(image)
            secondDone.fulfill()
        }

        wait(for: [started], timeout: 2)
        gate.signal()
        wait(for: [firstDone, secondDone], timeout: 2)
        XCTAssertEqual(loadCount.value, 1)
        XCTAssertNotNil(loader.cachedImage(id: id, maxPixelSize: 32))
    }

    func testDiskCacheAvoidsRedecodingAfterSessionEnd() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacClippyThumbLoader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let diskCache = MacClippyThumbnailDiskCache(
            directoryURL: directory,
            key: SymmetricKey(data: Data(repeating: 3, count: 32))
        )
        let id = RecordID.generate()
        let loadCount = MacClippyLockedCounter()
        let firstDone = expectation(description: "first decode")
        let secondDone = expectation(description: "disk hit")
        let loader = makeLoader(diskCache: diskCache) { _, _, _ in
            loadCount.increment()
            return Self.pngImage()
        }

        _ = loader.load(id: id, maxPixelSize: 480) { image in
            XCTAssertNotNil(image)
            firstDone.fulfill()
        }
        wait(for: [firstDone], timeout: 2)
        XCTAssertEqual(loadCount.value, 1)

        loader.resetForSessionEnd()
        XCTAssertNil(loader.cachedImage(id: id, maxPixelSize: 480))

        _ = loader.load(id: id, maxPixelSize: 480) { image in
            XCTAssertNotNil(image)
            secondDone.fulfill()
        }
        wait(for: [secondDone], timeout: 2)
        XCTAssertEqual(loadCount.value, 1, "reopening the dock must reuse the persisted 480px thumb")
        XCTAssertNotNil(loader.cachedImage(id: id, maxPixelSize: 480))
    }

    func testResetForSessionEndResumesWaitersForCancelledFlights() throws {
        let id = RecordID.generate()
        let started = expectation(description: "thumbnail work started")
        let waiterDone = expectation(description: "session-end waiter resumed")
        let gate = DispatchSemaphore(value: 0)
        let loader = makeLoader { _, _, isCancelled in
            started.fulfill()
            gate.wait()
            return isCancelled() ? nil : Self.pngImage()
        }

        _ = loader.load(id: id, maxPixelSize: 32) { image in
            XCTAssertNil(image)
            waiterDone.fulfill()
        }
        wait(for: [started], timeout: 2)
        loader.resetForSessionEnd()
        wait(for: [waiterDone], timeout: 2)
        gate.signal()
        XCTAssertNil(loader.cachedImage(id: id, maxPixelSize: 32))
    }

    func testResetForSessionEndClearsCachedThumbnails() throws {
        let id = RecordID.generate()
        let finished = expectation(description: "thumbnail cached")
        let loader = makeLoader { _, _, _ in Self.pngImage() }
        _ = loader.load(id: id, maxPixelSize: 32) { image in
            XCTAssertNotNil(image)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        XCTAssertNotNil(loader.cachedImage(id: id, maxPixelSize: 32))

        loader.resetForSessionEnd()

        XCTAssertNil(loader.cachedImage(id: id, maxPixelSize: 32))
    }

    private func makeLoader(
        diskCache: MacClippyThumbnailDiskCache? = nil,
        loadImage: @escaping MacClippyCardThumbnailLoader.LoadImage
    ) -> MacClippyCardThumbnailLoader {
        let queue = OperationQueue()
        queue.name = "MacClippyCardThumbnailLoaderTests"
        queue.maxConcurrentOperationCount = 1
        return MacClippyCardThumbnailLoader(
            cache: NSCache<NSString, MacClippyCardThumbnailLoader.CacheEntry>(),
            queue: queue,
            loadImage: loadImage,
            diskCache: diskCache
        )
    }

    private static func pngImage() -> CGImage {
        let png = Data(
            base64Encoded: """
            iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=
            """
        )!
        let source = CGImageSourceCreateWithData(png as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }
}
