import MacClippyCore
import SwiftUI

extension MacClippyDockView {
    var selectionHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.selectionCount) selected").font(.body.weight(.semibold))
                Text(model.isSelectingAllMatches ? "Selecting all matches…" : "In displayed order")
                    .font(.caption).foregroundStyle(MacClippyDockTheme.mutedColor)
            }
            .frame(minWidth: 120, alignment: .leading)
            if model.isSelectingAllMatches { ProgressView().controlSize(.small) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    SelectionBarButton("Merge & Paste", systemImage: "arrow.down.doc", emphasis: .primary) {
                        model.pasteSelectedAll(completion: onClose)
                    }
                    .disabled(!model.canMergeSelection)
                    .help(mergeHelp)
                    SelectionBarButton("Merge & Copy", systemImage: "doc.on.doc") { model.copySelectedAll() }
                        .disabled(!model.canMergeSelection)
                        .help(mergeHelp)
                    if !model.pinboards.isEmpty {
                        SelectionBarButton("Pin to…", systemImage: "pin") { model.requestPinSelection() }
                            .disabled(!model.selectionIsReady)
                    }
                    Menu {
                        Button("Paste selected items sequentially") { model.pasteQueued(completion: onClose) }
                            .help(
                                "Paste each item in displayed order into the current target. "
                                + "Does not move between form fields."
                            )
                        if case .pinboard = model.selectedTab {
                            Button("Remove from this Pinboard") { model.unpinSelected() }
                        }
                        Divider()
                        Button("Delete from history…", role: .destructive) { model.requestDeleteSelected() }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(!model.selectionIsReady)
                }
                .padding(.vertical, 4)
            }
            Spacer(minLength: 0)
            Button("Cancel selection") { model.clearSelection() }
                .buttonStyle(.plain)
                .help("Cancel selection · Esc")
        }
        .padding(.horizontal, 6)
        .foregroundStyle(MacClippyDockTheme.textColor)
    }

    private var mergeHelp: String {
        model.canMergeSelection
            ? "Combine selected text in displayed order" : "Only text-compatible items can be merged"
    }
}

struct MacClippyDeleteItemsConfirmation: View {
    let count: Int
    let includesPinned: Bool
    let onDelete: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Delete \(count) item\(count == 1 ? "" : "s") permanently?").font(.headline)
            Text(
                includesPinned
                    ? "These items will also be removed from their Pinboards. This cannot be undone."
                    : "The selected items will be removed from clipboard history. This cannot be undone."
            )
            .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Delete permanently", role: .destructive, action: onDelete)
            }
        }
        .padding(24).frame(width: 410)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct MacClippyPinboardPicker: View {
    let boards: [MacClippyPinboardEntry]
    let onChoose: (RecordID) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Pin to…").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(boards) { board in
                        Button {
                            onChoose(board.id)
                        } label: {
                            Label(board.name, systemImage: "pin").frame(
                                maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }.frame(maxHeight: 220)
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
        }
        .padding(24).frame(width: 350)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
    }
}
