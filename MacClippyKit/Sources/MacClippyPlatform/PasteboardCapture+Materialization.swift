import AppKit
import Foundation

import MacClippyCore

private struct MacClippyBoundedPasteboardTypes {
    let types: [String]
    let pasteboardTypes: [NSPasteboard.PasteboardType]
    let wasTruncated: Bool
}

private struct MacClippyMaterializedPasteboardPayloads {
    let representations: [String: Data]
    let oversizedTypes: Set<String>
}

struct MacClippyPasteboardSnapshotReadContext {
    let changeCount: Int
    var budget: MacClippyPasteboardSnapshotReadBudget
    var totalBytes = 0

    init(changeCount: Int, budget: MacClippyPasteboardSnapshotReadBudget = MacClippyPasteboardSnapshotReadBudget()) {
        self.changeCount = changeCount
        self.budget = budget
    }
}

extension MacClippySystemPasteboardReader {
    func rereadPasteboard(
        change: PasteboardChange,
        unavailableTypes: [(itemIndex: Int, uti: String)],
        shouldContinue: () -> Bool
    ) throws -> PasteboardChange {
        var context = MacClippyPasteboardSnapshotReadContext(
            changeCount: change.changeCount
        )
        guard !unavailableTypes.isEmpty,
              try isCurrent(context, shouldContinue: shouldContinue) else {
            return change
        }
        let pasteboardItems = try MacClippyNativePasteboard.items(of: pasteboard)
        guard try isCurrent(context, shouldContinue: shouldContinue) else { return change }

        var updatedItems = change.items
        for pending in unavailableTypes {
            guard try isCurrent(context, shouldContinue: shouldContinue) else { return change }
            guard pending.itemIndex < updatedItems.count,
                  pasteboardItems.indices.contains(pending.itemIndex) else { continue }

            let item = updatedItems[pending.itemIndex]
            let pasteboardItem = pasteboardItems[pending.itemIndex]
            let pasteboardType = NSPasteboard.PasteboardType(rawValue: pending.uti)
            let data = try readPayload(
                from: pasteboardItem,
                type: pasteboardType,
                context: &context,
                shouldContinue: shouldContinue
            )
            guard try isCurrent(context, shouldContinue: shouldContinue) else { return change }
            context.totalBytes = totalBytes(in: updatedItems)
            updatedItems[pending.itemIndex] = mergedItem(
                item,
                type: pending.uti,
                data: data,
                context: &context
            )
        }

        guard try isCurrent(context, shouldContinue: shouldContinue) else { return change }
        return PasteboardChange(
            changeCount: change.changeCount,
            items: updatedItems,
            sourceAppBundleID: change.sourceAppBundleID,
            truncatedItemCount: change.truncatedItemCount
        )
    }

    func materialize(
        sourceAppBundleID: String?,
        context: inout MacClippyPasteboardSnapshotReadContext,
        shouldContinue: () -> Bool
    ) throws -> PasteboardChange? {
        guard try isCurrent(context, shouldContinue: shouldContinue) else { return nil }
        let pasteboardItems = try MacClippyNativePasteboard.items(of: pasteboard)
        guard try isCurrent(context, shouldContinue: shouldContinue) else { return nil }

        var items: [PasteboardItem] = []
        items.reserveCapacity(min(pasteboardItems.count, inputLimits.maxItemsPerChange))
        for pasteboardItem in pasteboardItems.prefix(inputLimits.maxItemsPerChange) {
            guard try isCurrent(context, shouldContinue: shouldContinue) else { return nil }
            guard let item = try materializeItem(
                pasteboardItem,
                context: &context,
                shouldContinue: shouldContinue
            ) else {
                return nil
            }
            items.append(item)
        }

        guard try isCurrent(context, shouldContinue: shouldContinue) else { return nil }
        return PasteboardChange(
            changeCount: context.changeCount,
            items: items,
            sourceAppBundleID: sourceAppBundleID,
            truncatedItemCount: max(0, pasteboardItems.count - items.count)
        )
    }

