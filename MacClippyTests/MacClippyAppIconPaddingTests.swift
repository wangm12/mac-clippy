import AppKit
import XCTest

@testable import MacClippy

final class MacClippyAppIconPaddingTests: XCTestCase {
    func testLargestAppIconUsesTransparentTahoeContentMargin() throws {
        let url = repositoryRoot()
            .appendingPathComponent("MacClippy/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png")
        let image = try XCTUnwrap(NSImage(contentsOf: url))
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))

        XCTAssertEqual(rep.pixelsWide, 1024)
        XCTAssertEqual(rep.pixelsHigh, 1024)
        XCTAssertEqual(alpha(rep, x: 0, y: 0), 0)
        XCTAssertEqual(alpha(rep, x: 1023, y: 0), 0)
        XCTAssertEqual(alpha(rep, x: 0, y: 1023), 0)
        XCTAssertEqual(alpha(rep, x: 1023, y: 1023), 0)

        let bounds = opaqueBounds(rep, threshold: 8)
        XCTAssertEqual(Double(bounds.width), 824, accuracy: 16)
        XCTAssertEqual(Double(bounds.height), 824, accuracy: 16)
    }

    func testStatusItemUsesTemplatePolicyInsteadOfTheAppIcon() throws {
        let url = repositoryRoot()
            .appendingPathComponent("MacClippy/MacClippyAppDelegate+Maintenance.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(source.contains("MacClippyStatusItemIconPolicy"))
        XCTAssertFalse(source.contains("bundledApplicationIcon?.copy()"))
        XCTAssertFalse(source.contains("NSImage.applicationIconName"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func alpha(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Int {
        Int(((rep.colorAt(x: x, y: y)?.alphaComponent ?? -1) * 255).rounded())
    }

    private func opaqueBounds(_ rep: NSBitmapImageRep, threshold: Int) -> NSRect {
        var minX = rep.pixelsWide
        var minY = rep.pixelsHigh
        var maxX = -1
        var maxY = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard alpha(rep, x: x, y: y) > threshold else { continue }
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
        return NSRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX + 1),
            height: max(0, maxY - minY + 1)
        )
    }
}
