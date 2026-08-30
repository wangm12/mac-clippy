import Foundation

import MacClippyCore
import MacClippyPlatform

struct MacClippyPinboardSearchContext {
    let parsed: MacClippySearchGrammar.Query
    let requestedKind: MacClippyContentKind?
    let needsKind: Bool
    let bareTerms: [String]
    let ftsMatchIDs: Set<RecordID>
}

struct MacClippyPinboardSearchSelection {
    let metas: [ClipboardItemMeta]
    let nextToken: MacClippyPinboardSearchPageToken?
    let cancelled: Bool
}

struct MacClippyPinboardSearchRequest {
    let query: String
    let ftsMatchIDs: Set<RecordID>
    let limit: Int
    let memberOffset: Int
}

extension MacClippyRuntime {
    /// Loads a bounded search page against a stable board revision. The
    /// continuation is a member position, not a match count, so subsequent
    /// pages do not rescan the board from the beginning.
    func pinboardSearchPage(
        pinboardID: RecordID,
        query: String,
        limit: Int = 64,
        pageToken: MacClippyPinboardSearchPageToken? = nil,
        shouldCancel: () -> Bool = { false }
    ) throws -> MacClippyPinboardSearchPage {
        let snapshot = try withStoreLock {
            let board = try pinboardStore.fetch(id: pinboardID)
            if let pageToken, pageToken.boardModified != board.modified {
                throw MacClippyPinboardSearchPageError.boardChanged
            }
            return board
        }
        if shouldCancel() {
            return MacClippyPinboardSearchPage(items: [], nextPageToken: nil)
        }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = MacClippySearchGrammar.parse(trimmedQuery)
        let ftsMatchIDs = try pinboardFTSMatchIDs(
            terms: parsed.bareTerms,
            memberIDs: Set(snapshot.itemIDs),
            shouldCancel: shouldCancel
        )
        if shouldCancel() {
            return MacClippyPinboardSearchPage(items: [], nextPageToken: nil)
        }
        let selection = try withStoreLock {
            let board = try pinboardStore.fetch(id: pinboardID)
            if board.modified != snapshot.modified {
                throw MacClippyPinboardSearchPageError.boardChanged
            }
            return try pinboardSearchSelection(
                for: board,
                request: MacClippyPinboardSearchRequest(
                    query: query,
                    ftsMatchIDs: ftsMatchIDs,
                    limit: limit,
                    memberOffset: pageToken?.memberOffset ?? 0
                ),
                shouldCancel: shouldCancel
            )
        }
        if selection.cancelled {
            return MacClippyPinboardSearchPage(items: [], nextPageToken: nil)
        }
        let entriesByID = try entries(for: selection.metas, validateContentKind: true)
        let items = selection.metas.compactMap { entriesByID[$0.id] }
        return MacClippyPinboardSearchPage(items: items, nextPageToken: selection.nextToken)
    }

    func pinboardSearchSelection(
        for board: Pinboard,
        request: MacClippyPinboardSearchRequest,
        shouldCancel: () -> Bool
    ) throws -> MacClippyPinboardSearchSelection {
        let pageLimit = min(max(request.limit, 0), 128)
        guard pageLimit > 0 else {
            return MacClippyPinboardSearchSelection(metas: [], nextToken: nil, cancelled: false)
        }

        let trimmedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return try emptyPinboardSearchSelection(
                for: board,
                limit: pageLimit,
                memberOffset: request.memberOffset,
                shouldCancel: shouldCancel
            )
        }

