import Foundation

import MacClippyCore
import MacClippyPlatform

enum MacClippyHistoryRecencyOrder {
    static func sorted(_ items: [MacClippyHistoryEntry]) -> [MacClippyHistoryEntry] {
        items.sorted { lhs, rhs in
            if lhs.meta.modified != rhs.meta.modified {
                return lhs.meta.modified > rhs.meta.modified
            }
            if lhs.meta.lamport != rhs.meta.lamport {
                return lhs.meta.lamport > rhs.meta.lamport
            }
            return lhs.id.rawValue > rhs.id.rawValue
        }
    }

    static func sortedIDs(_ metas: [ClipboardItemMeta]) -> [RecordID] {
        metas.sorted { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified > rhs.modified }
            if lhs.lamport != rhs.lamport { return lhs.lamport > rhs.lamport }
            return lhs.id.rawValue > rhs.id.rawValue
        }.map(\.id)
    }
}

struct MacClippyHistoryStructuredPageContext {
    let query: MacClippySearchGrammar.Query
    let limit: Int
    let needsKind: Bool
    let requestedKind: MacClippyContentKind?
}

extension MacClippyRuntime {
    func matchingStructuredMetasForPage(
        _ metas: [ClipboardItemMeta],
        context: MacClippyHistoryStructuredPageContext,
        shouldCancel: () -> Bool
    ) throws -> [ClipboardItemMeta] {
        let knownKinds = context.requestedKind.map { kind in
            Dictionary(uniqueKeysWithValues: metas.map { ($0.id, kind) })
        } ?? [:]
        return try matchingStructuredMetas(
            metas,
            limit: metas.count,
            query: context.query,
            needsKind: context.needsKind,
            knownKinds: knownKinds,
            shouldCancel: shouldCancel
        )
    }

    func recencySorted(_ items: [MacClippyHistoryEntry]) -> [MacClippyHistoryEntry] {
        MacClippyHistoryRecencyOrder.sorted(items)
    }

    func historyCursor(for meta: ClipboardItemMeta) -> MacClippyClipboardHistoryCursor {
        MacClippyClipboardHistoryCursor(
            modified: meta.modified,
            lamport: meta.lamport,
            id: meta.id
        )
    }

    func hasMoreInStructuredBatch(
        matchingMeta: ClipboardItemMeta,
        metas: [ClipboardItemMeta],
        batchLimit: Int
    ) -> Bool {
        var sourceIndex = metas.count - 1
        if let foundIndex = metas.firstIndex(where: { $0.id == matchingMeta.id }) {
            sourceIndex = foundIndex
        }
        return sourceIndex + 1 < metas.count || metas.count == batchLimit
    }
}
