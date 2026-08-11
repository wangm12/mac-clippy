import AppKit
import CoreGraphics
import Foundation
import MacClippyCore
import MacClippyPlatform

private enum MacClippyQueuedPastePreparation {
    case content(MacClippyPasteboardContent)
    case unavailable(MacClippyDockMultiPastePolicy.Kind)
}

private enum MacClippyQueuedPasteAttempt {
    case injected
    case unavailable(MacClippyDockMultiPastePolicy.Kind)
    case manualPasteRequired
}

extension MacClippyRuntime {
    /// Mixed-content sequential queue paste. Processes the ordered selected IDs
    /// one at a time in visual order, injecting a separate Cmd+V per record so
    /// mixed selections (text + image + files) can each be consumed by the
    /// target app. This is NOT the homogeneous-only pasteOrdered path: every
    /// stored content kind the single paste(id:) path supports (text, html, rtf,
    /// image, files) is pasted in turn using the same pasteboardContent(for:)
    /// seam.
    ///
    /// Per record:
    ///   - Read the body under the store lock and prepare its
    ///     MacClippyPasteboardContent. A missing record, a malformed/undecodable
    ///     payload (e.g. malformed RTF), or any body-read failure is reported
    ///     explicitly with its ID and known content kind (or .unsupported when
    ///     the body cannot be read at all) in the unavailable lists, and the
    ///     queue CONTINUES with the remaining IDs — nothing is silently skipped.
    ///   - Inject one Cmd+V through the shared MacClippyPasteInjector. Bump that
    ///     record's frequency only after .injected.
    ///   - If the injector returns .manualPasteRequired, STOP immediately: the
    ///     current pasteboard item has not been consumed automatically. Return
    ///     the current ID plus all remaining IDs in remainingIDs; do not claim
    ///     them injected and do not continue posting events.
    ///   - After a successful injection, wait MacClippyQueuePastePolicy.
    ///    settleInterval off the main thread so the target app can consume the
    ///     paste before the next record overwrites the pasteboard. The store
    ///     lock is NOT held while sleeping.
    ///
    /// Ordering is deterministic: injectedIDs, unavailableIDs/unavailableKinds,
    /// and remainingIDs all follow the supplied visual order. This is a one-shot
    /// ordered execution; no queue database or speculative persistence is added.
    @discardableResult
    func pasteQueued(
        ids: [RecordID],
        shouldCancel: () -> Bool = { false },
        sideEffectGate: MacClippyPasteInjectionGate? = nil
    ) throws -> MacClippyQueuePasteResult {
        try measureDiagnosticMetric("paste_queue") {
            guard !shouldCancel() else {
                return completedQueuedPasteResult(
                    injectedIDs: [], unavailableIDs: [], unavailableKinds: []
                )
            }

            let knownKinds = try withStoreLock {
                try clipboardStore.contentKinds(for: ids)
            }
            return try pasteQueuedRecords(
                ids: ids,
                knownKinds: knownKinds,
                shouldCancel: shouldCancel,
                sideEffectGate: sideEffectGate
            )
        }
    }

    private func pasteQueuedRecords(
        ids: [RecordID],
        knownKinds: [RecordID: MacClippyContentKind],
        shouldCancel: () -> Bool,
        sideEffectGate: MacClippyPasteInjectionGate?
    ) throws -> MacClippyQueuePasteResult {
        var injectedIDs: [RecordID] = []
        var unavailableIDs: [RecordID] = []
        var unavailableKinds: [MacClippyDockMultiPastePolicy.Kind] = []

        for (index, id) in ids.enumerated() {
            guard !shouldCancel() else {
                return completedQueuedPasteResult(
                    injectedIDs: injectedIDs,
                    unavailableIDs: unavailableIDs,
                    unavailableKinds: unavailableKinds
                )
            }

            switch try attemptQueuedPaste(
                id: id,
                knownKinds: knownKinds,
                sideEffectGate: sideEffectGate
            ) {
            case let .unavailable(kind):
                unavailableIDs.append(id)
                unavailableKinds.append(kind)
            case .injected:
                injectedIDs.append(id)
            case .manualPasteRequired:
                return .manualPasteRequired(
                    injectedIDs: injectedIDs,
                    unavailableIDs: unavailableIDs,
                    unavailableKinds: unavailableKinds,
                    manualPasteRequiredID: id,
                    remainingIDs: Array(ids[index...])
                )
            }

            guard waitForQueuedPasteIfNeeded(
                index: index,
                totalCount: ids.count,
                shouldCancel: shouldCancel
            ) else {
                return completedQueuedPasteResult(
                    injectedIDs: injectedIDs,
                    unavailableIDs: unavailableIDs,
                    unavailableKinds: unavailableKinds
                )
            }
        }

        return completedQueuedPasteResult(
            injectedIDs: injectedIDs,
            unavailableIDs: unavailableIDs,
            unavailableKinds: unavailableKinds
        )
    }

