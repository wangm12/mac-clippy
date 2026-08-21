import AppKit
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyCopyPrepareFailureTests: XCTestCase {
    private var tempRoot: URL!
    private var pasteboard: NSPasteboard!
    private var postedEventCount: Int = 0

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyCopyPrepareFailureTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyCopyPrepare-\(UUID().uuidString)"))
        postedEventCount = 0
    }

    override func tearDownWithError() throws {
        pasteboard = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    @MainActor
    func testCopyFocusedDoesNotShowSuccessWhenPrepareReturnsFalse() throws {
        let runtime = try makeFailingRuntime()
        defer { runtime.closeForTesting() }

        let model = MacClippyDockModel(runtime: runtime)
        _ = try runtime.appendTestRecord(.text("will not copy"))
        model.reload()
        wait { model.historyItems.count == 1 }
        model.focusSelection(at: 0)

        model.copyFocused(plain: false)

        wait { model.actionError != nil || model.actionFeedback != nil }

        XCTAssertEqual(model.actionError, MacClippyUserFacingError.clipboardWrite)
        XCTAssertNil(model.actionFeedback)
        XCTAssertEqual(postedEventCount, 0)
    }

    @MainActor
    func testCopySelectedAllDoesNotShowSuccessWhenPrepareFails() throws {
        let runtime = try makeFailingRuntime()
        defer { runtime.closeForTesting() }

        let first = try runtime.appendTestRecord(.text("first"))
        let second = try runtime.appendTestRecord(.text("second"))
        XCTAssertThrowsError(
            try runtime.copyOrdered(ids: [second.id, first.id])
        ) { error in
            XCTAssertEqual(error as? MacClippyPasteboardPrepareError, .writeFailed)
        }

        let model = MacClippyDockModel(runtime: runtime)
        model.reload()
        wait { model.historyItems.count >= 2 }
        model.beginSession()
        model.selectAllVisible()
        model.copySelectedAll()

        wait { model.actionError != nil || model.actionFeedback != nil }

        XCTAssertEqual(model.actionError, MacClippyUserFacingError.clipboardWrite)
        XCTAssertNil(model.actionFeedback)
        XCTAssertEqual(postedEventCount, 0)
    }

    private func makeFailingRuntime() throws -> MacClippyRuntime {
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { [weak self] _, _ in
                self?.postedEventCount &+= 1
            },
            preparer: { _, _ in false }
        )
        return try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: tempRoot),
            pasteInjector: injector
        )
    }

    private func wait(until condition: () -> Bool, timeout: TimeInterval = 2.0) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
