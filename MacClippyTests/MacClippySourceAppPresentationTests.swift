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
}
