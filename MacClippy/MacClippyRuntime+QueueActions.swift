import AppKit
import CoreGraphics
import Foundation
import MacClippyCore
import MacClippyPlatform

private struct MacClippyPasteExecutionContext {
    let targetProcessIdentifier: Int32?
    let gate: MacClippyPasteInjectionGate?
}

private enum MacClippyQueuedPastePreparation {
    case content(MacClippyPasteboardContent)
    case unavailable(MacClippyDockMultiPastePolicy.Kind)
}

private enum MacClippyQueuedPasteAttempt {
    case injected
    case unavailable(MacClippyDockMultiPastePolicy.Kind)
    case preparedForManualPaste
    case failed(MacClippyPasteInjectionFailure)
    case cancelled
}

private struct MacClippyQueuedPasteProgress {
    private(set) var injectedIDs: [RecordID] = []
    private(set) var unavailableIDs: [RecordID] = []
    private(set) var unavailableKinds: [MacClippyDockMultiPastePolicy.Kind] = []

    mutating func record(
        _ attempt: MacClippyQueuedPasteAttempt,
        id: RecordID,
        remainingIDs: [RecordID]
    ) -> MacClippyQueuePasteResult? {
        switch attempt {
        case let .unavailable(kind):
            unavailableIDs.append(id)
            unavailableKinds.append(kind)
            return nil
        case .injected:
            injectedIDs.append(id)
            return nil
        case .preparedForManualPaste:
            return .preparedForManualPaste(
                injectedIDs: injectedIDs,
                unavailableIDs: unavailableIDs,
                unavailableKinds: unavailableKinds,
                preparedID: id,
                remainingIDs: remainingIDs
            )
        case let .failed(failure):
            return .failed(
                injectedIDs: injectedIDs,
                unavailableIDs: unavailableIDs,
                unavailableKinds: unavailableKinds,
                failedID: id,
                failure: failure,
                remainingIDs: remainingIDs
            )
        case .cancelled:
            return cancelled(remainingIDs: remainingIDs)
        }
    }

    func cancelled(remainingIDs: [RecordID]) -> MacClippyQueuePasteResult {
        .cancelled(
            injectedIDs: injectedIDs,
            unavailableIDs: unavailableIDs,
            unavailableKinds: unavailableKinds,
            remainingIDs: remainingIDs
        )
    }

    func completed() -> MacClippyQueuePasteResult {
        .completed(
            injectedIDs: injectedIDs,
            unavailableIDs: unavailableIDs,
            unavailableKinds: unavailableKinds
        )
    }
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
    ///   - If the injector returns .preparedForManualPaste, STOP immediately:
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
        shouldCancel: @escaping () -> Bool = { false },
        sideEffectGate: MacClippyPasteInjectionGate? = nil,
        targetProcessIdentifier: Int32? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> MacClippyQueuePasteResult {
        try measureDiagnosticMetric("paste_queue") {
            guard !shouldCancel(), sideEffectGate?.isOpen != false else {
                return .cancelled(
                    injectedIDs: [],
                    unavailableIDs: [],
                    unavailableKinds: [],
                    remainingIDs: ids
                )
            }

            let knownKinds = try withStoreLock {
                try clipboardStore.contentKinds(for: ids)
            }
            return try pasteQueuedRecords(
                ids: ids,
                knownKinds: knownKinds,
                shouldCancel: shouldCancel,
                context: .init(targetProcessIdentifier: targetProcessIdentifier, gate: sideEffectGate),
                onProgress: onProgress
            )
        }
    }

    private func pasteQueuedRecords(
        ids: [RecordID],
        knownKinds: [RecordID: MacClippyContentKind],
        shouldCancel: @escaping () -> Bool,
        context: MacClippyPasteExecutionContext,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) throws -> MacClippyQueuePasteResult {
        let sideEffectGate = context.gate
        var progress = MacClippyQueuedPasteProgress()

        for (index, id) in ids.enumerated() {
            guard !shouldCancel(), sideEffectGate?.isOpen != false else {
                return progress.cancelled(remainingIDs: Array(ids[index...]))
            }

            onProgress?(index + 1, ids.count)
            let attempt = try attemptQueuedPaste(
                id: id,
                knownKinds: knownKinds,
                shouldCancel: shouldCancel,
                sideEffectGate: sideEffectGate,
                targetProcessIdentifier: context.targetProcessIdentifier
            )
            if let terminalResult = progress.record(
                attempt,
                id: id,
                remainingIDs: Array(ids[index...])
            ) {
                return terminalResult
            }

            guard waitForQueuedPasteIfNeeded(
                index: index,
                totalCount: ids.count,
                shouldCancel: shouldCancel,
                sideEffectGate: sideEffectGate
            ) else {
                return progress.cancelled(remainingIDs: Array(ids.dropFirst(index + 1)))
            }
        }

        return progress.completed()
    }

