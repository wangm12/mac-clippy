import AppKit
import ImageIO
import XCTest

@testable import MacClippy
import MacClippyCore

final class MacClippyCardThumbnailStaleWaiterTests: XCTestCase {
    func testOldWaiterReleaseCannotCancelNewSameKeyFlightAfterReset() throws {
        let oldStarted = expectation(description: "old session work started")
        let newStarted = expectation(description: "new session work started")
        let oldWaiterResumed = expectation(description: "reset resumed the old waiter")
        let newWaiterFinished = expectation(description: "new session waiter finished")
        let scenario = CardThumbnailWaiterScenario(
            oldStarted: oldStarted,
            newStarted: newStarted,
            oldWaiterResumed: oldWaiterResumed,
            newWaiterFinished: newWaiterFinished
        )

        scenario.startOldWaiter()
        wait(for: [oldStarted], timeout: 2)
        scenario.resetSession()
        wait(for: [oldWaiterResumed], timeout: 2)
        XCTAssertFalse(scenario.oldWaiterReceivedImage)
        XCTAssertNil(scenario.cachedImage)

        scenario.startNewWaiter()
        wait(for: [newStarted], timeout: 2)
        XCTAssertTrue(scenario.releaseOldFlightAndWaitForFinish())
        XCTAssertNil(scenario.cachedImage, "the retired flight must not cache its late image")

        scenario.releaseNewFlight()
        wait(for: [newWaiterFinished], timeout: 2)
        XCTAssertFalse(scenario.newFlightWasCancelled)
        XCTAssertTrue(scenario.newWaiterReceivedImage)
        XCTAssertEqual(scenario.loadCount, 2)
        XCTAssertNotNil(scenario.cachedImage)
    }
}

private final class CardThumbnailWaiterScenario: @unchecked Sendable {
    private let id = RecordID.generate()
    private let oldStarted: XCTestExpectation
    private let newStarted: XCTestExpectation
    private let oldWaiterResumed: XCTestExpectation
    private let newWaiterFinished: XCTestExpectation
    private let oldDecodeGate = DispatchSemaphore(value: 0)
    private let newDecodeGate = DispatchSemaphore(value: 0)
    private let oldDecodeReturned = DispatchSemaphore(value: 0)
    private let state = MacClippyCardThumbnailStaleWaiterState()
    private let queue = OperationQueue()
    private var oldWaiter: MacClippyCardThumbnailWaiter?
    private var loader: MacClippyCardThumbnailLoader!

    init(
        oldStarted: XCTestExpectation,
        newStarted: XCTestExpectation,
        oldWaiterResumed: XCTestExpectation,
        newWaiterFinished: XCTestExpectation
    ) {
        self.oldStarted = oldStarted
        self.newStarted = newStarted
        self.oldWaiterResumed = oldWaiterResumed
        self.newWaiterFinished = newWaiterFinished
        queue.name = "MacClippyCardThumbnailStaleWaiterTests"
        queue.maxConcurrentOperationCount = 2
        loader = MacClippyCardThumbnailLoader(
            cache: NSCache<NSString, MacClippyCardThumbnailLoader.CacheEntry>(),
            queue: queue,
            loadImage: { [self] _, _, isCancelled in
                if state.nextLoad() == 1 {
                    oldStarted.fulfill()
                    oldDecodeGate.wait()
                    oldDecodeReturned.signal()
                    return Self.pngImage()
                }
                newStarted.fulfill()
                newDecodeGate.wait()
                let cancelled = isCancelled()
                state.setNewFlightWasCancelled(cancelled)
                return cancelled ? nil : Self.pngImage()
            }
        )
    }

    var cachedImage: CGImage? {
        loader.cachedImage(id: id, maxPixelSize: 32)
    }

    var loadCount: Int { state.loadCount }

    var newFlightWasCancelled: Bool { state.newFlightWasCancelled }

    var newWaiterReceivedImage: Bool { state.newWaiterReceivedImage }

    var oldWaiterReceivedImage: Bool { state.oldWaiterReceivedImage }

    func startOldWaiter() {
        oldWaiter = loader.load(id: id, maxPixelSize: 32) { [state, oldWaiterResumed] image in
            state.setOldWaiterReceivedImage(image != nil)
            oldWaiterResumed.fulfill()
        }
    }

    func resetSession() {
        loader.resetForSessionEnd()
    }

    func startNewWaiter() {
        _ = loader.load(id: id, maxPixelSize: 32) { [state, newWaiterFinished] image in
            state.setNewWaiterReceivedImage(image != nil)
            newWaiterFinished.fulfill()
        }
    }

    func releaseOldFlightAndWaitForFinish() -> Bool {
        oldWaiter?.release()
        oldDecodeGate.signal()
        guard oldDecodeReturned.wait(timeout: .now() + 2) == .success else { return false }
        return waitForOperationCount(1, timeout: 2)
    }

    func releaseNewFlight() {
        newDecodeGate.signal()
    }

    private func waitForOperationCount(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if queue.operationCount == count { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return queue.operationCount == count
    }

    private static func pngImage() -> CGImage {
        let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAA"
            + "AC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII="
        let png = Data(base64Encoded: encoded)!
        let source = CGImageSourceCreateWithData(png as CFData, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }
}

private final class MacClippyCardThumbnailStaleWaiterState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLoadCount = 0
    private var storedNewFlightWasCancelled = false
    private var storedNewWaiterReceivedImage = false
    private var storedOldWaiterReceivedImage = false

    func nextLoad() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storedLoadCount += 1
        return storedLoadCount
    }

    func setNewFlightWasCancelled(_ value: Bool) {
        lock.lock()
        storedNewFlightWasCancelled = value
        lock.unlock()
    }

    func setNewWaiterReceivedImage(_ value: Bool) {
        lock.lock()
        storedNewWaiterReceivedImage = value
        lock.unlock()
    }

    func setOldWaiterReceivedImage(_ value: Bool) {
        lock.lock()
        storedOldWaiterReceivedImage = value
        lock.unlock()
    }

    var loadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedLoadCount
    }

    var newFlightWasCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedNewFlightWasCancelled
    }

    var newWaiterReceivedImage: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedNewWaiterReceivedImage
    }

    var oldWaiterReceivedImage: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedOldWaiterReceivedImage
    }
}