        guard let context = pinboardSearchContext(
            for: trimmedQuery,
            ftsMatchIDs: request.ftsMatchIDs
        ) else {
            return MacClippyPinboardSearchSelection(metas: [], nextToken: nil, cancelled: false)
        }
        return try filteredPinboardSearchSelection(
            for: board,
            context: context,
            limit: pageLimit,
            memberOffset: request.memberOffset,
            shouldCancel: shouldCancel
        )
    }

    private func emptyPinboardSearchSelection(
        for board: Pinboard,
        limit: Int,
        memberOffset: Int,
        shouldCancel: () -> Bool
    ) throws -> MacClippyPinboardSearchSelection {
        var selectedMetas: [ClipboardItemMeta] = []
        selectedMetas.reserveCapacity(limit)
        var nextOffset = min(max(0, memberOffset), board.itemIDs.count)

        while nextOffset < board.itemIDs.count, selectedMetas.count < limit {
            guard !shouldCancel() else {
                return MacClippyPinboardSearchSelection(metas: [], nextToken: nil, cancelled: true)
            }
            let scanLimit = min(limit - selectedMetas.count, board.itemIDs.count - nextOffset)
            let batchIDs = Array(board.itemIDs[nextOffset ..< (nextOffset + scanLimit)])
            let metas = try clipboardStore.metas(for: batchIDs)
            let metasByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
            selectedMetas.append(contentsOf: batchIDs.compactMap { metasByID[$0] })
            nextOffset += scanLimit
        }

        guard !shouldCancel() else {
            return MacClippyPinboardSearchSelection(metas: [], nextToken: nil, cancelled: true)
        }
        let nextToken = nextOffset < board.itemIDs.count
            ? MacClippyPinboardSearchPageToken(boardModified: board.modified, memberOffset: nextOffset)
            : nil
        return MacClippyPinboardSearchSelection(
            metas: Array(selectedMetas.prefix(limit)),
            nextToken: nextToken,
            cancelled: false
        )
    }

    private func filteredPinboardSearchSelection(
        for board: Pinboard,
        context: MacClippyPinboardSearchContext,
        limit: Int,
        memberOffset: Int,
        shouldCancel: () -> Bool
    ) throws -> MacClippyPinboardSearchSelection {
        var selectedMetas: [ClipboardItemMeta] = []
        selectedMetas.reserveCapacity(limit)

        let metadataBatchSize = 500
        var nextOffset = min(max(0, memberOffset), board.itemIDs.count)
        var start = nextOffset
        while start < board.itemIDs.count {
            guard !shouldCancel() else {
                return MacClippyPinboardSearchSelection(metas: [], nextToken: nil, cancelled: true)
            }
            let end = min(start + metadataBatchSize, board.itemIDs.count)
            let batchIDs = Array(board.itemIDs[start ..< end])
            let metas = try clipboardStore.metas(for: batchIDs)
            let metasByID = Dictionary(uniqueKeysWithValues: metas.map { ($0.id, $0) })
            let knownKinds: [RecordID: MacClippyContentKind] = context.needsKind
                ? try clipboardStore.contentKinds(for: batchIDs)
                : [:]

            for (index, id) in batchIDs.enumerated() {
                guard !shouldCancel() else {
                    return MacClippyPinboardSearchSelection(metas: [], nextToken: nil, cancelled: true)
                }
                nextOffset = start + index + 1
                guard let meta = metasByID[id] else { continue }
                guard try pinboardMetaMatches(meta, context: context, knownKinds: knownKinds) else { continue }
                selectedMetas.append(meta)
                if selectedMetas.count == limit { break }
            }
            if selectedMetas.count == limit { break }
            start = end
        }

        let nextToken = nextOffset < board.itemIDs.count
            ? MacClippyPinboardSearchPageToken(boardModified: board.modified, memberOffset: nextOffset)
            : nil
        return MacClippyPinboardSearchSelection(
            metas: selectedMetas,
            nextToken: nextToken,
            cancelled: false
        )
    }

    func pinboardSearchContext(
        for query: String,
        ftsMatchIDs: Set<RecordID>
    ) -> MacClippyPinboardSearchContext? {
        let parsed = MacClippySearchGrammar.parse(query)
        let requestedKinds = parsed.clauses.compactMap { clause -> MacClippyContentKind? in
            if case let .type(kind) = clause { return kind }
            return nil
        }
        guard Set(requestedKinds).count <= 1 else { return nil }
        return MacClippyPinboardSearchContext(
            parsed: parsed,
            requestedKind: requestedKinds.first,
            needsKind: !requestedKinds.isEmpty,
            bareTerms: parsed.bareTerms,
            ftsMatchIDs: ftsMatchIDs
        )
    }

    func pinboardFTSMatchIDs(
        terms: [String],
        memberIDs: Set<RecordID>,
        shouldCancel: () -> Bool
    ) throws -> Set<RecordID> {
        guard !terms.isEmpty, !memberIDs.isEmpty else { return [] }
        var matches = Set<RecordID>()
        var cursor: MacClippySearchCursor?
        while matches.count < memberIDs.count {
            guard !shouldCancel() else { return matches }
            let hits = try searchStore.search(terms: terms, limit: 256, after: cursor)
            if hits.isEmpty { break }
            for hit in hits where memberIDs.contains(hit.id) {
                matches.insert(hit.id)
            }
            guard let last = hits.last else { break }
            cursor = MacClippySearchCursor(rank: last.rank, rowID: last.rowID)
            if hits.count < 256 { break }
        }
        return matches
    }

    func pinboardMetaMatches(
        _ meta: ClipboardItemMeta,
        context: MacClippyPinboardSearchContext,
        knownKinds: [RecordID: MacClippyContentKind]
    ) throws -> Bool {
        if context.parsed.hasStructuredClauses {
            guard let record = try searchRecord(
                for: meta,
                needsKind: context.needsKind,
                knownKinds: knownKinds
            ), MacClippySearchGrammar.matches(context.parsed, record: record) else {
                return false
            }
        }
        if !context.bareTerms.isEmpty {
            let haystacks = [
                meta.preview,
                meta.ocrText ?? "",
                meta.customLabel ?? ""
            ]
            let textMatches = MacClippySearchQuery.allTerms(context.bareTerms, appearIn: haystacks)
            guard textMatches || context.ftsMatchIDs.contains(meta.id) else {
                return false
            }
        }
        return context.requestedKind == nil || meta.contentKind == context.requestedKind
    }
}
