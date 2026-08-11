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
                parsed.bareTerms.joined(separator: " "),
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
        _ query: String,
        limit: Int,
        pageToken: MacClippyHistoryPageToken?,
        shouldCancel: () -> Bool
    ) throws -> MacClippyHistoryPage {
        let searchCursor = try validatedSearchCursor(pageToken)
        var lastSearchCursor = searchCursor.searchCursor
        var items: [MacClippyHistoryEntry] = []
        items.reserveCapacity(limit)

        while items.count < limit {
            guard !shouldCancel() else {
                return MacClippyHistoryPage(items: [], nextPageToken: nil)
            }
            let batchLimit = max(1, limit - items.count + 1)
            let (hits, metas) = try withStoreLock {
                let hits = try searchStore.search(query: query, limit: batchLimit, after: lastSearchCursor)
                let metas = try clipboardStore.metas(for: hits.map(\.id))
                return (hits, metas)
            }
            guard !hits.isEmpty else { break }

            let metasByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
            // Body decryption and DTO construction happen outside storeLock.
            let entriesByID = try entries(for: metas, validateContentKind: true)
            for (index, hit) in hits.enumerated() {
                guard !shouldCancel() else {
                    return MacClippyHistoryPage(items: [], nextPageToken: nil)
                }
                guard let meta = metasByID[hit.id], let entry = entriesByID[hit.id] else { continue }
                items.append(MacClippyHistoryEntry(
                    meta: meta,
                    contentKind: entry.contentKind,
                    preview: hit.snippet,
                    fileURLs: entry.fileURLs,
                    imageDimensions: entry.imageDimensions
                ))
                lastSearchCursor = MacClippySearchCursor(rank: hit.rank, rowID: hit.rowID)
                guard items.count == limit else { continue }

                let hasMoreInBatch = index + 1 < hits.count || hits.count == batchLimit
                try ensureSearchRevision(searchCursor.indexRevision)
                return MacClippyHistoryPage(
                    items: items,
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
        return MacClippyHistoryPage(items: items, nextPageToken: nil)
    }

    private func historyPageForBareAndStructuredQuery(
        _ context: MacClippyHistoryStructuredPageContext,
        pageToken: MacClippyHistoryPageToken?,
        shouldCancel: () -> Bool
    ) throws -> MacClippyHistoryPage {
        let searchCursor = try validatedSearchCursor(pageToken)
        var lastSearchCursor = searchCursor.searchCursor
        var items: [MacClippyHistoryEntry] = []
        items.reserveCapacity(context.limit)
        let ftsQuery = context.query.bareTerms.joined(separator: " ")

        while items.count < context.limit {
            guard !shouldCancel() else {
                return MacClippyHistoryPage(items: [], nextPageToken: nil)
            }
            let batchLimit = max(1, context.limit - items.count + 1)
            let (hits, metas, knownKinds) = try withStoreLock {
                let hits = try searchStore.search(query: ftsQuery, limit: batchLimit, after: lastSearchCursor)
                let ids = hits.map(\.id)
                let metas = try clipboardStore.metas(for: ids)
                let knownKinds: [RecordID: MacClippyContentKind] = context.needsKind
                    ? try clipboardStore.contentKinds(for: ids)
                    : [:]
                return (hits, metas, knownKinds)
            }
            guard !hits.isEmpty else { break }

            let metasByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
            let matchingHits = try matchingStructuredHits(
                hits,
                metasByID: metasByID,
                limit: hits.count,
                query: context.query,
                needsKind: context.needsKind,
                knownKinds: knownKinds,
                shouldCancel: shouldCancel
            )
            let entriesByID = try entries(
                for: matchingHits.map { $0.1 },
                validateContentKind: true
            )
            let matchingMetasByID = Dictionary(uniqueKeysWithValues: matchingHits.map { ($0.0.id, $0.1) })

            for (index, hit) in hits.enumerated() {
                guard !shouldCancel() else {
                    return MacClippyHistoryPage(items: [], nextPageToken: nil)
                }
                guard let meta = matchingMetasByID[hit.id],
                      let entry = entriesByID[meta.id],
                      context.requestedKind == nil || entry.contentKind == context.requestedKind else { continue }
                items.append(MacClippyHistoryEntry(
                    meta: meta,
                    contentKind: entry.contentKind,
                    preview: hit.snippet,
                    fileURLs: entry.fileURLs,
                    imageDimensions: entry.imageDimensions
                ))
                lastSearchCursor = MacClippySearchCursor(rank: hit.rank, rowID: hit.rowID)
                guard items.count == context.limit else { continue }

                let hasMoreInBatch = index + 1 < hits.count || hits.count == batchLimit
                try ensureSearchRevision(searchCursor.indexRevision)
                return MacClippyHistoryPage(
                    items: items,
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
        return MacClippyHistoryPage(items: items, nextPageToken: nil)
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

    private func ensureSearchRevision(_ revision: Int64) throws {
        guard try withStoreLock({ try searchStore.indexRevision() }) == revision else {
            throw MacClippyHistoryPageError.searchIndexChanged
        }
    }

}
