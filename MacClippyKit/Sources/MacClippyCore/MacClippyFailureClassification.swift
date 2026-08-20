import Foundation
import GRDB

public enum MacClippyFailureClassification {
    public static func isStorageFailure(_ error: Error) -> Bool {
        if error is DatabaseError { return true }
        let domain = (error as NSError).domain
        return domain.contains("GRDB") || domain.contains("SQLite")
    }
}
