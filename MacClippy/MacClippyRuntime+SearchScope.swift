import Foundation
import MacClippyCore

extension MacClippyRuntime {
    func structuredHistorySearchBatch(
        _ context: MacClippyHistoryStructuredPageContext,
        after cursor: MacClippySearchCursor?,
        scope: MacClippyHistorySearchScope,
        limit: Int,
        shouldCancel: () -> Bool
    ) throws -> (hits: [SearchHit], entriesByID: [RecordID: MacClippyHistoryEntry]) {
        let (hits, metas, knownKinds) = try withStoreLock {
            try ensureHistorySearchScopeLocked(scope, query: context.query)
            let hits = try searchStore.searchScoped(
                terms: context.query.bareTerms, limit: limit, after: cursor,
                scope: scope.recordScope
            )
            let ids = hits.map(\.id)
            let kinds = context.needsKind ? try clipboardStore.contentKinds(for: ids) : [:]
            return (hits, try clipboardStore.metas(for: ids), kinds)
        }
        let matches = try matchingStructuredHits(
            hits, metasByID: Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) }),
            limit: hits.count, query: context.query, needsKind: context.needsKind,
            knownKinds: knownKinds, shouldCancel: shouldCancel
        )
        let entriesByID = try entries(for: matches.map { $0.1 }, validateContentKind: true)
        var projected: [RecordID: MacClippyHistoryEntry] = [:]
        for (hit, meta) in matches {
            guard !shouldCancel() else { return ([], [:]) }
            guard let entry = entriesByID[hit.id],
                  context.requestedKind == nil || entry.contentKind == context.requestedKind else { continue }
            projected[hit.id] = historySearchEntry(hit, meta: meta, entry: entry)
        }
        return (hits, projected)
    }

    func historySearchEntry(
        _ hit: SearchHit, meta: ClipboardItemMeta, entry: MacClippyHistoryEntry
    ) -> MacClippyHistoryEntry {
        MacClippyHistoryEntry(
            meta: meta, contentKind: entry.contentKind,
            preview: MacClippySearchQuery.displayText(fromFTSSnippet: hit.snippet),
            fileURLs: entry.fileURLs, imageDimensions: entry.imageDimensions,
            isRemoteClipboard: entry.isRemoteClipboard
        )
    }

    func historySearchScope(
        _ context: MacClippyHistoryStructuredPageContext,
        reusing cached: MacClippyHistorySearchScope?,
        shouldCancel: () -> Bool
    ) throws -> MacClippyHistorySearchScope {
        if let cached {
            try withStoreLock { try ensureHistorySearchScopeLocked(cached, query: context.query) }
            // Legacy app-name resolution can change without a database write.
            // Re-evaluate app clauses on a continuation. A changed candidate
            // set invalidates the old rank cursor, including newly eligible
            // records ranked before it. An unchanged set can reuse its TEMP table.
            let resolvesAppName = context.query.clauses.contains { clause in
                if case .app = clause { return true }
                return false
            }
            if resolvesAppName {
                let ids = try matchingSearchRecordIDs(context, shouldCancel: shouldCancel)
                guard !shouldCancel() else { return cached }
                guard ids == cached.recordScope.recordIDs else { throw MacClippyHistoryPageError.searchIndexChanged }
                try withStoreLock { try ensureHistorySearchScopeLocked(cached, query: context.query) }
            }
            return cached
        }
        let revision = try withStoreLock { try clipboardStore.recordsRevision() }
        let ids = try matchingSearchRecordIDs(context, shouldCancel: shouldCancel)
        let scope = MacClippyHistorySearchScope(
            ownerID: searchScopeOwnerID, query: context.query, clipboardRevision: revision, recordIDs: ids
        )
        guard !shouldCancel() else { return scope }
        try withStoreLock { try ensureHistorySearchScopeLocked(scope, query: context.query) }
        return scope
    }

    func ensureHistorySearchScopeLocked(
        _ scope: MacClippyHistorySearchScope,
        query: MacClippySearchGrammar.Query
    ) throws {
        guard scope.ownerID == searchScopeOwnerID, scope.query == query,
              try clipboardStore.recordsRevision() == scope.clipboardRevision else {
            throw MacClippyHistoryPageError.searchIndexChanged
        }
    }

    func ensureStructuredSearchRevision(_ revision: Int64, scope: MacClippyHistorySearchScope) throws {
        try withStoreLock {
            try ensureHistorySearchScopeLocked(scope, query: scope.query)
            guard try searchStore.indexRevision() == revision else {
                throw MacClippyHistoryPageError.searchIndexChanged
            }
        }
    }

    func matchingSearchRecordIDs(
        _ context: MacClippyHistoryStructuredPageContext,
        shouldCancel: () -> Bool
    ) throws -> [RecordID] {
        let filter = metadataFilter(for: context.query, contentKind: context.requestedKind)
        let requiresURL = listRequiresURL(for: context.query)
        var ids: [RecordID] = []
        var afterID: RecordID?
        let pageSize = 512
        while !shouldCancel() {
            let page = try withStoreLock {
                try clipboardStore.matchingRecordIDs(
                    filter: filter, requiresURL: requiresURL, afterID: afterID, limit: pageSize,
                    sourceAppDisplayNameResolver: { MacClippySourceAppResolver.displayName(for: $0) }
                )
            }
            ids.append(contentsOf: page)
            guard page.count == pageSize, let lastID = page.last else { break }
            afterID = lastID
        }
        return shouldCancel() ? [] : ids
    }
}
