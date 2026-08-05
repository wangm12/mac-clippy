import Carbon.HIToolbox
import Foundation

import MacClippyCore

public struct MacClippySnippetExpansionPlan: Equatable, Sendable {
    public let body: String
    public let charactersToDelete: Int
    public let suppressCurrentEvent: Bool

    public init(body: String, charactersToDelete: Int, suppressCurrentEvent: Bool) {
        self.body = body
        self.charactersToDelete = charactersToDelete
        self.suppressCurrentEvent = suppressCurrentEvent
    }
}

public struct MacClippySnippetExpansionPlanner {
    public typealias Lookup = (String) -> String?

    private static let maxBufferLength = 64
    private static let triggerStart: Character = ";"
    private static let tabKeyCode = UInt16(kVK_Tab)

    private var buffer = ""
    private let modeProvider: () -> MacClippySnippetExpansionMode
    private let lookup: Lookup

    public init(
        mode: MacClippySnippetExpansionMode = MacClippySnippetExpansionSettings.defaultMode,
        lookup: @escaping Lookup
    ) {
        self.init(modeProvider: { mode }, lookup: lookup)
    }

    public init(
        modeProvider: @escaping () -> MacClippySnippetExpansionMode,
        lookup: @escaping Lookup
    ) {
        self.modeProvider = modeProvider
        self.lookup = lookup
    }

    public mutating func handle(
        _ character: Character,
        keyCode: UInt16? = nil,
        hasDisqualifyingModifiers: Bool = false
    ) -> MacClippySnippetExpansionPlan? {
        let mode = modeProvider()
        switch mode {
        case .disabled:
            reset()
            return nil
        case .autoExpand, .confirmWithTab:
            guard !hasDisqualifyingModifiers else {
                reset()
                return nil
            }
        }

        if mode == .confirmWithTab, keyCode == Self.tabKeyCode {
            defer { reset() }
            return expansionPlan()
        }

        if character.isWhitespace || character.isNewline {
            defer { reset() }
            guard mode == .autoExpand else { return nil }
            return expansionPlan()
        }

        buffer.append(character)
        if buffer.count > Self.maxBufferLength {
            buffer.removeFirst(buffer.count - Self.maxBufferLength)
        }
        return nil
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    private func expansionPlan() -> MacClippySnippetExpansionPlan? {
        guard let start = buffer.lastIndex(of: Self.triggerStart) else { return nil }
        let candidate = String(buffer[start...])
        guard candidate.count >= 2, let body = lookup(candidate) else { return nil }
        return MacClippySnippetExpansionPlan(
            body: body,
            charactersToDelete: candidate.count,
            suppressCurrentEvent: true
        )
    }
}
