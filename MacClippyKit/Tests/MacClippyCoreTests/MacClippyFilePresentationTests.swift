import XCTest

import MacClippyCore

final class MacClippyFilePresentationTests: XCTestCase {
    func testTitleMatchesPasteFileCountLabel() {
        XCTAssertEqual(MacClippyFilePresentation.title(fileCount: 1), "1 file")
        XCTAssertEqual(MacClippyFilePresentation.title(fileCount: 2), "2 files")
        XCTAssertEqual(MacClippyFilePresentation.title(fileCount: 0), "0 files")
    }

    func testStorePreviewUsesFilenameSoDifferentFilesDoNotCollapse() {
        let passport = URL(fileURLWithPath: "/tmp/docs/passport.pdf")
        let notes = URL(fileURLWithPath: "/tmp/notes/progress.md")

        XCTAssertEqual(MacClippyFilePresentation.storePreview(for: [passport]), "passport.pdf")
        XCTAssertEqual(MacClippyFilePresentation.storePreview(for: [notes]), "progress.md")
        XCTAssertNotEqual(
            MacClippyFilePresentation.storePreview(for: [passport]),
            MacClippyFilePresentation.storePreview(for: [notes])
        )
    }

    func testStorePreviewKeepsMultipleFileCountAndFirstName() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.txt"),
            URL(fileURLWithPath: "/tmp/b.txt")
        ]
        XCTAssertEqual(MacClippyFilePresentation.storePreview(for: urls), "2 files · a.txt")
    }

    func testDisplayNameAndPathPreferFilenameThenPOSIXPath() {
        let url = URL(fileURLWithPath: "/Users/me/H1B/passport.pdf")
        XCTAssertEqual(MacClippyFilePresentation.displayName(for: url), "passport.pdf")
        XCTAssertEqual(MacClippyFilePresentation.displayPath(for: url), "/Users/me/H1B/passport.pdf")
    }

    func testByteCountLabelUsesFileStyleNotRawFractionalKilobytes() {
        let label = MacClippyFilePresentation.byteCountLabel(bytes: 329_748)
        XCTAssertFalse(label.isEmpty)
        XCTAssertFalse(label.contains("322.01999"))
        XCTAssertTrue(label.contains("KB") || label.contains("kB") || label.contains("KB".lowercased()))
    }

    func testSearchSegmentsIndexFilenameNotAbsolutePath() {
        let url = URL(fileURLWithPath: "/Users/me/projects/progress.md")
        let segments = MacClippyFilePresentation.searchSegments(for: [url])
        XCTAssertEqual(segments, ["progress.md"])
        XCTAssertFalse(segments.contains(where: { $0.contains("/Users/") }))
    }

    func testFooterLabelPrefersCountAndSize() {
        XCTAssertEqual(MacClippyFilePresentation.footerLabel(fileCount: 1, totalByteCount: nil), "1 file")
        XCTAssertEqual(
            MacClippyFilePresentation.footerLabel(fileCount: 1, totalByteCount: 1024),
            "1 file · \(MacClippyFilePresentation.byteCountLabel(bytes: 1024))"
        )
        XCTAssertEqual(MacClippyFilePresentation.footerLabel(fileCount: 3, totalByteCount: nil), "3 files")
        XCTAssertNil(MacClippyFilePresentation.footerLabel(fileCount: 0, totalByteCount: 10))
    }

    func testMediaKindUsesPathExtensionWithoutTouchingDisk() {
        XCTAssertEqual(
            MacClippyFilePresentation.mediaKind(for: URL(fileURLWithPath: "/Users/me/Library/WeChat/c133.jpg")),
            .image
        )
        XCTAssertEqual(
            MacClippyFilePresentation.mediaKind(for: URL(fileURLWithPath: "/tmp/photo.JPEG")),
            .image
        )
        XCTAssertEqual(
            MacClippyFilePresentation.mediaKind(for: URL(fileURLWithPath: "/tmp/clip.mp4")),
            .movie
        )
        XCTAssertEqual(
            MacClippyFilePresentation.mediaKind(for: URL(fileURLWithPath: "/tmp/passport.pdf")),
            .other
        )
    }

    func testDedupKeyIncludesFileURLs() {
        let left = URL(fileURLWithPath: "/tmp/one/progress.md")
        let right = URL(fileURLWithPath: "/tmp/two/progress.md")
        XCTAssertEqual(
            MacClippyFilePresentation.dedupKey(preview: "(1 file)", fileURLs: [left]),
            MacClippyFilePresentation.dedupKey(preview: "(1 file)", fileURLs: [left])
        )
        XCTAssertNotEqual(
            MacClippyFilePresentation.dedupKey(preview: "(1 file)", fileURLs: [left]),
            MacClippyFilePresentation.dedupKey(preview: "(1 file)", fileURLs: [right])
        )
    }
}
