import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    /// Loads one bounded page of History and returns only the continuation
    /// needed for the next page. The existing `history(limit:query:)` API is
    /// intentionally left unchanged for callers that need a single bounded
    /// result; the Dock uses this page API to extend its carousel lazily.
    func historyPage(
        limit: Int,
        query: String,
        pageToken: MacClippyHistoryPageToken? = nil,
        shouldCancel: () -> Bool = { false }
    ) throws -> MacClippyHistoryPage {
        let pageLimit = min(max(limit, 0), 128)
        guard pageLimit > 0 else {
            return MacClippyHistoryPage(items: [], nextPageToken: nil)
        }

        return try measureDiagnosticMetric("search_history_page") {
            try historyPageLocked(
                limit: pageLimit,
                query: query,
                pageToken: pageToken,
                shouldCancel: shouldCancel
            )
        }
    }

    private func historyPageLocked(
        limit: Int,
        query: String,
        pageToken: MacClippyHistoryPageToken?,
        shouldCancel: () -> Bool
    ) throws -> MacClippyHistoryPage {
        guard !shouldCancel() else {
            return MacClippyHistoryPage(items: [], nextPageToken: nil)
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty {
            return try historyPageForEmptyQuery(
                limit: limit,
                before: pageToken?.historyCursor,
                shouldCancel: shouldCancel
            )
        }

        let parsed = MacClippySearchGrammar.parse(trimmedQuery)
        guard parsed.hasStructuredClauses else {
            return try historyPageForBareQuery(
                parsed.bareTerms,
                limit: limit,
                pageToken: pageToken,
                shouldCancel: shouldCancel
            )
        }
        return try historyPageForStructuredQuery(
            parsed,
            limit: limit,
            pageToken: pageToken,
            shouldCancel: shouldCancel
        )
    }

    private func historyPageForStructuredQuery(
        _ parsed: MacClippySearchGrammar.Query,
        limit: Int,
        pageToken: MacClippyHistoryPageToken?,
        shouldCancel: () -> Bool
    ) throws -> MacClippyHistoryPage {
        let needsKind = parsed.clauses.contains {
            if case .type = $0 { return true }
            return false
        }
        let requestedKinds = parsed.clauses.compactMap { clause -> MacClippyContentKind? in
            if case let .type(kind) = clause { return kind }
            return nil
        }
        if Set(requestedKinds).count > 1 {
            return MacClippyHistoryPage(items: [], nextPageToken: nil)
        }
        let context = MacClippyHistoryStructuredPageContext(
            query: parsed,
            limit: limit,
            needsKind: needsKind,
            requestedKind: requestedKinds.first
        )
        if parsed.isStructuredOnly {
            return try historyPageForStructuredOnlyQuery(
                context,
                before: pageToken?.historyCursor,
                shouldCancel: shouldCancel
            )
        }
        return try historyPageForBareAndStructuredQuery(
            context,
            pageToken: pageToken,
            shouldCancel: shouldCancel
        )
    }

    private func historyPageForEmptyQuery(
        limit: Int,
        before: MacClippyClipboardHistoryCursor?,
        shouldCancel: () -> Bool
    ) throws -> MacClippyHistoryPage {
        var cursor = before
        var items: [MacClippyHistoryEntry] = []
        items.reserveCapacity(limit)

        while items.count < limit {
            guard !shouldCancel() else {
                return MacClippyHistoryPage(items: [], nextPageToken: nil)
            }
            let batchLimit = max(1, limit - items.count + 1)
            let metas = try withStoreLock {
                try clipboardStore.list(limit: batchLimit, before: cursor)
            }
            guard !metas.isEmpty else { break }

            // Decode the bounded page after releasing the global store lock.
            // A concurrent capture can remove or replace one record; entries()
            // already treats missing/corrupt envelopes as an isolated card
            // failure and infrastructure errors remain throwable.
            let entriesByID = try entries(for: metas, validateContentKind: true)
            for (index, meta) in metas.enumerated() {
                guard !shouldCancel() else {
                    return MacClippyHistoryPage(items: [], nextPageToken: nil)
                }
                guard let entry = entriesByID[meta.id] else { continue }
                items.append(entry)
                guard items.count == limit else { continue }

                let hasMoreInBatch = index + 1 < metas.count || metas.count == batchLimit
                return MacClippyHistoryPage(
                    items: items,
                    nextPageToken: hasMoreInBatch
                        ? .historyCursor(historyCursor(for: meta))
                        : nil
                )
            }

            guard metas.count == batchLimit, let last = metas.last else { break }
            cursor = historyCursor(for: last)
        }

        return MacClippyHistoryPage(items: items, nextPageToken: nil)
    }

    private func historyPageForStructuredOnlyQuery(
        _ context: MacClippyHistoryStructuredPageContext,
        before: MacClippyClipboardHistoryCursor?,
        shouldCancel: () -> Bool
    ) throws -> MacClippyHistoryPage {
        var cursor = before
        var items: [MacClippyHistoryEntry] = []
        items.reserveCapacity(context.limit)
        let filter = metadataFilter(for: context.query, contentKind: context.requestedKind)

        while items.count < context.limit {
            guard !shouldCancel() else {
                return MacClippyHistoryPage(items: [], nextPageToken: nil)
            }
            let batchLimit = max(1, context.limit - items.count + 1)
            let metas = try withStoreLock {
                try clipboardStore.list(
                    limit: batchLimit,
                    filter: filter,
                    requiresURL: listRequiresURL(for: context.query),
                    before: cursor
                )
            }
            guard !metas.isEmpty else { break }

            let matchingMetas = try matchingStructuredMetasForPage(
                metas,
                context: context,
                shouldCancel: shouldCancel
            )
            let entriesByID = try entries(for: matchingMetas, validateContentKind: true)

            for meta in matchingMetas {
                guard !shouldCancel() else {
                    return MacClippyHistoryPage(items: [], nextPageToken: nil)
                }
                guard let entry = entriesByID[meta.id],
                      context.requestedKind == nil || entry.contentKind == context.requestedKind else { continue }
                items.append(entry)
                guard items.count == context.limit else { continue }

                let hasMoreInBatch = hasMoreInStructuredBatch(
                    matchingMeta: meta,
                    metas: metas,
                    batchLimit: batchLimit
                )
                return MacClippyHistoryPage(
                    items: items,
                    nextPageToken: hasMoreInBatch
                        ? .historyCursor(historyCursor(for: meta))
                        : nil
                )
            }

            guard metas.count == batchLimit, let last = metas.last else { break }
            cursor = historyCursor(for: last)
        }

        return MacClippyHistoryPage(items: items, nextPageToken: nil)
    }

    private func historyPageForBareQuery(
        _ terms: [String],
        limit: Int,
        pageToken: MacClippyHistoryPageToken?,
        shouldCancel: () -> Bool
    ) throws -> MacClippyHistoryPage {
        let searchCursor = try validatedSearchCursor(pageToken)
        guard searchCursor.structuredScope == nil else { throw MacClippyHistoryPageError.searchIndexChanged }
        var lastSearchCursor = searchCursor.searchCursor
        var items: [MacClippyHistoryEntry] = []
        items.reserveCapacity(limit)

        while items.count < limit {
            guard !shouldCancel() else {
                return MacClippyHistoryPage(items: [], nextPageToken: nil)
            }
            let batchLimit = max(1, limit - items.count + 1)
            let (hits, metas) = try withStoreLock {
                let hits = try searchStore.search(terms: terms, limit: batchLimit, after: lastSearchCursor)
                let metas = try clipboardStore.metas(for: hits.map(\.id))
                return (hits, metas)
            }
            guard !hits.isEmpty else { break }

            let metasByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
            // History entries project from metadata and stored preview first.
            let entriesByID = try entries(for: metas, validateContentKind: true)
            for (index, hit) in hits.enumerated() {
                guard !shouldCancel() else {
                    return MacClippyHistoryPage(items: [], nextPageToken: nil)
                }
                guard let meta = metasByID[hit.id], let entry = entriesByID[hit.id] else { continue }
                items.append(historySearchEntry(hit, meta: meta, entry: entry))
                lastSearchCursor = MacClippySearchCursor(rank: hit.rank, rowID: hit.rowID)
                guard items.count == limit else { continue }

                let hasMoreInBatch = index + 1 < hits.count || hits.count == batchLimit
                try ensureSearchRevision(searchCursor.indexRevision)
                return MacClippyHistoryPage(
                    items: recencySorted(items),
                    nextPageToken: hasMoreInBatch
                        ? .searchCursor(MacClippySearchPageCursor(
                            indexRevision: searchCursor.indexRevision,
                            lastRank: lastSearchCursor?.rank,
                            lastRowID: lastSearchCursor?.rowID
                        ))
                        : nil
                )
            }

            if let lastHit = hits.last {
                lastSearchCursor = MacClippySearchCursor(rank: lastHit.rank, rowID: lastHit.rowID)
            }
            guard hits.count == batchLimit else { break }
        }

        try ensureSearchRevision(searchCursor.indexRevision)
        return MacClippyHistoryPage(items: recencySorted(items), nextPageToken: nil)
    }

    private func historyPageForBareAndStructuredQuery(
        _ context: MacClippyHistoryStructuredPageContext,
        pageToken: MacClippyHistoryPageToken?,
        shouldCancel: () -> Bool
    ) throws -> MacClippyHistoryPage {
        let searchCursor = try validatedSearchCursor(pageToken)
        let scope = try historySearchScope(
            context, reusing: searchCursor.structuredScope, shouldCancel: shouldCancel
        )
        var lastSearchCursor = searchCursor.searchCursor
        var items: [MacClippyHistoryEntry] = []
        items.reserveCapacity(context.limit)

        while items.count < context.limit {
            guard !shouldCancel() else {
                return MacClippyHistoryPage(items: [], nextPageToken: nil)
            }
            let batchLimit = max(128, context.limit - items.count + 1)
            let batch = try structuredHistorySearchBatch(
                context, after: lastSearchCursor, scope: scope,
                limit: batchLimit, shouldCancel: shouldCancel
            )
            let hits = batch.hits
            guard !hits.isEmpty else { break }

            for (index, hit) in hits.enumerated() {
                guard !shouldCancel() else {
                    return MacClippyHistoryPage(items: [], nextPageToken: nil)
                }
                guard let entry = batch.entriesByID[hit.id] else { continue }
                items.append(entry)
                lastSearchCursor = MacClippySearchCursor(rank: hit.rank, rowID: hit.rowID)
                guard items.count == context.limit else { continue }

                let hasMoreInBatch = index + 1 < hits.count || hits.count == batchLimit
                try ensureStructuredSearchRevision(searchCursor.indexRevision, scope: scope)
                return MacClippyHistoryPage(
                    items: recencySorted(items),
                    nextPageToken: hasMoreInBatch
                        ? .searchCursor(MacClippySearchPageCursor(
                            indexRevision: searchCursor.indexRevision,
                            lastRank: lastSearchCursor?.rank,
                            lastRowID: lastSearchCursor?.rowID,
                            structuredScope: scope
                        ))
                        : nil
                )
            }

            if let lastHit = hits.last {
                lastSearchCursor = MacClippySearchCursor(rank: lastHit.rank, rowID: lastHit.rowID)
            }
            guard hits.count == batchLimit else { break }
        }

        try ensureStructuredSearchRevision(searchCursor.indexRevision, scope: scope)
        return MacClippyHistoryPage(items: recencySorted(items), nextPageToken: nil)
    }

    private func validatedSearchCursor(
        _ pageToken: MacClippyHistoryPageToken?
    ) throws -> MacClippySearchPageCursor {
        let currentRevision = try withStoreLock { try searchStore.indexRevision() }
        guard let pageToken else {
            return MacClippySearchPageCursor(indexRevision: currentRevision, lastRank: nil, lastRowID: nil)
        }
        guard case let .searchCursor(cursor) = pageToken,
              cursor.indexRevision == currentRevision else {
            throw MacClippyHistoryPageError.searchIndexChanged
        }
        return cursor
    }

    func ensureSearchRevision(_ revision: Int64) throws {
        guard try withStoreLock({ try searchStore.indexRevision() }) == revision else {
            throw MacClippyHistoryPageError.searchIndexChanged
        }
    }

}
