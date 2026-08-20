import Foundation

public extension MacClippySearchGrammar.Query {
    var hasConflictingContentTypes: Bool {
        var kinds: Set<MacClippyContentKind> = []
        var hasURL = false
        for clause in clauses {
            switch clause {
            case let .type(kind):
                kinds.insert(kind)
            case .url:
                hasURL = true
            default:
                break
            }
        }
        if kinds.count > 1 { return true }
        if hasURL, let kind = kinds.first {
            return kind == .image || kind == .files
        }
        return false
    }
}
