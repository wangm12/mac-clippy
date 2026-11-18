import AppKit
import XCTest

@testable import MacClippyPlatform

final class MacClippyPlatformHardeningFixesTests: XCTestCase {
    func testHTMLPlainTextExtractorStripsScriptsAndDecodesEntitiesOffline() {
        let html = """
        <script>fetch("https://example.invalid");</script>
        <style>.hidden { display: none; }</style>
        <p>Hello &amp; <b>world</b>&#33;</p><div>Line 2</div>
        """
        let text = MacClippyPasteboardPrivacyHTML.plainText(from: html)
        XCTAssertEqual(text, "Hello & world!\nLine 2")
        XCTAssertFalse(text.contains("fetch"))
        XCTAssertFalse(text.contains("display"))
    }

    func testPasteInjectorSnapshotToleratesSidecarPromisesAndBestEffortSizeLimit() {
        let injector = MacClippyPasteInjector()
        let board = NSPasteboard(name: .init("MacClippyHardeningPlatform-\(UUID().uuidString)"))
        board.clearContents()

        let item = NSPasteboardItem()
        item.setData(Data("hello".utf8), forType: .string)
        item.setDataProvider(EmptyPromiseProvider(), forTypes: [
            NSPasteboard.PasteboardType("Apple files promise pasteboard type"),
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content")
        ])
        XCTAssertTrue(board.writeObjects([item]))

        let strictSnapshot = injector.snapshotPasteboard(board, policy: .strict)
        XCTAssertTrue(strictSnapshot.isComplete)
        XCTAssertEqual(strictSnapshot.items.count, 1)
        XCTAssertEqual(strictSnapshot.items[0].first?.type, .string)

        let smallBoard = NSPasteboard(name: .init("MacClippyHardeningBestEffort-\(UUID().uuidString)"))
        smallBoard.clearContents()
        let bigItem = NSPasteboardItem()
        bigItem.setData(Data(repeating: 0x41, count: 4_096), forType: .string)
        bigItem.setData(Data("tiny".utf8), forType: .html)
        XCTAssertTrue(smallBoard.writeObjects([bigItem]))

        let bestEffort = injector.snapshotPasteboard(smallBoard, policy: .bestEffort(maxBytes: 256))
        XCTAssertTrue(bestEffort.isComplete)
        XCTAssertEqual(bestEffort.items.first?.map(\.type), [.html])
    }

    func testSnippetExpansionPlannerRecoversTriggerAfterBackspace() {
        var planner = MacClippySnippetExpansionPlanner(
            modeProvider: { .autoExpand },
            lookup: { trigger in
                trigger == ";sig" ? "Signed" : nil
            }
        )
        for char in ";sigx" {
            XCTAssertNil(planner.handle(char))
        }
        planner.handleBackspace()
        let plan = planner.handle(" ")
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.charactersToDelete, 5)
        XCTAssertEqual(plan?.body, "Signed")
    }
}

private final class EmptyPromiseProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {}
}
