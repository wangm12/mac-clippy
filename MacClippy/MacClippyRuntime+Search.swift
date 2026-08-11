import AppKit
import CoreGraphics
import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    private static let maxHistoryResultCount = 512
    private static let maxSearchRevisionRetries = 8
    static let searchIndexTextByteLimit = 1 * 1024 * 1024

    func history(
        limit: Int,
        query: String,
        shouldCancel: () -> Bool = { false }
    ) throws -> [MacClippyHistoryEntry] {
        let resultLimit = min(max(limit, 0), Self.maxHistoryResultCount)
        return try measureDiagnosticMetric("search_history") {
            guard resultLimit > 0 else { return [] }
            var revisionRetryCount = 0
            while true {
                do {
                    var results: [MacClippyHistoryEntry] = []
                    results.reserveCapacity(resultLimit)
                    var pageToken: MacClippyHistoryPageToken?

                    // Use the same bounded page path as the Dock. This keeps
                    // the synchronous compatibility API correct while ensuring
                    // a caller requesting a large result never holds storeLock
                    // across the entire search/decrypt/materialization pass.
                    while results.count < resultLimit {
                        guard !shouldCancel() else { return [] }
                        let page = try historyPage(
                            limit: min(128, resultLimit - results.count),
                            query: query,
                            pageToken: pageToken,
                            shouldCancel: shouldCancel
                        )
                        guard !shouldCancel() else { return [] }
                        results.append(contentsOf: page.items)
                        guard let nextPageToken = page.nextPageToken,
                              !page.items.isEmpty else { break }
                        pageToken = nextPageToken
                    }
                    return results
                } catch let error as MacClippyHistoryPageError where error == .searchIndexChanged {
                    // The compatibility API has no continuation for callers
                    // to recover. Restart the bounded scan when a concurrent
                    // label/OCR update changes FTS revision between pages.
                    revisionRetryCount += 1
                    guard revisionRetryCount < Self.maxSearchRevisionRetries else {
                        throw error
                    }
                }
            }
        }
    }

    private func historyForEmptyQuery(
        limit: Int,
        shouldCancel: () -> Bool
    ) throws -> [MacClippyHistoryEntry] {
        guard limit > 0 else { return [] }
        let metas = try clipboardStore.list(limit: limit)
        guard !shouldCancel() else { return [] }
        let entriesByID = try entries(for: metas, validateContentKind: true)
        return metas.compactMap { meta in
            guard !shouldCancel() else { return nil }
            return entriesByID[meta.id]
        }
    }

    private func historyForBareQuery(
        _ query: String,
        limit: Int,
        shouldCancel: () -> Bool
    ) throws -> [MacClippyHistoryEntry] {
        guard limit > 0 else { return [] }
        var collected: [MacClippyHistoryEntry] = []
        collected.reserveCapacity(limit)
        var pageOffset = 0
        while collected.count < limit {
            guard !shouldCancel() else { return [] }
            let remaining = limit - collected.count
            // Resolve no more than the number of cards still requested. If a
            // hit is corrupt/orphaned, the outer page loop fetches the next
            // FTS page instead of decrypting an oversized speculative batch.
            let pageSize = min(max(remaining, 1), 128)
            let hits = try searchStore.search(
                query: query,
                limit: pageSize,
                offset: pageOffset
            )
            guard !hits.isEmpty else { break }
            guard !shouldCancel() else { return [] }
            let pageEntries = try historyEntriesFromHits(hits, shouldCancel: shouldCancel)
            guard !shouldCancel() else { return [] }
            collected.append(contentsOf: pageEntries.prefix(limit - collected.count))
            if hits.count < pageSize { break }
            pageOffset += hits.count
        }
        return collected
    }

    private func historyForStructuredOnlyQuery(
        _ query: MacClippySearchGrammar.Query,
        limit: Int,
        needsKind: Bool,
        requestedKind: MacClippyContentKind?,
        shouldCancel: () -> Bool
    ) throws -> [MacClippyHistoryEntry] {
        guard limit > 0 else { return [] }
        var collected: [MacClippyHistoryEntry] = []
        collected.reserveCapacity(limit)
        let pageSize = 128
        var cursor: MacClippyClipboardHistoryCursor?
        let filter = metadataFilter(for: query, contentKind: requestedKind)

        while collected.count < limit {
            guard !shouldCancel() else { return collected }
            let metas = try clipboardStore.list(
                limit: pageSize,
                filter: filter,
                before: cursor
            )
            guard !metas.isEmpty else { break }

            let knownKinds = requestedKind.map { kind in
                Dictionary(uniqueKeysWithValues: metas.map { ($0.id, kind) })
            } ?? [:]
            let matchingMetas = try matchingStructuredMetas(
                metas,
                limit: limit - collected.count,
                query: query,
                needsKind: needsKind,
                knownKinds: knownKinds,
                shouldCancel: shouldCancel
            )
            guard !shouldCancel() else { return collected }

            let entriesByID = try entries(for: matchingMetas, validateContentKind: true)
            for meta in matchingMetas {
                guard collected.count < limit else { break }
                if let entry = entriesByID[meta.id],
                   requestedKind == nil || entry.contentKind == requestedKind {
                    collected.append(entry)
                }
            }

            guard metas.count == pageSize, let last = metas.last else { break }
            cursor = MacClippyClipboardHistoryCursor(
                modified: last.modified,
                lamport: last.lamport,
                id: last.id
            )
        }
        return collected
    }

    private func historyForBareAndStructuredQuery(
        _ query: MacClippySearchGrammar.Query,
        limit: Int,
        needsKind: Bool,
        requestedKind: MacClippyContentKind?,
        shouldCancel: () -> Bool
    ) throws -> [MacClippyHistoryEntry] {
        guard limit > 0 else { return [] }
        let ftsQuery = query.bareTerms.joined(separator: " ")
        var collected: [MacClippyHistoryEntry] = []
        collected.reserveCapacity(limit)
        var pageOffset = 0

        while collected.count < limit {
            guard !shouldCancel() else { return [] }
            let remaining = limit - collected.count
            let pageSize = min(max(remaining, 1), 128)
            let hits = try searchStore.search(
                query: ftsQuery,
                limit: pageSize,
                offset: pageOffset
            )
            guard !hits.isEmpty else { break }
            guard !shouldCancel() else { return [] }

            let hitIDs = hits.map(\.id)
            let metas = try clipboardStore.metas(for: hitIDs)
            let metasByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
            let knownKinds = needsKind ? try clipboardStore.contentKinds(for: hitIDs) : [:]
            let matchingHits = try matchingStructuredHits(
                hits,
                metasByID: metasByID,
                limit: limit - collected.count,
                query: query,
                needsKind: needsKind,
                knownKinds: knownKinds,
                shouldCancel: shouldCancel
            )
            guard !shouldCancel() else { return [] }

            let entriesByID = try entries(
                for: matchingHits.map { $0.1 },
                validateContentKind: true
            )
            for (hit, meta) in matchingHits {
                guard collected.count < limit,
                      let entry = entriesByID[meta.id],
                      requestedKind == nil || entry.contentKind == requestedKind else { continue }
                collected.append(
                    MacClippyHistoryEntry(
                        meta: meta,
                        contentKind: entry.contentKind,
                        preview: hit.snippet,
                        fileURLs: entry.fileURLs,
                        imageDimensions: entry.imageDimensions
                    )
                )
            }

            if hits.count < pageSize { break }
            pageOffset += hits.count
        }
        return collected
    }

    // Paging reuses these pure projection helpers across bounded History
    // queries. The explicit arguments keep query state visible at the call
    // site instead of storing mutable search state on Runtime.
    // swiftlint:disable function_parameter_count
    func matchingStructuredMetas(
        _ metas: [ClipboardItemMeta],
        limit: Int,
        query: MacClippySearchGrammar.Query,
        needsKind: Bool,
        knownKinds: [RecordID: MacClippyContentKind],
        shouldCancel: () -> Bool
    ) throws -> [ClipboardItemMeta] {
        var matching: [ClipboardItemMeta] = []
        matching.reserveCapacity(min(metas.count, limit))
        for meta in metas {
            guard !shouldCancel(), matching.count < limit else { break }
            guard let record = try searchRecord(
                for: meta,
                needsKind: needsKind,
                knownKinds: knownKinds
            ) else { continue }
            guard MacClippySearchGrammar.matches(query, record: record) else { continue }
            matching.append(meta)
        }
        return matching
    }

    func matchingStructuredHits(
        _ hits: [SearchHit],
        metasByID: [RecordID: ClipboardItemMeta],
        limit: Int,
        query: MacClippySearchGrammar.Query,
        needsKind: Bool,
        knownKinds: [RecordID: MacClippyContentKind],
        shouldCancel: () -> Bool
    ) throws -> [(SearchHit, ClipboardItemMeta)] {
        var matching: [(SearchHit, ClipboardItemMeta)] = []
        matching.reserveCapacity(min(hits.count, limit))
        for hit in hits {
            guard !shouldCancel(), matching.count < limit else { break }
            guard let meta = metasByID[hit.id] else { continue }
            guard let record = try searchRecord(
                for: meta,
                needsKind: needsKind,
                knownKinds: knownKinds
            ) else { continue }
            guard MacClippySearchGrammar.matches(query, record: record) else { continue }
            matching.append((hit, meta))
        }
        return matching
    }

    // swiftlint:enable function_parameter_count
    func metadataFilter(
        for query: MacClippySearchGrammar.Query,
        contentKind: MacClippyContentKind?
    ) -> MacClippyClipboardMetadataFilter {
        var filter = MacClippyClipboardMetadataFilter(contentKind: contentKind)
        for clause in query.clauses {
            switch clause {
            case let .app(value):
                filter.sourceAppContains.append(value)
            case let .label(value):
                filter.labelContains.append(value)
            case .hasLabel:
                filter.requiresLabel = true
            case .hasOCR:
                filter.requiresOCR = true
            case let .before(date):
                filter.modifiedBefore.append(date)
            case let .after(date):
                filter.modifiedAfter.append(date)
            case .bare, .type:
                break
            }
        }
        return filter
    }

}
