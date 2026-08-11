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
                        Text(color)
                    } icon: {
                        Circle()
                            .fill(Color(macClippyHex: color))
                            .frame(width: 12, height: 12)
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
                Button {
                    model.focus(item)
                    model.togglePinFocused(in: pinboard.id)
                } label: {
                    Label(
                        pinboard.name,
                        systemImage: model.isPinned(item.id, in: pinboard) ? "checkmark" : "pin"
                    )
                }
            }
        }
    }
}
