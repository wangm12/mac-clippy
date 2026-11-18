#if MACCLIPPY_E2E
import AppKit
import CryptoKit
import Foundation
import Darwin
import MacClippyCore
@_spi(Testing) import MacClippyPlatform

struct MacClippyE2ECaptureContext {
    let request: MacClippyE2EControlRequest
    let expectation: MacClippyE2ECaptureExpectation
    let isolation: MacClippyE2EIsolation
    let runtime: MacClippyRuntime
    let forcePoll: Bool
}

private struct MacClippyE2ECaptureFixtureFailure: Error {
    let response: MacClippyE2EControlResponse
}

enum MacClippyE2EPayloadRead {
    // E2E proof reads intentionally stop at 1 MiB. Larger payloads remain
    // represented in the proof list but have null byteCount/hash fields, so a
    // runner cannot report them as byte-verified by this bounded probe.
    static let maximumBytes = 1 * 1_024 * 1_024

    static func bytes(
        for representation: MacClippyClipboardRepresentation,
        runtime: MacClippyRuntime
    ) throws -> Data? {
        switch representation.payloadState {
        case .present:
            guard let payload = representation.payloadBytes,
                  payload.count <= maximumBytes else { return nil }
            return payload
        case .spilled:
            guard let blobID = representation.blobID else { return nil }
            do {
                return try runtime.blobStore.read(id: blobID, maxBytes: maximumBytes)
            } catch MacClippyBlobError.payloadTooLarge {
                return nil
            }
        case .unavailable, .oversized:
            return nil
        }
    }

    static func inspect(
        _ snapshot: MacClippyClipboardPlaybackSnapshot,
        runtime: MacClippyRuntime
    ) throws -> [(proof: MacClippyE2ERepresentationProof, bytes: Data?)] {
        try snapshot.representations.map { representation in
            let payload = try bytes(for: representation, runtime: runtime)
            return (
                proof: MacClippyE2ERepresentationProof(
                    itemIndex: representation.itemIndex,
                    uti: representation.uti,
                    payloadState: representation.payloadState.rawValue,
                    byteCount: payload?.count,
                    sha256: payload.map { data in
                        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    }
                ),
                bytes: payload
            )
        }
    }
}