    private func completedQueuedPasteResult(
        injectedIDs: [RecordID],
        unavailableIDs: [RecordID],
        unavailableKinds: [MacClippyDockMultiPastePolicy.Kind]
    ) -> MacClippyQueuePasteResult {
        .completed(
            injectedIDs: injectedIDs,
            unavailableIDs: unavailableIDs,
            unavailableKinds: unavailableKinds
        )
    }

    private func attemptQueuedPaste(
        id: RecordID,
        knownKinds: [RecordID: MacClippyContentKind],
        sideEffectGate: MacClippyPasteInjectionGate?
    ) throws -> MacClippyQueuedPasteAttempt {
        switch try prepareQueuedPasteContent(id: id, knownKinds: knownKinds) {
        case let .unavailable(kind):
            return .unavailable(kind)
        case let .content(content):
            switch injectPasteboardContent(
                content,
                frequencyIDs: [id],
                sideEffectGate: sideEffectGate
            ) {
            case .injected:
                return .injected
            case .manualPasteRequired:
                return .manualPasteRequired
            }
        }
    }

    private func prepareQueuedPasteContent(
        id: RecordID,
        knownKinds: [RecordID: MacClippyContentKind]
    ) throws -> MacClippyQueuedPastePreparation {
        do {
            return try withStoreLock {
                let body = try clipboardStore.body(for: id)
                return .content(try pasteboardContent(for: body, plain: false))
            }
        } catch {
            let isMissing: Bool = {
                guard let storeError = error as? MacClippyStoreError else { return false }
                if case .recordNotFound = storeError { return true }
                return false
            }()
            let isCorrupt = isCorruptStoredRecord(error)
            guard isMissing || isCorrupt else { throw error }
            if isCorrupt {
                recordCorruptStoredRecord(operation: "queued_paste_record")
            }
            let kind = knownKinds[id].map(MacClippyDockMultiPasteKindMapping.kind(for:)) ?? .unsupported
            return .unavailable(kind)
        }
    }

    private func waitForQueuedPasteIfNeeded(
        index: Int,
        totalCount: Int,
        shouldCancel: () -> Bool
    ) -> Bool {
        guard index < totalCount - 1 else { return true }
        let deadline = Date().addingTimeInterval(MacClippyQueuePastePolicy.settleInterval)
        while Date() < deadline {
            guard !shouldCancel() else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    func injectPasteboardContent(
        _ content: MacClippyPasteboardContent,
        frequencyIDs: [RecordID] = [],
        sideEffectGate: MacClippyPasteInjectionGate?
    ) -> PasteInjectionResult {
        let operation = {
            let result = self.pasteInjector.inject(content: content)
            guard result == .injected else { return result }
            for id in frequencyIDs {
                self.recordSuccessfulPasteFrequency(for: id)
            }
            return result
        }
        if let sideEffectGate {
            return sideEffectGate.withOpenGate(operation) ?? .manualPasteRequired
        }
        return operation()
    }

    /// Shared ordered-selection resolution for pasteOrdered and copyOrdered.
    /// Runs the pure MacClippyDockMultiPastePolicy under the store lock so both
    /// paths share one classification and never drift. Returns the policy
    /// result (mergedText / mixed / textUnavailable) without performing any
    /// pasteboard write or paste injection.
    func resolveOrderedMultiSelection(ids: [RecordID]) throws -> MacClippyDockMultiPastePolicy.Result {
        try withStoreLock {
            let knownKinds = try clipboardStore.contentKinds(for: ids)
            return try MacClippyDockMultiPastePolicy.resolveThrowing(
                orderedSelectedIDs: ids,
                kindForID: { id in
                    guard let contentKind = knownKinds[id] else { return .unsupported }
                    return MacClippyDockMultiPasteKindMapping.kind(for: contentKind)
                },
                textForID: { id in
                    do {
                        let record = try clipboardStore.body(for: id)
                        switch record {
                        case let .text(value):
                            return value
                        case let .html(value):
                            return MacClippyClipboardText.plainText(from: record) ?? value
                        case let .rtf(data):
                            let rtfRecord = ClipboardRecord.rtf(data)
                            return MacClippyClipboardText.plainText(from: rtfRecord)
                        case .image, .encryptedImage, .files:
                            // The policy does not request text from these kinds,
                            // but keep this defensive branch if the projection
                            // and payload ever diverge.
                            return nil
                        }
                    } catch {
                        if isCorruptStoredRecord(error) {
                            recordCorruptStoredRecord(operation: "ordered_multi_selection_record")
                            return nil
                        }
                        if case MacClippyStoreError.recordNotFound = error {
                            return nil
                        }
                        throw error
                    }
                }
            )
        }
    }
}
