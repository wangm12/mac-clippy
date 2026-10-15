import Foundation

import MacClippyCore
import MacClippyPlatform

final class MacClippyHistorySearchScope: Equatable, Sendable {
    let ownerID: UUID
    let query: MacClippySearchGrammar.Query
    let clipboardRevision: Int64
    let recordScope: MacClippySearchRecordScope

    init(ownerID: UUID, query: MacClippySearchGrammar.Query, clipboardRevision: Int64, recordIDs: [RecordID]) {
        self.ownerID = ownerID
        self.query = query
        self.clipboardRevision = clipboardRevision
        recordScope = MacClippySearchRecordScope(recordIDs: recordIDs)
    }

    static func == (lhs: MacClippyHistorySearchScope, rhs: MacClippyHistorySearchScope) -> Bool {
        lhs === rhs
    }
}

struct MacClippySearchPageCursor: Equatable, Sendable {
    let indexRevision: Int64
    let lastRank: Double?
    let lastRowID: Int64?
    let structuredScope: MacClippyHistorySearchScope?

    init(
        indexRevision: Int64, lastRank: Double?, lastRowID: Int64?,
        structuredScope: MacClippyHistorySearchScope? = nil
    ) {
        self.indexRevision = indexRevision
        self.lastRank = lastRank
        self.lastRowID = lastRowID
        self.structuredScope = structuredScope
    }

    var searchCursor: MacClippySearchCursor? {
        guard let lastRank, let lastRowID else { return nil }
        return MacClippySearchCursor(rank: lastRank, rowID: lastRowID)
    }
}

enum MacClippyHistoryPageError: Error, Equatable {
    case searchIndexChanged
}

struct MacClippyPinboardSearchPageToken: Equatable, Sendable {
    let boardModified: Date
    let memberOffset: Int
}

struct MacClippyPinboardSearchPage: Sendable {
    let items: [MacClippyHistoryEntry]
    let nextPageToken: MacClippyPinboardSearchPageToken?
}

enum MacClippyPinboardSearchPageError: Error, Equatable {
    case boardChanged
}

enum MacClippyHistoryPageToken: Equatable, Sendable {
    case historyCursor(MacClippyClipboardHistoryCursor)
    case searchCursor(MacClippySearchPageCursor)

    var historyCursor: MacClippyClipboardHistoryCursor? {
        guard case let .historyCursor(cursor) = self else { return nil }
        return cursor
    }

    var searchCursor: MacClippySearchPageCursor? {
        guard case let .searchCursor(cursor) = self else { return nil }
        return cursor
    }
}

struct MacClippyHistoryPage: Sendable {
    let items: [MacClippyHistoryEntry]
    let nextPageToken: MacClippyHistoryPageToken?
}
