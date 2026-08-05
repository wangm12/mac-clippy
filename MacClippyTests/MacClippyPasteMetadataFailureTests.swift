import AppKit
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyPasteMetadataFailureTests: XCTestCase {
    private var tempRoot: URL!
    private var pasteboard: NSPasteboard!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyPasteMetadataFailureTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("MacClippyPasteMetadataFailure-\(UUID().uuidString)"))
        MacClippyDiagnosticsRecorder.shared.clear()

        let paths = try MacClippyPaths(rootURL: tempRoot)
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { [weak self] _, _ in
                // Force the post-injection metadata write to fail. The
                // injection itself has already been accepted at this point.
                self?.runtime.closeForTesting()
            }
        )
        runtime = try MacClippyRuntime(paths: paths, pasteInjector: injector)
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        pasteboard = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testSuccessfulPasteIsNotReportedAsFailureWhenFrequencyWriteFails() throws {
        let record = try runtime.appendTestRecord(.text("paste body"))

        let result = try runtime.paste(id: record.id)

        XCTAssertEqual(result, .injected)
        XCTAssertEqual(pasteboard.string(forType: .string), "paste body")
        XCTAssertEqual(
            MacClippyDiagnosticsRecorder.shared.recentEvents().last?.code,
            .pasteMetadataUpdateFailed
        )
    }
}
