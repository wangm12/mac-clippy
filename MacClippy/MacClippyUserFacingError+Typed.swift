import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyUserFacingError {
    static let storage = "Could not access clipboard storage. Try again."
    static let permission = "Mac Clippy needs permission to complete this action."
    static let corruptItem = "This item could not be read because it is damaged."
    static let missingItem = "This item is no longer available."

    static let clipboardBusy = "Could not copy because the current clipboard item is still loading."
    static let clipboardWrite = "Could not copy to the clipboard. Try again."
    static let clipboardRestore = "Could not restore the previous clipboard. Try again."

    static func message(for error: Error, fallback: String = genericAction) -> String {
        if let pasteboardMessage = message(forPasteboard: error, fallback: fallback) {
            return pasteboardMessage
        }
        if let storeError = error as? MacClippyStoreError {
            switch storeError {
            case .recordNotFound:
                return missingItem
            case .invalidStoredRecord:
                return corruptItem
            case .inputTooLarge:
                return fallback
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoPermissionError || nsError.code == NSFileWriteNoPermissionError {
            return permission
        }
        if MacClippyFailureClassification.isStorageFailure(error) {
            return storage
        }
        return fallback
    }

    private static func message(forPasteboard error: Error, fallback: String) -> String? {
        guard let pasteboardError = error as? MacClippyPasteboardPrepareError else {
            return nil
        }
        switch pasteboardError {
        case .incompleteSnapshot:
            return clipboardBusy
        case .writeFailed:
            return clipboardWrite
        case .restoreFailed:
            return clipboardRestore
        case .gateClosed:
            return fallback
        }
    }
}
