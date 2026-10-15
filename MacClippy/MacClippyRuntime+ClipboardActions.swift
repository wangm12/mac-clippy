import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers
import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    func paste(
        id: RecordID,
        plain: Bool = false,
        targetProcessIdentifier: Int32? = nil,
        sideEffectGate: MacClippyPasteInjectionGate? = nil
    ) throws -> PasteInjectionResult {
        try measureDiagnosticMetric("paste") {
            let content = try withStoreLock {
                let snapshot = try clipboardStore.playbackSnapshot(for: id)
                return try pasteboardContent(for: snapshot, plain: plain)
            }
            return injectPasteboardContent(
                content,
                frequencyIDs: [id],
                targetProcessIdentifier: targetProcessIdentifier,
                sideEffectGate: sideEffectGate
            )
        }
    }

    @discardableResult
    func paste(
        snippetID: RecordID,
        manualFallback: MacClippyPasteManualFallbackPolicy = .preserveClipboard,
        targetProcessIdentifier: Int32? = nil,
        sideEffectGate: MacClippyPasteInjectionGate? = nil
    ) throws -> PasteInjectionResult {
        try measureDiagnosticMetric("paste_snippet") {
            let body = try withStoreLock { try snippetStore.fetch(id: snippetID).body }
            return pasteInjector.inject(
                text: expandedSnippetBody(body),
                manualFallback: manualFallback,
                gate: sideEffectGate,
                targetProcessIdentifier: targetProcessIdentifier
            )
        }
    }

    func copy(id: RecordID) throws {
        try copy(id: id, plain: false)
    }

    func copy(
        id: RecordID,
        plain: Bool,
        sideEffectGate: MacClippyPasteInjectionGate? = nil
    ) throws {
        let content = try withStoreLock {
            let snapshot = try clipboardStore.playbackSnapshot(for: id)
            return try pasteboardContent(for: snapshot, plain: plain)
        }
        try pasteInjector.prepare(content, gate: sideEffectGate)
    }

    func copy(
        snippetID: RecordID,
        sideEffectGate: MacClippyPasteInjectionGate? = nil
    ) throws {
        let body = try withStoreLock { try snippetStore.fetch(id: snippetID).body }
        try pasteInjector.prepareText(expandedSnippetBody(body), gate: sideEffectGate)
    }

    private func expandedSnippetBody(_ body: String) -> String {
        MacClippySnippetVariablePolicy.expand(
            body,
            context: MacClippySnippetVariableContext(clipboard: pasteInjector.currentPlainText())
        )
    }

    /// Transformed copy/paste: read the record body under the existing store
    /// lock, derive plain text via the existing MacClippyClipboardText path
    /// (html/rtf are converted to plain text because the transform engine
    /// operates on text), apply the given MacClippyTextTransform, then prepare
    /// or inject the result as plain text (.text). Image and files records are
    /// rejected explicitly with invalidStoredRecord so they are never silently
    /// transformed or dropped; a malformed/undecodable rtf payload (no plain
    /// text) is rejected the same way. Transformed copy only prepares the
    /// pasteboard and never posts Cmd+V, matching copy(id:plain:). Transformed
    /// paste injects Cmd+V and bumps frequency only when injection succeeds,
    /// matching paste(id:). Neither path mutates the stored record or the
    /// search index; the transform is a one-shot pasteboard operation.
    func copy(
        id: RecordID,
        transform: TextTransform,
        sideEffectGate: MacClippyPasteInjectionGate? = nil
    ) throws {
        let text = try withStoreLock { try transformedPlainText(for: id, transform: transform) }
        try pasteInjector.prepare(.text(text), gate: sideEffectGate)
    }

    @discardableResult
    func paste(
        id: RecordID,
        transform: TextTransform,
        targetProcessIdentifier: Int32? = nil,
        sideEffectGate: MacClippyPasteInjectionGate? = nil
    ) throws -> PasteInjectionResult {
        try measureDiagnosticMetric("paste_transform") {
            let text = try withStoreLock { try transformedPlainText(for: id, transform: transform) }
            return injectPasteboardContent(
                .text(text),
                frequencyIDs: [id],
                targetProcessIdentifier: targetProcessIdentifier,
                sideEffectGate: sideEffectGate
            )
        }
    }

    /// Shared plain-text derivation + transform for copy/paste. Reads the body
    /// under the caller's store lock, rejects non-text kinds and undecodable
    /// rtf/html explicitly, and applies the transform. A nil plain-text
    /// derivation for an otherwise text-bearing record is treated as an error
    /// so an empty or raw-markup transform result is never silently produced
    /// from a missing payload.
    private func transformedPlainText(for id: RecordID, transform: TextTransform) throws -> String {
        let body = try clipboardStore.body(for: id)
        switch body {
        case let .text(value):
            return transform.apply(to: value)
        case .html:
            guard let plain = MacClippyClipboardText.plainText(from: body) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return transform.apply(to: plain)
        case let .rtf(data):
            let rtfRecord = ClipboardRecord.rtf(data)
            guard let plain = MacClippyClipboardText.plainText(from: rtfRecord) else {
                throw MacClippyStoreError.invalidStoredRecord
            }
            return transform.apply(to: plain)
        case .image, .encryptedImage, .files:
            // Images and files are not text and must not be silently
            // transformed or dropped; report an explicit error so the dock can
            // surface it instead of showing a misleading success.
            throw MacClippyStoreError.invalidStoredRecord
        }
    }

    @discardableResult
    func togglePin(id: RecordID, preferredPinboardID: RecordID? = nil) throws -> Bool {
        try withStoreLock {
            let boards = try pinboardStore.list()
            if let preferredPinboardID,
               let preferred = boards.first(where: { $0.id == preferredPinboardID }) {
                if preferred.itemIDs.contains(id) {
                    try pinboardStore.removeItem(id, from: preferred.id)
                } else {
                    try pinboardStore.addItem(id, to: preferred.id)
                }
                return true
            }

            if let containing = boards.first(where: { $0.itemIDs.contains(id) }) {
                try pinboardStore.removeItem(id, from: containing.id)
                return true
            }
            guard let defaultBoard = boards.first else { return false }
            try pinboardStore.addItem(id, to: defaultBoard.id)
            return true
        }
    }

    func delete(id: RecordID) throws {
        try clipboardStore.authenticateOwnedBlobReferenceIndex()
        try withStoreLock {
            var journalStarted = false
            do {
                // Read the pinboard projection strictly before creating the
                // deletion journal. A damaged board must fail closed; otherwise
                // the record could be deleted while its stale pin reference is
                // skipped and the journal is incorrectly completed.
                let boards = try pinboardStore.listStrict()
                guard let journal = try clipboardStore.beginDeletion(ids: [id]) else {
                    throw MacClippyStoreError.recordNotFound
                }
                journalStarted = true
                try searchStore.remove(kind: .clipboardItem, id: id)
                try clipboardStore.delete(id: id)

                for board in boards where board.itemIDs.contains(id) {
                    try pinboardStore.removeItem(id, from: board.id)
                }

                // Reclaim both primary image blobs and oversized representation
                // blobs as soon as the parent record is gone. Shared blobs remain
                // protected by the reference check.
                let unreferenced = try clipboardStore.unreferencedBlobIDs(journal.blobIDs)
                for blobID in unreferenced {
                    try blobStore.delete(id: blobID)
                }
                try clipboardStore.completeDeletion(operationID: journal.operationID)
                thumbnailDiskCache.remove(id: id)
            } catch {
                // A durable journal is intentionally retained when any
                // secondary cleanup step fails. Retry it immediately once so
                // transient failures are repaired during this session; the
                // journal remains available for the next maintenance pass if
                // the retry also fails.
                guard journalStarted else { throw error }
                storageDegradedReasons.insert("deletion-recovery-pending")
                do {
                    try replayPendingDeletionsLocked()
                    storageDegradedReasons.remove("deletion-recovery-pending")
                } catch {
                    MacClippyLog.record(
                        category: .storage,
                        code: .recoveryFailed,
                        operation: "delete_recovery_retry",
                        recoveryAction: "run_storage_reconciliation",
                        impact: "deletion_cleanup_pending"
                    )
                }
                throw error
            }
        }
    }

    func delete(snippetID: RecordID) throws {
        try withStoreLock {
            let deletedSnippet = try snippetStore.fetch(id: snippetID)
            try snippetStore.delete(id: snippetID)
            do {
                try snippetLookupSnapshot.replace(with: snippetStore.list())
            } catch {
                // The delete already committed. Remove the deleted trigger
                // from the in-memory snapshot before surfacing the refresh
                // error, so a stale event tap can never expand deleted text.
                snippetLookupSnapshot.remove(trigger: deletedSnippet.trigger)
                throw error
            }
        }
    }

}