    private func materializeItem(
        _ pasteboardItem: NSPasteboardItem,
        context: inout MacClippyPasteboardSnapshotReadContext,
        shouldContinue: () -> Bool
    ) throws -> PasteboardItem? {
        guard let bounded = try boundedTypes(
            from: pasteboardItem,
            context: context,
            shouldContinue: shouldContinue
        ),
              let payloads = try materializeRepresentations(
                  from: pasteboardItem,
                  types: bounded.pasteboardTypes,
                  context: &context,
                  shouldContinue: shouldContinue
              ) else {
            return nil
        }

        var types = bounded.types
        var oversizedTypes = payloads.oversizedTypes
        if bounded.wasTruncated {
            types.append(MacClippyPasteboardInputLimits.truncatedUTIMarker)
            oversizedTypes.insert(MacClippyPasteboardInputLimits.truncatedUTIMarker)
        }
        return PasteboardItem(
            types: types,
            representations: payloads.representations,
            oversizedTypes: oversizedTypes
        )
    }

    private func boundedTypes(
        from pasteboardItem: NSPasteboardItem,
        context: MacClippyPasteboardSnapshotReadContext,
        shouldContinue: () -> Bool
    ) throws -> MacClippyBoundedPasteboardTypes? {
        let advertisedTypes = try MacClippyNativePasteboard.types(of: pasteboardItem)
        guard try isCurrent(context, shouldContinue: shouldContinue) else { return nil }
        var types: [String] = []
        var pasteboardTypes: [NSPasteboard.PasteboardType] = []
        var wasTruncated = false
        for rawType in advertisedTypes {
            guard try isCurrent(context, shouldContinue: shouldContinue) else { return nil }
            let type = NSPasteboard.PasteboardType(rawValue: rawType)
            guard rawType.utf8.count <= inputLimits.maxUTIBytes,
                  pasteboardTypes.count < inputLimits.maxRepresentationsPerItem else {
                wasTruncated = true
                continue
            }
            types.append(rawType)
            pasteboardTypes.append(type)
        }
        return MacClippyBoundedPasteboardTypes(
            types: types,
            pasteboardTypes: pasteboardTypes,
            wasTruncated: wasTruncated
        )
    }

    private func materializeRepresentations(
        from pasteboardItem: NSPasteboardItem,
        types: [NSPasteboard.PasteboardType],
        context: inout MacClippyPasteboardSnapshotReadContext,
        shouldContinue: () -> Bool
    ) throws -> MacClippyMaterializedPasteboardPayloads? {
        var representations: [String: Data] = [:]
        var oversizedTypes = Set<String>()
        for type in types {
            guard try isCurrent(context, shouldContinue: shouldContinue) else { return nil }
            let data = try readPayload(
                from: pasteboardItem,
                type: type,
                context: &context,
                shouldContinue: shouldContinue
            )
            guard try isCurrent(context, shouldContinue: shouldContinue) else { return nil }
            guard let data else { continue }

            if accept(data, totalBytes: &context.totalBytes) {
                representations[type.rawValue] = data
            } else {
                oversizedTypes.insert(type.rawValue)
            }
        }
        return MacClippyMaterializedPasteboardPayloads(
            representations: representations,
            oversizedTypes: oversizedTypes
        )
    }

