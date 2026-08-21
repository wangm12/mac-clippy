import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    private static let selectionRecordIDPageSize = 256

    /// Resolves the complete ordered History selection without decrypting or
    /// materializing card bodies. Cmd+A uses this instead of loading every
    /// remaining card into the carousel.
    func historyRecordIDs(
        query: String,
        shouldCancel: () -> Bool = { false }
    ) throws -> [RecordID] {
        try withStoreLock {
            try historyRecordIDsLocked(query: query, shouldCancel: shouldCancel)
        }
    }

    private func historyRecordIDsLocked(
        query: String,
        shouldCancel: () -> Bool
    ) throws -> [RecordID] {
        guard !shouldCancel() else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return try historyRecordIDsForEmptyQuery(shouldCancel: shouldCancel)
        }

        let parsed = MacClippySearchGrammar.parse(trimmedQuery)
        guard parsed.hasStructuredClauses else {
            return try historyRecordIDsForBareQuery(
                parsed.bareTerms,
                shouldCancel: shouldCancel
            )
        }

        let requestedKinds = parsed.clauses.compactMap { clause -> MacClippyContentKind? in
            if case let .type(kind) = clause { return kind }
            return nil
        }
        guard Set(requestedKinds).count <= 1 else { return [] }
        let requestedKind = requestedKinds.first
        let needsKind = !requestedKinds.isEmpty
        let context = MacClippyHistoryStructuredPageContext(
            query: parsed,
            limit: Self.selectionRecordIDPageSize,
            needsKind: needsKind,
            requestedKind: requestedKind
        )
        if parsed.isStructuredOnly {
            return try historyRecordIDsForStructuredOnlyQuery(
                context,
                shouldCancel: shouldCancel
            )
        }
        return try historyRecordIDsForBareAndStructuredQuery(
            context,
            shouldCancel: shouldCancel
        )
    }

    private func historyRecordIDsForEmptyQuery(
        shouldCancel: () -> Bool
    ) throws -> [RecordID] {
        var cursor: MacClippyClipboardHistoryCursor?
        var ids: [RecordID] = []
        while true {
            guard !shouldCancel() else { return [] }
            let metas = try clipboardStore.list(
                limit: Self.selectionRecordIDPageSize,
                before: cursor
            )
            guard !metas.isEmpty else { return ids }
            ids.append(contentsOf: metas.map(\.id))
            guard metas.count == Self.selectionRecordIDPageSize,
                  let last = metas.last else { return ids }
            cursor = historyCursor(for: last)
        }
    }

    private func historyRecordIDsForBareQuery(
        _ terms: [String],
        shouldCancel: () -> Bool
    ) throws -> [RecordID] {
        var cursor: MacClippySearchCursor?
        var collected: [ClipboardItemMeta] = []
        while true {
            guard !shouldCancel() else { return [] }
            let hits = try searchStore.search(
                terms: terms,
                limit: Self.selectionRecordIDPageSize,
                after: cursor
            )
            guard !hits.isEmpty else { return MacClippyHistoryRecencyOrder.sortedIDs(collected) }
            let metas = try clipboardStore.metas(for: hits.map(\.id))
            collected.append(contentsOf: metas)
            guard hits.count == Self.selectionRecordIDPageSize, let last = hits.last else {
                return MacClippyHistoryRecencyOrder.sortedIDs(collected)
            }
            cursor = MacClippySearchCursor(rank: last.rank, rowID: last.rowID)
        }
    }

    private func historyRecordIDsForStructuredOnlyQuery(
        _ context: MacClippyHistoryStructuredPageContext,
        shouldCancel: () -> Bool
    ) throws -> [RecordID] {
        var cursor: MacClippyClipboardHistoryCursor?
        var ids: [RecordID] = []
        let filter = metadataFilter(for: context.query, contentKind: context.requestedKind)
        while true {
            guard !shouldCancel() else { return [] }
            let metas = try clipboardStore.list(
                limit: Self.selectionRecordIDPageSize,
                filter: filter,
                requiresURL: listRequiresURL(for: context.query),
                before: cursor
            )
            guard !metas.isEmpty else { return ids }
            let knownKinds = context.needsKind
                ? try clipboardStore.contentKinds(for: metas.map(\.id))
                : [:]
            let matching = try matchingStructuredMetas(
                metas,
                limit: metas.count,
                query: context.query,
                needsKind: context.needsKind,
                knownKinds: knownKinds,
                shouldCancel: shouldCancel
            )
            ids.append(contentsOf: matching.map(\.id))
            guard metas.count == Self.selectionRecordIDPageSize,
                  let last = metas.last else { return ids }
            cursor = historyCursor(for: last)
        }
    }

    private func historyRecordIDsForBareAndStructuredQuery(
        _ context: MacClippyHistoryStructuredPageContext,
        shouldCancel: () -> Bool
    ) throws -> [RecordID] {
        var cursor: MacClippySearchCursor?
        var collected: [ClipboardItemMeta] = []
        while true {
            guard !shouldCancel() else { return [] }
            let hits = try searchStore.search(
                terms: context.query.bareTerms,
                limit: Self.selectionRecordIDPageSize,
                after: cursor
            )
            guard !hits.isEmpty else { return MacClippyHistoryRecencyOrder.sortedIDs(collected) }
            let metas = try clipboardStore.metas(for: hits.map(\.id))
            let metasByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
            let knownKinds = context.needsKind
                ? try clipboardStore.contentKinds(for: hits.map(\.id))
                : [:]
            let matching = try matchingStructuredHits(
                hits,
                metasByID: metasByID,
                limit: hits.count,
                query: context.query,
                needsKind: context.needsKind,
                knownKinds: knownKinds,
                shouldCancel: shouldCancel
            )
            collected.append(contentsOf: matching.map(\.1))
            guard hits.count == Self.selectionRecordIDPageSize, let last = hits.last else {
                return MacClippyHistoryRecencyOrder.sortedIDs(collected)
            }
            cursor = MacClippySearchCursor(rank: last.rank, rowID: last.rowID)
        }
    }

    /// Resolves all IDs in one Pinboard's current order using metadata only.
    /// The query semantics mirror the locally filtered Pinboard carousel.
    func pinboardRecordIDs(
        pinboardID: RecordID,
        query: String,
        shouldCancel: () -> Bool = { false }
    ) throws -> [RecordID] {
        for _ in 0..<2 {
            let snapshot = try withStoreLock { try pinboardStore.fetch(id: pinboardID) }
            if shouldCancel() { return [] }
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = MacClippySearchGrammar.parse(trimmedQuery)
            let ftsMatchIDs = try pinboardFTSMatchIDs(
                terms: parsed.bareTerms,
                memberIDs: Set(snapshot.itemIDs),
                shouldCancel: shouldCancel
            )
            if shouldCancel() { return [] }
            let resolved = try withStoreLock { () -> [RecordID]? in
                guard !shouldCancel() else { return [] }
                let board = try pinboardStore.fetch(id: pinboardID)
                if board.modified != snapshot.modified { return nil }
                let metas = try clipboardStore.metas(for: board.itemIDs)
                let metasByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
                let orderedMetas = board.itemIDs.compactMap { metasByID[$0] }
                guard !trimmedQuery.isEmpty else { return orderedMetas.map(\.id) }
                guard let context = pinboardSearchContext(
                    for: trimmedQuery,
                    ftsMatchIDs: ftsMatchIDs
                ) else { return [] }
                let knownKinds = context.needsKind
                    ? try clipboardStore.contentKinds(for: orderedMetas.map(\.id))
                    : [:]
                return try orderedMetas.compactMap { meta in
                    guard !shouldCancel(),
                          try pinboardMetaMatches(meta, context: context, knownKinds: knownKinds) else {
                        return nil
                    }
                    return meta.id
                }
            }
            if let resolved { return resolved }
        }
        throw MacClippyPinboardSearchPageError.boardChanged
    }
}
