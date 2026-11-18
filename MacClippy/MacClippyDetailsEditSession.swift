import Combine
import Foundation
import MacClippyCore

enum MacClippyDetailsSaveIntent: Equatable, Sendable {
    case save, saveAndPaste
}

@MainActor
final class MacClippyDetailsEditSession: ObservableObject {
    let recordID: RecordID
    @Published var contentDraft: String
    @Published var nameDraft: String
    @Published var isSaving = false
    @Published var errorMessage: String?
    private var originalContent: String
    private var originalName: String

    init(details: MacClippyItemDetails) {
        recordID = details.id
        originalContent = details.textContent ?? ""
        originalName = details.customLabel ?? ""
        contentDraft = originalContent
        nameDraft = originalName
    }

    func isDirty(editing: MacClippyDetailsEditing) -> Bool {
        switch editing {
        case .none: false
        case .content: contentDraft != originalContent
        case .name: nameDraft != originalName
        }
    }

    func resetDrafts() {
        contentDraft = originalContent
        nameDraft = originalName
        errorMessage = nil
    }

    func markSaved() {
        originalContent = contentDraft
        originalName = nameDraft
        errorMessage = nil
    }
}
