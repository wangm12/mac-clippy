#if MACCLIPPY_E2E
import AppKit
import Foundation
import MacClippyCore
@_spi(Testing) import MacClippyPlatform

private struct MacClippyE2EVerifiedCapture {
    let snapshot: MacClippyClipboardPlaybackSnapshot
    let inspected: [(proof: MacClippyE2ERepresentationProof, bytes: Data?)]
    let payload: Data
    let observedItemCount: Int
    let roundTrip: Bool
}

@MainActor
extension AppDelegate {
    func makeE2ECaptureResponse(
        record: MacClippyHistoryEntry,
        expectation: MacClippyE2ECaptureExpectation,
        context: MacClippyE2ECaptureContext
    ) -> MacClippyE2EControlResponse {
        do {
            // Retain every blob from the row lookup through authentication so
            // concurrent reconciliation cannot retire a spilled payload in
            // the gap between reading its reference and opening it.
            let blobLease = try context.runtime.blobStore.acquireRootReadLease()
            defer { blobLease.release() }
            let snapshot = try context.runtime.clipboardStore.playbackSnapshot(for: record.id)
            let inspected = try MacClippyE2EPayloadRead.inspect(snapshot, runtime: context.runtime)
            guard let representationIndex = snapshot.representations.firstIndex(where: {
                $0.itemIndex == 0 && $0.uti == expectation.uti.rawValue
            }), let payload = inspected[representationIndex].bytes else {
                return MacClippyE2EControlResponse(isOK: false, errorCode: "raw-representation-unavailable")
            }
            let observedItemCount = (snapshot.representations.map(\.itemIndex).max() ?? -1) + 1
            let snapshotMatches = captureSnapshotMatches(
                snapshot,
                inspected: inspected,
                context: context
            )
            let roundTrip = payload == expectation.payload && snapshotMatches
            guard roundTrip else {
                return MacClippyE2EControlResponse(isOK: false, errorCode: "capture-fixture-contract-mismatch")
            }
            return makeVerifiedCaptureResponse(
                record: record,
                verification: MacClippyE2EVerifiedCapture(
                    snapshot: snapshot,
                    inspected: inspected,
                    payload: payload,
                    observedItemCount: observedItemCount,
                    roundTrip: roundTrip
                ),
                context: context
            )
        } catch {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "encrypted-payload-read-failed")
        }
    }

    private func captureSnapshotMatches(
        _ snapshot: MacClippyClipboardPlaybackSnapshot,
        inspected: [(proof: MacClippyE2ERepresentationProof, bytes: Data?)],
        context: MacClippyE2ECaptureContext
    ) -> Bool {
        let expectation = context.expectation
        let observedItemCount = (snapshot.representations.map(\.itemIndex).max() ?? -1) + 1
        let primaryPayloads = snapshot.representations.enumerated().compactMap { index, representation -> Data? in
            guard representation.uti == expectation.uti.rawValue else { return nil }
            return inspected[index].bytes
        }
        return capturePayloadMatches(
            snapshot.record,
            expectation: expectation,
            token: context.request.token ?? ""
        )
            && observedItemCount == min(max(context.request.itemCount ?? 1, 1), 4)
            && primaryPayloads.count == snapshot.representations.filter { $0.uti == expectation.uti.rawValue }.count
            && primaryPayloads.count >= ((context.request.repeatPrimaryUTI ?? false) ? 2 : 1)
            && primaryPayloads.allSatisfy { $0 == expectation.payload }
    }

    private func makeVerifiedCaptureResponse(
        record: MacClippyHistoryEntry,
        verification: MacClippyE2EVerifiedCapture,
        context: MacClippyE2ECaptureContext
    ) -> MacClippyE2EControlResponse {
        let snapshot = verification.snapshot
        let expectation = context.expectation
        let pasteboard = context.isolation.pasteboard
        let livePasteboardEvidence: (types: [String], bytes: Int)
        do {
            livePasteboardEvidence = try context.isolation.pasteboardAccessCoordinator.withAccess {
                let types = try MacClippyNativePasteboard.boardTypes(of: pasteboard).sorted()
                let items = try MacClippyNativePasteboard.items(of: pasteboard)
                var bytes = 0
                for item in items {
                    for rawType in try MacClippyNativePasteboard.types(of: item) {
                        bytes += try MacClippyNativePasteboard.data(
                            from: item,
                            forType: NSPasteboard.PasteboardType(rawValue: rawType)
                        )?.count ?? 0
                    }
                }
                return (types, bytes)
            }
        } catch {
            context.isolation.recordDiagnostic(category: "capture-response-native-exception", error: error)
            return MacClippyE2EControlResponse(
                isOK: false,
                errorCode: "native-pasteboard-exception",
                message: String(String(describing: error).prefix(512))
            )
        }
        return MacClippyE2EControlResponse(
            isOK: true,
            recordID: record.id.rawValue,
            recordCount: 1,
            payloadByteCount: livePasteboardEvidence.bytes,
            primaryContentKind: snapshot.record.contentKind.rawValue,
            capturedItemCount: verification.observedItemCount,
            fixtureFileByteCount: expectation.fixtureFileByteCount,
            rawPayloadUTI: expectation.uti.rawValue,
            rawPayloadByteCount: verification.payload.count,
            rawPayloadSHA256: Self.sha256(verification.payload),
            rawPayloadRoundTrip: verification.roundTrip,
            spilledRepresentationCount: snapshot.representations.filter { $0.payloadState == .spilled }.count,
            pasteboardTypes: livePasteboardEvidence.types,
            sourceAppBundleIdentifier: MacClippyE2EIsolation.sourceAppBundleIdentifier,
            ingestionMode: context.forcePoll
                ? "forced_immediate_production_observer_read"
                : "natural_background_observer_poll",
            hitCount: 1,
            decodedText: MacClippyClipboardText.plainText(from: snapshot.record),
            representations: verification.inspected.map { $0.proof }
        )
    }

    private func capturePayloadMatches(
        _ record: MacClippyClipboardRecord,
        expectation: MacClippyE2ECaptureExpectation,
        token: String
    ) -> Bool {
        switch expectation.format {
        case "text", "html", "rtf":
            if matchesPlainText(record, expected: expectation.expectedPlainText) { return true }
            return matchesStructuredText(record, expectation: expectation)
        case "image":
            return matchesImage(record)
        case "files":
            return matchesFile(record, token: token)
        default:
            return false
        }
    }

    private func matchesPlainText(_ record: MacClippyClipboardRecord, expected: String?) -> Bool {
        guard let expected, case let .text(value) = record else { return false }
        return value == expected
    }

    private func matchesStructuredText(
        _ record: MacClippyClipboardRecord,
        expectation: MacClippyE2ECaptureExpectation
    ) -> Bool {
        switch (expectation.format, record) {
        case let ("html", .html(value)):
            guard let expectedHTML = String(data: expectation.payload, encoding: .utf8) else { return false }
            return value == expectedHTML
        case let ("rtf", .rtf(data)):
            return data == expectation.payload
        default:
            return false
        }
    }

    private func matchesImage(_ record: MacClippyClipboardRecord) -> Bool {
        switch record {
        case .image, .encryptedImage:
            return true
        default:
            return false
        }
    }

    private func matchesFile(_ record: MacClippyClipboardRecord, token: String) -> Bool {
        guard case let .files(urls) = record else { return false }
        return urls.contains { $0.lastPathComponent == "\(token).txt" }
    }

}
#endif
