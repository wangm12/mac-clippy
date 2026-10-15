import Foundation

import MacClippyCore
import MacClippyPlatform

private struct MacClippySelectionSearchRevision {
    let index: Int64
    let clipboard: Int64
}

extension MacClippyRuntime {
    func canMergeRecords(ids: [RecordID], shouldCancel: () -> Bool) throws -> Bool {
        guard !ids.isEmpty else { return false }
        for id in ids {
            guard !shouldCancel() else { throw CancellationError() }
            let record = try withStoreLock { try clipboardStore.body(for: id) }
            switch record {
            case .text, .html, .rtf: continue
            case .image, .encryptedImage, .files: return false
            }
        }
        return true
    }
    private static let selectionRecordIDPageSize = 256
    private static let selectionSearchAttempts = 4

    /// Resolves the complete ordered History selection without decrypting or
    /// materializing card bodies. Cmd+A uses this instead of loading every
    /// remaining card into the carousel.
    func historyRecordIDs(
        query: String,
        shouldCancel: () -> Bool = { false }
    ) throws -> [RecordID] {
        for _ in 0..<Self.selectionSearchAttempts {
            guard !shouldCancel() else { return [] }
            let revision = try withStoreLock {
                MacClippySelectionSearchRevision(
                    index: try searchStore.indexRevision(), clipboard: try clipboardStore.recordsRevision()
                )
            }
            do {
                let ids = try historyRecordIDsLocked(query: query, revision: revision, shouldCancel: shouldCancel)
                guard !shouldCancel() else { return [] }
                try withStoreLock { try ensureSelectionSearchRevisionLocked(revision) }
                var seen = Set<RecordID>()
                return ids.filter { seen.insert($0).inserted }
            } catch MacClippyHistoryPageError.searchIndexChanged {
                guard !shouldCancel() else { return [] }
            }
        }
        throw MacClippyHistoryPageError.searchIndexChanged
    }

    private func historyRecordIDsLocked(
        query: String,
        revision: MacClippySelectionSearchRevision,
        shouldCancel: () -> Bool
    ) throws -> [RecordID] {
        guard !shouldCancel() else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return try historyRecordIDsForEmptyQuery(revision: revision, shouldCancel: shouldCancel)
        }

