import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import XCTest

import MacClippyCore
@testable import MacClippyPlatform

final class MacClippyPasteboardPrivacyTests: XCTestCase {
    func testEveryRetainedTextRepresentationIsFilteredBeforeObserverStoreRoundTrip() throws {
        let store = try ClipboardStore(database: MacClippyDatabase(inMemory: true), deviceKey: key())
        let rules = preparedRules()
        let reader = PrivacyReader()
        let observer = PasteboardObserver(reader: reader, exclusionRules: rules, pollInterval: 3_600)
        var storedIDs: [RecordID] = []
        var failures: [Error] = []
        observer.start(
            admissionHandler: { _ in MacClippyPasteboardCaptureAdmission(finish: { _ in }) },
            admittedProjectionHandler: { _, projection, admission in
                do {
                    let meta = try store.append(
                        .text(projection.searchableText ?? "(non-text preview)"),
                        representations: projection.representations
                    )
                    storedIDs.append(meta.id)
                    admission.finish(wasPersisted: true)
                } catch { failures.append(error) }
            }
        )
        defer { observer.stop() }
        observer.poll()
        for (offset, fixture) in blockedFixtures().enumerated() {
            reader.replace(PasteboardChange(changeCount: offset + 2, items: fixture))
            observer.poll()
        }
        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(storedIDs.isEmpty)
        XCTAssertEqual(try store.databaseRowCount(), 0)

        reader.replace(PasteboardChange(changeCount: 100, items: [textItem("ordinary")]))
        observer.poll()
        let allowedID = try XCTUnwrap(storedIDs.first)
        XCTAssertEqual(try store.representations(for: allowedID).first?.payloadBytes, Data("ordinary".utf8))
        XCTAssertEqual(try store.databaseRowCount(), 1)

        observer.updateExclusionRules(CaptureExclusionRules())
        reader.replace(PasteboardChange(changeCount: 101, items: [textItem("token = secret")]))
        observer.poll()
        XCTAssertEqual(storedIDs.count, 2)
        XCTAssertEqual(try store.representations(for: storedIDs[1]).first?.payloadBytes, Data("token = secret".utf8))
    }

    func testEquivalentDefaultsRulesKeepPreparationAndPendingReplacementFailsClosed() throws {
        let compilationQueue = DispatchQueue(label: "MacClippyPrivacyTests.preparation")
        let release = DispatchSemaphore(value: 0)
        compilationQueue.async { _ = release.wait(timeout: .now() + 5) }
        defer { release.signal() }
        let reader = PrivacyReader()
        let observer = PasteboardObserver(
            reader: reader, exclusionRules: preparedRules(), pollInterval: 3_600,
            textRulePreparationQueue: compilationQueue
        )
        var delivered: [Int] = []
        observer.start { delivered.append($0.changeCount) }
        defer { observer.stop() }
        observer.poll()
        observer.updateExclusionRules(CaptureExclusionRules(excludedTextPatterns: ["token\\s*="]))
        reader.replace(PasteboardChange(changeCount: 2, items: [textItem("ordinary")]))
        observer.poll()
        XCTAssertEqual(delivered, [2])

        observer.updateExclusionRules(CaptureExclusionRules(excludedTextPatterns: ["different-secret"]))
        reader.replace(PasteboardChange(changeCount: 3, items: [textItem("ordinary")]))
        observer.poll()
        XCTAssertEqual(delivered, [2])
        observer.updateExclusionRules(CaptureExclusionRules())
        reader.replace(PasteboardChange(changeCount: 4, items: [textItem("different-secret")]))
        observer.poll()
        XCTAssertEqual(delivered, [2, 4])
        release.signal()
        compilationQueue.sync {}
        reader.replace(PasteboardChange(changeCount: 5, items: [textItem("different-secret")]))
        observer.poll()
        XCTAssertEqual(delivered, [2, 4, 5])
    }

