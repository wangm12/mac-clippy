import XCTest
import AppKit

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippyDockTests: XCTestCase {
    @MainActor
    func testDockPanelJoinsFullScreenSpacesWithoutActivatingHostApp() {
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240))
        defer {
            panel.animationBehavior = .none
            panel.orderOut(nil)
        }

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertEqual(panel.level.rawValue, NSWindow.Level.mainMenu.rawValue)
        XCTAssertEqual(panel.animationBehavior, .none)
    }

    @MainActor
    func testSearchFieldAcceptsNativeTextThroughThePanelFieldEditor() {
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80))
        let field = MacClippyIMESearchField(frame: NSRect(x: 12, y: 12, width: 296, height: 28))
        panel.contentView = field
        panel.makeKeyAndOrderFront(nil)
        defer {
            panel.animationBehavior = .none
            panel.orderOut(nil)
        }

        XCTAssertTrue(panel.makeFirstResponder(field))
        guard let editor = field.currentEditor() else {
            return XCTFail("search field did not acquire a field editor")
        }

        editor.insertText("abc")

        XCTAssertEqual(editor.string, "abc")
        XCTAssertEqual(field.stringValue, "abc")

        field.stringValue = ""

        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(field.stringValue, "")
    }

    @MainActor
    func testSearchFieldPublishesOnlyAfterNativeMarkedTextCommits() {
        var commits: [String] = []
        var compositionStates: [Bool] = []
        let representable = MacClippyAppKitSearchField(
            committedQuery: "",
            isFocused: true,
            collapseToken: 0,
            programmaticSyncToken: 0,
            onCommit: { commits.append($0) },
            onFocusChange: { _ in },
            onCompositionChange: { compositionStates.append($0) },
            onSubmit: {}
        )
        let coordinator = representable.makeCoordinator()
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80))
        let field = MacClippyIMESearchField(frame: NSRect(x: 12, y: 12, width: 296, height: 28))
        field.delegate = coordinator
        coordinator.attach(to: field, parent: representable)
        panel.contentView = field
        panel.makeKeyAndOrderFront(nil)
        defer {
            panel.animationBehavior = .none
            panel.orderOut(nil)
        }

        XCTAssertTrue(panel.makeFirstResponder(field))
        guard let editor = field.currentEditor() as? NSTextView else {
            return XCTFail("search field did not acquire a native text editor")
        }

        editor.setMarkedText(
            "ce",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertTrue(commits.isEmpty)
        XCTAssertEqual(compositionStates.last, true)

        editor.insertText("测试", replacementRange: editor.markedRange())

        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(field.stringValue, "测试")
        XCTAssertEqual(commits.last, "测试")
        XCTAssertEqual(compositionStates.last, false)
    }

    @MainActor
    func testSearchKeepsOverlayAboveTheSystemDockAfterFocusAndComposition() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyDockInputTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: root))
        defer { runtime.closeForTesting() }
        let controller = MacClippyDockController(runtime: runtime)
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80))
        controller.panel = panel
        panel.makeKeyAndOrderFront(nil)
        defer {
            panel.animationBehavior = .none
            panel.orderOut(nil)
        }

        controller.enterSearchMode()
        controller.isFullscreenSearchHost = false
        controller.applyOverlayLevel(allowsInputMethodCandidates: false)

        XCTAssertEqual(panel.level, .mainMenu)
        XCTAssertTrue(panel.isFloatingPanel)

        controller.applyOverlayLevel(allowsInputMethodCandidates: true)
        XCTAssertEqual(panel.level, .mainMenu)
        XCTAssertGreaterThan(panel.level.rawValue, Int(CGWindowLevelForKey(.dockWindow)))
        XCTAssertTrue(panel.isFloatingPanel)

        panel.level = .floating
        controller.applyOverlayLevel(allowsInputMethodCandidates: true)
        XCTAssertEqual(panel.level, .mainMenu)
        XCTAssertTrue(panel.isFloatingPanel)
    }

    @MainActor
    func testSearchFieldFocusReassertsOverlayAboveTheSystemDock() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyDockFocusOverlay-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: root))
        defer { runtime.closeForTesting() }
        let controller = MacClippyDockController(runtime: runtime)
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80))
        let field = MacClippyIMESearchField(frame: NSRect(x: 12, y: 12, width: 296, height: 28))
        panel.contentView = field
        controller.panel = panel
        panel.makeKeyAndOrderFront(nil)
        defer {
            panel.animationBehavior = .none
            panel.orderOut(nil)
        }

        controller.enterSearchMode()
        controller.isFullscreenSearchHost = false
        controller.applyOverlayLevel(allowsInputMethodCandidates: false)
        XCTAssertTrue(panel.makeFirstResponder(field))
        if let editor = field.currentEditor() {
            XCTAssertTrue(panel.makeFirstResponder(editor))
        }

        XCTAssertEqual(panel.level, .mainMenu)
        XCTAssertGreaterThan(panel.level.rawValue, Int(CGWindowLevelForKey(.dockWindow)))

        panel.level = .floating
        XCTAssertTrue(panel.makeFirstResponder(field))
        XCTAssertEqual(panel.level, .mainMenu)
        XCTAssertGreaterThan(panel.level.rawValue, Int(CGWindowLevelForKey(.dockWindow)))

        panel.level = .floating
        panel.makeKeyAndOrderFront(nil)
        XCTAssertEqual(panel.level, .mainMenu)
        XCTAssertGreaterThan(panel.level.rawValue, Int(CGWindowLevelForKey(.dockWindow)))
    }

    @MainActor
    func testFullscreenSearchYieldsOverlayToInputMethodCandidates() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyDockFullscreenIME-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: root))
        defer { runtime.closeForTesting() }
        let controller = MacClippyDockController(runtime: runtime)
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80))
        let field = MacClippyIMESearchField(frame: NSRect(x: 12, y: 12, width: 296, height: 28))
        panel.contentView = field
        controller.panel = panel
        panel.makeKeyAndOrderFront(nil)
        defer {
            panel.animationBehavior = .none
            panel.orderOut(nil)
        }

        controller.isFullscreenSearchHost = true
        controller.interactionMode = .search
        controller.applyOverlayLevel(allowsInputMethodCandidates: false)

        let yielded = NSWindow.Level.floating
        XCTAssertEqual(panel.level, yielded)
        XCTAssertEqual(panel.pinnedOverlayLevel, yielded)
        XCTAssertTrue(panel.collectionBehavior.contains(.moveToActiveSpace))
        XCTAssertFalse(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.isFloatingPanel)

        panel.level = .floating
        XCTAssertTrue(panel.makeFirstResponder(field))
        XCTAssertEqual(panel.level, yielded)

        panel.level = .mainMenu
        panel.makeKeyAndOrderFront(nil)
        XCTAssertEqual(panel.level, yielded)
    }

    @MainActor
    func testLeavingSearchClearsTheQueryInsteadOfInheritingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyDockSearchDismiss-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: root))
        defer { runtime.closeForTesting() }
        let controller = MacClippyDockController(runtime: runtime)
        controller.interactionMode = .search
        controller.model.query = "测试"

        controller.enterPickerMode()

        XCTAssertEqual(controller.interactionMode, .picker)
        XCTAssertEqual(controller.model.query, "")
    }

    @MainActor
    func testInputMethodHandoffFocusesTheNativeEditorBeforeReturningTheFirstKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyDockHandoffTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: root))
        defer { runtime.closeForTesting() }
        let controller = MacClippyDockController(runtime: runtime)
        let panel = MacClippyDockPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80))
        let field = MacClippyIMESearchField(frame: NSRect(x: 12, y: 12, width: 296, height: 28))
        panel.contentView = field
        controller.panel = panel
        panel.makeKeyAndOrderFront(nil)
        defer {
            panel.animationBehavior = .none
            panel.orderOut(nil)
        }

        XCTAssertFalse(controller.applyKeyAction(.handOffSearchToInputMethod))
        XCTAssertEqual(controller.interactionMode, .search)
        guard let editor = field.currentEditor() else {
            return XCTFail("input-method handoff did not synchronously focus the native editor")
        }
        XCTAssertTrue(panel.firstResponder === editor)

        editor.insertText("c")

        XCTAssertEqual(field.stringValue, "c")
    }

    @MainActor
    func testCopyToastPanelDoesNotAddRectangularWindowShadow() {
        let panel = MacClippyToastPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 40))
        defer {
            panel.animationBehavior = .none
            panel.orderOut(nil)
        }

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
        XCTAssertTrue(
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

    func testFileThumbnailLoaderDecodesJPEGWithoutQuickLook() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macclippy-thumb-\(UUID().uuidString).jpg")
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 8,
            pixelsHigh: 8,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let rep else {
            return XCTFail("could not allocate bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.red.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 8, height: 8)).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = rep.representation(using: .jpeg, properties: [:]) else {
            return XCTFail("could not encode jpeg")
        }
        try jpeg.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = waitForFileThumbnail(
            url: url,
            pointSize: CGSize(width: 16, height: 16)
        )
        XCTAssertNotNil(loaded)
        XCTAssertNotNil(
            MacClippyFileThumbnailLoader.cachedImage(
                for: url,
                pointSize: CGSize(width: 16, height: 16)
            )
        )
    }

    func testFileThumbnailTaskKeepsPixelsOnSameIdentity() throws {
        let files = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("MacClippy/MacClippyFileThumbnailLoader.swift"),
            encoding: .utf8
        )
        guard let start = files.range(of: "struct MacClippyFileThumbnail"),
              let end = files.range(of: "enum MacClippyFileByteCount") else {
            return XCTFail("MacClippyFileThumbnail is missing")
        }
        let thumbnail = String(files[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(thumbnail.contains("MacClippyThumbnailDisplayPolicy.displayed"))
        XCTAssertTrue(thumbnail.contains("MacClippyFileThumbnailLoader.cacheKey"))
        XCTAssertFalse(thumbnail.contains("image = nil\n            let loaded"))
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

    private func waitForFileThumbnail(url: URL, pointSize: CGSize) -> CGImage? {
        final class Box: @unchecked Sendable {
            var value: CGImage?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await MacClippyFileThumbnailLoader.image(for: url, pointSize: pointSize)
            semaphore.signal()
        }
        XCTAssertEqual(semaphore.wait(timeout: .now() + 2), .success)
        return box.value
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
