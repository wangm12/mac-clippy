import Foundation
import XCTest

@testable import MacClippyCore

final class MacClippyRegexBudgetTests: XCTestCase {
    func testCatastrophicBacktrackingStopsAndFailsClosed() throws {
        let text = String(repeating: "a", count: 1_000) + "!"
        let rules = CaptureExclusionRules(excludedTextPatterns: ["^(a+)+$"])
        let blocklist = try RegexBlocklist(patterns: ["^(a+)+$"])
        let started = Date()

        XCTAssertTrue(rules.shouldExcludeText(text))
        XCTAssertTrue(blocklist.matches(text))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        XCTAssertFalse(rules.shouldExcludeText("ordinary text"))
    }

    func testUpdatingRulesReplacesCompiledExpressionsAndPreservesValueSemantics() {
        var rules = CaptureExclusionRules(excludedTextPatterns: ["secret"])
        let original = rules
        rules.excludedTextPatterns = ["token\\s*="]

        XCTAssertTrue(original.shouldExcludeText("secret"))
        XCTAssertFalse(rules.shouldExcludeText("secret"))
        XCTAssertTrue(rules.shouldExcludeText("token = value"))
        XCTAssertEqual(rules, CaptureExclusionRules(excludedTextPatterns: ["token\\s*="]))
        rules.excludedTextPatterns = ["["]
        XCTAssertTrue(rules.shouldExcludeText("ordinary text"))
        rules.excludedTextPatterns = []
        XCTAssertFalse(rules.shouldExcludeText("token = value"))
    }

    func testResourceLimitsFailClosedWithoutRestrictingUnfilteredCapture() throws {
        let text = String(repeating: "x", count: MacClippyBoundedRegexMatcher.maximumInputBytes + 1)
        let pattern = String(repeating: "x", count: MacClippyBoundedRegexMatcher.maximumPatternBytes + 1)
        let patterns = Array(repeating: "secret", count: MacClippyBoundedRegexMatcher.maximumPatternCount + 1)

        XCTAssertTrue(CaptureExclusionRules(excludedTextPatterns: ["secret"]).shouldExcludeText(text))
        XCTAssertFalse(CaptureExclusionRules().shouldExcludeText(text))
        XCTAssertFalse(RegexBlocklist.isValid(pattern: pattern))
        XCTAssertThrowsError(try RegexBlocklist(patterns: patterns))
        XCTAssertTrue(CaptureExclusionRules(excludedTextPatterns: patterns).shouldExcludeText("ordinary"))
    }

    func testNormalUnicodeAndMultilineRulesRetainMatchingSemantics() throws {
        let rules = CaptureExclusionRules(excludedTextPatterns: ["(?m)^token\\s*=", "秘密"])
        XCTAssertTrue(rules.shouldExcludeText("first line\ntoken = value"))
        XCTAssertTrue(rules.shouldExcludeText("这是秘密"))
        XCTAssertFalse(rules.shouldExcludeText("ordinary text"))
    }

    func testRuleConstructionDefersExpensiveCompilationAndPendingEvaluationFailsClosed() {
        let patterns = Array(repeating: String(repeating: "\\p{Letter}", count: 800), count: 128)
        let started = Date()
        let rules = CaptureExclusionRules(excludedTextPatterns: patterns)

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertFalse(rules.isTextExclusionPrepared)
        XCTAssertNil(rules.preparedTextExclusionEvaluation())
        XCTAssertFalse(rules.prepareTextExclusions(shouldContinue: { false }))
        XCTAssertFalse(rules.isTextExclusionPrepared)
    }

    func testPreparationDoesNotBlockReadinessAndUnchangedRulesReuseIt() throws {
        let rules = CaptureExclusionRules(excludedTextPatterns: ["secret"])
        let gate = PreparationGate()
        let completed = expectation(description: "background rules prepared")
        DispatchQueue.global(qos: .utility).async {
            _ = rules.prepareTextExclusions(shouldContinue: { gate.shouldContinue() })
            completed.fulfill()
        }
        XCTAssertEqual(gate.entered.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(rules.isTextExclusionPrepared)
        XCTAssertNil(rules.preparedTextExclusionEvaluation())
        gate.release.signal()
        wait(for: [completed], timeout: 5)

        var repeated = CaptureExclusionRules(excludedTextPatterns: ["secret"])
            .reusingTextExclusionPreparation(from: rules)
        XCTAssertTrue(repeated.isTextExclusionPrepared)
        repeated.excludedTextPatterns = ["secret"]
        XCTAssertTrue(repeated.isTextExclusionPrepared)
        repeated.excludedTextPatterns = ["token"]
        XCTAssertFalse(repeated.isTextExclusionPrepared)
        XCTAssertTrue(rules.isTextExclusionPrepared)
        XCTAssertTrue(try XCTUnwrap(rules.preparedTextExclusionEvaluation()).isWithinBudget)
    }

    func testGenerationEvaluationSharesByteAndTimeBudgetsAcrossTexts() throws {
        let text = String(repeating: "x", count: 600_000)
        let rules = CaptureExclusionRules(excludedTextPatterns: ["^secret"])
        XCTAssertTrue(rules.prepareTextExclusions())
        var evaluation = try XCTUnwrap(rules.preparedTextExclusionEvaluation())
        XCTAssertFalse(evaluation.shouldExcludeText(text))
        XCTAssertTrue(evaluation.shouldExcludeText(text))

        var encodedEvaluation = try XCTUnwrap(rules.preparedTextExclusionEvaluation())
        XCTAssertTrue(encodedEvaluation.allowRepresentation(byteCount: 600_000))
        XCTAssertFalse(encodedEvaluation.allowRepresentation(byteCount: 600_000))
        XCTAssertTrue(encodedEvaluation.shouldExcludeText("ordinary"))

        var elapsedEvaluation = try XCTUnwrap(rules.preparedTextExclusionEvaluation())
        XCTAssertFalse(elapsedEvaluation.shouldExcludeText("ordinary"))
        Thread.sleep(forTimeInterval: 0.03)
        XCTAssertTrue(elapsedEvaluation.shouldExcludeText("still ordinary"))
        XCTAssertFalse(elapsedEvaluation.isWithinBudget)
    }

    private final class PreparationGate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var paused = false

        func shouldContinue() -> Bool {
            lock.lock()
            let shouldPause = !paused
            paused = true
            lock.unlock()
            guard shouldPause else { return true }
            entered.signal()
            return release.wait(timeout: .now() + 5) == .success
        }
    }
}
