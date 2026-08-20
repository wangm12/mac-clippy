import Foundation

import MacClippyCore

extension MacClippyUserFacingError {
    static let storage = "Could not access clipboard storage. Try again."
    static let permission = "Mac Clippy needs permission to complete this action."
    static let corruptItem = "This item could not be read because it is damaged."
    static let missingItem = "This item is no longer available."

    static func message(for error: Error, fallback: String = genericAction) -> String {
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
}
