import Foundation

public struct MacClippyOCRNormalizedRect: Equatable, Sendable {
    public let minX: Double
    public let minY: Double
    public let width: Double
    public let height: Double

    public init(minX: Double, minY: Double, width: Double, height: Double) {
        self.minX = minX
        self.minY = minY
        self.width = width
        self.height = height
    }
}

public struct MacClippyOCRCharacter: Equatable, Sendable {
    public let text: String
    public let boundingBox: MacClippyOCRNormalizedRect?

    public init(text: String, boundingBox: MacClippyOCRNormalizedRect?) {
        self.text = text
        self.boundingBox = boundingBox
    }
}

public struct MacClippyOCRTextLine: Equatable, Sendable {
    public let text: String
    public let boundingBox: MacClippyOCRNormalizedRect
    public let characters: [MacClippyOCRCharacter]

    public init(
        text: String,
        boundingBox: MacClippyOCRNormalizedRect,
        characters: [MacClippyOCRCharacter]
    ) {
        self.text = text
        self.boundingBox = boundingBox
        self.characters = characters
    }

    public var hasCompleteCharacterGeometry: Bool {
        characters.count == text.count
            && !characters.isEmpty
            && characters.allSatisfy { $0.boundingBox != nil }
    }
}

public struct MacClippyOCRResult: Equatable, Sendable {
    public let lines: [MacClippyOCRTextLine]
    public let fullText: String

    public init(lines: [MacClippyOCRTextLine]) {
        self.lines = lines
        self.fullText = lines.map(\.text).joined(separator: "\n")
    }

    public init(lines: [MacClippyOCRTextLine], fullText: String) {
        self.lines = lines
        self.fullText = fullText
    }
}
