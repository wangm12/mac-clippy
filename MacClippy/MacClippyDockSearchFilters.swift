import MacClippyCore
import SwiftUI

struct MacClippyDockSearchFilters: View {
    @ObservedObject var model: MacClippyDockModel
    @State private var source = ""
    @State private var before = ""
    @State private var after = ""
    @State private var validationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Filters").font(.headline)
            HStack(spacing: 6) {
                typeButton("All", clause: nil)
                typeButton("Text", clause: .type(.text))
                typeButton("Images", clause: .type(.image))
                typeButton("Links", clause: .url)
                typeButton("Files", clause: .type(.files))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Source app").font(.subheadline.weight(.semibold))
                HStack {
                    TextField("App name or bundle ID", text: $source)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(applyFields)
                    Menu {
                        ForEach(sourceSuggestions, id: \.self) { value in
                            Button(value) {
                                source = value
                                applyFields()
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 22)
                    .accessibilityLabel("Choose source app")
                }
            }
            HStack(spacing: 12) {
                dateField("On or after", value: $after)
                dateField("Before", value: $before)
            }
            Text("Dates use YYYY-MM-DD. Leave a field empty to remove its filter.")
                .font(.caption).foregroundStyle(.secondary)
            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red)
                    .accessibilityLabel(validationError)
            }
            HStack {
                Button("Clear filters") {
                    model.query = MacClippySearchWorkflowPolicy.clearingFilters(in: model.query)
                    model.searchQueryProgrammaticWriteToken += 1
                    syncFields()
                }
                Spacer()
                Button("Apply", action: applyFields)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            if !model.searchFilterChips.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.searchFilterChips) { chip in
                        HStack {
                            Text(chip.title).font(.caption)
                            Spacer()
                            Button {
                                model.removeSearchFilter(token: chip.token)
                                model.searchQueryProgrammaticWriteToken += 1
                                syncFields()
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(chip.title) filter")
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 370)
        .onAppear(perform: syncFields)
    }

    private var sourceSuggestions: [String] {
        Array(Set(model.historyItems.compactMap(\.meta.sourceAppDisplayName))).sorted()
    }

    private func dateField(_ label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline.weight(.semibold))
            TextField("YYYY-MM-DD", text: value).textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
                .onSubmit(applyFields)
        }
    }

    private func typeButton(_ title: String, clause: MacClippySearchGrammar.Clause?) -> some View {
        let clauses = MacClippySearchGrammar.parse(model.query).clauses
        let selected =
            clause.map { clauses.contains($0) } ?? !clauses.contains {
                if case .type = $0 { return true }
                return $0 == .url
            }
        return Button(title) {
            model.query = MacClippySearchWorkflowPolicy.replacing(.contentType, with: clause, in: model.query)
            model.searchQueryProgrammaticWriteToken += 1
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : .secondary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func applyFields() {
        let beforeValue = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let afterValue = after.trimmingCharacters(in: .whitespacesAndNewlines)
        let beforeClause: MacClippySearchGrammar.Clause?
        let afterClause: MacClippySearchGrammar.Clause?
        do {
            beforeClause = try MacClippySearchWorkflowPolicy.dateClause(beforeValue, for: .before)
            afterClause = try MacClippySearchWorkflowPolicy.dateClause(afterValue, for: .after)
        } catch {
            validationError = "Enter a valid date as YYYY-MM-DD."
            return
        }
        if case .before(let end)? = beforeClause, case .after(let start)? = afterClause, start >= end {
            validationError = "The start date must be earlier than the end date."
            return
        }
        let app = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var query = MacClippySearchWorkflowPolicy.replacing(
            .source, with: app.isEmpty ? nil : .app(app), in: model.query)
        query = MacClippySearchWorkflowPolicy.replacing(.before, with: beforeClause, in: query)
        query = MacClippySearchWorkflowPolicy.replacing(.after, with: afterClause, in: query)
        model.query = query
        model.searchQueryProgrammaticWriteToken += 1
        validationError = nil
    }

    private func syncFields() {
        source = ""
        before = ""
        after = ""
        validationError = nil
        for chip in model.searchFilterChips {
            switch MacClippySearchGrammar.parse(chip.token).clauses.first {
            case .app(let value): source = value
            case .before: before = String(chip.token.dropFirst(7))
            case .after: after = String(chip.token.dropFirst(6))
            default: break
            }
        }
    }
}
