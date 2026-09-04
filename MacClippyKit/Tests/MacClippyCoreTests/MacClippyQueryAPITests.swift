import XCTest

@testable import MacClippyCore

final class MacClippyQueryAPITests: XCTestCase {
    private var work: RecordID!
    private var loose: RecordID!
    private var secret: RecordID!
    private var catalog: MacClippyQueryCatalog!

    override func setUpWithError() throws {
        work = RecordID.generate()
        loose = RecordID.generate()
        secret = RecordID.generate()
        let board = RecordID.generate()
        catalog = MacClippyQueryCatalog(
            pinboards: [MacClippyQueryPinboard(id: board, name: "Work")],
            records: [
                queryRecord(id: work, preview: "invoice 42", kind: .text, pinboardIDs: [board], utis: ["public.utf8-plain-text"]),
                queryRecord(id: loose, preview: "loose note", kind: .text, pinboardIDs: [], utis: ["public.utf8-plain-text"]),
                queryRecord(
                    id: secret,
                    preview: "password = hunter2",
                    kind: .text,
                    pinboardIDs: [board],
                    utis: ["org.nspasteboard.ConcealedType"]
                )
            ]
        )
    }

    func testDefaultScopeHidesUnpinnedAndConcealedRecords() {
        let hits = MacClippyQueryCatalogPolicy.apply(
            .search(query: "invoice", limit: 20, scope: .pinboardsNonConcealed),
            to: &catalog
        )
        XCTAssertEqual(hits, .records([
            MacClippyQueryRecordView(id: work, preview: "invoice 42", contentKind: .text, pinboardNames: ["Work"])
        ]))

        XCTAssertEqual(
            MacClippyQueryCatalogPolicy.apply(
                .search(query: "loose", limit: 20, scope: .pinboardsNonConcealed),
                to: &catalog
            ),
            .records([])
        )
        XCTAssertEqual(
            MacClippyQueryCatalogPolicy.apply(
                .get(id: secret, scope: .pinboardsNonConcealed),
                to: &catalog
            ),
            .notFound
        )
    }

    func testCLIAndMCPParseTheSameSearchRequest() throws {
        let fromCLI = try MacClippyQueryCLIPolicy.parse(["search", "invoice"])
        let fromMCP = try MacClippyQueryMCPPolicy.request(
            tool: "search",
            arguments: ["query": "invoice"]
        )
        XCTAssertEqual(fromCLI, fromMCP)
        XCTAssertEqual(
            fromCLI,
            .search(query: "invoice", limit: 20, scope: .pinboardsNonConcealed)
        )
        XCTAssertEqual(
            Set(MacClippyQueryMCPPolicy.tools.map(\.name)),
            ["search", "get", "pin", "save"]
        )
        let id = RecordID.generate()
        XCTAssertEqual(
            try MacClippyQueryCLIPolicy.parse(["pin", id.rawValue, "--board", "Work"]),
            try MacClippyQueryMCPPolicy.request(
                tool: "pin",
                arguments: ["id": id.rawValue, "board": "Work"]
            )
        )
        XCTAssertEqual(
            try MacClippyQueryCLIPolicy.parse(["save", "hello", "--board", "Work"]),
            try MacClippyQueryMCPPolicy.request(
                tool: "save",
                arguments: ["text": "hello", "board": "Work"]
            )
        )
    }

    func testCLIDoesNotPretendToQueryAnUnattachedLibrary() {
        XCTAssertEqual(
            MacClippyQueryExecutionPolicy.unattachedLibraryMessage,
            "no local library attached; search/get/pin/save run inside the MacClippy app"
        )
        XCTAssertTrue(MacClippyQueryExecutionPolicy.requiresAttachedCatalog)
    }

    func testPinAndSaveGoThroughTheSharedCatalog() throws {
        let pinned = try XCTUnwrap(RecordID(rawValue: loose.rawValue))
        let pinResult = MacClippyQueryCatalogPolicy.apply(
            .pin(id: pinned, board: "Work"),
            to: &catalog
        )
        XCTAssertEqual(pinResult, .pinned(id: pinned, board: "Work"))
        XCTAssertEqual(
            MacClippyQueryCatalogPolicy.apply(
                .search(query: "loose", limit: 20, scope: .pinboardsNonConcealed),
                to: &catalog
            ),
            .records([
                MacClippyQueryRecordView(id: loose, preview: "loose note", contentKind: .text, pinboardNames: ["Work"])
            ])
        )

        let saved = MacClippyQueryCatalogPolicy.apply(
            .save(text: "new snippet", board: "Work"),
            to: &catalog
        )
        guard case let .saved(id) = saved else {
            return XCTFail("save should return a new id")
        }
        guard case let .record(view) = MacClippyQueryCatalogPolicy.apply(
            .get(id: id, scope: .pinboardsNonConcealed),
            to: &catalog
        ) else {
            return XCTFail("saved pinboard item should be gettable")
        }
        XCTAssertEqual(view.preview, "new snippet")
        XCTAssertEqual(view.pinboardNames, ["Work"])
    }

    private func queryRecord(
        id: RecordID,
        preview: String,
        kind: MacClippyContentKind,
        pinboardIDs: [RecordID],
        utis: [String]
    ) -> MacClippyQueryRecord {
        MacClippyQueryRecord(
            id: id,
            preview: preview,
            contentKind: kind,
            sourceAppBundleID: nil,
            customLabel: nil,
            ocrText: nil,
            modified: Date(timeIntervalSince1970: 1),
            isURL: false,
            pinboardIDs: pinboardIDs,
            representationUTIs: utis
        )
    }
}
