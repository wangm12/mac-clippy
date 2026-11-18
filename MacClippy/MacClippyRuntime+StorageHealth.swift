import Foundation

import MacClippyCore

extension MacClippyRuntime {
    func isCorruptStoredRecord(_ error: Error) -> Bool {
        if error is DecodingError {
            return true
        }
        if let storeError = error as? MacClippyStoreError,
           case .invalidStoredRecord = storeError {
            return true
        }
        if let cipherError = error as? MacClippyCipherError {
            switch cipherError {
            case .invalidEnvelope:
                return true
            case .openFailed, .sealFailed:
                return false
            }
        }
        if let blobError = error as? MacClippyBlobError {
            switch blobError {
            case .invalidIdentifier, .missingBlob:
                return true
            case .payloadTooLarge, .activeReadLease:
                return false
            }
        }
        return false
    }

    func recordCorruptStoredRecord(operation: String) {
        MacClippyLog.record(
            category: .storage,
            code: .corruptStoredRecord,
            operation: operation,
            recoveryAction: "repair_or_delete_corrupt_record",
            impact: "record_skipped"
        )
    }
}
