import Foundation

public struct MacClippySmartList: Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let query: String
    public let systemImage: String?

    public init(id: String, title: String, query: String, systemImage: String? = nil) {
        self.id = id
        self.title = title
        self.query = query
        self.systemImage = systemImage
    }
}

/// Named saved queries over the existing search grammar.
/// Built-in lists are virtual: they never write a pinboard row.
public enum MacClippySmartListPolicy {
    public static let hiddenIDsKey = "com.macallyouneed.macclippy.dock.hiddenSmartLists"

    public static let catalog: [MacClippySmartList] = [
        MacClippySmartList(id: "urls", title: "URL", query: "type:url", systemImage: "link"),
        MacClippySmartList(id: "images", title: "Image", query: "type:image", systemImage: "photo")
    ]

    public static func visibleCatalog(hiddenIDs: Set<String>) -> [MacClippySmartList] {
        catalog.filter { !hiddenIDs.contains($0.id) }
    }

    public static func hiding(_ list: MacClippySmartList, in hiddenIDs: Set<String>) -> Set<String> {
        hiddenIDs.union([list.id])
    }

    public static func hiddenIDs(from defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: hiddenIDsKey) ?? [])
    }

    public static func persist(hiddenIDs: Set<String>, to defaults: UserDefaults) {
        defaults.set(Array(hiddenIDs).sorted(), forKey: hiddenIDsKey)
    }

    public static func hasActiveList(in raw: String) -> Bool {
        catalog.contains { isActive($0, in: raw) }
    }

    public static func isAllSelected(isHistoryTab: Bool, query: String) -> Bool {
        isHistoryTab && !hasActiveList(in: query)
    }

    /// The AppKit field can keep a smart-list token after the rail pill
    /// already owns that filter — sometimes with the colon stripped
    /// (`typeimage`). Committing that residue as a bare term empties every list.
    public static func isFieldResidue(_ incoming: String) -> Bool {
        let trimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let compactIncoming = compactToken(trimmed)
        return catalog.contains { list in
            trimmed.compare(list.query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                || compactIncoming == compactToken(list.query)
        }
    }

    public static func clearing(_ raw: String) -> String {
        let parsed = MacClippySearchGrammar.parse(raw)
        let owned = catalog.flatMap { MacClippySearchGrammar.parse($0.query).clauses }
        let nextClauses = parsed.clauses.filter { !owned.contains($0) }
        return MacClippySearchFilterChipPolicy.serialize(
            MacClippySearchGrammar.Query(bareTerms: parsed.bareTerms, clauses: nextClauses)
        )
    }

    public static func visibleListTokens(hiddenIDs: Set<String> = []) -> Set<String> {
        Set(
            visibleCatalog(hiddenIDs: hiddenIDs).flatMap { list in
                MacClippySearchGrammar.parse(list.query).clauses.map {
                    MacClippySearchFilterChipPolicy.token(for: $0)
                }
            }
        )
    }

    public static func isActive(_ list: MacClippySmartList, in raw: String) -> Bool {
        isActive(list, in: MacClippySearchGrammar.parse(raw))
    }

    public static func isActive(
        _ list: MacClippySmartList,
        in query: MacClippySearchGrammar.Query
    ) -> Bool {
        let needed = MacClippySearchGrammar.parse(list.query).clauses
        return needed.allSatisfy(query.clauses.contains)
    }

    public static func apply(_ list: MacClippySmartList, to raw: String) -> String {
        let parsed = MacClippySearchGrammar.parse(raw)
        let listClauses = MacClippySearchGrammar.parse(list.query).clauses
        let nextClauses: [MacClippySearchGrammar.Clause]
        if isActive(list, in: parsed) {
            nextClauses = parsed.clauses.filter { !listClauses.contains($0) }
        } else {
            let owned = catalog.flatMap { MacClippySearchGrammar.parse($0.query).clauses }
            nextClauses = parsed.clauses.filter { !owned.contains($0) } + listClauses
        }
        return MacClippySearchFilterChipPolicy.serialize(
            MacClippySearchGrammar.Query(bareTerms: parsed.bareTerms, clauses: nextClauses)
        )
    }

    private static func compactToken(_ raw: String) -> String {
        raw.filter { !$0.isWhitespace && $0 != ":" }.lowercased()
    }

    public static func contains(
        _ record: MacClippySearchGrammar.SearchRecord,
        in list: MacClippySmartList
    ) -> Bool {
        MacClippySearchGrammar.matches(
            MacClippySearchGrammar.parse(list.query),
            record: record
        )
    }
}
