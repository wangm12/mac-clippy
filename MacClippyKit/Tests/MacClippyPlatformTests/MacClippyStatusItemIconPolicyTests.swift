import AppKit
import XCTest

@testable import MacClippyPlatform

final class MacClippyStatusItemIconPolicyTests: XCTestCase {
    func testPreparedImageIsATemplateAtEighteenPoints() {
        let source = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(rect: rect).fill()
            return true
        }

        let image = MacClippyStatusItemIconPolicy.prepared(source)

        XCTAssertEqual(image?.isTemplate, true)
        XCTAssertEqual(image?.size, MacClippyStatusItemIconPolicy.pointSize)
        XCTAssertEqual(MacClippyStatusItemIconPolicy.pointSize, NSSize(width: 18, height: 18))
    }

    func testMakeImagePrefersTheNamedAssetOverTheFallbackSymbol() {
        let named = NSImage(size: NSSize(width: 36, height: 36), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4)).fill()
            return true
        }
        named.accessibilityDescription = "named-scissors"

        let image = MacClippyStatusItemIconPolicy.makeImage(
            namedImage: named,
            fallbackSystemSymbolName: "circle"
        )

        XCTAssertEqual(image?.isTemplate, true)
        XCTAssertEqual(image?.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(image?.accessibilityDescription, "named-scissors")
    }

    func testMakeImageFallsBackToScissorsSymbolInsteadOfTheAppIcon() {
        XCTAssertEqual(MacClippyStatusItemIconPolicy.imageName, "MenuBarIcon")
        XCTAssertEqual(MacClippyStatusItemIconPolicy.fallbackSystemSymbolName, "scissors")

        let image = MacClippyStatusItemIconPolicy.makeImage(namedImage: nil)

        XCTAssertEqual(image?.isTemplate, true)
        XCTAssertEqual(image?.size, NSSize(width: 18, height: 18))
        XCTAssertNotEqual(image?.name(), NSImage.applicationIconName)
    }
}
