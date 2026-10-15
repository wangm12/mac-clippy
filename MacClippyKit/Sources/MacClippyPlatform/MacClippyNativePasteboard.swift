import AppKit
import Foundation
import MacClippyObjCExceptionSupport

/// Narrow bridge for synchronous AppKit pasteboard calls. Each method maps to
/// one Objective-C function that catches its own NSException before returning
/// through a Swift frame.
@_spi(Testing) public enum MacClippyNativePasteboard {
    public static func changeCount(of pasteboard: NSPasteboard) throws -> Int {
        var value: NSInteger = 0
        var error: NSError?
        let completed = MacClippyPasteboardReadChangeCount(pasteboard, &value, &error)
        try check(completed, operation: "pasteboard.change-count", error: error)
        return Int(value)
    }

    public static func items(of pasteboard: NSPasteboard) throws -> [NSPasteboardItem] {
        var value: AnyObject?
        var error: NSError?
        let completed = MacClippyPasteboardReadItems(pasteboard, &value, &error)
        try check(completed, operation: "pasteboard.items", error: error)
        guard let array = value as? NSArray else {
            throw malformed("pasteboard.items", expectedType: "NSArray<NSPasteboardItem>")
        }
        var items: [NSPasteboardItem] = []
        items.reserveCapacity(array.count)
        for (index, object) in array.enumerated() {
            guard let item = object as? NSPasteboardItem else {
                throw malformed("pasteboard.items", expectedType: "NSPasteboardItem", index: index)
            }
            items.append(item)
        }
        return items
    }

    public static func boardTypes(of pasteboard: NSPasteboard) throws -> [String] {
        var value: AnyObject?
        var error: NSError?
        let completed = MacClippyPasteboardReadBoardTypes(pasteboard, &value, &error)
        try check(completed, operation: "pasteboard.board-types", error: error)
        return try strings(in: value, operation: "pasteboard.board-types")
    }

    public static func types(of item: NSPasteboardItem) throws -> [String] {
        var value: AnyObject?
        var error: NSError?
        let completed = MacClippyPasteboardReadItemTypes(item, &value, &error)
        try check(completed, operation: "pasteboard.item-types", error: error)
        return try strings(in: value, operation: "pasteboard.item-types")
    }

    public static func data(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType
    ) throws -> Data? {
        var value: AnyObject?
        var error: NSError?
        let completed = MacClippyPasteboardReadItemData(item, type, &value, &error)
        try check(completed, operation: "pasteboard.item-data", error: error)
        return try data(from: value, operation: "pasteboard.item-data")
    }

    public static func string(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType
    ) throws -> String? {
        var value: AnyObject?
        var error: NSError?
        let completed = MacClippyPasteboardReadItemString(item, type, &value, &error)
        try check(completed, operation: "pasteboard.item-string", error: error)
        return try string(from: value, operation: "pasteboard.item-string")
    }

    public static func data(from pasteboard: NSPasteboard, forType type: NSPasteboard.PasteboardType) throws -> Data? {
        var value: AnyObject?
        var error: NSError?
        let completed = MacClippyPasteboardReadBoardData(pasteboard, type, &value, &error)
        try check(completed, operation: "pasteboard.board-data", error: error)
        return try data(from: value, operation: "pasteboard.board-data")
    }

    public static func string(
        from pasteboard: NSPasteboard,
        forType type: NSPasteboard.PasteboardType
    ) throws -> String? {
        var value: AnyObject?
        var error: NSError?
        let completed = MacClippyPasteboardReadBoardString(pasteboard, type, &value, &error)
        try check(completed, operation: "pasteboard.board-string", error: error)
        return try string(from: value, operation: "pasteboard.board-string")
    }

    public static func clear(_ pasteboard: NSPasteboard) throws {
        var error: NSError?
        let completed = MacClippyPasteboardClearContents(pasteboard, &error)
        try check(completed, operation: "pasteboard.clear", error: error)
    }

    private static func strings(in value: AnyObject?, operation: String) throws -> [String] {
        guard let array = value as? NSArray else {
            throw malformed(operation, expectedType: "NSArray<NSString>")
        }
        var strings: [String] = []
        strings.reserveCapacity(array.count)
        for (index, object) in array.enumerated() {
            guard let string = object as? NSString else {
                throw malformed(operation, expectedType: "NSString", index: index)
            }
            strings.append(string as String)
        }
        return strings
    }

    private static func data(from value: AnyObject?, operation: String) throws -> Data? {
        guard let value else { return nil }
        guard let data = value as? NSData else {
            throw malformed(operation, expectedType: "NSData")
        }
        return data as Data
    }

    private static func string(from value: AnyObject?, operation: String) throws -> String? {
        guard let value else { return nil }
        guard let string = value as? NSString else {
            throw malformed(operation, expectedType: "NSString")
        }
        return string as String
    }

    private static func malformed(
        _ operation: String,
        expectedType: String,
        index: Int? = nil
    ) -> MacClippyMalformedNativePasteboardResult {
        MacClippyMalformedNativePasteboardResult(
            operation: operation,
            expectedType: expectedType,
            elementIndex: index
        )
    }

    public static func write(_ objects: [NSPasteboardWriting], to pasteboard: NSPasteboard) throws -> Bool {
        var didWrite: NSInteger = 0
        var error: NSError?
        let completed = MacClippyPasteboardWriteObjects(pasteboard, objects, &didWrite, &error)
        try check(completed, operation: "pasteboard.write-objects", error: error)
        return didWrite != 0
    }

    public static func set(
        _ data: Data,
        on item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType
    ) throws -> Bool {
        var didSet: NSInteger = 0
        var error: NSError?
        let completed = MacClippyPasteboardSetItemData(item, data, type, &didSet, &error)
        try check(completed, operation: "pasteboard.set-item-data", error: error)
        return didSet != 0
    }

    public static func set(
        _ string: String,
        on item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType
    ) throws -> Bool {
        var didSet: NSInteger = 0
        var error: NSError?
        let completed = MacClippyPasteboardSetItemString(item, string, type, &didSet, &error)
        try check(completed, operation: "pasteboard.set-item-string", error: error)
        return didSet != 0
    }

    static func injectExceptionForTesting(after operation: String, skippingMatchingOperations: Int = 0) {
        MacClippyPasteboardInjectExceptionForTesting(operation, NSInteger(skippingMatchingOperations))
    }

    private static func check(_ completed: Bool, operation: String, error: NSError?) throws {
        guard !completed else { return }
        let nativeError = error ?? NSError(
            domain: MacClippyObjectiveCExceptionDomain,
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey: "\(operation) failed before returning a native result",
                MacClippyObjectiveCExceptionNameKey: "NativePasteboardBoundaryFailure",
                MacClippyObjectiveCExceptionReasonKey: "",
                MacClippyObjectiveCExceptionCallStackKey: [String]()
            ]
        )
        throw MacClippyObjectiveCException(operation: operation, error: nativeError)
    }
}
