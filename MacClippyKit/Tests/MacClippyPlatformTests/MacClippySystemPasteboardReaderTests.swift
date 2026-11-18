import AppKit
import Foundation
import XCTest

import MacClippyCore
@testable import MacClippyPlatform

final class MacClippySystemPasteboardReaderTests: XCTestCase {
    private let triggerType = NSPasteboard.PasteboardType("com.example.macclippy.reader-trigger")

    func testProductionReaderRetriesAfterLazyProviderReplacesPasteboardGeneration() {
        let pasteboard = NSPasteboard.withUniqueName()
        let reader = MacClippySystemPasteboardReader(
            pasteboard: pasteboard,
            sourceAppBundleID: { nil }
        )
        let provider = ReplacingPasteboardProvider(replacement: "NEW")
        let oldItem = NSPasteboardItem()
        XCTAssertTrue(oldItem.setString("OLD", forType: .string))
        XCTAssertTrue(oldItem.setDataProvider(provider, forTypes: [triggerType]))
        XCTAssertTrue(pasteboard.writeObjects([oldItem]))
        XCTAssertEqual(provider.requestCount, 0, "writing the promised item should not materialize it")

        let snapshot = reader.read()

        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "NEW")
        XCTAssertEqual(snapshot.changeCount, pasteboard.changeCount)
        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0].string(forType: NSPasteboard.PasteboardType.string.rawValue), "NEW")
        XCTAssertFalse(snapshot.pasteboardTypes.contains(triggerType.rawValue))
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testReadBoundsRepeatedGenerationChurnAndCanReadTheNextStableGeneration() {
        let pasteboard = NSPasteboard.withUniqueName()
        let provider = ChurningPasteboardProvider(triggerType: triggerType)
        let firstItem = NSPasteboardItem()
        XCTAssertTrue(firstItem.setString("first", forType: .string))
        XCTAssertTrue(firstItem.setDataProvider(provider, forTypes: [triggerType]))
        XCTAssertTrue(pasteboard.writeObjects([firstItem]))
        let reader = MacClippySystemPasteboardReader(pasteboard: pasteboard, sourceAppBundleID: { nil })

        let churnedSnapshot = reader.read()

        XCTAssertEqual(provider.requestCount, MacClippyPasteboardSnapshotReadPolicy.maxGenerationAttempts)
        XCTAssertTrue(churnedSnapshot.items.isEmpty)
        XCTAssertNotEqual(churnedSnapshot.changeCount, pasteboard.changeCount)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("STABLE", forType: .string))
        let stableSnapshot = reader.read()

        XCTAssertEqual(stableSnapshot.changeCount, pasteboard.changeCount)
        let stableText = stableSnapshot.items.first?.string(
            forType: NSPasteboard.PasteboardType.string.rawValue
        )
        XCTAssertEqual(stableText, "STABLE")
    }

    func testSnapshotDeadlineIsSharedAcrossGenerationRetries() {
        let pasteboard = NSPasteboard.withUniqueName()
        let provider = ChurningPasteboardProvider(
            triggerType: triggerType,
            delay: MacClippyPasteboardSnapshotReadPolicy.snapshotDeadline + 0.1
        )
        let firstItem = NSPasteboardItem()
        XCTAssertTrue(firstItem.setString("first", forType: .string))
        XCTAssertTrue(firstItem.setDataProvider(provider, forTypes: [triggerType]))
        XCTAssertTrue(pasteboard.writeObjects([firstItem]))
        let originalCount = pasteboard.changeCount
        let reader = MacClippySystemPasteboardReader(pasteboard: pasteboard, sourceAppBundleID: { nil })

        let snapshot = reader.read()

        XCTAssertEqual(provider.requestCount, 1, "a later generation must not restart the expired read budget")
        XCTAssertTrue(snapshot.items.isEmpty)
        XCTAssertEqual(snapshot.changeCount, originalCount)
        XCTAssertNotEqual(snapshot.changeCount, pasteboard.changeCount)
    }

    func testSnapshotDeadlineBoundsDelayedUnavailableRepresentationsAcrossOneItem() {
        let pasteboard = NSPasteboard.withUniqueName()
        let provider = DelayedUnavailablePasteboardProvider(delay: 0.06)
        let delayedTypes = (0..<24).map {
            NSPasteboard.PasteboardType("com.example.macclippy.delayed-\($0)")
        }
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setString("item", forType: .string))
        XCTAssertTrue(item.setDataProvider(provider, forTypes: delayedTypes))
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let reader = MacClippySystemPasteboardReader(pasteboard: pasteboard, sourceAppBundleID: { nil })
        let readQueue = DispatchQueue(label: "MacClippySystemPasteboardReaderTests.budget")
        let finished = expectation(description: "bounded production pasteboard read completes")
        let resultLock = NSLock()
        var readResult: PasteboardChange?
        let start = ProcessInfo.processInfo.systemUptime
        readQueue.async {
            let result = reader.read()
            resultLock.lock()
            readResult = result
            resultLock.unlock()
            finished.fulfill()
        }

        wait(for: [finished], timeout: 3)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        resultLock.lock()
        let snapshot = readResult
        resultLock.unlock()

        XCTAssertGreaterThan(provider.requestCount, 0)
        XCTAssertLessThanOrEqual(provider.requestCount, 4)
        XCTAssertLessThan(elapsed, 0.8)
        XCTAssertEqual(snapshot?.changeCount, pasteboard.changeCount)
        XCTAssertEqual(snapshot?.items.count, 1)
        let unavailableUTIs = snapshot.map {
            MacClippyPasteboardAvailability.unavailableTypes(in: $0).filter {
                $0.uti.hasPrefix("com.example.macclippy.delayed-")
            }
        }
        XCTAssertEqual(unavailableUTIs?.count, delayedTypes.count)
    }

    func testSnapshotAcceptsValidProviderDataReturnedAfterDeadlineAndStopsFurtherCalls() {
        let pasteboard = NSPasteboard.withUniqueName()
        let firstType = NSPasteboard.PasteboardType("com.example.macclippy.late-valid-first")
        let secondType = NSPasteboard.PasteboardType("com.example.macclippy.late-valid-second")
        let payload = Data("stable-after-deadline".utf8)
        let provider = LateValidPasteboardProvider(
            delay: MacClippyPasteboardSnapshotReadPolicy.snapshotDeadline + 0.1,
            payload: payload
        )
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [firstType, secondType]))
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let changeCount = pasteboard.changeCount
        let reader = MacClippySystemPasteboardReader(pasteboard: pasteboard, sourceAppBundleID: { nil })

        let snapshot = reader.read()

        XCTAssertEqual(provider.requestedTypes.count, 1)
        XCTAssertEqual(snapshot.changeCount, changeCount)
        XCTAssertEqual(snapshot.items.count, 1)
        guard let requestedType = provider.requestedTypes.first,
              let capturedItem = snapshot.items.first else {
            XCTFail("Expected the delayed provider response to be captured")
            return
        }
        XCTAssertTrue([firstType, secondType].contains(requestedType))
        XCTAssertEqual(capturedItem.data(forType: requestedType.rawValue), payload)
        let stillUnavailableType = [firstType, secondType].first { $0 != requestedType }
        XCTAssertTrue(stillUnavailableType.map { missingType in
            MacClippyPasteboardAvailability.unavailableTypes(in: snapshot).contains {
                $0.itemIndex == 0 && $0.uti == missingType.rawValue
            }
        } ?? false)
    }

    func testReadStopsWhenLifecycleCancellationArrivesDuringNativeProviderCall() {
        let pasteboard = NSPasteboard.withUniqueName()
        let cancellation = PasteboardReadCancellation()
        let provider = CancellingPasteboardProvider(cancellation: cancellation)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setDataProvider(provider, forTypes: [triggerType]))
        XCTAssertTrue(pasteboard.writeObjects([item]))
        let changeCount = pasteboard.changeCount
        let reader = MacClippySystemPasteboardReader(pasteboard: pasteboard, sourceAppBundleID: { nil })

        let snapshot = reader.read(shouldContinue: { cancellation.shouldContinue })

        XCTAssertFalse(cancellation.shouldContinue)
        XCTAssertEqual(provider.requestCount, 1)
        XCTAssertEqual(snapshot.changeCount, changeCount)
        XCTAssertTrue(snapshot.items.isEmpty)
    }
}

