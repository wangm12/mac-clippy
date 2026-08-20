import SwiftUI

import MacClippyCore

extension MacClippyDockView {
    func highlightedText(_ text: String, font: Font, color: Color) -> Text {
        let terms = MacClippySearchGrammar.parse(model.query).bareTerms
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