        let parsed = MacClippySearchGrammar.parse(trimmedQuery)
        guard parsed.hasStructuredClauses else {
            return try historyRecordIDsForBareQuery(
                parsed.bareTerms,
                revision: revision,
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
                revision: revision,
                shouldCancel: shouldCancel
            )
        }
        return try historyRecordIDsForBareAndStructuredQuery(
            context,
            revision: revision,
            shouldCancel: shouldCancel
        )
    }

    private func historyRecordIDsForEmptyQuery(
        revision: MacClippySelectionSearchRevision,
        shouldCancel: () -> Bool
    ) throws -> [RecordID] {
        var cursor: MacClippyClipboardHistoryCursor?
        var ids: [RecordID] = []
        while true {
            guard !shouldCancel() else { return [] }
            let metas = try withStoreLock {
                try ensureSelectionSearchRevisionLocked(revision)
                return try clipboardStore.list(
                    limit: Self.selectionRecordIDPageSize,
                    before: cursor
                )
            }
            guard !metas.isEmpty else { return ids }
            ids.append(contentsOf: metas.map(\.id))
            guard metas.count == Self.selectionRecordIDPageSize,
                  let last = metas.last else { return ids }
            cursor = historyCursor(for: last)
        }
    }

    private func historyRecordIDsForBareQuery(
        _ terms: [String],
        revision: MacClippySelectionSearchRevision,
        shouldCancel: () -> Bool
    ) throws -> [RecordID] {
        var cursor: MacClippySearchCursor?
        var collected: [ClipboardItemMeta] = []
        while true {
            guard !shouldCancel() else { return [] }
            let (hits, metas) = try withStoreLock { () -> ([SearchHit], [ClipboardItemMeta]) in
                try ensureSelectionSearchRevisionLocked(revision)
                let hits = try searchStore.search(
                    terms: terms,
                    limit: Self.selectionRecordIDPageSize,
                    after: cursor
                )
                let metas = try clipboardStore.metas(for: hits.map(\.id))
                return (hits, metas)
            }
            guard !hits.isEmpty else { return MacClippyHistoryRecencyOrder.sortedIDs(collected) }
            collected.append(contentsOf: metas)
            #if DEBUG
            afterSelectionSearchBatchForTesting?(collected.count)
            #endif
            guard hits.count == Self.selectionRecordIDPageSize, let last = hits.last else {
                return MacClippyHistoryRecencyOrder.sortedIDs(collected)
            }
            cursor = MacClippySearchCursor(rank: last.rank, rowID: last.rowID)
        }
    }

    private func historyRecordIDsForStructuredOnlyQuery(
        _ context: MacClippyHistoryStructuredPageContext,
        revision: MacClippySelectionSearchRevision,
        shouldCancel: () -> Bool
    ) throws -> [RecordID] {
        var cursor: MacClippyClipboardHistoryCursor?
        var ids: [RecordID] = []
        let filter = metadataFilter(for: context.query, contentKind: context.requestedKind)
        while true {
            guard !shouldCancel() else { return [] }
            let (metas, matching) = try withStoreLock { () -> ([ClipboardItemMeta], [ClipboardItemMeta]) in
                try ensureSelectionSearchRevisionLocked(revision)
                let metas = try clipboardStore.list(
                    limit: Self.selectionRecordIDPageSize,
                    filter: filter,
                    requiresURL: listRequiresURL(for: context.query),
                    before: cursor
                )
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
                return (metas, matching)
            }
            guard !metas.isEmpty else { return ids }
            ids.append(contentsOf: matching.map(\.id))
            guard metas.count == Self.selectionRecordIDPageSize,
                  let last = metas.last else { return ids }
            cursor = historyCursor(for: last)
        }
    }

    private func historyRecordIDsForBareAndStructuredQuery(
        _ context: MacClippyHistoryStructuredPageContext,
        revision: MacClippySelectionSearchRevision,
        shouldCancel: () -> Bool
    ) throws -> [RecordID] {
        var cursor: MacClippySearchCursor?
        var collected: [ClipboardItemMeta] = []
        let scope = try historySearchScope(context, reusing: nil, shouldCancel: shouldCancel)
        while true {
            guard !shouldCancel() else { return [] }
            let (hits, matching) = try withStoreLock { () -> ([SearchHit], [(SearchHit, ClipboardItemMeta)]) in
                try ensureSelectionSearchRevisionLocked(revision)
                try ensureHistorySearchScopeLocked(scope, query: context.query)
                return try selectionStructuredSearchBatch(
                    context, scope: scope, after: cursor, shouldCancel: shouldCancel
                )
            }
            guard !hits.isEmpty else { return MacClippyHistoryRecencyOrder.sortedIDs(collected) }
            collected.append(contentsOf: matching.map(\.1))
            #if DEBUG
            afterSelectionSearchBatchForTesting?(collected.count)
            #endif
            guard hits.count == Self.selectionRecordIDPageSize, let last = hits.last else {
                return MacClippyHistoryRecencyOrder.sortedIDs(collected)
            }
            cursor = MacClippySearchCursor(rank: last.rank, rowID: last.rowID)
        }
    }

    private func selectionStructuredSearchBatch(
        _ context: MacClippyHistoryStructuredPageContext,
        scope: MacClippyHistorySearchScope,
        after cursor: MacClippySearchCursor?,
        shouldCancel: () -> Bool
    ) throws -> ([SearchHit], [(SearchHit, ClipboardItemMeta)]) {
        let hits = try searchStore.searchScoped(
            terms: context.query.bareTerms, limit: Self.selectionRecordIDPageSize,
            after: cursor, scope: scope.recordScope
        )
        let metas = try clipboardStore.metas(for: hits.map(\.id))
        let knownKinds = context.needsKind ? try clipboardStore.contentKinds(for: hits.map(\.id)) : [:]
        let matching = try matchingStructuredHits(
            hits, metasByID: Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) }),
            limit: hits.count, query: context.query, needsKind: context.needsKind,
            knownKinds: knownKinds, shouldCancel: shouldCancel
        )
        return (hits, matching)
    }

    private func ensureSelectionSearchRevisionLocked(_ revision: MacClippySelectionSearchRevision) throws {
        guard try searchStore.indexRevision() == revision.index,
              try clipboardStore.recordsRevision() == revision.clipboard else {
            throw MacClippyHistoryPageError.searchIndexChanged
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