    private func readPayload(
        from pasteboardItem: NSPasteboardItem,
        type: NSPasteboard.PasteboardType,
        context: inout MacClippyPasteboardSnapshotReadContext,
        shouldContinue: () -> Bool
    ) throws -> Data? {
        let changeCount = context.changeCount
        let data = try context.budget.read(
            shouldContinue: shouldContinue,
            generationIsCurrent: { try MacClippyNativePasteboard.changeCount(of: pasteboard) == changeCount },
            operation: { try MacClippyNativePasteboard.data(from: pasteboardItem, forType: type) }
        )
        guard try isCurrent(context, shouldContinue: shouldContinue) else { return nil }
        if let data { return data }

        let string = try context.budget.read(
            shouldContinue: shouldContinue,
            generationIsCurrent: { try MacClippyNativePasteboard.changeCount(of: pasteboard) == changeCount },
            operation: { try MacClippyNativePasteboard.string(from: pasteboardItem, forType: type) }
        )
        guard try isCurrent(context, shouldContinue: shouldContinue) else { return nil }
        return string.map { Data($0.utf8) }
    }

    private func mergedItem(
        _ item: PasteboardItem,
        type: String,
        data: Data?,
        context: inout MacClippyPasteboardSnapshotReadContext
    ) -> PasteboardItem {
        guard let data else { return item }
        var representations = item.representations
        var oversizedTypes = item.oversizedTypes
        if accept(data, totalBytes: &context.totalBytes) {
            representations[type] = data
            oversizedTypes.remove(type)
        } else {
            oversizedTypes.insert(type)
        }
        return PasteboardItem(types: item.types, representations: representations, oversizedTypes: oversizedTypes)
    }

    private func isCurrent(
        _ context: MacClippyPasteboardSnapshotReadContext,
        shouldContinue: () -> Bool
    ) throws -> Bool {
        guard shouldContinue() else { return false }
        return try MacClippyNativePasteboard.changeCount(of: pasteboard) == context.changeCount
    }

    func emptyChange(at changeCount: Int) -> PasteboardChange {
        PasteboardChange(changeCount: changeCount, items: [])
    }

    private func accept(_ data: Data, totalBytes: inout Int) -> Bool {
        guard data.count <= inputLimits.maxRepresentationBytes,
              totalBytes <= inputLimits.maxChangeBytes - data.count else {
            return false
        }
        totalBytes += data.count
        return true
    }

    private func totalBytes(in items: [PasteboardItem]) -> Int {
        items.reduce(0) { total, item in
            total + item.representations.values.reduce(0) { $0 + $1.count }
        }
    }
}

struct MacClippyPasteboardSnapshotReadBudget {
    private let deadline: TimeInterval
    private var retriesRemaining = MacClippyPasteboardSnapshotReadPolicy.maxProviderRetries

    init(deadline: TimeInterval = ProcessInfo.processInfo.systemUptime
        + MacClippyPasteboardSnapshotReadPolicy.snapshotDeadline) {
        self.deadline = deadline
    }

    var isWithinDeadline: Bool {
        ProcessInfo.processInfo.systemUptime < deadline
    }

    mutating func read<Value>(
        shouldContinue: () -> Bool,
        generationIsCurrent: () throws -> Bool,
        operation: () throws -> Value?
    ) throws -> Value? {
        for attempt in 0..<MacClippyPasteboardReadRetry.defaultAttempts {
            guard try canContinue(shouldContinue: shouldContinue, generationIsCurrent: generationIsCurrent) else {
                return nil
            }

            let value = try operation()
            // A synchronous native provider call cannot be interrupted. The
            // deadline blocks new calls and retries, but a completed value is
            // valid if cancellation and generation still match.
            guard shouldContinue(), try generationIsCurrent() else {
                return nil
            }
            if let value { return value }
            guard attempt < MacClippyPasteboardReadRetry.defaultAttempts - 1,
                  retriesRemaining > 0 else {
                return nil
            }

            retriesRemaining -= 1
            if !Thread.isMainThread {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return nil }
                Thread.sleep(forTimeInterval: min(MacClippyPasteboardReadRetry.defaultDelay, remaining))
            }
        }
        return nil
    }

    private func canContinue(
        shouldContinue: () -> Bool,
        generationIsCurrent: () throws -> Bool
    ) throws -> Bool {
        guard shouldContinue(), try generationIsCurrent() else { return false }
        return isWithinDeadline
    }
}