private final class ReplacingPasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    private let replacement: String
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    init(replacement: String) {
        self.replacement = replacement
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item _: NSPasteboardItem,
        provideDataForType _: NSPasteboard.PasteboardType
    ) {
        lock.lock()
        requests += 1
        lock.unlock()
        guard let pasteboard else { return }
        pasteboard.clearContents()
        pasteboard.setString(replacement, forType: .string)
    }
}

private final class ChurningPasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    private let triggerType: NSPasteboard.PasteboardType
    private let delay: TimeInterval
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    init(triggerType: NSPasteboard.PasteboardType, delay: TimeInterval = 0) {
        self.triggerType = triggerType
        self.delay = delay
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item _: NSPasteboardItem,
        provideDataForType _: NSPasteboard.PasteboardType
    ) {
        lock.lock()
        requests += 1
        let request = requests
        lock.unlock()
        guard let pasteboard else { return }
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }

        let replacement = NSPasteboardItem()
        replacement.setString("generation-\(request)", forType: .string)
        replacement.setDataProvider(self, forTypes: [triggerType])
        pasteboard.clearContents()
        pasteboard.writeObjects([replacement])
    }
}

private final class DelayedUnavailablePasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    private let delay: TimeInterval
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func pasteboard(
        _: NSPasteboard?,
        item _: NSPasteboardItem,
        provideDataForType _: NSPasteboard.PasteboardType
    ) {
        lock.lock()
        requests += 1
        lock.unlock()
        Thread.sleep(forTimeInterval: delay)
    }
}

private final class LateValidPasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    private let delay: TimeInterval
    private let payload: Data
    private let lock = NSLock()
    private var types = [NSPasteboard.PasteboardType]()

    var requestedTypes: [NSPasteboard.PasteboardType] {
        lock.lock()
        defer { lock.unlock() }
        return types
    }

    init(delay: TimeInterval, payload: Data) {
        self.delay = delay
        self.payload = payload
    }

    func pasteboard(
        _: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        lock.lock()
        types.append(type)
        let isFirstRequest = types.count == 1
        lock.unlock()

        if isFirstRequest {
            Thread.sleep(forTimeInterval: delay)
        }
        _ = item.setData(payload, forType: type)
    }
}

private final class PasteboardReadCancellation {
    private let lock = NSLock()
    private var isCancelled = false

    var shouldContinue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !isCancelled
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }
}

private final class CancellingPasteboardProvider: NSObject, NSPasteboardItemDataProvider {
    private let cancellation: PasteboardReadCancellation
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    init(cancellation: PasteboardReadCancellation) {
        self.cancellation = cancellation
    }

    func pasteboard(
        _: NSPasteboard?,
        item _: NSPasteboardItem,
        provideDataForType _: NSPasteboard.PasteboardType
    ) {
        lock.lock()
        requests += 1
        lock.unlock()
        cancellation.cancel()
    }
}
