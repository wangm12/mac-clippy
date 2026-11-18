import AppKit
import Foundation
@_spi(Testing) import MacClippyPlatform
import XCTest

final class MacClippyPasteInjectorGateTests: XCTestCase {
    func testClosingGateDoesNotWaitForBlockedContentPreparation() {
        let pasteboard = makePasteboard("SlowPrepare")
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let gate = MacClippyPasteInjectionGate()
        let enteredPrepare = DispatchSemaphore(value: 0)
        let releasePrepare = DispatchSemaphore(value: 0)
        let completionCount = LockedPasteCounter()
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in XCTFail("cancelled work must not post paste events") },
            preparer: { content, stagingBoard in
                enteredPrepare.signal()
                releasePrepare.wait()
                return MacClippyPasteboardPreparer.prepare(content, on: stagingBoard)
            }
        )
        let result = LockedPasteResult<MacClippyPasteInjectionResult>()
        let completed = expectation(description: "injection finishes after preparation is released")

        DispatchQueue.global().async {
            result.set(injector.inject(
                text: "replacement",
                afterPasteEvents: { _ = completionCount.increment() },
                gate: gate
            ))
            completed.fulfill()
        }
        XCTAssertEqual(enteredPrepare.wait(timeout: .now() + 2), .success)

        assertCloseReturnsImmediately(gate)
        releasePrepare.signal()

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(result.get(), .cancelled)
        XCTAssertEqual(completionCount.value, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testClosingGateDuringBlockedPasteboardWritePreventsLaterPasteEvents() {
        let pasteboard = makePasteboard("SlowWrite")
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let gate = MacClippyPasteInjectionGate()
        let enteredWrite = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let writeCount = LockedPasteCounter()
        let eventCount = LockedPasteCounter()
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in _ = eventCount.increment() },
            writeObjects: { destination, items in
                if destination === pasteboard, writeCount.increment() == 1 {
                    enteredWrite.signal()
                    releaseWrite.wait()
                }
                return destination.writeObjects(items)
            }
        )
        let result = LockedPasteResult<MacClippyPasteInjectionResult>()
        let completed = expectation(description: "injection finishes after blocked write returns")

        DispatchQueue.global().async {
            result.set(injector.inject(text: "replacement", gate: gate))
            completed.fulfill()
        }
        XCTAssertEqual(enteredWrite.wait(timeout: .now() + 2), .success)

        assertCloseReturnsImmediately(gate)
        releaseWrite.signal()

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(result.get(), .cancelled)
        XCTAssertEqual(eventCount.value, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testClosingGateDuringSlowCommitValidationPreventsPasteCommit() {
        let pasteboard = makePasteboard("SlowBefore")
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let gate = MacClippyPasteInjectionGate()
        let enteredHook = DispatchSemaphore(value: 0)
        let releaseHook = DispatchSemaphore(value: 0)
        let eventCount = LockedPasteCounter()
        let completionCount = LockedPasteCounter()
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in _ = eventCount.increment() }
        )
        let result = LockedPasteResult<MacClippyPasteInjectionResult>()
        let completed = expectation(description: "injection finishes after hook returns")

        DispatchQueue.global().async {
            result.set(injector.inject(
                text: "replacement",
                beforePaste: { true },
                afterPasteEvents: { _ = completionCount.increment() },
                validateCommitContext: {
                    enteredHook.signal()
                    releaseHook.wait()
                    return true
                },
                gate: gate
            ))
            completed.fulfill()
        }
        XCTAssertEqual(enteredHook.wait(timeout: .now() + 2), .success)

        assertCloseReturnsImmediately(gate)
        releaseHook.signal()

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(result.get(), .cancelled)
        XCTAssertEqual(eventCount.value, 0)
        XCTAssertEqual(completionCount.value, 0)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testAccessibilityLossBeforeCommitPreparesHistoryForManualPaste() {
        let pasteboard = makePasteboard("PermissionChange")
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        var trustChecks = 0
        var eventCount = 0
        var beforePasteCount = 0
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: {
                trustChecks += 1
                return trustChecks == 1
            },
            postEvents: { _, _ in eventCount += 1 }
        )

        let result = injector.inject(text: "replacement", beforePaste: {
            beforePasteCount += 1
            return true
        })

        XCTAssertEqual(result, .preparedForManualPaste)
        XCTAssertEqual(pasteboard.string(forType: .string), "replacement")
        XCTAssertEqual(beforePasteCount, 0)
        XCTAssertEqual(eventCount, 0)
    }

    func testAccessibilityLossBeforeSnippetCommitPreservesClipboardAndTrigger() {
        let pasteboard = makePasteboard("SnippetPermissionChange")
        XCTAssertTrue(pasteboard.setString("typed trigger", forType: .string))
        var trustChecks = 0
        var eventCount = 0
        var beforePasteCount = 0
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: {
                trustChecks += 1
                return trustChecks == 1
            },
            postEvents: { _, _ in eventCount += 1 }
        )

        let result = injector.inject(
            text: "snippet body",
            beforePaste: {
                beforePasteCount += 1
                return true
            },
            manualFallback: .preserveClipboard
        )

        XCTAssertEqual(result, .failed(.accessibilityUnavailable))
        XCTAssertEqual(pasteboard.string(forType: .string), "typed trigger")
        XCTAssertEqual(beforePasteCount, 0)
        XCTAssertEqual(eventCount, 0)
    }

    func testClosingGateDoesNotWaitForInFlightEventPostOrPostDidAfterward() {
        let pasteboard = makePasteboard("SlowEvent")
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let gate = MacClippyPasteInjectionGate()
        let enteredPost = DispatchSemaphore(value: 0)
        let releasePost = DispatchSemaphore(value: 0)
        let didNotificationCount = LockedPasteCounter()
        let completionCount = LockedPasteCounter()
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in
                enteredPost.signal()
                releasePost.wait()
            }
        )
        let center = NotificationCenter.default
        let did = center.addObserver(
            forName: .macClippyDidInjectPasteKeystroke,
            object: injector,
            queue: nil
        ) { _ in
            _ = didNotificationCount.increment()
        }
        defer { center.removeObserver(did) }
        let result = LockedPasteResult<MacClippyPasteInjectionResult>()
        let completed = expectation(description: "in-flight event post returns")

        DispatchQueue.global().async {
            result.set(injector.inject(
                text: "replacement",
                afterPasteEvents: { _ = completionCount.increment() },
                gate: gate
            ))
            completed.fulfill()
        }
        XCTAssertEqual(enteredPost.wait(timeout: .now() + 2), .success)

        assertCloseReturnsImmediately(gate)
        releasePost.signal()

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(result.get(), .injected, "an admitted native post cannot be retracted")
        XCTAssertEqual(
            didNotificationCount.value,
            0,
            "closed work must not post follow-up notifications"
        )
        XCTAssertEqual(completionCount.value, 1, "internal completion must release admitted commit state")
    }

    private func makePasteboard(_ suffix: String) -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("MacClippyPasteGate-\(suffix)-\(UUID().uuidString)"))
    }

    private func originalRepresentations() -> [[(type: NSPasteboard.PasteboardType, data: Data)]] {
        [
            [
                (.string, Data("original text".utf8)),
                (.html, Data("<p>original text</p>".utf8))
            ],
            [
                (NSPasteboard.PasteboardType("com.example.macclippy-original"), Data([0x00, 0x81, 0xFE]))
            ]
        ]
    }

    private func write(
        _ representations: [[(type: NSPasteboard.PasteboardType, data: Data)]],
        to pasteboard: NSPasteboard
    ) -> Bool {
        var items: [NSPasteboardItem] = []
        for values in representations {
            let item = NSPasteboardItem()
            for value in values {
                guard item.setData(value.data, forType: value.type) else { return false }
            }
            items.append(item)
        }
        return pasteboard.writeObjects(items)
    }

    private func representationSignature(_ pasteboard: NSPasteboard) -> [[PasteboardRepresentation]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map {
                    PasteboardRepresentation(type: type.rawValue, data: $0)
                }
            }.sorted { $0.type < $1.type }
        }
    }

    private func assertCloseReturnsImmediately(_ gate: MacClippyPasteInjectionGate) {
        let closeStarted = DispatchTime.now()
        gate.close()
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - closeStarted.uptimeNanoseconds, 100_000_000)
    }
}

private struct PasteboardRepresentation: Equatable {
    let type: String
    let data: Data
}

private final class LockedPasteResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ value: Value) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class LockedPasteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        return storage
    }
}
