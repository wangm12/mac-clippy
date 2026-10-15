import Foundation

import MacClippyCore
import MacClippyPlatform

extension MacClippyRuntime {
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
            representations: [MacClippyClipboardRepresentation],
            now: Date = Date()
        ) throws -> ClipboardItemMeta {
            try withStoreLock {
                try clipboardStore.append(record, representations: representations, now: now)
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

        func setBeforeCaptureTransactionForTest(_ hook: (@Sendable () -> Void)?) {
            beforeCaptureTransactionForTesting = hook
        }

        func drainCaptureQueueForTest() {
            drainCaptureQueueForShutdown()
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

}
