import AppKit
import CoreGraphics
import Foundation
import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
    func paste(
        id: RecordID,
        plain: Bool = false,
        sideEffectGate: MacClippyPasteInjectionGate? = nil
    ) throws -> PasteInjectionResult {
        try measureDiagnosticMetric("paste") {
            let content = try withStoreLock {
                let body = try clipboardStore.body(for: id)
                return try pasteboardContent(for: body, plain: plain)
            }
            return injectPasteboardContent(
                content,
                frequencyIDs: [id],
                sideEffectGate: sideEffectGate
            )
        }
    }

    @discardableResult
    func paste(
        snippetID: RecordID,
        sideEffectGate: MacClippyPasteInjectionGate? = nil
    ) throws -> PasteInjectionResult {
        try measureDiagnosticMetric("paste_snippet") {
            let body = try withStoreLock { try snippetStore.fetch(id: snippetID).body }
            return pasteInjector.inject(text: expandedSnippetBody(body), gate: sideEffectGate)
        }
    }

    func copy(id: RecordID) throws {
        try copy(id: id, plain: false)
    }

    func dragPayload(
        id: RecordID,
        representation: MacClippyCardDragRepresentation
    ) throws -> MacClippyCardDragPayload {
        if representation == .recordID {
            return MacClippyCardDragPayload(
                typeIdentifier: MacClippyCardDragPolicy.recordTypeIdentifier,
                data: Data(id.rawValue.utf8)
            )
        }
        let content = try withStoreLock {
            let body = try clipboardStore.body(for: id)
            return try pasteboardContent(for: body, plain: false)
        }
        guard let payload = MacClippyCardDragExportPolicy.payload(
            for: representation,
            recordID: id,
            content: content
        ) else {
            throw MacClippyStoreError.invalidStoredRecord
        }
        return payload
    }

    func copy(
        id: RecordID,
        plain: Bool,
        sideEffectGate: MacClippyPasteInjectionGate? = nil
    ) throws {
        let content = try withStoreLock {
            let body = try clipboardStore.body(for: id)
            return try pasteboardContent(for: body, plain: plain)
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
        sideEffectGate: MacClippyPasteInjectionGate? = nil
    ) throws -> PasteInjectionResult {
        try measureDiagnosticMetric("paste_transform") {
            let text = try withStoreLock { try transformedPlainText(for: id, transform: transform) }
            return injectPasteboardContent(
                .text(text),
                frequencyIDs: [id],
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

    // Test-only direct append. The production capture path runs through the
    // observer and the capture mapper; tests of the batch store operations
    // (delete/pin/multi-paste) need records in the store without driving the
    // real pasteboard, so this internal helper writes a record directly. It is
    // intentionally internal (not public) so it is visible to the app test
    // target via @testable import but never part of the shipped API.
    //
    // Wrapped in #if DEBUG so Release builds contain no test helper and no
    // hard-coded fixture PNG. App tests run in the Debug configuration, so
    // @testable import continues to see this member during test builds.
    #if DEBUG
        @discardableResult
        func appendTestRecord(_ record: ClipboardRecord) throws -> ClipboardItemMeta {
            try withStoreLock {
                switch record {
                case let .text(value):
                    return try clipboardStore.append(.text(value))
                case let .html(value):
                    return try clipboardStore.append(.html(value))
                case let .rtf(data):
                    return try clipboardStore.append(.rtf(data))
                case let .image(_, width, height):
                    // Write a 1x1 PNG blob so the image record has a real blob id
                    // that BlobStore.read can resolve during multi-paste classify.
                    let png = Data([
                        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
                        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
                        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
                        0x42, 0x60, 0x82
                    ])
                    let blobID = try blobStore.write(png)
                    return try clipboardStore.append(.image(blobID: blobID, width: width, height: height))
                case let .encryptedImage(_, width, height):
                    let png = Data([
                        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
                        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
                        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
                        0x42, 0x60, 0x82
                    ])
                    let blobID = try blobStore.write(png)
                    return try clipboardStore.append(.image(blobID: blobID, width: width, height: height))
                case let .files(urls):
                    return try clipboardStore.append(.files(urls))
                }
            }
        }

        // P2b test-only append overload that accepts a sourceAppBundleID and an
        // explicit `now` so structured-search integration tests can exercise the
        // app: and before:/after: clauses without driving the real pasteboard.
        // Reuses clipboardStore.append's existing parameters; no production
        // capture behavior is duplicated. Same DEBUG/internal visibility as
        // appendTestRecord above so Release builds compile it out.
        @discardableResult
        func appendTestRecord(
            _ record: ClipboardRecord,
            sourceAppBundleID: String?,
            now: Date = Date()
        ) throws -> ClipboardItemMeta {
            try withStoreLock {
                let sourceAppDisplayName = MacClippySourceAppResolver.displayName(for: sourceAppBundleID)
                switch record {
                case let .text(value):
                    return try clipboardStore.append(
                        .text(value),
                        sourceAppBundleID: sourceAppBundleID,
                        sourceAppDisplayName: sourceAppDisplayName,
                        now: now
                    )
                case let .html(value):
                    return try clipboardStore.append(
                        .html(value),
                        sourceAppBundleID: sourceAppBundleID,
                        sourceAppDisplayName: sourceAppDisplayName,
                        now: now
                    )
                case let .rtf(data):
                    return try clipboardStore.append(
                        .rtf(data),
                        sourceAppBundleID: sourceAppBundleID,
                        sourceAppDisplayName: sourceAppDisplayName,
                        now: now
                    )
                case let .image(_, width, height), let .encryptedImage(_, width, height):
                    // Write a 1x1 PNG blob so the image record has a real blob id
                    // that BlobStore.read can resolve during preview/multi-paste.
                    let png = Data([
                        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
                        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
                        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x62, 0x00, 0x01, 0x00, 0x00,
                        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
                        0x42, 0x60, 0x82
                    ])
                    let blobID = try blobStore.write(png)
                    return try clipboardStore.append(
                        .image(blobID: blobID, width: width, height: height),
                        sourceAppBundleID: sourceAppBundleID,
                        sourceAppDisplayName: sourceAppDisplayName,
                        now: now
                    )
                case let .files(urls):
                    return try clipboardStore.append(
                        .files(urls),
                        sourceAppBundleID: sourceAppBundleID,
                        sourceAppDisplayName: sourceAppDisplayName,
                        now: now
                    )
                }
            }
        }

        @discardableResult
        func appendTestRecord(
            _ record: ClipboardRecord,
            representations: [MacClippyClipboardRepresentation]
        ) throws -> ClipboardItemMeta {
            try withStoreLock {
                try clipboardStore.append(record, representations: representations)
            }
        }

        @discardableResult
        func insertRemoteClipboardSample() throws -> ClipboardItemMeta {
            let body = MacClippyClipboardCardPreviewFactory.sampleText
            let meta = try appendTestRecord(
                .text(body),
                representations: [
                    MacClippyClipboardRepresentation(
                        uti: "public.utf8-plain-text",
                        payloadBytes: Data(body.utf8)
                    ),
                    MacClippyClipboardRepresentation(
                        uti: CaptureExclusionRules.remoteClipboardPasteboardType,
                        payloadBytes: Data()
                    )
                ]
            )
            return try setCustomLabel(id: meta.id, label: "Remote test")
        }
    #endif

    // P2a test-only OCR seeding. The production OCR path runs through
    // scheduleOCR -> MacClippyOCRService and writes OCR text via
    // clipboardStore.setOCRText; tests of setCustomLabel's index rebuild need
    // an image record with OCR text present without driving the real Vision
    // recognizer. This internal helper writes OCR text directly to the store
    // under the existing storeLock, reusing the private clipboardStore.setOCRText
    // so no production OCR behavior is duplicated or changed. Intentionally
    // internal (not public) and #if DEBUG so Release builds contain no test
    // helper; @testable import sees it during Debug app test builds, matching
    // appendTestRecord above.
    #if DEBUG
        func setOCRTextForTest(id: RecordID, text: String) throws {
            try withStoreLock {
                try clipboardStore.setOCRText(id: id, text: text)
            }
        }

        /// Test-only lifecycle hooks exercise the same bounded OCR queue used
        /// by capture without requiring a real NSPasteboard or Vision request.
        /// The helper is intentionally unavailable to Release builds.
        func scheduleOCRForTest(data: Data, recordID: RecordID) {
            captureQueue.sync {
                guard let lifecycleToken = activeLifecycleToken() else { return }
                scheduleOCR(
                    for: data,
                    recordID: recordID,
                    lifecycleToken: lifecycleToken,
                    forceStart: true
                )
            }
        }

        func setOCRScheduleConditionsForTest(
            secondsSinceLastInput: TimeInterval,
            isLowPowerMode: Bool
        ) {
            ocrScheduleConditionsProvider = {
                (secondsSinceLastInput, isLowPowerMode)
            }
        }

        func enqueueScheduledOCRForTest(data: Data, recordID: RecordID) {
            captureQueue.sync {
                scheduleOCR(for: data, recordID: recordID)
            }
        }

        func flushDeferredOCRForTest() {
            captureQueue.sync {
                startDeferredOCRIfReady()
            }
        }

        func pendingOCRJobsForTest() -> Int {
            captureQueue.sync { pendingOCRJobs }
        }

        func pendingOCRBytesForTest() -> Int {
            captureQueue.sync { pendingOCRBytes }
        }

        func failNextOCRSearchUpsertForTest() {
            withStoreLock {
                failNextOCRSearchUpsertForTesting = true
            }
        }
    #endif

    #if DEBUG
        /// Test-only fault marker used to verify that an ordinary successful FTS
        /// write cannot clear a degraded state. Only an explicit full repair may
        /// clear `fts-repair-needed`.
        func markSearchIndexNeedsRepairForTest() throws {
            try withStoreLock {
                storageDegradedReasons.insert("fts-repair-needed")
                try searchStore.markRepairNeeded()
            }
        }

        /// Test-only crash simulation for the deletion recovery path. The parent
        /// record is removed after the durable journal is written, while FTS,
        /// pinboards, and BlobStore are intentionally left untouched so the test
        /// can exercise the same idempotent replay used at startup.
        func simulateInterruptedDeletionForTest(id: RecordID) throws {
            try withStoreLock {
                guard let journal = try clipboardStore.beginDeletion(ids: [id]) else {
                    throw MacClippyStoreError.recordNotFound
                }
                try clipboardStore.delete(id: id)
                _ = journal
            }
        }

        func replayPendingDeletionsForTest() throws {
            try withStoreLock {
                try replayPendingDeletionsLocked()
            }
        }

        func pendingDeletionCountForTest() throws -> Int {
            try withStoreLock {
                try clipboardStore.pendingDeletionCount()
            }
        }

        func indexedClipboardIDsForTest() throws -> [RecordID] {
            try withStoreLock {
                try searchStore.indexedRecordIDs(kind: .clipboardItem)
            }
        }
    #endif

    /// P1 batch delete: delete every supplied clipboard record, remove it from
}
