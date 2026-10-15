import AppKit
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyPasteResultRuntimeTests: XCTestCase {
    private var tempRoot: URL!
    private var pasteboard: NSPasteboard!
    private var control: MacClippyPasteTestControl!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyPasteResultRuntime-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPasteResultRuntime-\(UUID().uuidString)"))
        let control = MacClippyPasteTestControl()
        self.control = control
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { [control] in control.isTrusted },
            postEvents: { [control] _, _ in control.recordPostedEventPair() },
            postEventsToProcess: { [control] _, _, pid in control.recordPostedEventPair(processIdentifier: pid) }
        )
        runtime = try MacClippyRuntime(
            paths: MacClippyPaths(rootURL: tempRoot),
            pasteInjector: injector
        )
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        pasteboard = nil
        control = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testPasteReturnsPreparedForManualPasteWithSelectedContentOnClipboard() throws {
        pasteboard.setString("previous clipboard", forType: .string)
        control.setTrusted(false)
        let selected = try runtime.appendTestRecord(.text("selected record payload"))

        let result = try runtime.paste(id: selected.id)

        XCTAssertEqual(result, .preparedForManualPaste)
        XCTAssertEqual(pasteboard.string(forType: .string), "selected record payload")
        XCTAssertEqual(control.postedEventPairCount, 0, "manual preparation must not post a paste keystroke")
        XCTAssertEqual(try frequency(for: selected.id), 0, "manual preparation must not count as an injected paste")
    }

    func testSnippetPasteFailurePreservesExistingClipboardWhenAutomaticPasteIsUnavailable() throws {
        pasteboard.setString("typed snippet trigger", forType: .string)
        control.setTrusted(false)
        let snippet = try runtime.createSnippet(name: "Greeting", trigger: nil, body: "Hello from snippet")

        let result = try runtime.paste(snippetID: snippet.id)

        guard case let .failed(failure) = result else {
            XCTFail("expected a typed failure for a snippet that cannot post its paste keystroke, got \(result)")
            return
        }
        XCTAssertEqual(failure, .accessibilityUnavailable)
        XCTAssertEqual(pasteboard.string(forType: .string), "typed snippet trigger")
        XCTAssertNotEqual(result, .preparedForManualPaste, "snippets must not claim manual-paste success")
        XCTAssertEqual(control.postedEventPairCount, 0)
    }

    func testClosedGateCancelsPasteWithoutChangingClipboardOrFrequency() throws {
        pasteboard.setString("previous clipboard", forType: .string)
        let selected = try runtime.appendTestRecord(.text("must not be prepared"))
        let gate = MacClippyPasteInjectionGate()
        gate.close()

        let result = try runtime.paste(id: selected.id, sideEffectGate: gate)

        XCTAssertEqual(result, .cancelled)
        XCTAssertEqual(pasteboard.string(forType: .string), "previous clipboard")
        XCTAssertEqual(control.postedEventPairCount, 0)
        XCTAssertEqual(try frequency(for: selected.id), 0)
    }

    func testPasteKeepsExplicitDestinationThroughAllContentActions() throws {
        pasteboard.setString("previous clipboard", forType: .string)
        let selected = try runtime.appendTestRecord(.text("selected"))
        let second = try runtime.appendTestRecord(.text("second"))
        XCTAssertEqual(try runtime.paste(id: selected.id, targetProcessIdentifier: 12345), .injected)
        XCTAssertEqual(control.postedProcessIdentifier, 12345)
        XCTAssertEqual(try runtime.paste(id: selected.id, transform: .uppercase,
                                        targetProcessIdentifier: 23456), .injected)
        XCTAssertEqual(control.postedProcessIdentifier, 23456)
        _ = try runtime.pasteOrdered(ids: [selected.id, second.id], targetProcessIdentifier: 34567)
        XCTAssertEqual(control.postedProcessIdentifier, 34567)
        _ = try runtime.pasteQueued(ids: [selected.id, second.id], targetProcessIdentifier: 45678)
        XCTAssertEqual(control.postedProcessIdentifier, 45678)
    }

    private func frequency(for id: RecordID) throws -> Int? {
        try runtime.history(limit: 10, query: "").first(where: { $0.id == id })?.meta.frequency
    }
}