    func testTextDecodingMatchesEntitiesRTFAndUTF16WithoutInspectingBinaryImages() {
        let rules = preparedRules()
        let fixtures = [
            item("public.html", Data("<p>tok&#101;n = secret</p>".utf8)),
            item("public.rtf", Data("{\\rtf1\\ansi tok\\'65n = secret}".utf8)),
            item("public.utf16-plain-text", "token = secret".data(using: .utf16LittleEndian)!)
        ]
        for fixture in fixtures {
            XCTAssertTrue(MacClippyPasteboardPrivacyTextFilter.shouldExclude(
                PasteboardChange(changeCount: 1, items: [fixture]), rules: rules
            ))
        }
        XCTAssertFalse(MacClippyPasteboardPrivacyTextFilter.shouldExclude(
            PasteboardChange(changeCount: 1, items: [item("public.png", Data(repeating: 0xFF, count: 2_000_000))]),
            rules: rules
        ))
    }

    func testHTMLFiltersEntitiesInAttributesCommentsAndBothTagBoundaryForms() {
        let ordinaryRules = preparedRules()
        let hidden = [
            "<p data-secret='tok&#101;n = secret'>ordinary</p>",
            "<!-- tok&#101;n = secret --><p>ordinary</p>",
            "to<span>ken</span>= secret"
        ]
        for html in hidden { XCTAssertTrue(excludes(html: html, rules: ordinaryRules)) }
        let spaced = CaptureExclusionRules(excludedTextPatterns: ["token\\s+="])
        XCTAssertTrue(spaced.prepareTextExclusions())
        XCTAssertTrue(excludes(html: "token<br>= secret", rules: spaced))
        XCTAssertTrue(excludes(html: "token<p>= secret</p>", rules: spaced))
        let newline = CaptureExclusionRules(excludedTextPatterns: ["token\n="])
        XCTAssertTrue(newline.prepareTextExclusions())
        XCTAssertTrue(excludes(html: "<table><tr><td>token</td><td>= secret</td></tr></table>", rules: newline))
        XCTAssertFalse(excludes(html: "<p>ordinary&nbsp;text</p>", rules: ordinaryRules))
        XCTAssertFalse(excludes(html: "<p>ordinary<img src='https://example.invalid/track'></p>", rules: ordinaryRules))
        XCTAssertTrue(excludes(html: "<p>unknown &unsupportedNamedEntity;</p>", rules: ordinaryRules))
    }

    func testRTFAllowsSupportedFormattingAndFiltersEscapesAndControlBoundaries() {
        let rules = preparedRules()
        let hidden = [
            "{\\rtf1\\ansi tok\\'65n = secret}",
            "{\\rtf1\\uc1 \\u116?oken = secret}",
            "{\\rtf1 to{\\b k}en = secret}"
        ]
        for rtf in hidden { XCTAssertTrue(excludes(rtf: rtf, rules: rules)) }
        let ordinary = "{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0\\fnil\\fcharset0 Helvetica;}}\\f0\\fs24 ordinary}"
        XCTAssertFalse(excludes(rtf: ordinary, rules: rules))
        XCTAssertFalse(excludes(rtf: "{\\rtf1\\uc1\\u-10179?\\u-8704?}", rules: rules))
        let emoji = CaptureExclusionRules(excludedTextPatterns: ["😀"])
        XCTAssertTrue(emoji.prepareTextExclusions())
        XCTAssertTrue(excludes(rtf: "{\\rtf1\\uc1\\u-10179?\\u-8704?}", rules: emoji))
        let spaced = CaptureExclusionRules(excludedTextPatterns: ["token\\s+="])
        XCTAssertTrue(spaced.prepareTextExclusions())
        for control in ["line", "page", "cell", "row"] {
            XCTAssertTrue(excludes(rtf: "{\\rtf1 token\\\(control) = secret}", rules: spaced))
        }
    }

    func testUnsupportedRTFAndRTFDStayExcludedOnlyWhenRulesAreEnabled() {
        let rules = preparedRules()
        for rtf in [
            "{\\rtf1\\ansicpg932 ordinary}", "{\\rtf1\\uc1\\u-10179?}",
            "{\\rtf1 to{\\upr{bad}{\\*\\ud k}}en = secret}", "{\\rtf1\\unknownTextControl ordinary}"
        ] {
            XCTAssertTrue(excludes(rtf: rtf, rules: rules))
        }
        for type in ["com.apple.flat-rtfd", UTType.rtfd.identifier] {
            let change = PasteboardChange(changeCount: 1, items: [item(type, Data("wrapper".utf8))])
            XCTAssertTrue(MacClippyPasteboardPrivacyTextFilter.shouldExclude(change, rules: rules))
            XCTAssertFalse(MacClippyPasteboardPrivacyTextFilter.shouldExclude(change, rules: CaptureExclusionRules()))
        }
    }

