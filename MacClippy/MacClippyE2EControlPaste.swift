#if MACCLIPPY_E2E
import AppKit
import CryptoKit
import Foundation
import MacClippyCore
@_spi(Testing) import MacClippyPlatform

private struct MacClippyE2ESourcePasteProof {
    let contentKind: String
    let decodedText: String?
    let representations: [MacClippyE2ERepresentationProof]
}

private struct MacClippyE2ERecipientPasteProof {
    let query: String?
    let recordID: String
    let primaryContentKind: String
    let decodedText: String?
    let representations: [MacClippyE2ERepresentationProof]
    let startedAtUptimeNanoseconds: UInt64
}

private struct MacClippyE2EPreparedPaste {
    let controller: MacClippyDockController
    let request: MacClippyE2EControlRequest
    let query: String
    let item: MacClippyHistoryEntry
    let plain: Bool
    let sourceProof: MacClippyE2ESourcePasteProof
}

private enum MacClippyE2EPasteSelection {
    case selected(MacClippyHistoryEntry)
    case failed(String)
}

@MainActor
extension AppDelegate {
    func pasteE2EItem(
        _ request: MacClippyE2EControlRequest,
        plain: Bool
    ) async -> MacClippyE2EControlResponse {
        let requestedID: RecordID?
        if let rawID = request.recordID {
            guard let parsed = RecordID(rawValue: rawID) else {
                return MacClippyE2EControlResponse(isOK: false, errorCode: "invalid-record-id")
            }
            requestedID = parsed
        } else {
            requestedID = nil
        }
        let query = request.query ?? ""
        guard let controller = dockController,
              let runtime,
              requestedID != nil || !query.isEmpty else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "paste-query-required")
        }
        let item: MacClippyHistoryEntry
        switch await prepareE2EPasteSelection(
            controller,
            requestedID: requestedID,
            query: query
        ) {
        case let .selected(selectedItem):
            item = selectedItem
        case let .failed(errorCode):
            return MacClippyE2EControlResponse(isOK: false, errorCode: errorCode)
        }
        let sourceProof: MacClippyE2ESourcePasteProof
        do {
            sourceProof = try e2eSourcePasteProof(for: item, runtime: runtime)
        } catch {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "record-payload-read-failed")
        }
        return await executeE2EPaste(
            MacClippyE2EPreparedPaste(
                controller: controller,
                request: request,
                query: query,
                item: item,
                plain: plain,
                sourceProof: sourceProof
            )
        )
    }

    private func e2eSourcePasteProof(
        for item: MacClippyHistoryEntry,
        runtime: MacClippyRuntime
    ) throws -> MacClippyE2ESourcePasteProof {
        let blobLease = try runtime.blobStore.acquireRootReadLease()
        defer { blobLease.release() }
        let snapshot = try runtime.clipboardStore.playbackSnapshot(for: item.id)
        let inspected = try MacClippyE2EPayloadRead.inspect(snapshot, runtime: runtime)
        return MacClippyE2ESourcePasteProof(
            contentKind: snapshot.record.contentKind.rawValue,
            decodedText: MacClippyClipboardText.plainText(from: snapshot.record),
            representations: inspected.map { $0.proof }
        )
    }

    private func executeE2EPaste(
        _ paste: MacClippyE2EPreparedPaste
    ) async -> MacClippyE2EControlResponse {
        let oldInsertionCount = e2eRecipient?.insertionCount ?? 0
        let pasteStartedAt = DispatchTime.now().uptimeNanoseconds
        _ = paste.controller.applyKeyAction(.paste(plain: paste.plain))
        let timeout = max(1, min(paste.request.timeoutSeconds ?? 15, 120))
        guard let recipient = e2eRecipient,
              await waitForE2ERecipientInsertion(
                recipient,
                after: oldInsertionCount,
                timeoutSeconds: timeout
              ) else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "recipient-insertion-timeout")
        }
        return makeE2ERecipientPasteResponse(
            recipient,
            proof: MacClippyE2ERecipientPasteProof(
                query: paste.query.isEmpty ? nil : paste.query,
                recordID: paste.item.id.rawValue,
                primaryContentKind: paste.sourceProof.contentKind,
                decodedText: paste.sourceProof.decodedText,
                representations: paste.sourceProof.representations,
                startedAtUptimeNanoseconds: pasteStartedAt
            )
        )
    }

    private func prepareE2EPasteSelection(
        _ controller: MacClippyDockController,
        requestedID: RecordID?,
        query: String
    ) async -> MacClippyE2EPasteSelection {
        activateE2EForVisibleUI(controller)
        if controller.panel?.isVisible != true {
            controller.show()
        }
        guard await waitForE2EPanel(controller) else {
            return .failed("panel-interactive-timeout")
        }
        controller.enterSearchMode()
        guard await prepareE2EModelSearch(controller, query: query),
              let item = controller.model.visibleItems.first(where: { entry in
                  if let requestedID { return entry.id == requestedID }
                  return entry.preview.contains(query)
              }) else {
            return .failed("paste-item-search-timeout")
        }
        controller.setSearchMode(false)
        controller.model.focus(item)
        controller.model.ensureFocusedSelection()
        return .selected(item)
    }

    private func waitForPasteBarrier(_ barrier: MacClippyE2EPasteBarrier) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while !barrier.isWaiting,
              DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return barrier.isWaiting
    }

    private func waitForE2ERecipientInsertion(
        _ recipient: MacClippyE2ERecipient,
        after previousCount: Int,
        timeoutSeconds: Double
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutSeconds * 1_000_000_000)
        while recipient.insertionCount <= previousCount,
              DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return recipient.insertionCount > previousCount
    }

    private func makeE2ERecipientPasteResponse(
        _ recipient: MacClippyE2ERecipient,
        proof: MacClippyE2ERecipientPasteProof
    ) -> MacClippyE2EControlResponse {
        let insertedText = recipient.lastInsertedText
        let didInsertQuery = proof.query.map { insertedText.contains($0) } ?? true
        let hasPayloadProof = recipient.insertedRepresentations.contains { $0.sha256 != nil }
        let didInsertPayload = didInsertQuery && hasPayloadProof
        let elapsedMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - proof.startedAtUptimeNanoseconds
        ) / 1_000_000
        return MacClippyE2EControlResponse(
            isOK: didInsertPayload,
            errorCode: didInsertPayload ? nil : "recipient-content-mismatch",
            recordID: proof.recordID,
            primaryContentKind: proof.primaryContentKind,
            elapsedMilliseconds: elapsedMilliseconds,
            uiLatencyMilliseconds: elapsedMilliseconds,
            contentInserted: didInsertPayload,
            recipientSHA256: recipient.lastInsertedTextSHA256,
            recipientByteCount: insertedText.utf8.count,
            recipientInsertionCount: recipient.insertionCount,
            recipientPostRoute: recipient.lastPosterRoute?.rawValue,
            recipientTypes: recipient.insertedTypes,
            recipientLabel: "MacClippyE2ERecipient in-memory test double; not TextEdit, Safari, Terminal, or Finder",
            actualOSAXInjectionPerformed: false,
            pasteResult: "isolated-recipient-inserted",
            decodedText: proof.decodedText,
            representations: proof.representations,
            recipientRepresentations: recipient.insertedRepresentations
        )
    }

    func beginCancelableE2EPaste(
        _ request: MacClippyE2EControlRequest,
        barrier: MacClippyE2EPasteBarrier
    ) async -> MacClippyE2EControlResponse {
        guard let controller = dockController,
              let runtime,
              let query = request.query,
              !query.isEmpty,
              let plain = request.plain else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "paste-mode-required")
        }
        activateE2EForVisibleUI(controller)
        if controller.panel?.isVisible != true {
            controller.show()
        }
        guard await waitForE2EPanel(controller) else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "panel-interactive-timeout")
        }
        controller.enterSearchMode()
        guard await prepareE2EModelSearch(controller, query: query),
              let item = controller.model.visibleItems.first(where: { $0.preview.contains(query) }) else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "paste-item-search-timeout")
        }
        controller.setSearchMode(false)
        controller.model.focus(item)
        controller.model.ensureFocusedSelection()
        let recordID = item.id
        let gate = MacClippyPasteInjectionGate()
        barrier.arm(gate: gate)
        Task.detached(priority: .userInitiated) {
            let result: PasteInjectionResult
            do {
                result = try runtime.paste(id: recordID, plain: plain, sideEffectGate: gate)
            } catch {
                barrier.complete(result: nil)
                return
            }
            barrier.complete(result: result)
        }
        guard await waitForPasteBarrier(barrier) else {
            barrier.release()
            return MacClippyE2EControlResponse(isOK: false, errorCode: "paste-barrier-timeout")
        }
        return MacClippyE2EControlResponse(
            isOK: true,
            operationID: UUID().uuidString.lowercased(),
            recipientLabel: "MacClippyE2ERecipient in-memory test double",
            pasteBarrierWaiting: true
        )
    }

    func cancelE2EPaste(
        barrier: MacClippyE2EPasteBarrier,
        recipient: MacClippyE2ERecipient
    ) async -> MacClippyE2EControlResponse {
        guard barrier.isWaiting else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "paste-not-cancelable")
        }
        barrier.release()
        let didComplete = await barrier.waitForCompletion(timeoutSeconds: 10)
        let wasReleased = barrier.hasReleased
        let insertionCount = recipient.insertionCount
        let didCancel = barrier.pasteResult == "cancelled"
        let passed = didComplete && wasReleased && didCancel && insertionCount == 0
        return MacClippyE2EControlResponse(
            isOK: passed,
            errorCode: passed ? nil : "paste-cancellation-failed",
            contentInserted: insertionCount > 0,
            recipientInsertionCount: insertionCount,
            recipientLabel: "MacClippyE2ERecipient in-memory test double",
            actualOSAXInjectionPerformed: false,
            pasteResult: didCancel ? "cancelled-before-injection" : barrier.pasteResult,
            pasteBarrierReleased: wasReleased,
            pasteOperationCompleted: didComplete
        )
    }
}
#endif
