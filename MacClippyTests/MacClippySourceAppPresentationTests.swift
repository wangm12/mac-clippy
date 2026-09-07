import XCTest

@testable import MacClippy

final class MacClippySourceAppPresentationTests: XCTestCase {
    func testUnknownSourceUsesDeterministicNeutralAccent() {
        XCTAssertEqual(
            MacClippySourceAccent.representativeRGB(from: []),
            MacClippySourceAccent.neutralRGB
        )
        XCTAssertEqual(
            MacClippySourceAppPresentation.unknown.accentRGB,
            MacClippySourceAccent.neutralRGB
        )
    }

    func testRepresentativeAccentMappingIsDeterministic() {
        let pixels = [
            MacClippySourceRGB(red: 0.95, green: 0.10, blue: 0.08),
            MacClippySourceRGB(red: 0.80, green: 0.12, blue: 0.10)
        ]

        XCTAssertEqual(
            MacClippySourceAccent.representativeRGB(from: pixels),
            MacClippySourceAccent.representativeRGB(from: pixels)
        )
        let accent = MacClippySourceAccent.representativeRGB(from: pixels)
        XCTAssertGreaterThan(accent.red, accent.green)
        XCTAssertGreaterThan(accent.red, accent.blue)
    }

    func testMonochromeSourcesStayNeutralInsteadOfUsingSyntheticHue() {
        let accent = MacClippySourceAccent.representativeRGB(from: [
            MacClippySourceRGB(red: 0.5, green: 0.5, blue: 0.5)
        ])

        XCTAssertEqual(accent, MacClippySourceAccent.neutralRGB)
    }

    func testRepresentativeAccentUsesActualDominantColorPixels() {
        let accent = MacClippySourceAccent.representativeRGB(from: [
            MacClippySourceRGB(red: 0.95, green: 0.08, blue: 0.05),
            MacClippySourceRGB(red: 0.90, green: 0.10, blue: 0.06),
            MacClippySourceRGB(red: 0.05, green: 0.05, blue: 0.05)
        ])

        XCTAssertGreaterThan(accent.red, accent.green)
        XCTAssertGreaterThan(accent.red, accent.blue)
    }

    func testSourceResolveOnlyInvalidatesCardsForThatBundle() {
        var batch = MacClippySourceResolveBatch()
        batch.enqueue("com.google.Chrome")
        batch.flush()
        XCTAssertEqual(
            MacClippySourceCardRefreshPolicy.snapshotGeneration(
                cardBundleID: "com.apple.finder",
                generations: batch.generations
            ),
            0
        )
        batch.enqueue("com.apple.finder")
        batch.flush()
        XCTAssertEqual(
            MacClippySourceCardRefreshPolicy.snapshotGeneration(
                cardBundleID: "com.apple.finder",
                generations: batch.generations
            ),
            1
        )
        XCTAssertEqual(
            MacClippySourceCardRefreshPolicy.snapshotGeneration(
                cardBundleID: nil,
                generations: batch.generations
            ),
            0
        )
    }

    func testSourceResolveIncrementsTheSameBundleAgainAfterCacheEviction() {
        var batch = MacClippySourceResolveBatch()
        batch.enqueue("com.google.Chrome")
        batch.enqueue("com.apple.finder")
        batch.enqueue("com.google.Chrome")
        XCTAssertEqual(batch.pending, ["com.google.Chrome", "com.apple.finder"])
        XCTAssertTrue(batch.generations.isEmpty)

        batch.flush()
        XCTAssertEqual(batch.pending, [])
        XCTAssertEqual(batch.generations["com.google.Chrome"], 1)
        XCTAssertEqual(batch.generations["com.apple.finder"], 1)

        batch.flush()
        XCTAssertEqual(batch.generations["com.google.Chrome"], 1)

        batch.enqueue("com.google.Chrome")
        batch.flush()
        XCTAssertEqual(batch.generations["com.google.Chrome"], 2)
        XCTAssertEqual(
            MacClippySourceCardRefreshPolicy.snapshotGeneration(
                cardBundleID: "com.apple.finder",
                generations: batch.generations
            ),
            1
        )
    }

