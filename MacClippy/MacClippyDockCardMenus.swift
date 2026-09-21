import AppKit
import SwiftUI

import MacClippyCore

extension MacClippyDockView {
    @ViewBuilder
    func snippetContextMenu(_ snippet: MacClippySnippetEntry) -> some View {
        Button("Copy") {
            model.focus(snippet)
            model.copyFocused()
        }
        Button("Paste") {
            model.focus(snippet)
            model.pasteFocused(completion: onClose)
        }
        Divider()
        Button("Delete", role: .destructive) {
            model.focus(snippet)
            model.deleteFocused()
        }
    }

    @ViewBuilder
    func pinboardContextMenu(_ pinboard: MacClippyPinboardEntry) -> some View {
        Button("Rename…") {
            model.presentRenameCategory(for: pinboard)
        }
        Menu("Change Color") {
            ForEach(MacClippyCategoryColorPolicy.palette, id: \.self) { color in
                Button {
                    model.setPinboardColor(pinboard, to: color)
                } label: {
                    Label {
                        Text(MacClippyCategoryColorPolicy.displayName(for: color))
                    } icon: {
                        Image(nsImage: MacClippyCategoryColorSwatch.image(for: color))
                    }
                }
                .accessibilityLabel("Change color to \(MacClippyCategoryColorPolicy.name(for: color))")
            }
        }
        Divider()
        Button("Delete", role: .destructive) {
            model.presentConfirmDeleteCategory(for: pinboard)
        }
    }

    @ViewBuilder
    func itemContextMenu(_ item: MacClippyHistoryEntry) -> some View {
        Button("Copy") {
            model.focus(item)
            model.copyFocused()
        }
        if item.supportsPlainCopy {
            Button("Copy plain") {
                model.focus(item)
                model.copyFocused(plain: true)
            }
            itemTransformMenu(item)
        }
        Button("Paste") {
            model.focus(item)
            model.pasteFocused(completion: onClose)
        }
        Button("Rename…") {
            model.focus(item)
            model.presentRenameItem(for: item)
        }
        let pinnedBoards = model.pinboards.filter { model.isPinned(item.id, in: $0) }
        if case let .pinboard(boardID) = model.selectedTab,
           let currentBoard = model.pinboards.first(where: { $0.id == boardID }) {
            Button("Remove from \(currentBoard.name)") {
                model.focus(item)
                model.unpin(item.id, from: currentBoard.id)
            }
        } else if !pinnedBoards.isEmpty {
            Menu("Remove from list") {
                ForEach(pinnedBoards) { board in
                    Button(board.name) {
                        model.focus(item)
                        model.unpin(item.id, from: board.id)
                    }
                }
            }
        }
        if !model.pinboards.isEmpty {
            itemPinboardMenu(item)
        }
        Divider()
        Button("Delete", role: .destructive) {
            model.focus(item)
            model.deleteFocused()
        }
    }

    @ViewBuilder
    private func itemTransformMenu(_ item: MacClippyHistoryEntry) -> some View {
        Menu("Transform") {
            ForEach(TextTransform.allCases, id: \.self) { transform in
                Menu(transform.displayName) {
                    Button("Copy transformed") {
                        model.focus(item)
                        model.copyFocused(transform: transform)
                    }
                    Button("Paste transformed") {
                        model.focus(item)
                        model.pasteFocused(transform: transform, completion: onClose)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func itemPinboardMenu(_ item: MacClippyHistoryEntry) -> some View {
        Menu("Pin to list") {
            ForEach(model.pinboards) { pinboard in
                let isPinned = model.isPinned(item.id, in: pinboard)
                Button {
                    model.focus(item)
                    if isPinned {
                        model.unpin(item.id, from: pinboard.id)
                    } else {
                        model.pin(recordID: item.id, to: pinboard)
                    }
                } label: {
                    Label(
                        pinboard.name,
                        systemImage: isPinned ? "checkmark" : "pin"
                    )
                }
            }
        }
    }
}

enum MacClippyCategoryColorSwatch {
    static func image(for hex: String, diameter: CGFloat = 14) -> NSImage {
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            let inset = rect.insetBy(dx: 0.5, dy: 0.5)
            NSColor(Color(macClippyHex: hex)).setFill()
            NSBezierPath(ovalIn: inset).fill()
            NSColor.black.withAlphaComponent(0.18).setStroke()
            let stroke = NSBezierPath(ovalIn: inset)
            stroke.lineWidth = 1
            stroke.stroke()
            return true
        }
        image.isTemplate = false
        return image
    }
}
