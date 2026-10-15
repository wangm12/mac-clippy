#if MACCLIPPY_E2E
import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform

@MainActor
extension AppDelegate {
    func searchE2EDatabase(
        _ request: MacClippyE2EControlRequest,
        runtime: MacClippyRuntime
    ) -> MacClippyE2EControlResponse {
        guard let query = request.query, !query.isEmpty else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "search-query-required")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        do {
            let results = try runtime.history(
                limit: min(max(request.limit ?? 100, 1), 512),
                query: query
            )
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            return MacClippyE2EControlResponse(
                isOK: true,
                matchedRecordIDs: results.map { $0.id.rawValue },
                hitCount: results.count,
                elapsedMilliseconds: Double(elapsed) / 1_000_000,
                searchCompleted: true
            )
        } catch {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "database-search-failed")
        }
    }

    func verifyE2ERecord(
        _ request: MacClippyE2EControlRequest,
        runtime: MacClippyRuntime
    ) -> MacClippyE2EControlResponse {
        let requestedID: RecordID?
        if let recordID = request.recordID {
            guard let parsed = RecordID(rawValue: recordID) else {
                return MacClippyE2EControlResponse(isOK: false, errorCode: "invalid-record-id")
            }
            requestedID = parsed
        } else {
            requestedID = nil
        }
        guard requestedID != nil || request.query?.isEmpty == false else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "record-id-or-query-required")
        }
        do {
            var entries: [MacClippyHistoryEntry] = []
            let recordID: RecordID
            if let requestedID {
                recordID = requestedID
            } else if let query = request.query {
                entries = try runtime.history(limit: 512, query: query)
                guard let found = entries.first(where: { $0.preview.contains(query) }) else {
                    return MacClippyE2EControlResponse(
                        isOK: false,
                        errorCode: "record-not-found-after-restart",
                        recordCount: entries.count,
                        hitCount: 0
                    )
                }
                recordID = found.id
            } else {
                return MacClippyE2EControlResponse(
                    isOK: false,
                    errorCode: "record-id-or-query-required"
                )
            }
            return try makeVerifiedE2ERecordResponse(
                request,
                recordID: recordID,
                recordCount: requestedID == nil ? entries.count : 1,
                runtime: runtime
            )
        } catch {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "encrypted-record-read-failed")
        }
    }

    private func makeVerifiedE2ERecordResponse(
        _ request: MacClippyE2EControlRequest,
        recordID: RecordID,
        recordCount: Int,
        runtime: MacClippyRuntime
    ) throws -> MacClippyE2EControlResponse {
        let blobLease = try runtime.blobStore.acquireRootReadLease()
        defer { blobLease.release() }
        let snapshot = try runtime.clipboardStore.playbackSnapshot(for: recordID)
        let inspected = try MacClippyE2EPayloadRead.inspect(snapshot, runtime: runtime)
        let rawIndex = snapshot.representations.firstIndex {
            $0.itemIndex == 0 && (request.format == nil || $0.uti == request.format)
        }
        let rawIndexFallback = rawIndex ?? snapshot.representations.firstIndex {
            request.format == nil || $0.uti == request.format
        }
        let rawData = rawIndexFallback.flatMap { inspected[$0].bytes }
        return MacClippyE2EControlResponse(
            isOK: rawData != nil,
            errorCode: rawData == nil ? "encrypted-payload-read-failed" : nil,
            recordID: recordID.rawValue,
            recordCount: recordCount,
            primaryContentKind: snapshot.record.contentKind.rawValue,
            rawPayloadUTI: rawIndexFallback.map { snapshot.representations[$0].uti },
            rawPayloadByteCount: rawData?.count,
            rawPayloadSHA256: rawData.map(Self.sha256),
            rawPayloadRoundTrip: rawData != nil,
            spilledRepresentationCount: snapshot.representations.filter { $0.payloadState == .spilled }.count,
            hitCount: 1,
            decodedText: MacClippyClipboardText.plainText(from: snapshot.record),
            representations: inspected.map { $0.proof }
        )
    }
}
#endif
