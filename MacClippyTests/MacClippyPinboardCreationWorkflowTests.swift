import AppKit
import MacClippyCore
import MacClippyPlatform
import XCTest

@testable import MacClippy

final class MacClippyPinboardCreationWorkflowTests: XCTestCase {
    private var root: URL!
    private var board: NSPasteboard!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacClippyPinboardCreation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        board = NSPasteboard(name: .init("MacClippyPinboardCreation-\(UUID())"))
        board.setString("unchanged", forType: .string)
        runtime = try MacClippyRuntime(
            paths: MacClippyPaths(rootURL: root),
            pasteInjector: MacClippyPasteInjector(pasteboard: board, isProcessTrusted: { false }),
            enableSnippetExpansion: false)
        MacClippyMainHop.setCaptureForTesting(true)
    }

    override func tearDownWithError() throws {
        runtime.closeForTesting()
        try FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testSubmittingPinboardConsumesEscapeAndDuplicateSubmissionUntilItFinishes() throws {
        let controller = MacClippyDockController(runtime: runtime)
        controller.panel = MacClippyDockPanel(contentRect: NSRect(x: 100, y: 100, width: 800, height: 360))
        controller.panel?.animationBehavior = .none
        controller.panel?.orderFrontRegardless()
        controller.interactionMode = .modal
        defer { controller.cleanup() }
        let model = controller.model
        model.query = "invoice type:text"
        let token = try openCreateModal(model)
        let gate = blockQueue(model)
        defer { gate.signal() }
        var completions = 0
        model.createPinboard(name: "  Work  ", color: "#007AFF", modalToken: token) { succeeded in
            XCTAssertTrue(succeeded)
            completions += 1
        }
        model.createPinboard(name: "Duplicate", color: "#007AFF", modalToken: token) { _ in
            XCTFail("Duplicate submission must not finish the current editor")
        }
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: controller.panel?.windowNumber ?? 0, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertNil(controller.routeKeyEvent(escape))
        XCTAssertEqual(model.modal, .createCategory(token: token))
        XCTAssertTrue(model.isCreatingPinboard)
        XCTAssertEqual(completions, 0)
        finishQueue(model, gate: gate)
        XCTAssertEqual(completions, 1)
        XCTAssertNil(model.modal)
        XCTAssertFalse(model.isCreatingPinboard)
        let created = try XCTUnwrap(runtime.pinboards().first)
        XCTAssertEqual(created.name, "Work")
        XCTAssertEqual(try runtime.pinboards().count, 1)
        XCTAssertEqual(model.selectedTab, .pinboard(created.id))
        XCTAssertEqual(model.query, "invoice type:text")
        XCTAssertEqual(board.string(forType: .string), "unchanged")
    }

    @MainActor
    func testLateCreationDoesNotDismissReplacementModalOrChangeItsScope() throws {
        let model = MacClippyDockModel(runtime: runtime)
        model.query = "invoice type:text"
        let token = try openCreateModal(model)
        let gate = blockQueue(model)
        defer { gate.signal() }
        model.createPinboard(name: "Old", color: "#007AFF", modalToken: token) { _ in
            XCTFail("A replaced editor must not receive the old completion")
        }
        let replacement = try openCreateModal(model)
        finishQueue(model, gate: gate)
        XCTAssertEqual(model.modal, .createCategory(token: replacement))
        XCTAssertEqual(model.selectedTab, .history)
        XCTAssertEqual(model.query, "invoice type:text")
        XCTAssertNil(model.actionError)
        XCTAssertFalse(model.isCreatingPinboard)
        XCTAssertEqual(try runtime.pinboards().map(\.name), ["Old"])
    }

    @MainActor
    func testOldCompletionCannotClearNewPinboardSubmission() throws {
        let model = MacClippyDockModel(runtime: runtime)
        let firstToken = try openCreateModal(model)
        let firstGate = blockQueue(model)
        defer { firstGate.signal() }
        model.createPinboard(name: "Old", color: "#007AFF", modalToken: firstToken) { _ in
            XCTFail("A superseded operation must not receive a completion")
        }
        let secondGate = blockQueue(model)
        defer { secondGate.signal() }
        let secondToken = try openCreateModal(model)
        var completed = false
        model.createPinboard(name: "New", color: "#007AFF", modalToken: secondToken) { succeeded in
            completed = succeeded
        }
        firstGate.signal()
        MacClippyTestWait.until({ (try? self.runtime.pinboards().count) == 1 }, failOnTimeout: true)
        MacClippyMainHop.flushCapturedWork()
        XCTAssertEqual(model.modal, .createCategory(token: secondToken))
        XCTAssertTrue(model.isCreatingPinboard)
        XCTAssertFalse(completed)
        XCTAssertEqual(model.selectedTab, .history)
        finishQueue(model, gate: secondGate)
        XCTAssertTrue(completed)
        XCTAssertNil(model.modal)
        XCTAssertFalse(model.isCreatingPinboard)
        let created = try XCTUnwrap(runtime.pinboards().first { $0.name == "New" })
        XCTAssertEqual(model.selectedTab, .pinboard(created.id))
    }

    @MainActor
    func testLateCreationFromClosedSessionCannotAffectReopenedEditor() throws {
        let model = MacClippyDockModel(runtime: runtime)
        model.beginSession()
        let token = try openCreateModal(model)
        let gate = blockQueue(model)
        defer { gate.signal() }
        model.createPinboard(name: "Old session", color: "#007AFF", modalToken: token) { _ in
            XCTFail("The closed session must not receive the creation callback")
        }
        model.endSession()
        model.beginSession()
        model.query = "new query"
        let replacement = try openCreateModal(model)
        finishQueue(model, gate: gate)
        XCTAssertEqual(model.modal, .createCategory(token: replacement))
        XCTAssertEqual(model.selectedTab, .history)
        XCTAssertEqual(model.query, "new query")
        XCTAssertFalse(model.isCreatingPinboard)
        XCTAssertNil(model.actionError)
    }

    @MainActor
    private func openCreateModal(_ model: MacClippyDockModel) throws -> UInt {
        model.presentCreateCategory()
        let token: UInt?
        if case let .createCategory(value)? = model.modal { token = value } else { token = nil }
        return try XCTUnwrap(token)
    }

    @MainActor
    private func blockQueue(_ model: MacClippyDockModel) -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        model.workQueue.async { gate.wait() }
        return gate
    }

    @MainActor
    private func finishQueue(_ model: MacClippyDockModel, gate: DispatchSemaphore) {
        gate.signal()
        model.workQueue.sync {}
        MacClippyMainHop.flushCapturedWork()
        model.workQueue.sync {}
        MacClippyMainHop.flushCapturedWork()
    }
}
