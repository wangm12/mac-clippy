import Foundation
import MacClippyCore

extension MacClippyRuntime {
    func updateSnippet(
        id: RecordID, name: String, trigger: String?, body: String, folder: String?
    ) throws -> MacClippySnippetEntry {
        try withStoreLock {
            let input = try validatedSnippetInput(name: name, trigger: trigger, body: body, excluding: id)
            var snippet = try snippetStore.fetch(id: id)
            snippet.name = input.name
            snippet.trigger = input.trigger
            snippet.body = body
            snippet.folder = MacClippySnippetFolderPolicy.normalized(folder)
            snippet.modified = Date()
            // Complete every throwing read before committing. Once the store
            // update succeeds, publishing the prepared lookup cannot fail.
            let currentSnippets: [Snippet]
            #if DEBUG
            currentSnippets = try snippetUpdateListForTesting?() ?? snippetStore.list()
            #else
            currentSnippets = try snippetStore.list()
            #endif
            let nextSnippets = currentSnippets.filter { $0.id != id } + [snippet]
            try snippetStore.update(snippet)
            snippetLookupSnapshot.replace(with: nextSnippets)
            return MacClippySnippetEntry(snippet: snippet)
        }
    }

    func validatedSnippetInput(
        name: String, trigger: String?, body: String, excluding id: RecordID? = nil
    ) throws -> (name: String, trigger: String?) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw MacClippySnippetCreationError.invalidName }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacClippySnippetCreationError.emptyBody
        }
        let trigger = normalizedSnippetTrigger(trigger)
        if let trigger, let existing = try snippetStore.find(trigger: trigger), existing.id != id {
            throw MacClippySnippetCreationError.duplicateTrigger
        }
        return (name, trigger)
    }
}
