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
                parsed.bareTerms.joined(separator: " "),
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
        _ query: String,
        shouldCancel: () -> Bool
    ) throws -> [RecordID] {
        var offset = 0
        var ids: [RecordID] = []
        while true {
            guard !shouldCancel() else { return [] }
            let hits = try searchStore.search(
                query: query,
                limit: Self.selectionRecordIDPageSize,
                offset: offset
            )
            guard !hits.isEmpty else { return ids }
            let metas = try clipboardStore.metas(for: hits.map(\.id))
            let available = Set(metas.map(\.id))
            ids.append(contentsOf: hits.compactMap { available.contains($0.id) ? $0.id : nil })
            guard hits.count == Self.selectionRecordIDPageSize else { return ids }
            offset += hits.count
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
        var offset = 0
        var ids: [RecordID] = []
        let ftsQuery = context.query.bareTerms.joined(separator: " ")
        while true {
            guard !shouldCancel() else { return [] }
            let hits = try searchStore.search(
                query: ftsQuery,
                limit: Self.selectionRecordIDPageSize,
                offset: offset
            )
            guard !hits.isEmpty else { return ids }
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
            ids.append(contentsOf: matching.map { $0.1.id })
            guard hits.count == Self.selectionRecordIDPageSize else { return ids }
            offset += hits.count
        }
    }

    /// Resolves all IDs in one Pinboard's current order using metadata only.
    /// The query semantics mirror the locally filtered Pinboard carousel.
    func pinboardRecordIDs(
        pinboardID: RecordID,
        query: String,
        shouldCancel: () -> Bool = { false }
    ) throws -> [RecordID] {
        try withStoreLock {
            guard !shouldCancel() else { return [] }
            let board = try pinboardStore.fetch(id: pinboardID)
            let metas = try clipboardStore.metas(for: board.itemIDs)
            let metasByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
            let orderedMetas = board.itemIDs.compactMap { metasByID[$0] }
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedQuery.isEmpty else { return orderedMetas.map(\.id) }

            let parsed = MacClippySearchGrammar.parse(trimmedQuery)
            guard parsed.hasStructuredClauses else {
                return orderedMetas
                    .filter { $0.preview.localizedCaseInsensitiveContains(trimmedQuery) }
                    .map(\.id)
            }

            let requestedKinds = parsed.clauses.compactMap { clause -> MacClippyContentKind? in
                if case let .type(kind) = clause { return kind }
                return nil
            }
            guard Set(requestedKinds).count <= 1 else { return [] }
            let needsKind = !requestedKinds.isEmpty
            let knownKinds = needsKind
                ? try clipboardStore.contentKinds(for: orderedMetas.map(\.id))
                : [:]
            return try orderedMetas.compactMap { meta in
                guard !shouldCancel(),
                      let record = try searchRecord(
                          for: meta,
                          needsKind: needsKind,
                          knownKinds: knownKinds
                      ),
                      MacClippySearchGrammar.matches(parsed, record: record) else { return nil }
                if parsed.bareTerms.isEmpty { return meta.id }
                let bare = parsed.bareTerms.joined(separator: " ")
                return meta.preview.localizedCaseInsensitiveContains(bare) ? meta.id : nil
            }
        }
    }
}
