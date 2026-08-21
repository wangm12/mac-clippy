import XCTest

import MacClippyCore

final class MacClippyClipboardPresentationTests: XCTestCase {
    func testClassifiesHexColorBeforePlainText() {
        XCTAssertEqual(
            MacClippyClipboardPresentation.kind(forPlainText: "#0A84FF"),
            .color(
                MacClippyColorSwatch(
                    hex: "#0A84FF",
                    rgb: MacClippyRGB(red: 10, green: 132, blue: 255),
                    hslDisplay: "hsl(210, 100%, 52%)"
                )
            )
        )
    }

    func testClassifiesRGBColorBeforePlainText() {
        XCTAssertEqual(
            MacClippyClipboardPresentation.kind(forPlainText: "rgb(10, 132, 255)"),
            .color(
                MacClippyColorSwatch(
                    hex: "#0A84FF",
                    rgb: MacClippyRGB(red: 10, green: 132, blue: 255),
                    hslDisplay: "hsl(210, 100%, 52%)"
                )
            )
        )
    }

    func testClassifiesSingleHTTPURL() {
        XCTAssertEqual(
            MacClippyClipboardPresentation.kind(forPlainText: "https://example.com"),
            .url
        )
    }

    func testClassifiesSingleWWWURL() {
        XCTAssertEqual(
            MacClippyClipboardPresentation.kind(forPlainText: "www.example.com"),
            .url
        )
    }

    func testClassifiesJSONObject() {
        XCTAssertEqual(
            MacClippyClipboardPresentation.kind(forPlainText: "{\"a\":1}"),
            .json
        )
    }

    func testDoesNotClassifyJSONScalarRootsAsJSON() {
        XCTAssertEqual(MacClippyClipboardPresentation.kind(forPlainText: "\"hello\""), .plain)
        XCTAssertEqual(MacClippyClipboardPresentation.kind(forPlainText: "42"), .plain)
        XCTAssertEqual(MacClippyClipboardPresentation.kind(forPlainText: "true"), .plain)
    }

    func testClassifiesCodeAfterJSON() {
        XCTAssertEqual(
            MacClippyClipboardPresentation.kind(forPlainText: "func foo() {}"),
            .code
        )
    }

    func testClassifiesPlainText() {
        XCTAssertEqual(
            MacClippyClipboardPresentation.kind(forPlainText: "hello"),
            .plain
        )
    }

    func testProseContainingURLStaysPlain() {
        XCTAssertEqual(
            MacClippyClipboardPresentation.kind(forPlainText: "see https://x.com"),
            .plain
        )
    }
}
