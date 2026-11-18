import Foundation

/// Read a component together with its implementation extensions for source-contract checks.
func macClippyTestAppSource(named fileName: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MacClippy")
    let extensions: [String: [String]] = [
        "MacClippyClipboardCardLabel.swift": ["MacClippyClipboardCardLabel+Content.swift"],
        "MacClippyDockPreview.swift": ["MacClippyDockPreview+Header.swift"]
    ]
    return try ([fileName] + (extensions[fileName] ?? [])).map {
        try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
    }.joined(separator: "\n")
}
