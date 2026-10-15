import AppKit
import MacClippyCore
import MacClippyPlatform
import XCTest

@testable import MacClippy

final class MacClippySearchWorkflowTests: XCTestCase {
    private var root: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyUIWorkflow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        runtime = try MacClippyRuntime(paths: MacClippyPaths(rootURL: root), enableSnippetExpansion: false)
    }

    override func tearDownWithError() throws {
        runtime.closeForTesting()
        try FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testSnippetsKeepKeywordsAndRestoreHistoryFilters() {
        let model = MacClippyDockModel(runtime: runtime)
        model.query = "\"two words\" type:text app:Safari has:ocr"
        model.selectSnippetsFilter()
        XCTAssertEqual(model.query, "\"two words\"")
        model.query = "new words"
        model.selectAllFilter()
        let parsed = MacClippySearchGrammar.parse(model.query)
        XCTAssertEqual(parsed.bareTerms, ["new", "words"])
        XCTAssertEqual(parsed.clauses, [.type(.text), .app("Safari"), .hasOCR])
    }

    @MainActor
    func testExplicitClearAlsoClearsTemporarilyHiddenHistoryConditions() {
        let model = MacClippyDockModel(runtime: runtime)
        model.query = "invoice app:Safari"
        model.selectSnippetsFilter()
        model.clearSearchQuery()
        model.selectAllFilter()
        XCTAssertEqual(model.query, "")
    }

    @MainActor
    func testPickerTypingEditsKeywordsWhileKeepingMountedFilters() {
        for raw in ["type:image", "invoice type:image", "\"two words\" app:Safari type:image has:ocr"] {
            let controller = MacClippyDockController(runtime: runtime)
            controller.model.query = raw
            let clauses = MacClippySearchGrammar.parse(raw).clauses
            let visible = controller.model.displayedSearchText
            let action = MacClippyDockKeyRouterPolicy.action(
                for: .keyDown(keyCode: 0, characters: "a", modifiers: [], isRepeat: false),
                mode: .picker, hasCardFocus: true, hasMultipleSelection: false)
            _ = controller.applyKeyAction(action)
            XCTAssertEqual(controller.interactionMode, .search)
            XCTAssertEqual(controller.model.displayedSearchText, visible + "a")
            let parsed = MacClippySearchGrammar.parse(controller.model.query)
            XCTAssertEqual(parsed.clauses.count, clauses.count)
            XCTAssertTrue(clauses.allSatisfy(parsed.clauses.contains))
            XCTAssertEqual(controller.model.searchFilterChips.count, clauses.count)
        }
    }

    @MainActor
    func testPickerBackspaceOnlyDeletesVisibleKeywords() {
        for raw in ["type:image", "a type:image", "invoice app:Safari type:image", "\"two words\" type:text"] {
            let controller = MacClippyDockController(runtime: runtime)
            controller.model.query = raw
            let clauses = MacClippySearchGrammar.parse(raw).clauses
            var visible = controller.model.displayedSearchText
            if !visible.isEmpty { visible.removeLast() }
            let action = MacClippyDockKeyRouterPolicy.action(
                for: .keyDown(keyCode: 51, characters: nil, modifiers: [], isRepeat: false),
                mode: .picker, hasCardFocus: true, hasMultipleSelection: false)
            _ = controller.applyKeyAction(action)
            XCTAssertEqual(controller.model.displayedSearchText, visible)
            let parsed = MacClippySearchGrammar.parse(controller.model.query)
            XCTAssertEqual(parsed.clauses.count, clauses.count)
            XCTAssertTrue(clauses.allSatisfy(parsed.clauses.contains))
        }
    }

    @MainActor
    func testFullQueryReplacementClearsOldFiltersButFieldCommitsPreserveThem() {
        let model = MacClippyDockModel(runtime: runtime)
        model.query = "textneedle type:text app:Safari"
        model.commitSearchFieldText("htmlneedle")
        let clauses = MacClippySearchGrammar.parse(model.query).clauses
        XCTAssertEqual(clauses.count, 2)
        XCTAssertTrue(clauses.contains(.type(.text)))
        XCTAssertTrue(clauses.contains(.app("Safari")))
        model.replaceSearchQuery("htmlneedle")
        XCTAssertEqual(model.query, "htmlneedle")
        XCTAssertTrue(model.searchFilterChips.isEmpty)
        model.replaceSearchQuery("textneedle type:text")
        model.replaceSearchQuery("transitionneedle")
        XCTAssertEqual(model.query, "transitionneedle")
        model.replaceSearchQuery("textneedle type:text")
        XCTAssertEqual(model.query, "textneedle type:text")
    }

    @MainActor
    func testSnippetsRestoreFiltersAroundUnfinishedQuotedAndEscapedKeywords() {
        for text in ["\"invoice", "invoice\\"] {
            let model = MacClippyDockModel(runtime: runtime)
            model.query = MacClippySearchWorkflowPolicy.composing(text, clauses: [.type(.image), .app("Safari")])
            model.selectSnippetsFilter()
            XCTAssertEqual(model.query, text)
            model.selectAllFilter()
            let parsed = MacClippySearchGrammar.parse(model.query)
            XCTAssertEqual(model.displayedSearchText, text)
            XCTAssertEqual(parsed.clauses.count, 2)
            XCTAssertTrue(parsed.clauses.contains(.type(.image)))
            XCTAssertTrue(parsed.clauses.contains(.app("Safari")))
        }
    }

    @MainActor
    func testFirstReturnAndTabPreserveSelectionAndQueryWithoutWritingClipboard() throws {
        let record = try runtime.appendTestRecord(.text("invoice payload"))
        _ = try runtime.setCustomLabel(id: record.id, label: "Invoice")
        let controller = MacClippyDockController(runtime: runtime)
        let model = controller.model
        model.beginSession()
        model.query = "invoice type:text"
        model.reload()
        MacClippyTestWait.until({ model.visibleItems.count == 1 }, failOnTimeout: true)
        model.focusSelection(at: 0)
        controller.interactionMode = .search
        _ = controller.applyKeyAction(.focusResults)
        XCTAssertEqual(controller.interactionMode, .picker)
        XCTAssertEqual(model.query, "invoice type:text")
        XCTAssertEqual(model.focusedItem?.id, record.id)
        XCTAssertNil(model.actionFeedback)
        controller.enterSearchMode()
        XCTAssertEqual(model.query, "invoice type:text")
    }

    @MainActor
    func testEmptyResultsRemainInSearch() {
        let controller = MacClippyDockController(runtime: runtime)
        controller.model.query = "missing"
        controller.interactionMode = .search
        controller.focusResults()
        XCTAssertEqual(controller.interactionMode, .search)
        XCTAssertEqual(controller.model.query, "missing")
    }

    @MainActor
    func testMixedSelectionDisablesMergeAndDeletionConfirmationFreezesIDs() throws {
        let text = try runtime.appendTestRecord(.text("text"))
        let file = try runtime.appendTestRecord(.files([root]))
        let model = MacClippyDockModel(runtime: runtime)
        model.reload()
        MacClippyTestWait.until({ model.visibleItems.count == 2 }, failOnTimeout: true)
        model.focusSelection(at: 0)
        model.toggleSelection(at: 1)
        XCTAssertFalse(model.canMergeSelection)
        model.requestDeleteSelected()
        guard case .confirmDeleteItems(let ids, _, _) = model.modal else {
            return XCTFail("Missing confirmation")
        }
        XCTAssertEqual(Set(ids), Set([text.id, file.id]))
        model.clearSelection()
        model.dismissModal()
        XCTAssertEqual(try runtime.clipboardStore.metas(for: ids).count, 2)
    }

    @MainActor
    func testHeaderBudgetsLeaveSearchAndControlsRoomAtAcceptanceWidths() {
        for width: CGFloat in [1024, 1280, 1440] {
            for statusWidth: CGFloat in [0, 72] {
                let navigation = MacClippyDockHeaderLayoutPolicy.navigationWidth(
                    available: width - 24, captureStatusWidth: statusWidth)
                let search = MacClippyDockHeaderLayoutPolicy.searchWidth(
                    available: width - 24, captureStatusWidth: statusWidth)
                let chips = MacClippyDockHeaderLayoutPolicy.chipWidth(searchWidth: search)
                XCTAssertGreaterThanOrEqual(search - chips - 90, 200)
                XCTAssertLessThanOrEqual(search, 448)
                XCTAssertGreaterThanOrEqual(navigation, 220)
            }
        }
    }

    @MainActor
    func testNativeMenuTrackingPreventsOutsideDismissalAndFocusRecovery() {
        let controller = MacClippyDockController(runtime: runtime)
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 0, y: 0, width: 800, height: 360))
        controller.panel = panel
        controller.swiftUIReduceMotion = true
        panel.orderFrontRegardless()
        defer { controller.cleanup() }
        controller.nativeMenuTrackingDepth = 1
        controller.closeIfOutside(at: CGPoint(x: 900, y: 200))
        controller.handlePanelDidResignKey(
            panel, monitorGeneration: controller.monitorGeneration,
            pointerLocation: CGPoint(x: 900, y: 200))
        XCTAssertTrue(panel.isVisible)
        controller.nativeMenuTrackingDepth = 0
        controller.closeIfOutside(at: CGPoint(x: 900, y: 200))
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testNativeMarkedTextConfirmationDoesNotEnterResults() {
        let coordinator = MacClippyAppKitSearchField.Coordinator()
        var submits = 0
        coordinator.parent = MacClippyAppKitSearchField(
            committedQuery: "", isFocused: true, collapseToken: 0, programmaticSyncToken: 0,
            onCommit: { _ in }, onFocusChange: { _ in }, onCompositionChange: { _ in },
            onSubmit: { submits += 1 })
        let editor = NSTextView()
        editor.setMarkedText("中文", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        let command = #selector(NSResponder.insertNewline(_:))
        XCTAssertFalse(coordinator.control(NSTextField(), textView: editor, doCommandBy: command))
        XCTAssertEqual(submits, 0)
        editor.unmarkText()
        XCTAssertTrue(coordinator.control(NSTextField(), textView: editor, doCommandBy: command))
        XCTAssertEqual(submits, 1)
    }
}

extension MacClippySearchWorkflowTests {
    @MainActor
    func testSettingsRequestUsesItsInjectedApplicationHandler() {
        var opened = 0
        let controller = MacClippyDockController(runtime: runtime, onOpenSettings: { opened += 1 })
        defer { controller.cleanup() }

        controller.openSettingsAfterHide()

        XCTAssertEqual(opened, 1, "Settings must not depend on casting SwiftUI's NSApplication delegate")
    }
}
