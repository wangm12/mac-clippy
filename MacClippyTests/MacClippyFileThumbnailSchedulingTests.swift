import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import MacClippy

private final class MacClippyFileThumbnailProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var activeWorkers = 0
    private var maximumActiveWorkers = 0

    func started() -> Int {
        lock.lock()
        starts += 1
        activeWorkers += 1
        maximumActiveWorkers = max(maximumActiveWorkers, activeWorkers)
        let result = starts
        lock.unlock()
        return result
    }

    func finished() {
        lock.lock()
        activeWorkers -= 1
        lock.unlock()
    }

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return starts
    }

    var maximumActiveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximumActiveWorkers
    }
}

private final class MacClippyFileThumbnailResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedImage: CGImage?

    func set(_ image: CGImage?) {
        lock.lock()
        storedImage = image
        lock.unlock()
    }

    var image: CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return storedImage
    }
}

private final class MacClippyFileThumbnailCallbackProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callbackWasMainThread: Bool?

    func recordCallbackThread() {
        lock.lock()
        callbackWasMainThread = Thread.isMainThread
        lock.unlock()
    }

    var callbackWasOnMainThread: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return callbackWasMainThread
    }
}

final class MacClippyFileThumbnailSchedulingTests: XCTestCase {
    func testRasterRequestsHaveFinitePixelAndDecodedByteLimits() {
        let oversized = CGSize(width: CGFloat.infinity, height: 100_000)
        let normalized = MacClippyFileThumbnailRasterPolicy.normalizedPointSize(oversized)
        let pixelSize = MacClippyFileThumbnailRasterPolicy.maximumPixelSize(
            for: normalized,
            scale: 2
        )

        XCTAssertTrue(normalized.width.isFinite)
        XCTAssertTrue(normalized.height.isFinite)
        XCTAssertLessThanOrEqual(max(normalized.width, normalized.height), 1_536)
        XCTAssertGreaterThanOrEqual(pixelSize, 1)
        XCTAssertLessThanOrEqual(pixelSize, MacClippyFileThumbnailRasterPolicy.maximumPixelDimension)
        let decodedBytes: Int = pixelSize * pixelSize * 4
        XCTAssertLessThanOrEqual(decodedBytes, MacClippyFileThumbnailRasterPolicy.maximumDecodedBytes)
        XCTAssertNoThrow(
            MacClippyFileThumbnailLoader.cacheKey(
                url: URL(fileURLWithPath: "/tmp/example.jpg"),
                pointSize: CGSize(width: CGFloat.nan, height: CGFloat.infinity)
            )
        )
    }

    @MainActor
    func testBackgroundCompletionDoesNotQueueBehindBlockedMainThread() {
        XCTAssertTrue(Thread.isMainThread)
        let completed = DispatchSemaphore(value: 0)
        let probe = MacClippyFileThumbnailCallbackProbe()
        let service = makeService { _, _, _ in nil }

        DispatchQueue.global(qos: .utility).async {
            let waiter = service.load(
                for: Self.url("callback.jpg"),
                pointSize: Self.pointSize
            ) { _ in
                probe.recordCallbackThread()
                completed.signal()
            }
            withExtendedLifetime(waiter) {}
        }

        XCTAssertEqual(
            completed.wait(timeout: .now() + 2),
            .success,
            "thumbnail completion must not wait for the main queue to unblock"
        )
        XCTAssertEqual(probe.callbackWasOnMainThread, false)
    }

    func testCancelReturnsPromptlyAndKeepsSlot() {
        let probe = MacClippyFileThumbnailProbe()
        let firstStarted = expectation(description: "first decode started")
        let secondStarted = expectation(description: "queued decode starts after cancelled decode returns")
        let secondCompleted = expectation(description: "queued decode completed")
        let firstGate = DispatchSemaphore(value: 0)
        let firstWaiterReturned = expectation(description: "cancelled waiter returned before decode")
        let result = MacClippyFileThumbnailResult()
        let service = makeService(maximumConcurrentWorkers: 1) { _, _, isCancelled in
            let startNumber = probe.started()
            if startNumber == 1 {
                firstStarted.fulfill()
                firstGate.wait()
                probe.finished()
                XCTAssertTrue(isCancelled())
                return Self.pngImage()
            }
            secondStarted.fulfill()
            probe.finished()
            return isCancelled() ? nil : Self.pngImage()
        }

        let blockedURL = Self.url("blocked.jpg")
        let blockedSize = Self.pointSize
        let task = Task.detached(priority: .utility) {
            let image = await service.image(for: blockedURL, pointSize: blockedSize)
            result.set(image)
            firstWaiterReturned.fulfill()
        }
        wait(for: [firstStarted], timeout: 2)
        task.cancel()
        wait(for: [firstWaiterReturned], timeout: 1)
        XCTAssertNil(result.image, "cancellation should resume the requesting task immediately")

        let queuedWaiter = service.load(for: Self.url("queued.jpg"), pointSize: Self.pointSize) { image in
            XCTAssertNotNil(image)
            secondCompleted.fulfill()
        }
        XCTAssertEqual(probe.startCount, 1, "a cancelled native decode still occupies its worker slot")
        firstGate.signal()
        wait(for: [secondStarted, secondCompleted], timeout: 2)
        XCTAssertNil(service.cachedImage(forKey: MacClippyFileThumbnailLoader.cacheKey(
            url: Self.url("blocked.jpg"),
            pointSize: Self.pointSize
        )))
        XCTAssertNotNil(service.cachedImage(forKey: MacClippyFileThumbnailLoader.cacheKey(
            url: Self.url("queued.jpg"),
            pointSize: Self.pointSize
        )))
        XCTAssertEqual(probe.maximumActiveCount, 1)
        queuedWaiter.release()
    }

