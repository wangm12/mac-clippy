import Combine
import CoreGraphics
import ImageIO
import XCTest

@testable import MacClippy
import MacClippyCore

final class MacClippyDockEfficiencyTests: XCTestCase {
    private var tempRoot: URL!
    private var runtime: MacClippyRuntime!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyDockEfficiencyTests-\(UUID().uuidString)",
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

    @MainActor
    func testQueryChangeCachesHighlightTermsOnce() {
        let model = MacClippyDockModel(runtime: runtime)

        model.query = "hello world"
        XCTAssertEqual(model.highlightTerms, ["hello", "world"])

        model.query = "hello world"
        XCTAssertEqual(model.highlightTerms, ["hello", "world"])

        model.query = ""
        XCTAssertEqual(model.highlightTerms, [])
    }

    @MainActor
    func testTypingDoesNotBumpSelectAllGenerationWhenNothingIsSelected() {
        let model = MacClippyDockModel(runtime: runtime)
        let generation = model.selectAllGeneration

        model.query = "hello"

        XCTAssertEqual(model.selectAllGeneration, generation)
        XCTAssertNil(model.allSelectedRecordIDs)
    }

    @MainActor
    func testQueryInvalidatesSelectAllScope() {
        let model = MacClippyDockModel(runtime: runtime)
        model.allSelectedRecordIDs = [RecordID.generate()]
        model.allSelectedRecordIDSet = Set(model.allSelectedRecordIDs ?? [])

        model.query = "hello"

        XCTAssertNil(model.allSelectedRecordIDs)
        XCTAssertNil(model.allSelectedRecordIDSet)
    }

    @MainActor
    func testRecomputeDedupRunsSkipsNoOpPublish() {
        let model = MacClippyDockModel(runtime: runtime)
        var publishes = 0
        let cancellable = model.$dedupRunCounts.sink { _ in
            publishes += 1
        }

        model.recomputeDedupRuns()
        model.recomputeDedupRuns()
        _ = cancellable

        XCTAssertEqual(publishes, 1)
    }

    @MainActor
    func testEndSessionReleasesThumbnailCache() throws {
        let model = MacClippyDockModel(runtime: runtime)
        let id = RecordID.generate()
        let image = try XCTUnwrap(Self.pngImage())
        model.thumbnailLoader.cache.setObject(
            MacClippyCardThumbnailLoader.CacheEntry(image: image),
            forKey: "\(id.rawValue)#480" as NSString,
            cost: 4
        )
        XCTAssertNotNil(model.thumbnailLoader.cachedImage(id: id, maxPixelSize: 480))

        model.endSession()

        XCTAssertNil(model.thumbnailLoader.cachedImage(id: id, maxPixelSize: 480))
    }

    private static func pngImage() -> CGImage? {
        let png = Data(
            base64Encoded: """
            iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+ip1sAAAAASUVORK5CYII=
            """
        )!
        let source = CGImageSourceCreateWithData(png as CFData, nil)
        return source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
}
