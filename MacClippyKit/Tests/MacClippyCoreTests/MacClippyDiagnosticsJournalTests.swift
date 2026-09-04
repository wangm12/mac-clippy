import XCTest

@testable import MacClippyCore

final class MacClippyDiagnosticsJournalTests: XCTestCase {
    func testPersistsNoticeEventsAcrossANewRecorder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyDiagnosticsJournalTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("diagnostics.jsonl")
        let first = MacClippyDiagnosticsJournal(url: url, capacity: 8)
        first.record(
            MacClippyDiagnosticsEvent(
                category: .ui,
                code: .dockPresented,
                operation: "dock_show",
                impact: "panel_existed=false items=0"
            )
        )

        let second = MacClippyDiagnosticsJournal(url: url, capacity: 8)
        XCTAssertEqual(second.recentEvents().map(\.operation), ["dock_show"])
        XCTAssertEqual(second.recentEvents().first?.code, .dockPresented)
    }

    func testBoundsPersistedEventsToCapacity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyDiagnosticsJournalCap-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = root.appendingPathComponent("diagnostics.jsonl")
        let journal = MacClippyDiagnosticsJournal(url: url, capacity: 2)
        for index in 0..<4 {
            journal.record(
                MacClippyDiagnosticsEvent(
                    category: .ui,
                    code: .dockPresented,
                    operation: "dock_show_\(index)"
                )
            )
        }

        XCTAssertEqual(journal.recentEvents().map(\.operation), ["dock_show_2", "dock_show_3"])
    }
}
