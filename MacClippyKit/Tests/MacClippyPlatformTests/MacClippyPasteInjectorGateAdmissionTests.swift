import AppKit
import Foundation
@_spi(Testing) import MacClippyPlatform
import XCTest

final class MacClippyPasteInjectorGateAdmissionTests: XCTestCase {
    func testCancellationAtEventAdmissionRestoresExactOriginalRepresentations() {
        let pasteboard = makePasteboard("EventAdmissionCancel")
        let original = originalRepresentations()
        XCTAssertTrue(write(original, to: pasteboard))
        let expectedOriginal = representationSignature(pasteboard)
        let gate = MacClippyPasteInjectionGate()
        let reachedAdmission = DispatchSemaphore(value: 0)
        let releaseAdmission = DispatchSemaphore(value: 0)
        let eventCount = AdmissionPasteCounter()
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in _ = eventCount.increment() }
        )
        injector.setPreEventAdmissionHookForTesting {
            reachedAdmission.signal()
            releaseAdmission.wait()
        }
        let result = AdmissionPasteResult<MacClippyPasteInjectionResult>()
        let completed = expectation(description: "cancelled admission restores the clipboard")
        defer { releaseAdmission.signal() }

        DispatchQueue.global().async {
            result.set(injector.inject(text: "replacement", gate: gate))
            completed.fulfill()
        }
        XCTAssertEqual(reachedAdmission.wait(timeout: .now() + 2), .success)

        gate.close()
        releaseAdmission.signal()

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(result.get(), .cancelled)
        XCTAssertEqual(eventCount.value, 0)
        XCTAssertEqual(representationSignature(pasteboard), expectedOriginal)
    }

    func testForeignGenerationAtCancelledEventAdmissionIsPreserved() {
        let pasteboard = makePasteboard("EventAdmissionForeignGeneration")
        XCTAssertTrue(write(originalRepresentations(), to: pasteboard))
        let gate = MacClippyPasteInjectionGate()
        let reachedAdmission = DispatchSemaphore(value: 0)
        let releaseAdmission = DispatchSemaphore(value: 0)
        let eventCount = AdmissionPasteCounter()
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in _ = eventCount.increment() }
        )
        injector.setPreEventAdmissionHookForTesting {
            reachedAdmission.signal()
            releaseAdmission.wait()
        }
        let result = AdmissionPasteResult<MacClippyPasteInjectionResult>()
        let completed = expectation(description: "foreign clipboard generation wins cancellation race")
        defer { releaseAdmission.signal() }

        DispatchQueue.global().async {
            result.set(injector.inject(text: "replacement", gate: gate))
            completed.fulfill()
        }
        XCTAssertEqual(reachedAdmission.wait(timeout: .now() + 2), .success)

        gate.close()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("foreign generation", forType: .string))
        let expectedForeign = representationSignature(pasteboard)
        releaseAdmission.signal()

        wait(for: [completed], timeout: 2)
        XCTAssertEqual(result.get(), .failed(.clipboardChanged))
        XCTAssertEqual(eventCount.value, 0)
        XCTAssertEqual(representationSignature(pasteboard), expectedForeign)
        XCTAssertEqual(pasteboard.string(forType: .string), "foreign generation")
    }

    func testOrdinaryAdmittedPasteKeepsPreparedClipboardAndPostsInjectedEventPair() {
        let pasteboard = makePasteboard("OrdinaryAdmitted")
        XCTAssertTrue(pasteboard.setString("original", forType: .string))
        let eventPairCount = AdmissionPasteCounter()
        let completionCount = AdmissionPasteCounter()
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in _ = eventPairCount.increment() }
        )

        let result = injector.inject(
            text: "replacement",
            afterPasteEvents: { _ = completionCount.increment() }
        )

        XCTAssertEqual(result, .injected)
        XCTAssertEqual(eventPairCount.value, 1)
        XCTAssertEqual(completionCount.value, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "replacement")
    }
}

