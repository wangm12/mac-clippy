import Foundation

// P2b: a pure, Foundation-only structured search grammar layered over the
// existing clipboard metadata. This file adds NO new storage: it only parses a
// query string into typed clauses and evaluates those clauses against a
// MacClippySearchRecord built from the existing ClipboardItemMeta fields
// (contentKind, sourceAppBundleID, customLabel, ocrText, modified). Bare
// free-text terms are NOT evaluated here; they are returned to the caller so
// the existing FTS5 search index keeps its behavior. Structured clauses and
// bare terms are ANDed at the runtime layer.
//
// Safety rules encoded here:
// - Unknown or malformed clauses (unknown key, empty value, unparseable date)
//   are NOT silently dropped and NOT treated as match-all. They degrade to a
//   bare free-text term so the query narrows via FTS instead of broadening.
// - Quoted values (name:"project alpha") are accepted; the surrounding quotes
//   are stripped and embedded escaped quotes are handled.
// - Dates are parsed with the current local calendar so a malformed date
//   never crashes; an invalid date degrades the clause to a bare term.

public enum MacClippySearchGrammar {
    // A single typed clause. `bare` carries a free-text term that the caller
    // forwards to the existing FTS index; the remaining cases are structured
    // predicates evaluated against MacClippySearchRecord.
    public enum Clause: Equatable, Sendable {
        case bare(String)
        case type(MacClippyContentKind)
        case app(String)
        case label(String)
        case hasLabel
        case hasOCR
        case before(Date)
        case after(Date)
        case url
    }

    public struct Query: Equatable, Sendable {
        public let bareTerms: [String]
        public let clauses: [Clause]

        public init(bareTerms: [String] = [], clauses: [Clause] = []) {
            self.bareTerms = bareTerms
            self.clauses = clauses
        }

        // True when the query contains at least one structured clause. Used by
        // the runtime to decide whether to apply the predicate after FTS.
        public var hasStructuredClauses: Bool {
            clauses.contains { $0.isStructured }
        }

        // True when the query has structured clauses AND no bare free-text
        // terms. The runtime uses this to fetch all metas and filter them,
        // rather than seeding from an FTS query, so structured-only queries
        // work and fill the result limit.
        public var isStructuredOnly: Bool {
            hasStructuredClauses && bareTerms.isEmpty
        }
    }

    // The subset of clipboard metadata the predicate needs. The runtime
    // builds this from ClipboardItemMeta plus the contentKind it already
    // resolves when reading the body for entry(for:). Keeping this separate
    // from ClipboardItemMeta avoids adding a stored contentKind field to the
    // persisted model (the content kind lives on the clipboard record body).
    public struct SearchRecord: Equatable, Sendable {
        public let contentKind: MacClippyContentKind
        public let sourceAppBundleID: String?
        public let sourceAppDisplayName: String?
        public let customLabel: String?
        public let ocrText: String?
        public let modified: Date
        public let isURL: Bool

        public init(
            contentKind: MacClippyContentKind,
            sourceAppBundleID: String?,
            sourceAppDisplayName: String? = nil,
            customLabel: String?,
            ocrText: String?,
            modified: Date,
            isURL: Bool = false
        ) {
            self.contentKind = contentKind
            self.sourceAppBundleID = sourceAppBundleID
            self.sourceAppDisplayName = sourceAppDisplayName
            self.customLabel = customLabel
            self.ocrText = ocrText
            self.modified = modified
            self.isURL = isURL
        }

        public init(
            meta: ClipboardItemMeta,
            contentKind: MacClippyContentKind,
            sourceAppDisplayName: String? = nil
        ) {
            self.contentKind = contentKind
            self.sourceAppBundleID = meta.sourceAppBundleID
            self.sourceAppDisplayName = sourceAppDisplayName
            self.customLabel = meta.customLabel
            self.ocrText = meta.ocrText
            self.modified = meta.modified
            self.isURL = Self.detectsURL(meta)
        }

        public static func detectsURL(_ meta: ClipboardItemMeta) -> Bool {
            if let json = meta.detectedTypeJSON, json.localizedCaseInsensitiveContains("url") {
                return true
            }
            return MacClippySmartText.matchesURL(meta.preview)
        }
    }

    // Evaluate the structured clauses of a Query against a record. Bare terms
    // are intentionally NOT evaluated here; they are handled by the FTS layer
    // at the runtime. Returns true when every structured clause matches.
    public static func matches(_ query: Query, record: SearchRecord) -> Bool {
        for clause in query.clauses where clause.isStructured {
            if !matches(clause, record: record) { return false }
        }
        return true
    }

    // Evaluate a single structured clause against a record. Public so tests
    // can assert individual clauses without composing a full Query.
    public static func matches(_ clause: Clause, record: SearchRecord) -> Bool {
        switch clause {
        case .bare:
            // Bare terms are evaluated by the FTS layer, not here. A bare
            // clause is never a structured predicate, so it always matches
            // here and does not narrow the predicate.
            return true
        case .type(let kind):
            return record.contentKind == kind
        case .app(let value):
            return sourceHaystacks(for: record).contains {
                $0.localizedCaseInsensitiveContains(value)
            }
        case .label(let value):
            return record.customLabel?.localizedCaseInsensitiveContains(value) ?? false
        case .hasLabel:
            let trimmed = record.customLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false
        case .hasOCR:
            let trimmed = record.ocrText?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false
        case .before(let dayStart):
            // before:<day> means modified strictly before the start of that
            // day; a record modified earlier the same calendar day is NOT
            // included (it is >= the start).
            return record.modified < dayStart
        case .after(let dayStart):
            // after:<day> means modified on or after the start of that day.
            return record.modified >= dayStart
        case .url:
            return record.isURL
        }
    }

    private static func sourceHaystacks(for record: SearchRecord) -> [String] {
        MacClippySourceAppSearch.segments(
            bundleID: record.sourceAppBundleID,
            displayName: record.sourceAppDisplayName
        )
    }
}

public extension MacClippySearchGrammar.Clause {
    // True for clauses that are structured predicates (everything except
    // .bare). Used to distinguish FTS-bound terms from predicate clauses.
    var isStructured: Bool {
        switch self {
        case .bare: return false
        default: return true
        }
    }
}