    func testCancelledPendingWaiterIsRemoved() {
        let probe = MacClippyFileThumbnailProbe()
        let firstStarted = expectation(description: "first decode started")
        let thirdStarted = expectation(description: "remaining pending decode starts")
        let thirdCompleted = expectation(description: "remaining pending decode completed")
        let firstGate = DispatchSemaphore(value: 0)
        let service = makeService(maximumConcurrentWorkers: 1) { url, _, isCancelled in
            _ = probe.started()
            if url.lastPathComponent == "first.jpg" {
                firstStarted.fulfill()
                firstGate.wait()
            } else if url.lastPathComponent == "third.jpg" {
                thirdStarted.fulfill()
            }
            probe.finished()
            return isCancelled() ? nil : Self.pngImage()
        }

        let firstWaiter = service.load(for: Self.url("first.jpg"), pointSize: Self.pointSize) { _ in }
        wait(for: [firstStarted], timeout: 2)
        let cancelledPendingWaiter = service.load(for: Self.url("cancelled.jpg"), pointSize: Self.pointSize) { _ in
            XCTFail("a cancelled pending waiter must not receive a result")
        }
        let thirdWaiter = service.load(for: Self.url("third.jpg"), pointSize: Self.pointSize) { image in
            XCTAssertNotNil(image)
            thirdCompleted.fulfill()
        }
        cancelledPendingWaiter.release()
        firstGate.signal()
        wait(for: [thirdStarted, thirdCompleted], timeout: 2)

        XCTAssertEqual(probe.startCount, 2)
        XCTAssertEqual(probe.maximumActiveCount, 1)
        firstWaiter.release()
        thirdWaiter.release()
    }

    func testResetFencesLateDecodeAndReopens() {
        let probe = MacClippyFileThumbnailProbe()
        let oldStarted = expectation(description: "old session decode started")
        let newStarted = expectation(description: "new session decode starts after old decode returns")
        let reopenedCompleted = expectation(description: "reopened session thumbnail completed")
        let oldGate = DispatchSemaphore(value: 0)
        let newGate = DispatchSemaphore(value: 0)
        let oldResult = MacClippyFileThumbnailResult()
        let newResult = MacClippyFileThumbnailResult()
        let url = Self.url("same-identity.jpg")
        let key = MacClippyFileThumbnailLoader.cacheKey(url: url, pointSize: Self.pointSize)
        let oldWaiterReturned = expectation(description: "reset resumes old session waiter")
        let service = makeService(maximumConcurrentWorkers: 1) { _, _, _ in
            let startNumber = probe.started()
            if startNumber == 1 {
                oldStarted.fulfill()
                oldGate.wait()
            } else {
                newStarted.fulfill()
                newGate.wait()
            }
            probe.finished()
            return Self.pngImage()
        }

        let oldSize = Self.pointSize
        let oldTask = Task.detached(priority: .utility) {
            let image = await service.image(for: url, pointSize: oldSize)
            oldResult.set(image)
            oldWaiterReturned.fulfill()
        }
        wait(for: [oldStarted], timeout: 2)
        service.resetForSessionEnd()
        wait(for: [oldWaiterReturned], timeout: 1)
        XCTAssertNil(oldResult.image)
        XCTAssertNil(service.cachedImage(forKey: key))

        let reopenedWaiter = service.load(for: url, pointSize: Self.pointSize) { image in
            newResult.set(image)
            reopenedCompleted.fulfill()
        }
        oldGate.signal()
        wait(for: [newStarted], timeout: 2)
        XCTAssertNil(service.cachedImage(forKey: key), "the old session decode must not repopulate the cache")
        newGate.signal()
        wait(for: [reopenedCompleted], timeout: 2)

        XCTAssertNotNil(newResult.image)
        XCTAssertNotNil(service.cachedImage(forKey: key))
        XCTAssertEqual(probe.startCount, 2)
        reopenedWaiter.release()
        oldTask.cancel()
    }

