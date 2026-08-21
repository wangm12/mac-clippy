import Foundation

public enum MacClippyPasteboardPrepareError: Error, Equatable, Sendable {
    case incompleteSnapshot
    case writeFailed
    case restoreFailed
    case gateClosed
}