@MainActor
extension AppDelegate {
    func handleE2EControlRequest(
        _ request: MacClippyE2EControlRequest,
        acceptedAt: UInt64
    ) async -> MacClippyE2EControlResponse {
        guard let e2eIsolation,
              let runtime,
              let e2eRecipient,
              let e2ePasteBarrier else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "runtime-not-ready")
        }
        switch request.command {
        case "surface-show":
            return showE2EReviewSurface(request.text)
        case "appearance-set":
            return setE2EReviewAppearance(request.text)
        case "ping":
            return e2ePingResponse(isolation: e2eIsolation)
        case "metrics":
            return makeE2EMetricsResponse(runtime: runtime, paths: e2eIsolation.paths)
        case "capture":
            return await captureE2EItem(request, runtime: runtime, isolation: e2eIsolation)
        case "search-db":
            return searchE2EDatabase(request, runtime: runtime)
        case "verify-record":
            return verifyE2ERecord(request, runtime: runtime)
        default:
            return await handleE2EVisibleControlRequest(
                request,
                acceptedAt: acceptedAt,
                recipient: e2eRecipient,
                barrier: e2ePasteBarrier
            )
        }
    }

    private func e2ePingResponse(isolation: MacClippyE2EIsolation) -> MacClippyE2EControlResponse {
        MacClippyE2EControlResponse(
            isOK: true,
            ready: true,
            pid: getpid(),
            bundleIdentifier: Bundle.main.bundleIdentifier,
            rootPath: isolation.rootURL.path,
            runID: isolation.runID,
            executablePath: Bundle.main.executableURL?.standardizedFileURL.path,
            buildConfiguration: Bundle.main.infoDictionary?["MacClippyE2EBuildConfiguration"] as? String,
            sourceContentSHA256: Bundle.main.infoDictionary?["MacClippyE2ESourceContentSHA256"] as? String
        )
    }

    private func handleE2EVisibleControlRequest(
        _ request: MacClippyE2EControlRequest,
        acceptedAt: UInt64,
        recipient: MacClippyE2ERecipient,
        barrier: MacClippyE2EPasteBarrier
    ) async -> MacClippyE2EControlResponse {
        switch request.command {
        case "native-host-show":
            let ready = await recipient.showNativeHost()
            return MacClippyE2EControlResponse(
                isOK: ready, errorCode: ready ? nil : "native-host-interactive-timeout",
                ready: ready, nativeHostVisible: recipient.nativeHostIsVisible)
        case "native-host-hide":
            recipient.hideNativeHost()
            return MacClippyE2EControlResponse(isOK: true, nativeHostVisible: recipient.nativeHostIsVisible)
        case "search-ui":
            return await searchE2EUI(request, acceptedAt: acceptedAt)
        case "panel-show":
            return await showE2EPanel(acceptedAt: acceptedAt)
        case "panel-show-preserving-activation":
            return await showE2EPanel(acceptedAt: acceptedAt, activateApplication: false)
        case "panel-hide":
            return await hideE2EPanel(acceptedAt: acceptedAt)
        case "preview-loop":
            return await runE2EPreviewLoop(request)
        case "paste":
            return await pasteE2EItem(request, plain: request.plain ?? false)
        case "paste-injection-probe":
            return pasteInjectionE2EProbe()
        default:
            return await handleE2EPasteControlRequest(request, recipient: recipient, barrier: barrier)
        }
    }

    private func handleE2EPasteControlRequest(
        _ request: MacClippyE2EControlRequest,
        recipient: MacClippyE2ERecipient,
        barrier: MacClippyE2EPasteBarrier
    ) async -> MacClippyE2EControlResponse {
        switch request.command {
        case "paste-begin-cancelable":
            return await beginCancelableE2EPaste(request, barrier: barrier)
        case "paste-barrier-status":
            return MacClippyE2EControlResponse(
                isOK: true,
                recipientSHA256: recipient.insertedTextSHA256,
                recipientInsertionCount: recipient.insertionCount,
                pasteResult: barrier.pasteResult,
                pasteBarrierWaiting: barrier.isWaiting,
                pasteBarrierReleased: barrier.hasReleased,
                pasteOperationCompleted: barrier.operationCompleted
            )
        case "paste-cancel":
            return await cancelE2EPaste(barrier: barrier, recipient: recipient)
        case "recipient-reset":
            recipient.reset()
            return MacClippyE2EControlResponse(isOK: true)
        case "terminate":
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
                NSApp.terminate(nil)
            }
            return MacClippyE2EControlResponse(isOK: true, message: "terminating")
        default:
            return MacClippyE2EControlResponse(isOK: false, errorCode: "unknown-command")
        }
    }

    private func captureE2EItem(
        _ request: MacClippyE2EControlRequest,
        runtime: MacClippyRuntime,
        isolation: MacClippyE2EIsolation
    ) async -> MacClippyE2EControlResponse {
        guard let token = request.token,
              token.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "invalid-capture-payload")
        }
        let priorID: String?
        do {
            priorID = try runtime.history(limit: 1, query: "").first?.id.rawValue
        } catch {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "history-read-failed")
        }
        let expected: MacClippyE2ECaptureExpectation
        do {
            expected = try writeE2ECaptureFixture(request: request, isolation: isolation)
        } catch let failure as MacClippyE2ECaptureFixtureFailure {
            return failure.response
        } catch {
            return MacClippyE2EControlResponse(isOK: false, errorCode: "capture-fixture-write-failed")
        }
        let forcePoll = request.forcePoll ?? true
        if forcePoll {
            runtime.observer.requestCurrentGenerationRead { _ in }
        }
        guard let found = await waitForNewE2ERecord(
            after: priorID,
            runtime: runtime,
            timeoutSeconds: request.timeoutSeconds ?? 10
        ) else {
            isolation.recordDiagnostic(
                category: "capture-index-timeout",
                error: NSError(
                    domain: "com.macallyouneed.macclippy.e2e-control",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "production capture did not index before the request deadline"
                    ]
                )
            )
            return MacClippyE2EControlResponse(isOK: false, errorCode: "capture-index-timeout")
        }
        let context = MacClippyE2ECaptureContext(
            request: request,
            expectation: expected,
            isolation: isolation,
            runtime: runtime,
            forcePoll: forcePoll
        )
        return makeE2ECaptureResponse(record: found, expectation: expected, context: context)
    }

    private func writeE2ECaptureFixture(
        request: MacClippyE2EControlRequest,
        isolation: MacClippyE2EIsolation
    ) throws -> MacClippyE2ECaptureExpectation {
        do {
            return try MacClippyE2ECaptureFixtureBuilder.write(request: request, isolation: isolation)
        } catch let error as MacClippyE2ECaptureError {
            isolation.recordDiagnostic(category: "capture-fixture-write", error: error)
            throw MacClippyE2ECaptureFixtureFailure(response: MacClippyE2EControlResponse(
                isOK: false,
                errorCode: String(describing: error),
                message: String(String(describing: error).prefix(512))
            ))
        } catch let error as MacClippyObjectiveCException {
            isolation.recordDiagnostic(category: "capture-fixture-native-exception", error: error)
            throw MacClippyE2ECaptureFixtureFailure(response: MacClippyE2EControlResponse(
                isOK: false,
                errorCode: "native-pasteboard-exception",
                message: String((error.errorDescription ?? String(describing: error)).prefix(512))
            ))
        } catch {
            isolation.recordDiagnostic(category: "capture-fixture-write", error: error)
            throw MacClippyE2ECaptureFixtureFailure(response: MacClippyE2EControlResponse(
                isOK: false,
                errorCode: "capture-fixture-write-failed",
                message: String(String(describing: error).prefix(512))
            ))
        }
    }

    private func waitForNewE2ERecord(
        after priorID: String?,
        runtime: MacClippyRuntime,
        timeoutSeconds: Double
    ) async -> MacClippyHistoryEntry? {
        let timeout = max(1, min(timeoutSeconds, 120))
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if let entries = try? runtime.history(limit: 1, query: ""),
               let newest = entries.first,
               newest.id.rawValue != priorID {
                return newest
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

}
#endif