    func testBOMIdentifiesCustomTextWithoutGuessingBinaryEncoding() {
        let rules = preparedRules()
        for encoding in [String.Encoding.utf16, .utf32] {
            let change = PasteboardChange(changeCount: 1, items: [
                item("com.review.custom-bom-text", "token = secret".data(using: encoding)!)
            ])
            XCTAssertTrue(MacClippyPasteboardPrivacyTextFilter.shouldExclude(change, rules: rules))
        }
    }

    func testPureNormalizersStopWhenTheirSharedBudgetIsUnavailable() {
        let html = String(repeating: "&#97;", count: 10_000)
        let rtf = Data(("{\\rtf1 " + String(repeating: "\\'61", count: 10_000) + "}").utf8)
        XCTAssertNil(MacClippyPasteboardPrivacyHTML.texts(html, isWithinBudget: { false }))
        XCTAssertNil(MacClippyPasteboardPrivacyRTF.texts(rtf, isWithinBudget: { false }))
    }

    private func excludes(html: String, rules: CaptureExclusionRules) -> Bool {
        MacClippyPasteboardPrivacyTextFilter.shouldExclude(
            PasteboardChange(changeCount: 1, items: [item("public.html", Data(html.utf8))]), rules: rules
        )
    }

    private func excludes(rtf: String, rules: CaptureExclusionRules) -> Bool {
        MacClippyPasteboardPrivacyTextFilter.shouldExclude(
            PasteboardChange(changeCount: 1, items: [item("public.rtf", Data(rtf.utf8))]), rules: rules
        )
    }

    private func blockedFixtures() -> [[PasteboardItem]] {
        let secret = Data("token = secret".utf8)
        let large = textItem(String(repeating: "x", count: 400_000))
        return [
            [textItem("token = secret")],
            [textItem("ordinary"), textItem("token = secret")],
            [PasteboardItem(types: ["public.png", "public.utf8-plain-text"], representations: [
                "public.png": Data([0x89, 0x50, 0x4E, 0x47]), "public.utf8-plain-text": secret
            ])],
            [PasteboardItem(types: ["public.file-url", "public.utf8-plain-text"], representations: [
                "public.file-url": Data("file:///tmp/synthetic.txt".utf8), "public.utf8-plain-text": secret
            ])],
            [textItem("ordinary"), item("public.html", Data("<p>token = secret</p>".utf8))],
            [textItem("ordinary"), item("public.rtf", Data("{\\rtf1 token = secret}".utf8))],
            [textItem("ordinary"), item("com.review.custom-text", secret)],
            [item("public.utf8-plain-text", Data([0xFF]))],
            [PasteboardItem(types: ["public.utf8-plain-text"])],
            [large, large, large]
        ]
    }

    private func preparedRules() -> CaptureExclusionRules {
        let rules = CaptureExclusionRules(excludedTextPatterns: ["token\\s*="])
        XCTAssertTrue(rules.prepareTextExclusions())
        return rules
    }

    private func textItem(_ text: String) -> PasteboardItem {
        item("public.utf8-plain-text", Data(text.utf8))
    }

    private func item(_ type: String, _ data: Data) -> PasteboardItem {
        PasteboardItem(types: [type], representations: [type: data])
    }

    private func key() -> SymmetricKey { SymmetricKey(data: Data(repeating: 19, count: 32)) }

    private final class PrivacyReader: PasteboardReading {
        private let lock = NSLock()
        private var change = PasteboardChange(changeCount: 1, items: [])
        func replace(_ newChange: PasteboardChange) { lock.lock(); change = newChange; lock.unlock() }
        func currentChangeCount() -> Int { lock.lock(); defer { lock.unlock() }; return change.changeCount }
        func read() -> PasteboardChange { lock.lock(); defer { lock.unlock() }; return change }
    }
}