final class MacClippyPasteInjectorGateRestoreTests: XCTestCase {
    func testAdmissionCancellationReportsRestoreWriteFailureWhenBothRetriesFail() {
        let pasteboard = makePasteboard("AdmissionRestoreWriteFailure")
        XCTAssertTrue(write(originalRepresentations(), to: pasteboard))
        let expectedOriginal = originalRepresentationSignature()
        XCTAssertEqual(representationSignature(pasteboard), expectedOriginal)
        let gate = MacClippyPasteInjectionGate()
        let eventPairCount = AdmissionPasteCounter()
        let completionCount = AdmissionPasteCounter()
        var writeAttempts = 0
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in _ = eventPairCount.increment() },
            writeObjects: { pasteboard, items in
                writeAttempts += 1
                if writeAttempts == 1 { return pasteboard.writeObjects(items) }
                return false
            }
        )
        injector.setPreEventAdmissionHookForTesting { gate.close() }

        let result = injector.inject(
            text: "replacement",
            afterPasteEvents: { _ = completionCount.increment() },
            gate: gate
        )

        XCTAssertEqual(result, .failed(.clipboardRestoreFailed))
        XCTAssertEqual(writeAttempts, 3, "prepared write succeeds, then both restore writes fail")
        XCTAssertEqual(eventPairCount.value, 0)
        XCTAssertEqual(completionCount.value, 0)
        XCTAssertTrue(representationSignature(pasteboard).isEmpty)
    }

    func testAdmissionCancellationPreservesConcurrentForeignGenerationDuringRestore() {
        let pasteboard = makePasteboard("AdmissionRestoreForeignGeneration")
        XCTAssertTrue(write(originalRepresentations(), to: pasteboard))
        let expectedOriginal = originalRepresentationSignature()
        XCTAssertEqual(representationSignature(pasteboard), expectedOriginal)
        let gate = MacClippyPasteInjectionGate()
        let eventPairCount = AdmissionPasteCounter()
        let completionCount = AdmissionPasteCounter()
        var writeAttempts = 0
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in _ = eventPairCount.increment() },
            writeObjects: { pasteboard, items in
                writeAttempts += 1
                if writeAttempts == 1 { return pasteboard.writeObjects(items) }
                if writeAttempts == 2 {
                    pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.setString("foreign during restore", forType: .string))
                }
                return false
            }
        )
        injector.setPreEventAdmissionHookForTesting { gate.close() }

        let result = injector.inject(
            text: "replacement",
            afterPasteEvents: { _ = completionCount.increment() },
            gate: gate
        )
        let expectedForeign = [[AdmissionPasteboardRepresentation(
            type: NSPasteboard.PasteboardType.string.rawValue,
            data: Data("foreign during restore".utf8)
        )]]

        XCTAssertEqual(result, .failed(.clipboardChanged))
        XCTAssertEqual(writeAttempts, 2, "ownership loss ends restoration without overwriting the foreign generation")
        XCTAssertEqual(eventPairCount.value, 0)
        XCTAssertEqual(completionCount.value, 0)
        XCTAssertEqual(representationSignature(pasteboard), expectedForeign)
    }

    func testInitialPreparedWriteFailureReportsExhaustedRestoreWriteFailure() {
        let pasteboard = makePasteboard("InitialWriteRestoreFailure")
        XCTAssertTrue(write(originalRepresentations(), to: pasteboard))
        let expectedOriginal = originalRepresentationSignature()
        XCTAssertEqual(representationSignature(pasteboard), expectedOriginal)
        let eventPairCount = AdmissionPasteCounter()
        let completionCount = AdmissionPasteCounter()
        var writeAttempts = 0
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in _ = eventPairCount.increment() },
            writeObjects: { _, _ in
                writeAttempts += 1
                return false
            }
        )

        let result = injector.inject(
            text: "replacement",
            afterPasteEvents: { _ = completionCount.increment() }
        )

        XCTAssertEqual(result, .failed(.clipboardRestoreFailed))
        XCTAssertEqual(writeAttempts, 3, "the initial write and both restore writes fail")
        XCTAssertEqual(eventPairCount.value, 0)
        XCTAssertEqual(completionCount.value, 0)
        XCTAssertTrue(representationSignature(pasteboard).isEmpty)
    }

    func testInitialPreparedWriteFailurePreservesConcurrentForeignGenerationDuringRestore() {
        let pasteboard = makePasteboard("InitialWriteRestoreForeignGeneration")
        XCTAssertTrue(write(originalRepresentations(), to: pasteboard))
        let expectedOriginal = originalRepresentationSignature()
        XCTAssertEqual(representationSignature(pasteboard), expectedOriginal)
        let eventPairCount = AdmissionPasteCounter()
        let completionCount = AdmissionPasteCounter()
        var writeAttempts = 0
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in _ = eventPairCount.increment() },
            writeObjects: { pasteboard, _ in
                writeAttempts += 1
                if writeAttempts == 2 {
                    pasteboard.clearContents()
                    XCTAssertTrue(pasteboard.setString("foreign during restore", forType: .string))
                }
                return false
            }
        )

        let result = injector.inject(
            text: "replacement",
            afterPasteEvents: { _ = completionCount.increment() }
        )
        let expectedForeign = [[AdmissionPasteboardRepresentation(
            type: NSPasteboard.PasteboardType.string.rawValue,
            data: Data("foreign during restore".utf8)
        )]]

        XCTAssertEqual(result, .failed(.clipboardChanged))
        XCTAssertEqual(writeAttempts, 2, "ownership loss ends restoration without a second write")
        XCTAssertEqual(eventPairCount.value, 0)
        XCTAssertEqual(completionCount.value, 0)
        XCTAssertEqual(representationSignature(pasteboard), expectedForeign)
    }

    func testInitialPreparedWriteFailureRestoresExactOriginalRepresentationsWithoutEvents() {
        let pasteboard = makePasteboard("InitialWriteRestoreOriginals")
        XCTAssertTrue(write(originalRepresentations(), to: pasteboard))
        let expectedOriginal = originalRepresentationSignature()
        XCTAssertEqual(representationSignature(pasteboard), expectedOriginal)
        let eventPairCount = AdmissionPasteCounter()
        let completionCount = AdmissionPasteCounter()
        var writeAttempts = 0
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in _ = eventPairCount.increment() },
            writeObjects: { pasteboard, items in
                writeAttempts += 1
                if writeAttempts == 1 { return false }
                return pasteboard.writeObjects(items)
            }
        )

        let result = injector.inject(
            text: "replacement",
            afterPasteEvents: { _ = completionCount.increment() }
        )

        XCTAssertEqual(result, .failed(.pasteboardWriteFailed))
        XCTAssertEqual(representationSignature(pasteboard), expectedOriginal)
        XCTAssertEqual(eventPairCount.value, 0)
        XCTAssertEqual(completionCount.value, 0)
    }
}