    private func attemptQueuedPaste(
        id: RecordID,
        knownKinds: [RecordID: MacClippyContentKind],
        shouldCancel: @escaping () -> Bool,
        sideEffectGate: MacClippyPasteInjectionGate?,
        targetProcessIdentifier: Int32?
    ) throws -> MacClippyQueuedPasteAttempt {
        switch try prepareQueuedPasteContent(id: id, knownKinds: knownKinds) {
        case let .unavailable(kind):
            return .unavailable(kind)
        case let .content(content):
            switch injectPasteboardContent(
                content,
                frequencyIDs: [id],
                targetProcessIdentifier: targetProcessIdentifier,
                validateBeforePaste: { !shouldCancel() },
                sideEffectGate: sideEffectGate
            ) {
            case .injected:
                return .injected
            case .preparedForManualPaste:
                return .preparedForManualPaste
            case let .failed(failure):
                return .failed(failure)
            case .cancelled:
                return .cancelled
            }
        }
    }

    private func prepareQueuedPasteContent(
        id: RecordID,
        knownKinds: [RecordID: MacClippyContentKind]
    ) throws -> MacClippyQueuedPastePreparation {
        do {
            return try withStoreLock {
                let snapshot = try clipboardStore.playbackSnapshot(for: id)
                return .content(try pasteboardContent(for: snapshot, plain: false))
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
        shouldCancel: () -> Bool,
        sideEffectGate: MacClippyPasteInjectionGate?
    ) -> Bool {
        guard index < totalCount - 1 else { return true }
        let deadline = Date().addingTimeInterval(MacClippyQueuePastePolicy.settleInterval)
        while Date() < deadline {
            guard !shouldCancel(), sideEffectGate?.isOpen != false else { return false }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return true
    }

    func injectPasteboardContent(
        _ content: MacClippyPasteboardContent,
        frequencyIDs: [RecordID] = [],
        targetProcessIdentifier: Int32? = nil,
        validateBeforePaste: (() -> Bool)? = nil,
        sideEffectGate: MacClippyPasteInjectionGate?
    ) -> PasteInjectionResult {
        let result = pasteInjector.inject(
            content: content,
            validateBeforePaste: validateBeforePaste,
            validateCommitContext: validateBeforePaste,
            gate: sideEffectGate,
            targetProcessIdentifier: targetProcessIdentifier
        )
        guard result == .injected else { return result }
        for id in frequencyIDs {
            recordSuccessfulPasteFrequency(for: id)
        }
        return result
    }

    /// Shared ordered-selection resolution for pasteOrdered and copyOrdered.
    /// Runs the pure MacClippyDockMultiPastePolicy under the store lock so both
    /// paths share one classification and never drift. Returns the policy
    /// result (mergedText / mixed / textUnavailable) without performing any
    /// pasteboard write or paste injection.
    func resolveOrderedMultiSelection(ids: [RecordID]) throws -> MacClippyDockMultiPastePolicy.Result {
        let knownKinds = try withStoreLock {
            try clipboardStore.contentKinds(for: ids)
        }
        let textIDs = ids.filter { id in
            switch knownKinds[id] {
            case .text, .html, .rtf: return true
            default: return false
            }
        }
        var texts: [RecordID: String?] = [:]
        var index = 0
        while index < textIDs.count {
            let end = min(index + 16, textIDs.count)
            let chunk = Array(textIDs[index..<end])
            let records = withStoreLock {
                chunk.map { id -> (RecordID, Result<ClipboardRecord, Error>) in
                    (id, Result { try clipboardStore.body(for: id) })
                }
            }
            for (id, result) in records {
                switch result {
                case let .success(record):
                    switch record {
                    case let .text(value):
                        texts[id] = value
                    case let .html(value):
                        texts[id] = MacClippyClipboardText.plainText(from: record) ?? value
                    case let .rtf(data):
                        texts[id] = MacClippyClipboardText.plainText(from: .rtf(data))
                    case .image, .encryptedImage, .files:
                        texts[id] = nil
                    }
                case let .failure(error):
                    if isCorruptStoredRecord(error) {
                        recordCorruptStoredRecord(operation: "ordered_multi_selection_record")
                        texts[id] = nil
                    } else if case MacClippyStoreError.recordNotFound = error {
                        texts[id] = nil
                    } else {
                        throw error
                    }
                }
            }
            index = end
        }
        return try MacClippyDockMultiPastePolicy.resolveThrowing(
            orderedSelectedIDs: ids,
            kindForID: { id in
                guard let contentKind = knownKinds[id] else { return .unsupported }
                return MacClippyDockMultiPasteKindMapping.kind(for: contentKind)
            },
            textForID: { id in
                if let value = texts[id] { return value }
                return nil
            }
        )
    }
}
