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
        XCTAssertFalse(
            MacClippyDockKeyboardOwnershipPolicy.shouldRestoreKeyboard(
                for: .preview,
                isVisible: true,
                isClosing: false,
                isSystemQuickLookVisible: true
            )
        )
    }

    func testMenuBarToggleUsesAppKitVisibilityDuringCloseAnimation() {
        XCTAssertTrue(MacClippyDockTogglePolicy.shouldHide(panelIsVisible: true))
        XCTAssertFalse(MacClippyDockTogglePolicy.shouldHide(panelIsVisible: false))
    }

    func testStatusItemToggleDoesNotReopenAPanelThatThisClickAlreadyHid() {
        XCTAssertEqual(
            MacClippyDockTogglePolicy.action(
                source: .statusItem,
                panelIsVisible: true,
                isClosing: true
            ),
            .ignore
        )
        XCTAssertEqual(
            MacClippyDockTogglePolicy.action(
                source: .hotKey,
                panelIsVisible: true,
                isClosing: true
            ),
            .show
        )
        XCTAssertEqual(
            MacClippyDockTogglePolicy.action(
                source: .statusItem,
                panelIsVisible: true,
                isClosing: false
            ),
            .hide
        )
        XCTAssertEqual(
            MacClippyDockTogglePolicy.action(
                source: .statusItem,
                panelIsVisible: false,
                isClosing: false
            ),
            .show
        )
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

    // Movie URLs stay on `.files`. SwiftUI VideoPlayer is not a content case;
    // AppKit Quick Look renders the existing path instead.
    func testPreviewContentPolicyKeepsMoviesOnTheFileSurface() {
        let video = MacClippyDockPreviewContentPolicy.content(forFiles: [URL(fileURLWithPath: "/tmp/clip.mp4")])
        if case let .files(urls) = video {
            XCTAssertEqual(urls.map(\.path), ["/tmp/clip.mp4"])
        } else {
            XCTFail("expected .files for a single movie URL, got \(video)")
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

    func testPreviewFileSurfaceUsesFirstExistingPathForNativeQuickLook() throws {
        let missing = URL(fileURLWithPath: "/tmp/macclippy-missing-\(UUID().uuidString).mp4")
        XCTAssertNil(MacClippyDockPreviewFileSurface.nativePreviewURL(in: [missing]))
        XCTAssertNil(MacClippyDockPreviewFileSurface.nativePreviewURL(in: []))

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("macclippy-ql-\(UUID().uuidString).png")
        try Data([0x89, 0x50]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(MacClippyDockPreviewFileSurface.nativePreviewURL(in: [file])?.path, file.path)
        XCTAssertEqual(
            MacClippyDockPreviewFileSurface.nativePreviewURL(in: [missing, file])?.path,
            file.path
        )
        XCTAssertEqual(
            MacClippySystemQuickLookPolicy.existingFileURLs(in: [missing, file]).map(\.path),
            [file.path]
        )
        XCTAssertFalse(
            MacClippySystemQuickLookPolicy.prefersSystemQuickLook(
                contentKind: .files,
                fileURLs: [file]
            ),
            "Raster images must stay in the in-app panel; QLPreviewPanel freezes fullscreen Spaces"
        )
        XCTAssertFalse(
            MacClippySystemQuickLookPolicy.prefersSystemQuickLook(
                contentKind: .files,
                fileURLs: [missing]
            )
        )
        XCTAssertFalse(
            MacClippySystemQuickLookPolicy.prefersSystemQuickLook(
                contentKind: .image,
                fileURLs: [file]
            )
        )
        XCTAssertFalse(
            MacClippySystemQuickLookPolicy.prefersSystemQuickLook(
                contentKind: .text,
                fileURLs: []
            )
        )
    }

    func testSystemQuickLookSkipsImageFilesThatHangFullscreenSpaces() throws {
        let jpeg = FileManager.default.temporaryDirectory
            .appendingPathComponent("macclippy-wechat-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF]).write(to: jpeg)
        defer { try? FileManager.default.removeItem(at: jpeg) }

        XCTAssertFalse(
            MacClippySystemQuickLookPolicy.prefersSystemQuickLook(
                contentKind: .files,
                fileURLs: [jpeg]
            )
        )

        let pdf = FileManager.default.temporaryDirectory
            .appendingPathComponent("macclippy-doc-\(UUID().uuidString).pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        defer { try? FileManager.default.removeItem(at: pdf) }
        XCTAssertFalse(
            MacClippySystemQuickLookPolicy.prefersSystemQuickLook(
                contentKind: .files,
                fileURLs: [pdf]
            ),
            "Documents must stay in the in-app overlay. QLPreviewPanel sits below the dock window and Space looks like a no-op."
        )
    }

    func testSystemQuickLookDoesNotCaptureSpreadsheetFiles() throws {
        let xlsx = FileManager.default.temporaryDirectory
            .appendingPathComponent("macclippy-sheet-\(UUID().uuidString).xlsx")
        try Data("PK".utf8).write(to: xlsx)
        defer { try? FileManager.default.removeItem(at: xlsx) }

        XCTAssertEqual(MacClippyFilePresentation.mediaKind(for: xlsx), .other)
        XCTAssertFalse(
            MacClippySystemQuickLookPolicy.prefersSystemQuickLook(
                contentKind: .files,
                fileURLs: [xlsx]
            )
        )
        XCTAssertEqual(
            MacClippyDockPreviewFileSurface.nativePreviewURL(in: [xlsx])?.path,
            xlsx.path
        )
    }

    func testFileThumbnailPolicyUsesImageIOForRasterImages() {
        XCTAssertTrue(
            MacClippyFileThumbnailPolicy.usesImageIO(
                for: URL(fileURLWithPath: "/Users/me/Library/WeChat/c133.jpg")
            )
        )
        XCTAssertFalse(
            MacClippyFileThumbnailPolicy.usesImageIO(
                for: URL(fileURLWithPath: "/tmp/passport.pdf")
            )
        )
    }

    func testFileThumbnailLoaderDecodesJPEGWithoutQuickLook() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macclippy-thumb-\(UUID().uuidString).jpg")
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 8, height: 8)).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [:]) else {
            return XCTFail("could not encode jpeg")
        }
        try jpeg.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = await MacClippyFileThumbnailLoader.image(
            for: url,
            pointSize: CGSize(width: 16, height: 16)
        )
        XCTAssertNotNil(loaded)
    }

    func testSystemQuickLookArrowSwitchReloadsWithoutStealingKeyboard() {
        XCTAssertEqual(
            MacClippySystemQuickLookPresentationPolicy.action(panelIsVisible: false),
            .open
        )
        XCTAssertEqual(
            MacClippySystemQuickLookPresentationPolicy.action(panelIsVisible: true),
            .reload
        )
        XCTAssertFalse(
            MacClippySystemQuickLookPresentationPolicy.shouldTakeDockKeyboard(for: .open)
        )
        XCTAssertFalse(
            MacClippySystemQuickLookPresentationPolicy.shouldTakeDockKeyboard(for: .reload)
        )
        XCTAssertFalse(
            MacClippyDockKeyboardOwnershipPolicy.shouldTakeKeyboardOwnership(
                isSystemQuickLookVisible: true
            )
        )
        XCTAssertTrue(
            MacClippyDockKeyboardOwnershipPolicy.shouldTakeKeyboardOwnership(
                isSystemQuickLookVisible: false
            )
        )
    }

    func testSystemQuickLookEndDoesNotDropPreviewDuringProgrammaticClose() {
        XCTAssertFalse(
            MacClippySystemQuickLookPresentationPolicy.shouldExitPreviewOnEnd(
                isProgrammaticClose: true,
                customPreviewVisible: false
            )
        )
        XCTAssertFalse(
            MacClippySystemQuickLookPresentationPolicy.shouldExitPreviewOnEnd(
                isProgrammaticClose: false,
                customPreviewVisible: true
            )
        )
        XCTAssertTrue(
            MacClippySystemQuickLookPresentationPolicy.shouldExitPreviewOnEnd(
                isProgrammaticClose: false,
                customPreviewVisible: false
            )
        )
    }

    func testPreviewSurfaceSwitchSkipsQuickLookZoomAndLoadingReset() {
        XCTAssertEqual(MacClippyPreviewSurfacePolicy.transition(isOpening: true), .openSession)
        XCTAssertEqual(MacClippyPreviewSurfacePolicy.transition(isOpening: false), .switchSurface)

        XCTAssertTrue(MacClippyPreviewSurfacePolicy.shouldAnimateSystemQuickLook(for: .openSession))
        XCTAssertTrue(MacClippyPreviewSurfacePolicy.shouldAnimateSystemQuickLook(for: .closeSession))
        XCTAssertFalse(MacClippyPreviewSurfacePolicy.shouldAnimateSystemQuickLook(for: .switchSurface))

        XCTAssertFalse(MacClippyPreviewSurfacePolicy.shouldResetCustomPreviewToLoading(for: .switchSurface))
        XCTAssertTrue(MacClippyPreviewSurfacePolicy.shouldResetCustomPreviewToLoading(for: .closeSession))
        XCTAssertFalse(MacClippyPreviewSurfacePolicy.shouldResetCustomPreviewToLoading(for: .openSession))

        XCTAssertEqual(
            MacClippyPreviewSurfacePolicy.keyboardOwnershipRetryLimit(for: .switchSurface),
            0
        )
        XCTAssertEqual(
            MacClippyPreviewSurfacePolicy.keyboardOwnershipRetryLimit(for: .openSession),
            3
        )
        XCTAssertEqual(
            MacClippyPreviewSurfacePolicy.keyboardOwnershipRetryLimit(for: .closeSession),
            3
        )
        XCTAssertEqual(
            MacClippyPreviewSurfacePolicy.quickLookAnimationBehavior(animated: true),
            .default
        )
        XCTAssertEqual(
            MacClippyPreviewSurfacePolicy.quickLookAnimationBehavior(animated: false),
            .none
        )
    }

    func testSystemQuickLookForwardsPickerNavigationKeys() {
        XCTAssertTrue(MacClippySystemQuickLookEventPolicy.shouldHandleInPicker(keyCode: 123))
        XCTAssertTrue(MacClippySystemQuickLookEventPolicy.shouldHandleInPicker(keyCode: 124))
        XCTAssertTrue(MacClippySystemQuickLookEventPolicy.shouldHandleInPicker(keyCode: 49))
        XCTAssertTrue(MacClippySystemQuickLookEventPolicy.shouldHandleInPicker(keyCode: 36))
        XCTAssertTrue(MacClippySystemQuickLookEventPolicy.shouldHandleInPicker(keyCode: 76))
        XCTAssertTrue(MacClippySystemQuickLookEventPolicy.shouldHandleInPicker(keyCode: 53))
        XCTAssertFalse(MacClippySystemQuickLookEventPolicy.shouldHandleInPicker(keyCode: 0))
    }

    func testPreviewFileSurfaceUsesInlineVideoControlsForMoviesOnly() {
        XCTAssertTrue(
            MacClippyDockPreviewFileSurface.usesInlineVideoControls(
                for: URL(fileURLWithPath: "/tmp/clip.mp4")
            )
        )
        XCTAssertTrue(
            MacClippyDockPreviewFileSurface.usesInlineVideoControls(
                for: URL(fileURLWithPath: "/tmp/clip.mov")
            )
        )
        XCTAssertFalse(
            MacClippyDockPreviewFileSurface.usesInlineVideoControls(
                for: URL(fileURLWithPath: "/tmp/photo.png")
            )
        )
        XCTAssertFalse(
            MacClippyDockPreviewFileSurface.usesInlineVideoControls(
                for: URL(fileURLWithPath: "/tmp/notes.pdf")
            )
        )
        XCTAssertEqual(MacClippyVideoClock.string(0), "0:00")
        XCTAssertEqual(MacClippyVideoClock.string(65), "1:05")
        XCTAssertEqual(MacClippyVideoClock.string(3661), "1:01:01")
    }

    func testPreviewFilesFooterUsesFileCountNotCharacterCount() {
        let content = MacClippyDockPreviewContent.files([URL(fileURLWithPath: "/tmp/passport.pdf")])
        XCTAssertNil(content.footerText(characterCount: 9))
        XCTAssertEqual(MacClippyFilePresentation.title(fileCount: 1), "1 file")
        XCTAssertEqual(
            MacClippyFilePresentation.displayPath(for: URL(fileURLWithPath: "/tmp/passport.pdf")),
            "/tmp/passport.pdf"
        )
    }

    func testCodePolicyKeepsBuildOutputOnTheReadableSurface() {
        let buildOutput = """
        -normal/arm64/
        MacClippy.LinkFileList
        -install_name @rpath/MacClippy.debug.dylib -Xlinker /usr/lib/swift
        """

        XCTAssertFalse(MacClippyClipboardPresentation.isCode(buildOutput))
    }

    func testCodePolicyStillRecognizesSourceCode() {
        XCTAssertTrue(
            MacClippyClipboardPresentation.isCode("""
            func greet() {
                return \"hello\";
            }
            """)
        )
    }

    func testCodePolicyKeepsPromptWithParenthesesAndTimestampsReadable() {
        XCTAssertFalse(
            MacClippyClipboardPresentation.isCode("""
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
