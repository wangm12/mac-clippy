import Foundation

/// Privacy rules fail closed when their cost or validity cannot be established.
/// ICU progress callbacks stop the matcher itself, including during backtracking.
struct MacClippyBoundedRegexMatcher: Sendable, Equatable {
    static let maximumPatternBytes = 8 * 1024
    static let maximumPatternCount = 128
    static let maximumInputBytes = 1024 * 1024
    static let evaluationBudgetNanoseconds: UInt64 = 20_000_000

    let patterns: [String]
    private let preparation: Preparation

    init(patterns: [String]) {
        self.patterns = patterns
        preparation = Preparation(patterns: patterns)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.patterns == rhs.patterns
    }

    static func compile(_ pattern: String) -> NSRegularExpression? {
        guard pattern.utf8.count <= maximumPatternBytes else { return nil }
        return try? NSRegularExpression(pattern: pattern)
    }

    func matches(_ text: String) -> Bool {
        guard !patterns.isEmpty else { return false }
        guard prepare(shouldContinue: { true }), var evaluation = preparedEvaluation() else { return true }
        return evaluation.shouldExcludeText(text)
    }

    var isPrepared: Bool { preparation.expressions != nil }

    func prepare(shouldContinue: @Sendable () -> Bool) -> Bool {
        preparation.prepare(patterns: patterns, shouldContinue: shouldContinue)
    }

    func preparedEvaluation() -> MacClippyCaptureTextExclusionEvaluation? {
        preparation.expressions.map { MacClippyCaptureTextExclusionEvaluation(expressions: $0) }
    }

    /// Compilation never holds the state lock. Readiness checks therefore stay
    /// cheap while the observer's dedicated preparation queue compiles rules.
    private final class Preparation: @unchecked Sendable {
        private let condition = NSCondition()
        private var cached: [NSRegularExpression?]?
        private var isCompiling = false

        init(patterns: [String]) {
            if patterns.isEmpty { cached = [] }
            if patterns.count > MacClippyBoundedRegexMatcher.maximumPatternCount { cached = [nil] }
        }

        var expressions: [NSRegularExpression?]? {
            condition.lock()
            defer { condition.unlock() }
            return cached
        }

        func prepare(patterns: [String], shouldContinue: @Sendable () -> Bool) -> Bool {
            guard beginPreparation(shouldContinue: shouldContinue) else { return expressions != nil }
            let compiled = compilePatterns(patterns, shouldContinue: shouldContinue)
            condition.lock()
            cached = compiled
            isCompiling = false
            condition.broadcast()
            condition.unlock()
            return compiled != nil
        }

        private func beginPreparation(shouldContinue: @Sendable () -> Bool) -> Bool {
            while shouldContinue() {
                condition.lock()
                if cached != nil { condition.unlock(); return false }
                if isCompiling {
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
                    condition.unlock()
                    continue
                }
                isCompiling = true
                condition.unlock()
                return true
            }
            return false
        }

        private func compilePatterns(
            _ patterns: [String],
            shouldContinue: @Sendable () -> Bool
        ) -> [NSRegularExpression?]? {
            var expressions: [NSRegularExpression?] = []
            var compiledByPattern: [String: NSRegularExpression] = [:]
            var invalidPatterns = Set<String>()
            for pattern in patterns {
                guard shouldContinue() else { return nil }
                if let existing = compiledByPattern[pattern] {
                    expressions.append(existing)
                } else if invalidPatterns.contains(pattern) {
                    expressions.append(nil)
                } else {
                    let expression = MacClippyBoundedRegexMatcher.compile(pattern)
                    if let expression {
                        compiledByPattern[pattern] = expression
                    } else {
                        invalidPatterns.insert(pattern)
                    }
                    expressions.append(expression)
                }
            }
            return shouldContinue() ? expressions : nil
        }
    }
}
