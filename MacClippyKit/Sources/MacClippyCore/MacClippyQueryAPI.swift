import Foundation

public enum MacClippyQueryExposureScope: String, Equatable, Sendable {
    case pinboardsNonConcealed = "pinboards"
    case allNonConcealed = "all-non-concealed"
    case all = "all"
}

public enum MacClippyQueryRequest: Equatable, Sendable {
    case search(query: String, limit: Int, scope: MacClippyQueryExposureScope)
    case get(id: RecordID, scope: MacClippyQueryExposureScope)
    case pin(id: RecordID, board: String)
    case save(text: String, board: String?)
}

public enum MacClippyQueryResponse: Equatable, Sendable {
    case records([MacClippyQueryRecordView])
    case record(MacClippyQueryRecordView)
    case pinned(id: RecordID, board: String)
    case saved(id: RecordID)
    case notFound
}

public struct MacClippyQueryRecordView: Equatable, Sendable {
    public let id: RecordID
    public let preview: String
    public let contentKind: MacClippyContentKind
    public let pinboardNames: [String]

    public init(
        id: RecordID,
        preview: String,
        contentKind: MacClippyContentKind,
        pinboardNames: [String]
    ) {
        self.id = id
        self.preview = preview
        self.contentKind = contentKind
        self.pinboardNames = pinboardNames
    }
}

public struct MacClippyQueryPinboard: Equatable, Sendable {
    public let id: RecordID
    public let name: String

    public init(id: RecordID, name: String) {
        self.id = id
        self.name = name
    }
}

public struct MacClippyQueryRecord: Equatable, Sendable {
    public let id: RecordID
    public let preview: String
    public let contentKind: MacClippyContentKind
    public let sourceAppBundleID: String?
    public let customLabel: String?
    public let ocrText: String?
    public let modified: Date
    public let isURL: Bool
    public let pinboardIDs: [RecordID]
    public let representationUTIs: [String]

    public init(
        id: RecordID,
        preview: String,
        contentKind: MacClippyContentKind,
        sourceAppBundleID: String?,
        customLabel: String?,
        ocrText: String?,
        modified: Date,
        isURL: Bool,
        pinboardIDs: [RecordID],
        representationUTIs: [String]
    ) {
        self.id = id
        self.preview = preview
        self.contentKind = contentKind
        self.sourceAppBundleID = sourceAppBundleID
        self.customLabel = customLabel
        self.ocrText = ocrText
        self.modified = modified
        self.isURL = isURL
        self.pinboardIDs = pinboardIDs
        self.representationUTIs = representationUTIs
    }
}

public struct MacClippyQueryCatalog: Equatable, Sendable {
    public var pinboards: [MacClippyQueryPinboard]
    public var records: [MacClippyQueryRecord]

    public init(
        pinboards: [MacClippyQueryPinboard] = [],
        records: [MacClippyQueryRecord] = []
    ) {
        self.pinboards = pinboards
        self.records = records
    }
}

public enum MacClippyQueryExposurePolicy {
    public static let defaultScope = MacClippyQueryExposureScope.pinboardsNonConcealed
    public static let defaultLimit = 20

    public static func isConcealed(
        utis: [String],
        concealedTypes: Set<String> = MacClippyCaptureExclusionRules.defaultConcealedPasteboardTypes
    ) -> Bool {
        utis.contains(where: concealedTypes.contains)
    }

    public static func shouldExpose(
        isPinned: Bool,
        isConcealed: Bool,
        scope: MacClippyQueryExposureScope = defaultScope
    ) -> Bool {
        switch scope {
        case .pinboardsNonConcealed:
            return isPinned && !isConcealed
        case .allNonConcealed:
            return !isConcealed
        case .all:
            return true
        }
    }
}

public enum MacClippyQueryCatalogPolicy {
    public static func apply(
        _ request: MacClippyQueryRequest,
        to catalog: inout MacClippyQueryCatalog
    ) -> MacClippyQueryResponse {
        switch request {
        case let .search(query, limit, scope):
            return .records(search(query, limit: max(0, limit), scope: scope, in: catalog))
        case let .get(id, scope):
            guard let record = visibleRecord(id: id, scope: scope, in: catalog) else {
                return .notFound
            }
            return .record(view(for: record, in: catalog))
        case let .pin(id, board):
            return pin(id: id, board: board, catalog: &catalog)
        case let .save(text, board):
            return save(text: text, board: board, catalog: &catalog)
        }
    }

    private static func search(
        _ raw: String,
        limit: Int,
        scope: MacClippyQueryExposureScope,
        in catalog: MacClippyQueryCatalog
    ) -> [MacClippyQueryRecordView] {
        let parsed = MacClippySearchGrammar.parse(raw)
        var hits: [MacClippyQueryRecordView] = []
        for record in catalog.records {
            guard hits.count < limit else { break }
            guard isVisible(record, scope: scope) else { continue }
            guard matches(parsed, record: record) else { continue }
            hits.append(view(for: record, in: catalog))
        }
        return hits
    }

