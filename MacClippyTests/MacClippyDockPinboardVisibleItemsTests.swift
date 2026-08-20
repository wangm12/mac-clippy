import XCTest

@testable import MacClippy
import MacClippyCore

final class MacClippyDockPinboardVisibleItemsTests: XCTestCase {
    func testKeepsBoardSourceWhileSearchHasNotSettled() throws {
        let boardID = RecordID.generate()
        let source = [try historyEntry(preview: "board")]
        let stale = [try historyEntry(preview: "stale")]

        XCTAssertEqual(
            MacClippyDockPinboardVisibleItems.resolve(
                MacClippyDockPinboardVisibleItemsState(
                    query: "hello",
                    boardID: boardID,
                    source: source,
                    searchBoardID: nil,
                    searchQuery: "",
                    searchItems: [],
                    isLoading: false
                )
            ).map(\.preview),
            ["board"]
        )
        XCTAssertEqual(
            MacClippyDockPinboardVisibleItems.resolve(
                MacClippyDockPinboardVisibleItemsState(
                    query: "hello",
                    boardID: boardID,
                    source: source,
                    searchBoardID: boardID,
                    searchQuery: "hello",
                    searchItems: [],
                    isLoading: true
                )
            ).map(\.preview),
            ["board"]
        )
        XCTAssertEqual(
            MacClippyDockPinboardVisibleItems.resolve(
                MacClippyDockPinboardVisibleItemsState(
                    query: "hellos",
                    boardID: boardID,
                    source: source,
                    searchBoardID: boardID,
                    searchQuery: "hello",
                    searchItems: stale,
                    isLoading: true
                )
            ).map(\.preview),
            ["stale"]
        )
    }

    func testShowsNoMatchesOnlyAfterSettledEmptySearch() throws {
        let boardID = RecordID.generate()
        let source = [try historyEntry(preview: "board")]
        XCTAssertTrue(
            MacClippyDockPinboardVisibleItems.resolve(
                MacClippyDockPinboardVisibleItemsState(
                    query: "zzz",
                    boardID: boardID,
                    source: source,
                    searchBoardID: boardID,
                    searchQuery: "zzz",
                    searchItems: [],
                    isLoading: false
                )
            ).isEmpty
        )
    }

    func testEmptyQueryAlwaysUsesBoardSource() throws {
        let boardID = RecordID.generate()
        let source = [try historyEntry(preview: "board")]
        XCTAssertEqual(
            MacClippyDockPinboardVisibleItems.resolve(
                MacClippyDockPinboardVisibleItemsState(
                    query: "",
                    boardID: boardID,
                    source: source,
                    searchBoardID: boardID,
                    searchQuery: "hello",
                    searchItems: [],
                    isLoading: false
                )
            ).map(\.preview),
            ["board"]
        )
    }

    private func historyEntry(preview: String) throws -> MacClippyHistoryEntry {
        MacClippyHistoryEntry(
            meta: ClipboardItemMeta(
                id: .generate(),
                created: Date(timeIntervalSince1970: 1),
                modified: Date(timeIntervalSince1970: 1),
                deviceID: try XCTUnwrap(DeviceID(rawValue: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                lamport: 1,
                preview: preview
            ),
            contentKind: .text,
            preview: preview
        )
    }
}