private func makePasteboard(_ suffix: String) -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("MacClippyPasteGate-\(suffix)-\(UUID().uuidString)"))
}

private func originalRepresentations() -> [[(type: NSPasteboard.PasteboardType, data: Data)]] {
    [
        [(.string, Data("original text".utf8)), (.html, Data("<p>original text</p>".utf8))],
        [(NSPasteboard.PasteboardType("com.example.macclippy-original"), Data([0x00, 0x81, 0xFE]))]
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

private func representationSignature(_ pasteboard: NSPasteboard) -> [[AdmissionPasteboardRepresentation]] {
    (pasteboard.pasteboardItems ?? []).map { item in
        item.types.compactMap { type in
            item.data(forType: type).map {
                AdmissionPasteboardRepresentation(type: type.rawValue, data: $0)
            }
        }.sorted { $0.type < $1.type }
    }
}

private func originalRepresentationSignature() -> [[AdmissionPasteboardRepresentation]] {
    [
        [
            AdmissionPasteboardRepresentation(
                type: NSPasteboard.PasteboardType.html.rawValue,
                data: Data("<p>original text</p>".utf8)
            ),
            AdmissionPasteboardRepresentation(
                type: NSPasteboard.PasteboardType.string.rawValue,
                data: Data("original text".utf8)
            )
        ].sorted { $0.type < $1.type },
        [AdmissionPasteboardRepresentation(
            type: "com.example.macclippy-original",
            data: Data([0x00, 0x81, 0xFE])
        )]
    ]
}

private struct AdmissionPasteboardRepresentation: Equatable {
    let type: String
    let data: Data
}

private final class AdmissionPasteResult<Value>: @unchecked Sendable {
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

private final class AdmissionPasteCounter: @unchecked Sendable {
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
