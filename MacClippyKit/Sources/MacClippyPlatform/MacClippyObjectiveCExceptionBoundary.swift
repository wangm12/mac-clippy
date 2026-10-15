import Foundation
import MacClippyObjCExceptionSupport

public struct MacClippyObjectiveCException: Error, Equatable, LocalizedError, Sendable {
    public let operation: String
    public let name: String
    public let reason: String
    public let callStack: [String]
    /// True only when the native operation returned before a later exception
    /// was raised. False means its side effects may be unknown.
    public let nativeOperationCompleted: Bool

    public var errorDescription: String? {
        let detail = reason.isEmpty ? name : "\(name): \(reason)"
        return "\(operation): \(String(detail.prefix(512)))"
    }

    init(operation: String, error: NSError) {
        self.operation = String(operation.prefix(128))
        name = String((error.userInfo[MacClippyObjectiveCExceptionNameKey] as? String ?? "NSException").prefix(128))
        reason = String((error.userInfo[MacClippyObjectiveCExceptionReasonKey] as? String ?? "").prefix(512))
        callStack = (error.userInfo[MacClippyObjectiveCExceptionCallStackKey] as? [String] ?? [])
            .prefix(8)
            .map { String($0.prefix(256)) }
        nativeOperationCompleted = error.userInfo[MacClippyNativeOperationCompletedKey] as? Bool ?? false
    }
}

public struct MacClippyMalformedNativePasteboardResult: Error, Equatable, LocalizedError, Sendable {
    public let operation: String
    public let expectedType: String
    public let elementIndex: Int?

    init(operation: String, expectedType: String, elementIndex: Int? = nil) {
        self.operation = String(operation.prefix(128))
        self.expectedType = String(expectedType.prefix(64))
        self.elementIndex = elementIndex.map { max(0, $0) }
    }

    public var errorDescription: String? {
        let location = elementIndex.map { " at index \($0)" } ?? ""
        return "\(operation) returned a malformed native result\(location); expected \(expectedType)."
    }
}
