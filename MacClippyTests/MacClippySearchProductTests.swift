import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

final class MacClippySearchProductTests: XCTestCase {
    private var tempRoot: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippySearchProductTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        MacClippySourceAppResolver.testDisplayNames = [:]
        runtime = try MacClippyRuntime(paths: try MacClippyPaths(rootURL: tempRoot))
    }

    override func tearDownWithError() throws {
        MacClippySourceAppResolver.testDisplayNames = [:]
        runtime?.closeForTesting()
        runtime = nil
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testBareSearchFindsCJKSubstringAndQuotedPhrases() throws {
        let cjk = try runtime.appendTestRecord(
            .text("你好世界"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 1_000)
        )
        _ = try runtime.setCustomLabel(id: cjk.id, label: "cjk")
        let phrase = try runtime.appendTestRecord(
            .text("project alpha notes"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 2_000)
        )
        _ = try runtime.setCustomLabel(id: phrase.id, label: "phrase")
        let distractor = try runtime.appendTestRecord(
            .text("project beta and alpha elsewhere"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 3_000)
        )
        _ = try runtime.setCustomLabel(id: distractor.id, label: "distractor")

        XCTAssertEqual(try runtime.history(limit: 16, query: "世界").map(\.id), [cjk.id])
        XCTAssertEqual(try runtime.history(limit: 16, query: "\"project alpha\"").map(\.id), [phrase.id])
    }

    func testBareSearchMatchesWordAndFilenamePrefixes() throws {
        let file = try runtime.appendTestRecord(
            .files([URL(fileURLWithPath: "/tmp/docs/passport.pdf")]),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 1_000)
        )
        _ = try runtime.setCustomLabel(id: file.id, label: "file")
        let text = try runtime.appendTestRecord(
            .text("renew the passport tomorrow"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 2_000)
        )
        _ = try runtime.setCustomLabel(id: text.id, label: "text")
        let miss = try runtime.appendTestRecord(
            .text("unrelated note"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 3_000)
        )
        _ = try runtime.setCustomLabel(id: miss.id, label: "other")

        XCTAssertEqual(
            Set(try runtime.history(limit: 16, query: "pas").map(\.id)),
            [file.id, text.id]
        )
        XCTAssertEqual(
            Set(try runtime.history(limit: 16, query: "passport").map(\.id)),
            [file.id, text.id]
        )
        XCTAssertEqual(
            Set(try runtime.history(limit: 16, query: "ss").map(\.id)),
            [file.id, text.id]
        )
    }

    func testBareSearchMatchesASCIIInfixInsideWordsAndFilenames() throws {
        let file = try runtime.appendTestRecord(
            .files([URL(fileURLWithPath: "/tmp/docs/passport.pdf")]),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 1_000)
        )
        _ = try runtime.setCustomLabel(id: file.id, label: "file")
        let text = try runtime.appendTestRecord(
            .text("renew the passport tomorrow"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 2_000)
        )
        _ = try runtime.setCustomLabel(id: text.id, label: "text")
        let miss = try runtime.appendTestRecord(
            .text("unrelated note"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 3_000)
        )
        _ = try runtime.setCustomLabel(id: miss.id, label: "other")

        XCTAssertEqual(
            Set(try runtime.history(limit: 16, query: "ss").map(\.id)),
            [file.id, text.id]
        )
        XCTAssertEqual(
            Set(try runtime.history(limit: 16, query: "pas").map(\.id)),
            [file.id, text.id]
        )
    }

    func testBareSearchSupportsPrefixStarAndStripsFTSMarkers() throws {
        let meta = try runtime.appendTestRecord(
            .text("clipboard manager notes"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 1_000)
        )
        _ = try runtime.setCustomLabel(id: meta.id, label: "prefix")

        let results = try runtime.history(limit: 16, query: "clip*")
        XCTAssertEqual(results.map(\.id), [meta.id])
        let preview = try XCTUnwrap(results.first?.preview)
        XCTAssertFalse(preview.contains("<"))
        XCTAssertFalse(preview.contains(">"))
        XCTAssertNotNil(preview.range(of: "clipboard"))
    }

    func testBareSearchPageOrdersMatchesByRecency() throws {
        let older = try runtime.appendTestRecord(
            .text("sharedterm sharedterm sharedterm"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 1_000)
        )
        _ = try runtime.setCustomLabel(id: older.id, label: "older")
        let newer = try runtime.appendTestRecord(
            .text("sharedterm sharedterm sharedterm"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 2_000)
        )
        _ = try runtime.setCustomLabel(id: newer.id, label: "newer")

        let page = try runtime.historyPage(limit: 16, query: "sharedterm")
        XCTAssertEqual(page.items.first?.id, newer.id)
    }

    func testTypeURLMatchesDetectedLinkText() throws {
        let url = try runtime.appendTestRecord(
            .text("https://example.com/macclippy"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 1_000)
        )
        let plain = try runtime.appendTestRecord(
            .text("just a sentence"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 2_000)
        )
        _ = try runtime.setCustomLabel(id: url.id, label: "link")
        _ = try runtime.setCustomLabel(id: plain.id, label: "plain")

        XCTAssertEqual(try runtime.history(limit: 16, query: "type:url").map(\.id), [url.id])
    }

    func testTypeURLRejectsHTTPStatusText() throws {
        let url = try runtime.appendTestRecord(
            .text("https://example.com/macclippy"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 1_000)
        )
        _ = try runtime.setCustomLabel(id: url.id, label: "link")
        let www = try runtime.appendTestRecord(
            .text("www.example.com"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 2_000)
        )
        _ = try runtime.setCustomLabel(id: www.id, label: "www")
        let status = try runtime.appendTestRecord(
            .text("http status 500"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 3_000)
        )
        _ = try runtime.setCustomLabel(id: status.id, label: "status")

        XCTAssertEqual(
            Set(try runtime.history(limit: 16, query: "type:url").map(\.id)),
            [url.id, www.id]
        )
    }

    func testBareSearchCombinesASCIIPrefixAndCJKSubstring() throws {
        let both = try runtime.appendTestRecord(
            .text("clipboard 世界"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 1_000)
        )
        _ = try runtime.setCustomLabel(id: both.id, label: "both")
        let ascii = try runtime.appendTestRecord(
            .text("clipboard only"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 2_000)
        )
        _ = try runtime.setCustomLabel(id: ascii.id, label: "ascii")
        let cjk = try runtime.appendTestRecord(
            .text("你好世界"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 3_000)
        )
        _ = try runtime.setCustomLabel(id: cjk.id, label: "cjk")

        XCTAssertEqual(try runtime.history(limit: 16, query: "clip* 世界").map(\.id), [both.id])
    }

    func testBareSelectAllOrdersMatchesByRecency() throws {
        let older = try runtime.appendTestRecord(
            .text("sharedterm sharedterm sharedterm"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 1_000)
        )
        _ = try runtime.setCustomLabel(id: older.id, label: "older")
        let newer = try runtime.appendTestRecord(
            .text("sharedterm sharedterm sharedterm"),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 2_000)
        )
        _ = try runtime.setCustomLabel(id: newer.id, label: "newer")

        XCTAssertEqual(try runtime.historyRecordIDs(query: "sharedterm"), [newer.id, older.id])
    }

    func testFileSearchIndexesFilenameNotAbsolutePath() throws {
        let directory = "MacClippyPathMarker-\(UUID().uuidString)"
        let url = URL(fileURLWithPath: "/tmp/\(directory)/invoice.pdf")
        let meta = try runtime.appendTestRecord(
            .files([url]),
            sourceAppBundleID: nil,
            now: Date(timeIntervalSince1970: 1_000)
        )
        _ = try runtime.setCustomLabel(id: meta.id, label: "file")

        XCTAssertTrue(try runtime.history(limit: 16, query: directory).isEmpty)
        XCTAssertEqual(try runtime.history(limit: 16, query: "invoice.pdf").map(\.id), [meta.id])
    }

    func testPinboardSearchMatchesOCRAndCustomLabel() throws {
        let board = try runtime.createPinboard(name: "OCR Board", color: nil)
        let image = try runtime.appendTestRecord(.image(blobID: "unused", width: 4, height: 4))
        try runtime.setOCRTextForTest(id: image.id, text: "uniqueocrphrase")
        try runtime.pin(recordID: image.id, to: board.id)
        let labeled = try runtime.appendTestRecord(.text("unrelated preview body"))
        _ = try runtime.setCustomLabel(id: labeled.id, label: "secretpinlabel")
        try runtime.pin(recordID: labeled.id, to: board.id)

        let ocrPage = try runtime.pinboardSearchPage(
            pinboardID: board.id,
            query: "uniqueocrphrase",
            limit: 16
        )
        XCTAssertEqual(ocrPage.items.map(\.id), [image.id])

        let labelPage = try runtime.pinboardSearchPage(
            pinboardID: board.id,
            query: "secretpinlabel",
            limit: 16
        )
        XCTAssertEqual(labelPage.items.map(\.id), [labeled.id])
    }

    func testPinboardTypeURLUsesTheSamePredicateAsHistory() throws {
        let board = try runtime.createPinboard(name: "Links", color: nil)
        let url = try runtime.appendTestRecord(.text("https://example.com/macclippy"))
        _ = try runtime.setCustomLabel(id: url.id, label: "link")
        try runtime.pin(recordID: url.id, to: board.id)
        let www = try runtime.appendTestRecord(.text("www.example.com"))
        _ = try runtime.setCustomLabel(id: www.id, label: "www")
        try runtime.pin(recordID: www.id, to: board.id)
        let status = try runtime.appendTestRecord(.text("http status 500"))
        _ = try runtime.setCustomLabel(id: status.id, label: "status")
        try runtime.pin(recordID: status.id, to: board.id)

        let page = try runtime.pinboardSearchPage(
            pinboardID: board.id,
            query: "type:url",
            limit: 16
        )
        XCTAssertEqual(Set(page.items.map(\.id)), [url.id, www.id])
    }

    func testBareSearchAndAppClauseFindSourceAppName() throws {
        let safari = try runtime.appendTestRecord(
            .text("unrelated note from a browser"),
            sourceAppBundleID: "com.apple.Safari",
            now: Date(timeIntervalSince1970: 1_000)
        )
        _ = try runtime.setCustomLabel(id: safari.id, label: "browser")
        let other = try runtime.appendTestRecord(
            .text("unrelated note from an editor"),
            sourceAppBundleID: "com.example.Editor",
            now: Date(timeIntervalSince1970: 2_000)
        )
        _ = try runtime.setCustomLabel(id: other.id, label: "editor")

        XCTAssertEqual(try runtime.history(limit: 16, query: "safari").map(\.id), [safari.id])
        XCTAssertEqual(try runtime.history(limit: 16, query: "Safari").map(\.id), [safari.id])
        XCTAssertEqual(try runtime.history(limit: 16, query: "app:safari").map(\.id), [safari.id])
        XCTAssertEqual(try runtime.history(limit: 16, query: "app:EDITOR").map(\.id), [other.id])
    }

    func testBareSearchAndAppClauseFindLocalizedSourceDisplayName() throws {
        MacClippySourceAppResolver.testDisplayNames["com.tencent.xinWeChat"] = "微信"
        MacClippySourceAppResolver.testDisplayNames["com.apple.MobileSMS"] = "Messages"
        let weChat = try runtime.appendTestRecord(
            .text("chat excerpt without the app name"),
            sourceAppBundleID: "com.tencent.xinWeChat",
            now: Date(timeIntervalSince1970: 1_000)
        )
        _ = try runtime.setCustomLabel(id: weChat.id, label: "chat")
        let messages = try runtime.appendTestRecord(
            .text("sms excerpt without the app name"),
            sourceAppBundleID: "com.apple.MobileSMS",
            now: Date(timeIntervalSince1970: 2_000)
        )
        _ = try runtime.setCustomLabel(id: messages.id, label: "sms")

        XCTAssertEqual(try runtime.history(limit: 16, query: "微信").map(\.id), [weChat.id])
        XCTAssertEqual(try runtime.history(limit: 16, query: "app:微信").map(\.id), [weChat.id])
        XCTAssertEqual(try runtime.history(limit: 16, query: "Messages").map(\.id), [messages.id])
        XCTAssertEqual(try runtime.history(limit: 16, query: "app:Messages").map(\.id), [messages.id])
    }

    func testSearchableIndexTextIncludesSourceSegments() {
        let indexed = MacClippyRuntime.searchableIndexText(
            for: .text("body only"),
            ocrText: nil,
            label: nil,
            sourceAppBundleID: "com.tencent.xinWeChat",
            sourceAppDisplayName: "微信"
        )
        XCTAssertTrue(indexed.contains("body only"))
        XCTAssertTrue(indexed.contains("com.tencent.xinWeChat"))
        XCTAssertTrue(indexed.contains("xinWeChat"))
        XCTAssertTrue(indexed.contains("微信"))
        XCTAssertFalse(indexed.contains("Unknown source"))
    }
}
