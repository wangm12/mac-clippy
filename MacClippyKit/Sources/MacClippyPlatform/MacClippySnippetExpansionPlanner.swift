import Carbon.HIToolbox
import Foundation

import MacClippyCore

public struct MacClippySnippetExpansionPlan: Equatable, Sendable {
    public let body: String
    public let charactersToDelete: Int
    public let suppressCurrentEvent: Bool
    public let suppressedDelimiterKeyCode: UInt16?

    public init(
        body: String,
        charactersToDelete: Int,
        suppressCurrentEvent: Bool,
        suppressedDelimiterKeyCode: UInt16? = nil
    ) {
        self.body = body
        self.charactersToDelete = charactersToDelete
        self.suppressCurrentEvent = suppressCurrentEvent
        self.suppressedDelimiterKeyCode = suppressedDelimiterKeyCode
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

    package var currentTrigger: String? {
        guard let start = buffer.lastIndex(of: Self.triggerStart) else { return nil }
        return String(buffer[start...])
    }

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
            return expansionPlan(suppressedDelimiterKeyCode: Self.tabKeyCode, suppressDelimiter: true)
        }

        if character.isWhitespace || character.isNewline {
            defer { reset() }
            // Space confirms expansion. Return and Tab remain available to
            // send messages and move focus unless Tab confirmation is chosen.
            guard mode == .autoExpand, character == " " else { return nil }
            return expansionPlan(
                suppressedDelimiterKeyCode: nil,
                suppressDelimiter: false,
                includesDelimiter: true
            )
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

    private func expansionPlan(
        suppressedDelimiterKeyCode: UInt16?,
        suppressDelimiter: Bool,
        includesDelimiter: Bool = false
    ) -> MacClippySnippetExpansionPlan? {
        guard let start = buffer.lastIndex(of: Self.triggerStart) else { return nil }
        let candidate = String(buffer[start...])
        guard candidate.count >= 2, let body = lookup(candidate) else { return nil }
        return MacClippySnippetExpansionPlan(
            body: body,
            charactersToDelete: candidate.count + (includesDelimiter ? 1 : 0),
            suppressCurrentEvent: suppressDelimiter,
            suppressedDelimiterKeyCode: suppressedDelimiterKeyCode
        )
    }
}