    func testFinderSourceBadgePixelsStayStableAcrossAppearances() throws {
        guard let finderURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") else {
            throw XCTSkip("Finder is not installed")
        }
        let icon = NSWorkspace.shared.icon(forFile: finderURL.path)
        let prepared = MacClippySourceAppIcon.prepared(
            icon,
            pointSize: MacClippyDockCardMetrics.sourceBadgeSize
        )
        guard let aqua = pngData(from: prepared) else {
            return XCTFail("Finder badge did not rasterize")
        }
        var darkAqua: Data?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            darkAqua = pngData(from: prepared)
        }
        XCTAssertEqual(aqua, darkAqua)
        XCTAssertGreaterThan(aqua.count, 0)
    }

    func testPreparedSourceIconIsAFrozenBitmap() {
        let icon = NSImage(size: NSSize(width: 64, height: 64))
        icon.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 64, height: 64)).fill()
        icon.unlockFocus()

        let prepared = MacClippySourceAppIcon.prepared(icon, pointSize: 48)
        XCTAssertFalse(prepared.representations.isEmpty)
        XCTAssertGreaterThan(prepared.representations[0].pixelsWide, 0)
        XCTAssertGreaterThan(prepared.representations[0].pixelsHigh, 0)

        guard let first = pngData(from: prepared), let second = pngData(from: prepared) else {
            return XCTFail("prepared icon did not rasterize")
        }
        XCTAssertEqual(first, second)

        var darkPixels: Data?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            darkPixels = pngData(from: prepared)
        }
        XCTAssertEqual(first, darkPixels)
    }

    func testSourceResolveNotificationReadsBundleIdentifier() {
        XCTAssertEqual(
            MacClippySourceCardRefreshPolicy.resolvedBundleID(from: "com.apple.finder"),
            "com.apple.finder"
        )
        XCTAssertNil(MacClippySourceCardRefreshPolicy.resolvedBundleID(from: nil))
        XCTAssertNil(MacClippySourceCardRefreshPolicy.resolvedBundleID(from: 12))
        XCTAssertNil(MacClippySourceCardRefreshPolicy.resolvedBundleID(from: ""))
    }

    func testThumbnailRetainKeepsPixelsForTheSameIdentity() {
        XCTAssertFalse(
            MacClippyThumbnailRetainPolicy.shouldClearDisplayedImage(
                displayedIdentity: "file:///tmp/clip.mp4|96x96",
                loadingIdentity: "file:///tmp/clip.mp4|96x96"
            )
        )
        XCTAssertTrue(
            MacClippyThumbnailRetainPolicy.shouldClearDisplayedImage(
                displayedIdentity: "file:///tmp/a.mp4|96x96",
                loadingIdentity: "file:///tmp/b.mp4|96x96"
            )
        )
    }

    func testDisplayedThumbnailIgnoresStalePixelsWhenIdentityChanges() {
        XCTAssertEqual(
            MacClippyThumbnailDisplayPolicy.displayed(
                loadedIdentity: "/tmp/a.mp4|96x96",
                currentIdentity: "/tmp/b.mp4|96x96",
                image: 1,
                cached: 2
            ),
            2
        )
    }

    func testDisplayedThumbnailKeepsLoadedPixelsForTheSameIdentity() {
        XCTAssertEqual(
            MacClippyThumbnailDisplayPolicy.displayed(
                loadedIdentity: "/tmp/a.mp4|96x96",
                currentIdentity: "/tmp/a.mp4|96x96",
                image: 1,
                cached: 2
            ),
            1
        )
    }

    func testDisplayedThumbnailUsesCacheWhenTaskHasNotLoaded() {
        XCTAssertEqual(
            MacClippyThumbnailDisplayPolicy.displayed(
                loadedIdentity: nil,
                currentIdentity: "/tmp/a.mp4|96x96",
                image: 1,
                cached: 2
            ),
            2
        )
        XCTAssertEqual(
            MacClippyThumbnailDisplayPolicy.displayed(
                loadedIdentity: "/tmp/a.mp4|96x96",
                currentIdentity: "/tmp/a.mp4|96x96",
                image: Optional<Int>.none,
                cached: 2
            ),
            2
        )
    }

    func testFileThumbnailIdentityUsesTheSameKeyAsTheCache() {
        let url = URL(fileURLWithPath: "/tmp/clip.mp4")
        let size = CGSize(width: 96.4, height: 96.6)
        XCTAssertEqual(
            MacClippyFileThumbnailLoader.cacheKey(url: url, pointSize: size),
            "\(url.path)|96x97"
        )
    }

    private func pngData(from image: NSImage) -> Data? {
        var rect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            return nil
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        return bitmap.representation(using: .png, properties: [:])
    }
}
