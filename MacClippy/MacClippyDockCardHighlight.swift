import SwiftUI

import MacClippyCore

@MainActor
enum MacClippyDockCardHighlight {
    static func text(_ text: String, font: Font, color: Color, terms: [String]) -> Text {
        let ranges = MacClippySearchQuery.highlightedRanges(in: text, queryTerms: terms)
            .sorted { $0.lowerBound < $1.lowerBound }
        guard !ranges.isEmpty else {
            return Text(text).font(font).foregroundStyle(color)
        }
        var pieces: [Text] = []
        var current = text.startIndex
        for range in ranges {
            if current < range.lowerBound {
                pieces.append(
                    Text(String(text[current..<range.lowerBound]))
                        .font(font)
                        .foregroundStyle(color)
                )
            }
            pieces.append(
                Text(String(text[range]))
                    .font(font.weight(.semibold))
                    .foregroundStyle(MacClippyDockTheme.accentColor)
            )
            current = range.upperBound
        }
        if current < text.endIndex {
            pieces.append(
                Text(String(text[current...]))
                    .font(font)
                    .foregroundStyle(color)
            )
        }
        return pieces.reduce(Text("")) { partial, piece in
            partial + piece
        }
    }
}

extension MacClippyDockView {
    func highlightedText(_ text: String, font: Font, color: Color, terms: [String]? = nil) -> Text {
        MacClippyDockCardHighlight.text(
            text,
            font: font,
            color: color,
            terms: terms ?? model.highlightTerms,
        )
    }
}
