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
            case .bare, .type, .url:
                break
            }
        }
        return filter
    }

    func listRequiresURL(for query: MacClippySearchGrammar.Query) -> Bool {
        query.clauses.contains { clause in
            if case .url = clause { return true }
            return false
        }
    }

}