    private static func pin(
        id: RecordID,
        board name: String,
        catalog: inout MacClippyQueryCatalog
    ) -> MacClippyQueryResponse {
        guard let board = catalog.pinboards.first(where: { $0.name == name }) else {
            return .notFound
        }
        guard let index = catalog.records.firstIndex(where: { $0.id == id }) else {
            return .notFound
        }
        var record = catalog.records[index]
        if !record.pinboardIDs.contains(board.id) {
            record = copy(record, pinboardIDs: record.pinboardIDs + [board.id])
            catalog.records[index] = record
        }
        return .pinned(id: id, board: name)
    }

    private static func save(
        text: String,
        board name: String?,
        catalog: inout MacClippyQueryCatalog
    ) -> MacClippyQueryResponse {
        var pinboardIDs: [RecordID] = []
        if let name {
            guard let board = catalog.pinboards.first(where: { $0.name == name }) else {
                return .notFound
            }
            pinboardIDs = [board.id]
        }
        let id = RecordID.generate()
        catalog.records.append(
            MacClippyQueryRecord(
                id: id,
                preview: text,
                contentKind: .text,
                sourceAppBundleID: nil,
                customLabel: nil,
                ocrText: nil,
                modified: Date(),
                isURL: false,
                pinboardIDs: pinboardIDs,
                representationUTIs: ["public.utf8-plain-text"]
            )
        )
        return .saved(id: id)
    }

    private static func visibleRecord(
        id: RecordID,
        scope: MacClippyQueryExposureScope,
        in catalog: MacClippyQueryCatalog
    ) -> MacClippyQueryRecord? {
        guard let record = catalog.records.first(where: { $0.id == id }) else {
            return nil
        }
        return isVisible(record, scope: scope) ? record : nil
    }

    private static func isVisible(
        _ record: MacClippyQueryRecord,
        scope: MacClippyQueryExposureScope
    ) -> Bool {
        MacClippyQueryExposurePolicy.shouldExpose(
            isPinned: !record.pinboardIDs.isEmpty,
            isConcealed: MacClippyQueryExposurePolicy.isConcealed(utis: record.representationUTIs),
            scope: scope
        )
    }

    private static func matches(
        _ query: MacClippySearchGrammar.Query,
        record: MacClippyQueryRecord
    ) -> Bool {
        let searchRecord = MacClippySearchGrammar.SearchRecord(
            contentKind: record.contentKind,
            sourceAppBundleID: record.sourceAppBundleID,
            customLabel: record.customLabel,
            ocrText: record.ocrText,
            modified: record.modified,
            isURL: record.isURL
        )
        guard MacClippySearchGrammar.matches(query, record: searchRecord) else {
            return false
        }
        let haystacks = [record.preview, record.customLabel ?? "", record.ocrText ?? ""]
        return MacClippySearchQuery.allTerms(query.bareTerms, appearIn: haystacks)
    }

    private static func view(
        for record: MacClippyQueryRecord,
        in catalog: MacClippyQueryCatalog
    ) -> MacClippyQueryRecordView {
        let names = record.pinboardIDs.compactMap { id in
            catalog.pinboards.first(where: { $0.id == id })?.name
        }
        return MacClippyQueryRecordView(
            id: record.id,
            preview: record.preview,
            contentKind: record.contentKind,
            pinboardNames: names
        )
    }

    private static func copy(
        _ record: MacClippyQueryRecord,
        pinboardIDs: [RecordID]
    ) -> MacClippyQueryRecord {
        MacClippyQueryRecord(
            id: record.id,
            preview: record.preview,
            contentKind: record.contentKind,
            sourceAppBundleID: record.sourceAppBundleID,
            customLabel: record.customLabel,
            ocrText: record.ocrText,
            modified: record.modified,
            isURL: record.isURL,
            pinboardIDs: pinboardIDs,
            representationUTIs: record.representationUTIs
        )
    }
}

public struct MacClippyQueryCLIError: Error, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// The Kit executable parses the shared request type but does not open the
/// encrypted store. Live search/get/pin/save stay in the MacClippy app.
public enum MacClippyQueryExecutionPolicy {
    public static let requiresAttachedCatalog = true
    public static let unattachedLibraryMessage =
        "no local library attached; search/get/pin/save run inside the MacClippy app"
}

