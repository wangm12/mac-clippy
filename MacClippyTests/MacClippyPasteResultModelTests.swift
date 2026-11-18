import AppKit
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyPasteResultModelTests: XCTestCase {
    private var tempRoot: URL!
    private var pasteboard: NSPasteboard!
    private var control: MacClippyPasteTestControl!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyPasteResultModel-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPasteResultModel-\(UUID().uuidString)"))
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

    @MainActor
    func testFocusedRecordManualPreparationShowsManualFeedbackAndUsesSelectedContent() throws {
        pasteboard.setString("previous clipboard", forType: .string)
        control.setTrusted(false)
        _ = try runtime.appendTestRecord(.text("selected model payload"))
        let model = MacClippyDockModel(runtime: runtime)
        model.reload()
        wait { model.historyItems.count == 1 }

        model.beginSession()
        model.focusSelection(at: 0)
        let completion = MacClippyPasteTestCompletion()
        model.pasteFocused(completion: { completion.wasCalled = true })

        wait { completion.wasCalled || model.actionFeedback != nil || model.actionError != nil }

        XCTAssertTrue(
            completion.wasCalled,
            "manual preparation is a successful single-record action that closes the dock"
        )
        guard case let .pasted(manual) = model.actionFeedback else {
            XCTFail("expected manual-paste feedback, got \(String(describing: model.actionFeedback))")
            return
        }
        XCTAssertTrue(manual)
        XCTAssertNil(model.actionError)
        XCTAssertEqual(pasteboard.string(forType: .string), "selected model payload")
        XCTAssertEqual(control.postedEventPairCount, 0)
    }

    @MainActor
    func testExplicitSnippetPastePreparesManualClipboardAndReportsSuccess() throws {
        pasteboard.setString("typed snippet trigger", forType: .string)
        control.setTrusted(false)
        let snippet = try runtime.createSnippet(name: "Greeting", trigger: nil, body: "Hello from snippet")
        let model = MacClippyDockModel(runtime: runtime)
        model.snippets = [snippet]
        model.filteredSnippets = [snippet]
        model.selectedTab = .snippets
        model.beginSession()

        let completion = MacClippyPasteTestCompletion()
        model.pasteFocused(completion: { completion.wasCalled = true })

        wait { model.actionError != nil || model.actionFeedback != nil || completion.wasCalled }

        XCTAssertTrue(completion.wasCalled)
        XCTAssertNil(model.actionError)
        XCTAssertEqual(model.actionFeedback, .pasted(manual: true))
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello from snippet")
        XCTAssertEqual(control.postedEventPairCount, 0)
    }

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 2.0) {
        MacClippyTestWait.until(condition, timeout: timeout)
    }

    @MainActor
    func testControllerPasteUsesCapturedApplicationRatherThanCurrentEditor() throws {
        pasteboard.setString("previous clipboard", forType: .string)
        let item = try runtime.appendTestRecord(.text("fixed destination"))
        let controller = MacClippyDockController(runtime: runtime)
        controller.model.actionToastHandler = { _ in }
        controller.pasteTargetApplication = NSRunningApplication.current
        let completion = MacClippyPasteTestCompletion()
        controller.model.selectRecord(id: item.id, completion: { completion.wasCalled = true })
        wait { completion.wasCalled || controller.model.actionError != nil }
        XCTAssertTrue(completion.wasCalled)
        XCTAssertEqual(control.postedProcessIdentifier, NSRunningApplication.current.processIdentifier)
        controller.pasteTargetApplication = nil
        XCTAssertNil(controller.model.pasteTargetProcessIdentifier)
    }
}