    func testNonRasterUsesWorkspaceIconRenderer() {
        let iconRendered = expectation(description: "workspace icon rendered")
        let completed = expectation(description: "file icon thumbnail completed")
        let service = makeService(
            imageIODecoder: { _, _, _ in
                XCTFail("non-raster files should use the workspace icon renderer")
                return nil
            },
            workspaceIconRenderer: { _, _, isCancelled in
                XCTAssertTrue(Thread.isMainThread)
                iconRendered.fulfill()
                return isCancelled() ? nil : Self.pngImage()
            }
        )

        let result = MacClippyFileThumbnailResult()
        let waiter = service.load(for: Self.url("document.pdf"), pointSize: Self.pointSize) { image in
            result.set(image)
            completed.fulfill()
        }
        wait(for: [iconRendered, completed], timeout: 2)

        XCTAssertNotNil(result.image)
        waiter.release()
    }

    private func makeService(
        maximumConcurrentWorkers: Int = 2,
        imageIODecoder: @escaping MacClippyFileThumbnailService.ImageIODecoder,
        workspaceIconRenderer: @escaping MacClippyFileThumbnailService.WorkspaceIconRenderer = { _, _, _ in nil }
    ) -> MacClippyFileThumbnailService {
        MacClippyFileThumbnailService(
            maximumConcurrentWorkers: maximumConcurrentWorkers,
            maximumPendingFlights: 8,
            imageIODecoder: imageIODecoder,
            workspaceIconRenderer: workspaceIconRenderer
        )
    }

    private func makeWaiter(
        for url: URL,
        service: MacClippyFileThumbnailService,
        completed: XCTestExpectation
    ) -> MacClippyFileThumbnailWaiter {
        service.load(for: url, pointSize: Self.pointSize) { image in
            XCTAssertNotNil(image)
            completed.fulfill()
        }
    }

    private static let pointSize = CGSize(width: 64, height: 64)

    private static func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    private static func pngImage() -> CGImage {
        let png = Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8A"
                + "AwMCAO+ip1sAAAAASUVORK5CYII="
        )!
        let source = CGImageSourceCreateWithData(png as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }
}

extension MacClippyFileThumbnailSchedulingTests {
    func testCoalescesAndCapsWorkers() {
        let probe = MacClippyFileThumbnailProbe()
        let twoWorkersStarted = expectation(description: "two thumbnail workers started")
        twoWorkersStarted.expectedFulfillmentCount = 2
        let thirdWorkerStarted = expectation(description: "third identity starts after a slot opens")
        let workerGate = DispatchSemaphore(value: 0)
        let allWaitersCompleted = expectation(description: "coalesced and queued waiters completed")
        allWaitersCompleted.expectedFulfillmentCount = 4
        let service = makeService { url, _, isCancelled in
            let startNumber = probe.started()
            if startNumber <= 2 {
                twoWorkersStarted.fulfill()
            } else if url.lastPathComponent == "third.jpg" {
                thirdWorkerStarted.fulfill()
            }
            workerGate.wait()
            probe.finished()
            return isCancelled() ? nil : Self.pngImage()
        }

        let firstURL = Self.url("first.jpg")
        let secondURL = Self.url("second.jpg")
        let thirdURL = Self.url("third.jpg")
        var waiters = [
            makeWaiter(for: firstURL, service: service, completed: allWaitersCompleted),
            makeWaiter(for: firstURL, service: service, completed: allWaitersCompleted),
            makeWaiter(for: secondURL, service: service, completed: allWaitersCompleted),
            makeWaiter(for: thirdURL, service: service, completed: allWaitersCompleted)
        ]

        wait(for: [twoWorkersStarted], timeout: 2)
        let thirdDidNotStartEarly = expectation(description: "third identity stays queued")
        thirdDidNotStartEarly.isInverted = true
        wait(for: [thirdDidNotStartEarly], timeout: 0.1)
        XCTAssertEqual(probe.startCount, 2)

        workerGate.signal()
        wait(for: [thirdWorkerStarted], timeout: 2)
        workerGate.signal()
        workerGate.signal()
        wait(for: [allWaitersCompleted], timeout: 2)

        XCTAssertEqual(probe.startCount, 3, "identical requests should share one decode")
        XCTAssertEqual(probe.maximumActiveCount, 2, "the scheduler must keep worker concurrency at two")
        waiters.removeAll()
    }
}
