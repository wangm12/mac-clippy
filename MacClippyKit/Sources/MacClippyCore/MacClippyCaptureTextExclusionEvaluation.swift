import Foundation

/// One evaluation is shared by every textual representation of a pasteboard
/// generation. Both decoding inputs and matched text have cumulative limits.
public struct MacClippyCaptureTextExclusionEvaluation: Sendable {
    private let expressions: [NSRegularExpression?]
    private let started = DispatchTime.now().uptimeNanoseconds
    private var remainingEncodedBytes = MacClippyBoundedRegexMatcher.maximumInputBytes
    private var remainingTextBytes = MacClippyBoundedRegexMatcher.maximumInputBytes
    private var excluded = false

    init(expressions: [NSRegularExpression?]) {
        self.expressions = expressions
        excluded = expressions.contains { $0 == nil }
    }

    public var isWithinBudget: Bool {
        expressions.isEmpty || (!excluded && elapsed < MacClippyBoundedRegexMatcher.evaluationBudgetNanoseconds)
    }

    /// Check before allocating or decoding an advertised textual payload.
    public mutating func allowRepresentation(byteCount: Int) -> Bool {
        guard !expressions.isEmpty else { return true }
        guard isWithinBudget, byteCount >= 0, byteCount <= remainingEncodedBytes else {
            excluded = true
            return false
        }
        remainingEncodedBytes -= byteCount
        return true
    }

    public mutating func shouldExcludeText(_ text: String) -> Bool {
        guard !expressions.isEmpty else { return false }
        guard isWithinBudget, text.utf8.count <= remainingTextBytes else {
            excluded = true
            return true
        }
        remainingTextBytes -= text.utf8.count
        let range = NSRange(location: 0, length: text.utf16.count)
        for expression in expressions {
            guard let expression else { excluded = true; return true }
            if matchesOrExceedsBudget(expression, text: text, range: range) {
                excluded = true
                return true
            }
        }
        return false
    }

    private var elapsed: UInt64 { DispatchTime.now().uptimeNanoseconds - started }

    private func matchesOrExceedsBudget(
        _ expression: NSRegularExpression, text: String, range: NSRange
    ) -> Bool {
        let began = started
        let budget = MacClippyBoundedRegexMatcher.evaluationBudgetNanoseconds
        var blocked = false
        expression.enumerateMatches(in: text, options: .reportProgress, range: range) { match, flags, stop in
            if match != nil || flags.contains(.internalError)
                || DispatchTime.now().uptimeNanoseconds - began >= budget {
                blocked = true
                stop.pointee = true
            }
        }
        return blocked || elapsed >= MacClippyBoundedRegexMatcher.evaluationBudgetNanoseconds
    }
}
