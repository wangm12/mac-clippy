import XCTest

@testable import MacClippy
import MacClippyCore

final class MacClippySnippetTests: XCTestCase {
    private var tempRoot: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippySnippetTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: tempRoot))
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
        XCTAssertEqual(try runtime.snippets().map(\.id), [snippet.id])
    }

    func testCreateSnippetManuallyRejectsBlankNameAndBody() throws {
        XCTAssertThrowsError(try runtime.createSnippet(name: " ", trigger: nil, body: "Body")) { error in
            XCTAssertEqual(error as? MacClippySnippetCreationError, .invalidName)
        }
        XCTAssertThrowsError(try runtime.createSnippet(name: "Name", trigger: nil, body: " \n")) { error in
            XCTAssertEqual(error as? MacClippySnippetCreationError, .emptyBody)
        }
    }
}
