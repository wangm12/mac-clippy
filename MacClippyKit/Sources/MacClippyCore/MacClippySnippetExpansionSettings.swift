import Foundation

public enum MacClippySnippetExpansionMode: String, CaseIterable, Identifiable, Sendable {
    case autoExpand
    case confirmWithTab
    case disabled

    public var id: String { rawValue }
}

public enum MacClippySnippetExpansionSettings {
    public static let modeKey = "com.macallyouneed.macclippy.snippetExpansionMode"
    public static let defaultMode = MacClippySnippetExpansionMode.autoExpand

    public static func load(from defaults: UserDefaults = .standard) -> MacClippySnippetExpansionMode {
        MacClippySnippetExpansionMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? defaultMode
    }

    public static func save(_ mode: MacClippySnippetExpansionMode, to defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }
}
