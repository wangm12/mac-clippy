import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippySnippetTests: XCTestCase {
    private var tempRoot: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippySnippetTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        runtime = try MacClippyRuntime(
            paths: try MacClippyPaths(rootURL: tempRoot),
            enableSnippetExpansion: false
        )
    }

    override func tearDownWithError() throws {
        runtime?.closeForTesting()
        runtime = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testCreateSnippetFromTextRecordUsesFirstLineAsName() throws {
        let record = try runtime.appendTestRecord(.text("First line\nSecond line"))

        let snippet = try runtime.createSnippet(from: record.id)

        XCTAssertEqual(snippet.name, "First line")
        XCTAssertEqual(snippet.body, "First line\nSecond line")
        XCTAssertNil(snippet.trigger)
        XCTAssertEqual(try runtime.snippets().map(\.id), [snippet.id])
    }

    func testCreateSnippetConvertsHTMLToPlainText() throws {
        let record = try runtime.appendTestRecord(.html("<p>Hello <strong>world</strong></p>"))

        let snippet = try runtime.createSnippet(from: record.id)

        XCTAssertEqual(snippet.body, "Hello world")
    }

    func testCreateSnippetRejectsImagesAndFiles() throws {
        let image = try runtime.appendTestRecord(.image(blobID: "unused", width: 1, height: 1))
        let files = try runtime.appendTestRecord(.files([URL(fileURLWithPath: "/tmp/example.txt")]))

        XCTAssertThrowsError(try runtime.createSnippet(from: image.id)) { error in
            XCTAssertEqual(error as? MacClippySnippetCreationError, .unsupportedContent)
        }
        XCTAssertThrowsError(try runtime.createSnippet(from: files.id)) { error in
            XCTAssertEqual(error as? MacClippySnippetCreationError, .unsupportedContent)
        }
        XCTAssertTrue(try runtime.snippets().isEmpty)
    }

    func testCreateSnippetManuallyNormalizesTrigger() throws {
        let snippet = try runtime.createSnippet(
            name: "Email",
            trigger: "email",
            body: "Hello from mac-clippy"
        )

        XCTAssertEqual(snippet.name, "Email")
        XCTAssertEqual(snippet.trigger, ";email")
        XCTAssertEqual(snippet.body, "Hello from mac-clippy")
        XCTAssertNil(snippet.folder)
        XCTAssertEqual(try runtime.snippets().map(\.id), [snippet.id])
    }

    func testCreateSnippetPersistsNormalizedFolder() throws {
        let snippet = try runtime.createSnippet(
            name: "Email",
            trigger: nil,
            body: "Hello {{date}}",
            folder: " Work / Email "
        )

        XCTAssertEqual(snippet.folder, "Work/Email")
        XCTAssertEqual(try runtime.snippets().first?.folder, "Work/Email")
    }

    func testCreatedAndDeletedSnippetsRefreshTriggerLookup() throws {
        let outlook = try runtime.createSnippet(name: "Outlook", trigger: "outlook", body: "email@example.test")
        XCTAssertEqual(runtime.snippetLookupSnapshot.body(for: ";outlook"), "email@example.test")

        _ = try runtime.createSnippet(name: "Short", trigger: "out", body: "short")
        XCTAssertEqual(runtime.snippetLookupSnapshot.body(for: ";out"), "short")

        try runtime.delete(snippetID: outlook.id)
        XCTAssertNil(runtime.snippetLookupSnapshot.body(for: ";outlook"))
        XCTAssertEqual(runtime.snippetLookupSnapshot.body(for: ";out"), "short")
    }

    func testEditedSnippetUpdatesBodyTriggerFolderAndLookupImmediately() throws {
        let original = try runtime.createSnippet(name: "Original", trigger: "old", body: "old body")
        let edited = try runtime.updateSnippet(
            id: original.id, name: "Renamed", trigger: "new", body: "new body", folder: " Work / Email "
        )
        XCTAssertEqual(edited.id, original.id)
        XCTAssertEqual(edited.folder, "Work/Email")
        XCTAssertEqual(edited.name, "Renamed")
        XCTAssertNil(runtime.snippetLookupSnapshot.body(for: ";old"))
        XCTAssertEqual(runtime.snippetLookupSnapshot.body(for: ";new"), "new body")
        XCTAssertEqual(try runtime.snippets().first?.body, "new body")
    }

    func testEditSnippetRejectsAnotherTriggerWithoutChangingSavedValue() throws {
        _ = try runtime.createSnippet(name: "A", trigger: "used", body: "A")
        let otherRecord = try runtime.createSnippet(name: "B", trigger: "otherRecord", body: "B")
        XCTAssertThrowsError(try runtime.updateSnippet(
            id: otherRecord.id, name: "Changed", trigger: "used", body: "Changed", folder: nil
        )) {
            XCTAssertEqual($0 as? MacClippySnippetCreationError, .duplicateTrigger)
        }
        XCTAssertEqual(runtime.snippetLookupSnapshot.body(for: ";otherRecord"), "B")
    }

    func testSnippetSnapshotReadFailureDoesNotCommitAnEdit() throws {
        let original = try runtime.createSnippet(name: "Original", trigger: "old", body: "old body")
        runtime.withStoreLock {
            runtime.snippetUpdateListForTesting = { throw MacClippyStoreError.invalidStoredRecord }
        }
        defer { runtime.withStoreLock { runtime.snippetUpdateListForTesting = nil } }
        XCTAssertThrowsError(try runtime.updateSnippet(
            id: original.id, name: "Renamed", trigger: "new", body: "new body", folder: "Work"))
        let saved = try runtime.snippetStore.fetch(id: original.id)
        XCTAssertEqual(saved.name, "Original")
        XCTAssertEqual(saved.body, "old body")
        XCTAssertEqual(saved.trigger, ";old")
        XCTAssertNil(saved.folder)
        XCTAssertEqual(runtime.snippetLookupSnapshot.body(for: ";old"), "old body")
        XCTAssertNil(runtime.snippetLookupSnapshot.body(for: ";new"))
    }

    func testSnippetSnapshotPreflightRunsBeforeCommitAndOnlyOnce() throws {
        let original = try runtime.createSnippet(name: "Original", trigger: "old", body: "old body")
        var reads = 0
        runtime.withStoreLock {
            runtime.snippetUpdateListForTesting = { [self] in
                reads += 1
                XCTAssertEqual(try runtime.snippetStore.fetch(id: original.id).body, "old body")
                return try runtime.snippetStore.list()
            }
        }
        defer { runtime.withStoreLock { runtime.snippetUpdateListForTesting = nil } }
        _ = try runtime.updateSnippet(id: original.id, name: "New", trigger: "new", body: "new body", folder: nil)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(try runtime.snippetStore.fetch(id: original.id).body, "new body")
        XCTAssertNil(runtime.snippetLookupSnapshot.body(for: ";old"))
        XCTAssertEqual(runtime.snippetLookupSnapshot.body(for: ";new"), "new body")
    }

    func testCreateSnippetManuallyRejectsBlankNameAndBody() throws {
        XCTAssertThrowsError(try runtime.createSnippet(name: " ", trigger: nil, body: "Body")) { error in
            XCTAssertEqual(error as? MacClippySnippetCreationError, .invalidName)
        }
        XCTAssertThrowsError(try runtime.createSnippet(name: "Name", trigger: nil, body: " \n")) { error in
            XCTAssertEqual(error as? MacClippySnippetCreationError, .emptyBody)
        }
    }

    func testDisabledSnippetModeDoesNotInstallEventTap() {
        let expander = MacClippySnippetExpander(
            modeProvider: { .disabled },
            lookup: { _ in nil }
        )

        XCTAssertTrue(expander.start())
        XCTAssertFalse(expander.isInstalled)
        XCTAssertNil(expander.lastStartError)
    }

    func testEnabledToDisabledTransitionStopsOrPreventsEventTap() throws {
        guard ProcessInfo.processInfo.environment["MACCLIPPY_RUN_REAL_INPUT_TAP_TESTS"] == "1" else {
            throw XCTSkip("Set MACCLIPPY_RUN_REAL_INPUT_TAP_TESTS=1 to exercise a real session event tap")
        }
        var mode: MacClippySnippetExpansionMode = .autoExpand
        let expander = MacClippySnippetExpander(
            modeProvider: { mode },
            lookup: { _ in nil }
        )
        defer { expander.stop() }

        _ = expander.start()
        mode = .disabled

        XCTAssertTrue(expander.start())
        XCTAssertFalse(expander.isInstalled)
        XCTAssertNil(expander.lastStartError)
    }
}
