import XCTest

@testable import MacClippy
import MacClippyCore

final class MacClippyRenamePresentationTests: XCTestCase {
    @MainActor
    func testPresentRenameItemUsesCurrentNameAndFreshToken() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyRenameTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: root))
        let model = MacClippyDockModel(runtime: runtime)
        let meta = try runtime.appendTestRecord(.text("clipboard body"))
        _ = try runtime.setCustomLabel(id: meta.id, label: "Project notes")
        guard let entry = try runtime.history(limit: 1, query: "").first else {
            return XCTFail("expected a clipboard item")
        }

        model.presentRenameItem(for: entry)
        guard case let .renameItem(firstID, firstName, firstToken) = model.modal else {
            return XCTFail("expected rename item modal")
        }
        XCTAssertEqual(firstID, meta.id)
        XCTAssertEqual(firstName, "Project notes")

        model.presentRenameItem(for: entry)
        guard case let .renameItem(_, _, secondToken) = model.modal else {
            return XCTFail("expected rename item modal")
        }
        XCTAssertNotEqual(firstToken, secondToken)
    }
}