public enum MacClippyQueryCLIPolicy {
    public static func parse<Arguments: Sequence>(
        _ arguments: Arguments
    ) throws -> MacClippyQueryRequest where Arguments.Element == String {
        var tokens = Array(arguments)
        guard let command = tokens.first else {
            throw MacClippyQueryCLIError("missing command")
        }
        tokens.removeFirst()
        switch command {
        case "search":
            let scope = try takeScope(&tokens)
            let limit = try takeLimit(&tokens)
            let query = tokens.joined(separator: " ")
            guard !query.isEmpty else { throw MacClippyQueryCLIError("missing search query") }
            return .search(query: query, limit: limit, scope: scope)
        case "get":
            let scope = try takeScope(&tokens)
            guard let raw = tokens.first, let id = RecordID(rawValue: raw) else {
                throw MacClippyQueryCLIError("missing record id")
            }
            return .get(id: id, scope: scope)
        case "pin":
            guard let raw = tokens.first, let id = RecordID(rawValue: raw) else {
                throw MacClippyQueryCLIError("missing record id")
            }
            tokens.removeFirst()
            guard let board = takeValue("--board", from: &tokens), !board.isEmpty else {
                throw MacClippyQueryCLIError("missing --board")
            }
            return .pin(id: id, board: board)
        case "save":
            let board = takeValue("--board", from: &tokens)
            let text = tokens.joined(separator: " ")
            guard !text.isEmpty else { throw MacClippyQueryCLIError("missing text") }
            return .save(text: text, board: board)
        default:
            throw MacClippyQueryCLIError("unknown command")
        }
    }

    private static func takeScope(_ tokens: inout [String]) throws -> MacClippyQueryExposureScope {
        guard let raw = takeValue("--scope", from: &tokens) else {
            return MacClippyQueryExposurePolicy.defaultScope
        }
        guard let scope = MacClippyQueryExposureScope(rawValue: raw) else {
            throw MacClippyQueryCLIError("unknown scope")
        }
        return scope
    }

    private static func takeLimit(_ tokens: inout [String]) throws -> Int {
        guard let raw = takeValue("--limit", from: &tokens) else {
            return MacClippyQueryExposurePolicy.defaultLimit
        }
        guard let limit = Int(raw), limit >= 0 else {
            throw MacClippyQueryCLIError("invalid limit")
        }
        return limit
    }

    private static func takeValue(_ flag: String, from tokens: inout [String]) -> String? {
        guard let index = tokens.firstIndex(of: flag), tokens.indices.contains(index + 1) else {
            return nil
        }
        let value = tokens[index + 1]
        tokens.removeSubrange(index...index + 1)
        return value
    }
}

public struct MacClippyQueryMCPTool: Equatable, Sendable {
    public let name: String
    public let description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

public enum MacClippyQueryMCPPolicy {
    public static let tools = [
        MacClippyQueryMCPTool(name: "search", description: "Search exposed clipboard records"),
        MacClippyQueryMCPTool(name: "get", description: "Get one exposed clipboard record"),
        MacClippyQueryMCPTool(name: "pin", description: "Pin a clipboard record onto a pinboard"),
        MacClippyQueryMCPTool(name: "save", description: "Save text, optionally onto a pinboard")
    ]

    public static func request(
        tool: String,
        arguments: [String: String]
    ) throws -> MacClippyQueryRequest {
        let scope = try scope(from: arguments["scope"])
        switch tool {
        case "search":
            guard let query = arguments["query"], !query.isEmpty else {
                throw MacClippyQueryCLIError("missing query")
            }
            let limit = arguments["limit"].flatMap(Int.init) ?? MacClippyQueryExposurePolicy.defaultLimit
            return .search(query: query, limit: limit, scope: scope)
        case "get":
            guard let raw = arguments["id"], let id = RecordID(rawValue: raw) else {
                throw MacClippyQueryCLIError("missing record id")
            }
            return .get(id: id, scope: scope)
        case "pin":
            guard let raw = arguments["id"], let id = RecordID(rawValue: raw) else {
                throw MacClippyQueryCLIError("missing record id")
            }
            guard let board = arguments["board"], !board.isEmpty else {
                throw MacClippyQueryCLIError("missing board")
            }
            return .pin(id: id, board: board)
        case "save":
            guard let text = arguments["text"], !text.isEmpty else {
                throw MacClippyQueryCLIError("missing text")
            }
            let board = arguments["board"]
            return .save(text: text, board: board?.isEmpty == true ? nil : board)
        default:
            throw MacClippyQueryCLIError("unknown tool")
        }
    }

    private static func scope(from raw: String?) throws -> MacClippyQueryExposureScope {
        guard let raw else { return MacClippyQueryExposurePolicy.defaultScope }
        guard let scope = MacClippyQueryExposureScope(rawValue: raw) else {
            throw MacClippyQueryCLIError("unknown scope")
        }
        return scope
    }
}
