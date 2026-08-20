import XCTest
import AppKit

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyDockTests: XCTestCase {
    @MainActor
    func testDockPanelJoinsFullScreenSpacesWithoutActivatingHostApp() {
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240))
        defer { panel.close() }

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertEqual(panel.level.rawValue, NSWindow.Level.mainMenu.rawValue)
    }

    @MainActor
    func testCopyToastPanelDoesNotAddRectangularWindowShadow() {
        let panel = MacClippyToastPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 40))
        defer { panel.close() }

        XCTAssertFalse(panel.hasShadow)
        XCTAssertFalse(panel.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(panel.level.rawValue, NSWindow.Level.mainMenu.rawValue)
    }

    func testKeyboardOwnershipRestoresOnlyPickerAndPreviewModes() {
        XCTAssertTrue(
            MacClippyDockKeyboardOwnershipPolicy.shouldRestoreKeyboard(
                for: .picker,
                isVisible: true,
                isClosing: false
            )
        )
        XCTAssertTrue(
            MacClippyDockKeyboardOwnershipPolicy.shouldRestoreKeyboard(
                for: .preview,
                isVisible: true,
                isClosing: false
            )
        )
        XCTAssertTrue(
            MacClippyDockKeyboardOwnershipPolicy.shouldRestoreKeyboard(
                for: .modal,
                isVisible: true,
                isClosing: false
            )
        )
        XCTAssertFalse(
            MacClippyDockKeyboardOwnershipPolicy.shouldRestoreKeyboard(
                for: .search,
                isVisible: true,
                isClosing: false
            )
        )
        XCTAssertFalse(
            MacClippyDockKeyboardOwnershipPolicy.shouldRestoreKeyboard(
                for: .details,
                isVisible: true,
                isClosing: false
            )
        )
        XCTAssertFalse(
            MacClippyDockKeyboardOwnershipPolicy.shouldRestoreKeyboard(
                for: .picker,
                isVisible: true,
                isClosing: true
            )
        )
        XCTAssertFalse(
            MacClippyDockKeyboardOwnershipPolicy.shouldRestoreKeyboard(
                for: .picker,
                isVisible: true,
                isClosing: false,
                isExternalWindowPresented: true
            )
        )
        XCTAssertFalse(
            MacClippyDockKeyboardOwnershipPolicy.shouldRestoreFirstResponder(for: .modal)
        )
    }

    func testMenuBarToggleUsesAppKitVisibilityDuringCloseAnimation() {
        XCTAssertTrue(MacClippyDockTogglePolicy.shouldHide(panelIsVisible: true))
        XCTAssertFalse(MacClippyDockTogglePolicy.shouldHide(panelIsVisible: false))
    }

    @MainActor
    func testPresentRenameCategoryUsesPinboardDetailsAndFreshToken() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyDockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: root))
        let model = MacClippyDockModel(runtime: runtime)
        let pinboard = MacClippyPinboardEntry(board: Pinboard(name: "Work"), items: [])

        model.presentRenameCategory(for: pinboard)
        guard case let .renameCategory(id, firstToken) = model.modal else {
            return XCTFail("expected rename category modal")
        }
        XCTAssertEqual(id, pinboard.id)

        model.presentRenameCategory(for: pinboard)
        guard case let .renameCategory(_, secondToken) = model.modal else {
            return XCTFail("expected rename category modal")
        }
        XCTAssertNotEqual(firstToken, secondToken)
    }

    @MainActor
    func testPresentConfirmDeleteCategoryUsesPinboardDetails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyDockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: root))
        let model = MacClippyDockModel(runtime: runtime)
        let pinboard = MacClippyPinboardEntry(board: Pinboard(name: "Personal"), items: [])

        model.presentConfirmDeleteCategory(for: pinboard)
        guard case let .confirmDeleteCategory(id, name, _) = model.modal else {
            return XCTFail("expected confirm delete category modal")
        }
        XCTAssertEqual(id, pinboard.id)
        XCTAssertEqual(name, "Personal")
    }

    func testPickerRouterConsumesInputIndependentlyOfFirstResponder() {
        XCTAssertEqual(
            MacClippyDockKeyRouterPolicy.action(
                for: .keyDown(keyCode: 0, characters: "a", modifiers: [], isRepeat: false),
                mode: .picker,
                hasCardFocus: true,
                hasMultipleSelection: false
            ),
            .appendSearch("a")
        )
        XCTAssertEqual(
            MacClippyDockKeyRouterPolicy.action(
                for: .keyDown(keyCode: 49, characters: " ", modifiers: [], isRepeat: false),
                mode: .picker,
                hasCardFocus: true,
                hasMultipleSelection: false
            ),
            .showPreview
        )
        XCTAssertEqual(
            MacClippyDockKeyRouterPolicy.action(
                for: .keyDown(keyCode: 124, characters: nil, modifiers: [], isRepeat: false),
                mode: .picker,
                hasCardFocus: true,
                hasMultipleSelection: false
            ),
            .moveFocus(.right)
        )
    }

    func testPreviewHighlightFollowsFocusInsteadOfLeavingSelectionHighlightBehind() {
        XCTAssertTrue(
            MacClippyDockCardHighlightPolicy.isActive(
                isFocused: true,
                isSelected: false,
                isPreviewVisible: true
            )
        )
        XCTAssertFalse(
            MacClippyDockCardHighlightPolicy.isActive(
                isFocused: false,
                isSelected: true,
                isPreviewVisible: true
            )
        )
        XCTAssertTrue(
            MacClippyDockCardHighlightPolicy.isActive(
                isFocused: false,
                isSelected: true,
                isPreviewVisible: false
            )
        )
    }

    func testPickerRoutingUsesInteractionModeInsteadOfWindowResponder() {
        XCTAssertEqual(
            MacClippyDockKeyRouterPolicy.action(
                for: .keyDown(keyCode: 49, characters: " ", modifiers: [], isRepeat: false),
                mode: .picker,
                hasCardFocus: true,
                hasMultipleSelection: false
            ),
            .showPreview
        )
        XCTAssertEqual(
            MacClippyDockKeyRouterPolicy.action(
                for: .keyDown(keyCode: 49, characters: " ", modifiers: [], isRepeat: false),
                mode: .search,
                hasCardFocus: true,
                hasMultipleSelection: false
            ),
            .native
        )
    }

    func testModalRoutingLeavesPrintableInputToModalTextField() {
        XCTAssertEqual(
            MacClippyDockKeyRouterPolicy.action(
                for: .keyDown(keyCode: 35, characters: "p", modifiers: [], isRepeat: false),
                mode: .modal,
                hasCardFocus: true,
                hasMultipleSelection: false
            ),
            .native
        )
        XCTAssertEqual(
            MacClippyDockKeyRouterPolicy.action(
                for: .keyUp(keyCode: 35, modifiers: []),
                mode: .modal,
                hasCardFocus: true,
                hasMultipleSelection: false
            ),
            .native
        )
    }

    // The double-click copy indicator surfaces through .copied(plain: false)
    // (plain copy is reserved for text-only representations). Asserting the
    // exact title/image keeps the indicator path stable across dock changes.
    func testCopiedFeedbackWithPlainFalseHasCopiedTitleAndCheckmarkImage() {
        let feedback = MacClippyDockActionFeedback.copied(plain: false)
        XCTAssertEqual(feedback.title, "Copied")
        XCTAssertEqual(feedback.systemImage, "checkmark.circle.fill")
    }

    // A single movie URL is promoted to a video preview; a single non-video
    // file and any multi-URL selection stay on the file list. This keeps the
    // pasted-file preview picking the right surface without surprising users.
    func testPreviewContentPolicyRoutesVideoVersusFiles() {
        let video = MacClippyDockPreviewContentPolicy.content(forFiles: [URL(fileURLWithPath: "/tmp/clip.mp4")])
        if case let .video(url) = video {
            XCTAssertEqual(url.path, "/tmp/clip.mp4")
        } else {
            XCTFail("expected .video for a single movie URL, got \(video)")
        }

        let image = MacClippyDockPreviewContentPolicy.content(forFiles: [URL(fileURLWithPath: "/tmp/photo.png")])
        if case let .files(urls) = image {
            XCTAssertEqual(urls.count, 1)
            XCTAssertEqual(urls.first?.path, "/tmp/photo.png")
        } else {
            XCTFail("expected .files for a non-video image URL, got \(image)")
        }

        let multiple = MacClippyDockPreviewContentPolicy.content(forFiles: [
            URL(fileURLWithPath: "/tmp/clip.mp4"),
            URL(fileURLWithPath: "/tmp/photo.png")
        ])
        if case let .files(urls) = multiple {
            XCTAssertEqual(urls.count, 2)
        } else {
            XCTFail("expected .files for multiple URLs including a movie, got \(multiple)")
        }
    }

    func testCodePolicyKeepsBuildOutputOnTheReadableSurface() {
        let buildOutput = """
        -normal/arm64/
        MacClippy.LinkFileList
        -install_name @rpath/MacClippy.debug.dylib -Xlinker /usr/lib/swift
        """

        XCTAssertFalse(MacClippyDockCodePolicy.isCode(buildOutput))
    }

    func testCodePolicyStillRecognizesSourceCode() {
        XCTAssertTrue(
            MacClippyDockCodePolicy.isCode("""
            func greet() {
                return \"hello\";
            }
            """)
        )
    }

    func testCodePolicyKeepsPromptWithParenthesesAndTimestampsReadable() {
        XCTAssertFalse(
            MacClippyDockCodePolicy.isCode("""
            Structure: 3-shot sequence (Start Scene → Insert Close-up → Lab Scene).
            SHOT 1: Camera lock (00:00.000–00:03.000).
            """)
        )
    }

    func testPreviewTextPolicyBoundsOnlyTheRenderedPayload() {
        let text = String(repeating: "x", count: MacClippyDockPreviewTextPolicy.maxRenderedCharacters + 10)
        let rendered = MacClippyDockPreviewTextPolicy.displayText(for: text)

        XCTAssertEqual(
            String(rendered.prefix(MacClippyDockPreviewTextPolicy.maxRenderedCharacters)),
            String(text.prefix(MacClippyDockPreviewTextPolicy.maxRenderedCharacters))
        )
        XCTAssertTrue(rendered.contains("10 more characters"))
    }

    func testCategoryRailOnlyShowsPositiveCounts() {
        XCTAssertNil(MacClippyDockCategoryRailPolicy.countLabel(for: 0))
        XCTAssertNil(MacClippyDockCategoryRailPolicy.countLabel(for: -1))
        XCTAssertEqual(MacClippyDockCategoryRailPolicy.countLabel(for: 7), "7")
    }

    func testPinResolverPrefersSelectedBoardAndHidesWhenNoBoardExists() throws {
        let firstItem = try historyEntry()
        let secondItem = try historyEntry()
        let firstBoard = Pinboard(name: "Work", itemIDs: [firstItem.id])
        let secondBoard = Pinboard(name: "Personal", itemIDs: [secondItem.id])
        let boards = [
            MacClippyPinboardEntry(board: firstBoard, items: [firstItem]),
            MacClippyPinboardEntry(board: secondBoard, items: [secondItem])
        ]

        XCTAssertEqual(
            MacClippyDockPinResolver.action(for: firstItem.id, selectedTab: .pinboard(secondBoard.id), pinboards: boards),
            .unpin(boardName: "Work")
        )
        XCTAssertEqual(
            MacClippyDockPinResolver.action(for: firstItem.id, selectedTab: .history, pinboards: boards),
            .unpin(boardName: "Work")
        )
        XCTAssertEqual(
            MacClippyDockPinResolver.action(for: RecordID.generate(), selectedTab: .history, pinboards: boards),
            .pin(boardName: "Work")
        )
        XCTAssertNil(MacClippyDockPinResolver.action(for: firstItem.id, selectedTab: .history, pinboards: []))
    }

    func testHistoryEntryOnlyOffersPlainCopyForTextRepresentations() throws {
        let text = try historyEntry(kind: .text)
        let image = try historyEntry(kind: .image)
        let files = try historyEntry(kind: .files)

        XCTAssertTrue(text.supportsPlainCopy)
        XCTAssertFalse(image.supportsPlainCopy)
        XCTAssertFalse(files.supportsPlainCopy)
        XCTAssertTrue(image.isPasteable)
        XCTAssertTrue(files.isPasteable)
    }

    private func historyEntry(kind: ContentKind = .text) throws -> MacClippyHistoryEntry {
        MacClippyHistoryEntry(
            meta: ClipboardItemMeta(
                id: .generate(),
                created: Date(),
                modified: Date(),
                deviceID: try XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                lamport: 1,
                preview: "item"
            ),
            contentKind: kind,
            preview: "item"
        )
    }
}
