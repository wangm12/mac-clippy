import Foundation

import MacClippyCore

final class MacClippyTextRulePreparationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var shouldContinue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

extension MacClippyPasteboardObserver {
    func applyExclusionRulesOnLifecycleQueue(_ rules: CaptureExclusionRules) {
        let patternsChanged = rules.excludedTextPatterns != exclusionRules.excludedTextPatterns
        exclusionRules = rules.reusingTextExclusionPreparation(from: exclusionRules)
        guard patternsChanged else { return }
        textRulePreparationToken?.cancel()
        textRulePreparationToken = nil
        prepareTextExclusionsOnLifecycleQueue()
    }

    func prepareTextExclusionsOnLifecycleQueue() {
        guard !exclusionRules.isTextExclusionPrepared, textRulePreparationToken == nil else { return }
        let token = MacClippyTextRulePreparationToken()
        textRulePreparationToken = token
        let rules = exclusionRules
        textRulePreparationQueue.async { [weak self, rules, token] in
            guard rules.prepareTextExclusions(shouldContinue: { token.shouldContinue }) else { return }
            self?.enqueueOnLifecycleQueue { [weak self, token] in
                guard let self, self.textRulePreparationToken === token else { return }
                self.textRulePreparationToken = nil
            }
        }
    }
}
