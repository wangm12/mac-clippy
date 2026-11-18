import AppKit
import Foundation
import XCTest

import MacClippyCore
@testable import MacClippyPlatform

final class MacClippySystemPasteboardRetryTests: XCTestCase {
    func testNamedPasteboardAccumulatesRepeatedUTIBytesWhenItemsResolveOnDifferentRetries() {
        let scenario = NamedPasteboardRetryScenario()
        defer { scenario.stop() }
        scenario.start()
        scenario.installPromisedItems()
        scenario.assertBothItemsPending()
        scenario.materializeFirstItemAndAssertPartialCapture()
        scenario.materializeSecondItem()
        scenario.assertDeliveredGeneration()
        scenario.assertStopQueueBarrier()
    }
}

private final class NamedPasteboardRetryScenario {
    let pasteboard: NSPasteboard
    let sharedUTI: NSPasteboard.PasteboardType
    let firstPayload: Data
    let secondPayload: Data
    let firstProvider: StaggeredRepresentationProvider
    let secondProvider: StaggeredRepresentationProvider
    private let observer: PasteboardObserver
    private var delivered: [PasteboardChange] = []
    private var baselineChangeCount = 0
    private var generation = -1

    init() {
        let pasteboard = NSPasteboard.withUniqueName()
        let sharedUTI = NSPasteboard.PasteboardType("com.example.macclippy.staggered-shared")
        let firstPayload = Data("first-item-shared-bytes".utf8)
        let secondPayload = Data("second-item-shared-bytes".utf8)
        self.pasteboard = pasteboard
        self.sharedUTI = sharedUTI
        self.firstPayload = firstPayload
        self.secondPayload = secondPayload
        firstProvider = StaggeredRepresentationProvider(payload: firstPayload, type: sharedUTI)
        secondProvider = StaggeredRepresentationProvider(payload: secondPayload, type: sharedUTI)
        let reader = MacClippySystemPasteboardReader(
            pasteboard: pasteboard,
            sourceAppBundleID: { nil }
        )
        observer = PasteboardObserver(
            reader: reader,
            pollInterval: 60,
            queue: DispatchQueue(label: "MacClippySystemPasteboardRetryTests.poll"),
            retryState: MacClippyPasteboardReadRetryState(maxAttempts: 4)
        )
        observer.disableAutomaticPollingForTesting()
    }

    func start() {
        observer.start { [weak self] in self?.delivered.append($0) }
        observer.poll()
        XCTAssertFalse(observer.hasPollingTimerForTesting())
        baselineChangeCount = pasteboard.changeCount
    }

    func installPromisedItems() {
        let firstItem = NSPasteboardItem()
        XCTAssertTrue(firstItem.setString("first item", forType: .string))
        XCTAssertTrue(firstItem.setDataProvider(firstProvider, forTypes: [sharedUTI]))
        let secondItem = NSPasteboardItem()
        XCTAssertTrue(secondItem.setString("second item", forType: .string))
        XCTAssertTrue(secondItem.setDataProvider(secondProvider, forTypes: [sharedUTI]))
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([firstItem, secondItem]))
        generation = pasteboard.changeCount
        XCTAssertGreaterThan(generation, baselineChangeCount)
    }

    func assertBothItemsPending() {
        observer.poll()
        XCTAssertTrue(delivered.isEmpty, "both lazy item-specific slots must remain pending")
        XCTAssertEqual(firstProvider.requestCount, 1)
        XCTAssertEqual(secondProvider.requestCount, 1)
    }

    func materializeFirstItemAndAssertPartialCapture() {
        XCTAssertTrue(firstProvider.materialize())
        XCTAssertEqual(pasteboard.changeCount, generation)
        XCTAssertEqual(pasteboard.pasteboardItems?.first?.data(forType: sharedUTI), firstPayload)
        observer.poll()
        XCTAssertTrue(delivered.isEmpty, "the first item may resolve while the second remains pending")
        guard let partial = observer.retryState.pending(for: generation)?.originalChange else {
            return XCTFail("The observer should retain the first item's resolved bytes while retrying the second")
        }
        XCTAssertEqual(partial.items[0].data(forType: sharedUTI.rawValue), firstPayload)
        XCTAssertNil(partial.items[1].data(forType: sharedUTI.rawValue))
    }

    func materializeSecondItem() {
        XCTAssertTrue(secondProvider.materialize())
        XCTAssertEqual(pasteboard.changeCount, generation)
        XCTAssertEqual(pasteboard.pasteboardItems?.last?.data(forType: sharedUTI), secondPayload)
    }

    func assertDeliveredGeneration() {
        observer.poll()
        XCTAssertEqual(firstProvider.requestCount, 1)
        XCTAssertEqual(secondProvider.requestCount, 1)
        XCTAssertEqual(delivered.map(\.changeCount), [generation])
        guard let captured = delivered.first else {
            return XCTFail("The fully materialized named pasteboard generation should be delivered")
        }
        XCTAssertEqual(captured.items.count, 2)
        XCTAssertEqual(captured.items[0].data(forType: sharedUTI.rawValue), firstPayload)
        XCTAssertEqual(captured.items[1].data(forType: sharedUTI.rawValue), secondPayload)
        XCTAssertEqual(captured.items[0].string(forType: NSPasteboard.PasteboardType.string.rawValue), "first item")
        XCTAssertEqual(captured.items[1].string(forType: NSPasteboard.PasteboardType.string.rawValue), "second item")
    }

    func assertStopQueueBarrier() {
        observer.stop()
        observer.poll()
        XCTAssertFalse(observer.hasPollingTimerForTesting())
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("after observer stop", forType: .string))
        observer.poll()
        XCTAssertEqual(delivered.count, 1)
    }

    func stop() {
        observer.stop()
        observer.poll()
        XCTAssertFalse(observer.hasPollingTimerForTesting())
    }
}

private final class StaggeredRepresentationProvider: NSObject, NSPasteboardItemDataProvider {
    private let payload: Data
    private let type: NSPasteboard.PasteboardType
    private let lock = NSLock()
    private var requests = 0
    private weak var promisedItem: NSPasteboardItem?

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    init(payload: Data, type: NSPasteboard.PasteboardType) {
        self.payload = payload
        self.type = type
    }

    func pasteboard(
        _: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType _: NSPasteboard.PasteboardType
    ) {
        lock.lock()
        requests += 1
        promisedItem = item
        lock.unlock()
    }

    func materialize() -> Bool {
        lock.lock()
        let item = promisedItem
        lock.unlock()
        guard let item else { return false }
        return item.setData(payload, forType: type)
    }
}
