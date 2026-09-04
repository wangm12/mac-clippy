import Foundation

public struct MacClippySnippetVariableContext: Equatable, Sendable {
    public var now: Date
    public var calendar: Calendar
    public var clipboard: String?

    public init(
        now: Date = Date(),
        calendar: Calendar = .current,
        clipboard: String? = nil
    ) {
        self.now = now
        self.calendar = calendar
        self.clipboard = clipboard
    }
}

/// Expands known `{{token}}` placeholders at inject/paste time.
/// Unknown or unclosed tokens stay in the body. There is no shell.
public enum MacClippySnippetVariablePolicy {
    public static func expand(_ body: String, context: MacClippySnippetVariableContext) -> String {
        let nsBody = body as NSString
        let matches = tokenPattern.matches(
            in: body,
            range: NSRange(location: 0, length: nsBody.length)
        )
        var result = ""
        var cursor = 0
        for match in matches {
            let fullRange = match.range
            result += nsBody.substring(
                with: NSRange(location: cursor, length: fullRange.location - cursor)
            )
            let name = nsBody.substring(with: match.range(at: 1)).lowercased()
            if let replacement = value(for: name, context: context) {
                result += replacement
            } else {
                result += nsBody.substring(with: fullRange)
            }
            cursor = fullRange.location + fullRange.length
        }
        result += nsBody.substring(from: cursor)
        return result
    }

    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"\{\{([A-Za-z][A-Za-z0-9]*)\}\}"#
    )

    private static func value(
        for name: String,
        context: MacClippySnippetVariableContext
    ) -> String? {
        let parts = context.calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: context.now
        )
        switch name {
        case "date":
            return String(
                format: "%04d-%02d-%02d",
                parts.year ?? 0,
                parts.month ?? 0,
                parts.day ?? 0
            )
        case "time":
            return String(
                format: "%02d:%02d",
                parts.hour ?? 0,
                parts.minute ?? 0
            )
        case "clipboard":
            return context.clipboard ?? ""
        default:
            return nil
        }
    }
}

public struct MacClippySnippetFolderGroup: Equatable, Sendable {
    public var folder: String?
    public var snippetIDs: [RecordID]

    public init(folder: String?, snippetIDs: [RecordID]) {
        self.folder = folder
        self.snippetIDs = snippetIDs
    }
}

/// Folder paths are display labels, not filesystem paths.
/// `..` / `.` segments are rejected so a folder never looks like traversal.
public enum MacClippySnippetFolderPolicy {
    public static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var segments: [String] = []
        for part in raw.split(separator: "/", omittingEmptySubsequences: true) {
            let segment = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !segment.isEmpty else { continue }
            if segment == "." || segment == ".." {
                return nil
            }
            segments.append(segment)
        }
        guard !segments.isEmpty else { return nil }
        return segments.joined(separator: "/")
    }

    public static func groups(
        from items: [(id: RecordID, folder: String?)]
    ) -> [MacClippySnippetFolderGroup] {
        var namedOrder: [String] = []
        var namedIDs: [String: [RecordID]] = [:]
        var unfiled: [RecordID] = []

        for item in items {
            if let folder = normalized(item.folder) {
                if namedIDs[folder] == nil {
                    namedOrder.append(folder)
                    namedIDs[folder] = []
                }
                namedIDs[folder, default: []].append(item.id)
            } else {
                unfiled.append(item.id)
            }
        }

        var groups = namedOrder.map { folder in
            MacClippySnippetFolderGroup(folder: folder, snippetIDs: namedIDs[folder] ?? [])
        }
        if !unfiled.isEmpty {
            groups.append(MacClippySnippetFolderGroup(folder: nil, snippetIDs: unfiled))
        }
        return groups
    }
}
