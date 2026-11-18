#if MACCLIPPY_E2E
import AppKit
import CryptoKit
import Foundation
import MacClippyCore
@_spi(Testing) import MacClippyPlatform

private struct MacClippyE2EPasteProbeSnapshot {
    let result: MacClippyPasteInjectionResult?
    let eventPairCount: Int
    let completionCount: Int
}

private struct MacClippyE2EPasteProbeOutcome {
    let snapshot: MacClippyE2EPasteProbeSnapshot
    let representations: [MacClippyE2EPasteboardProof]
    let secondRepresentations: [MacClippyE2EPasteboardProof]
    let reachedAdmission: Bool
    let contentPreserved: Bool
    let passed: Bool
}

private struct MacClippyE2EProbeBoards {
    let expected: NSPasteboard
    let cancellation: NSPasteboard
    let foreign: NSPasteboard
    let admitted: NSPasteboard
    let originalProofs: [MacClippyE2EPasteboardProof]

    func releaseAll() {
        expected.releaseGlobally()
        cancellation.releaseGlobally()
        foreign.releaseGlobally()
        admitted.releaseGlobally()
    }
}

private final class MacClippyE2EPasteInjectionProbeState: @unchecked Sendable {
    let admissionReached = DispatchSemaphore(value: 0)
    let releaseAdmission = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var result: MacClippyPasteInjectionResult?
    private var eventPairCount = 0
    private var completionCount = 0

    func notePostedEventPair() {
        lock.lock()
        eventPairCount += 1
        lock.unlock()
    }

    func noteCompletion() {
        lock.lock()
        completionCount += 1
        lock.unlock()
    }

    func finish(_ result: MacClippyPasteInjectionResult) {
        lock.lock()
        self.result = result
        lock.unlock()
        completed.signal()
    }

    func snapshot() -> MacClippyE2EPasteProbeSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return MacClippyE2EPasteProbeSnapshot(
            result: result,
            eventPairCount: eventPairCount,
            completionCount: completionCount
        )
    }
}

private typealias ProbePasteboardItems = [[(type: String, data: Data)]]

@MainActor
extension AppDelegate {
    func pasteInjectionE2EProbe() -> MacClippyE2EControlResponse {
        guard let boards = makeProbeBoards() else { return failedProbe("paste-probe-setup-failed") }
        defer { boards.releaseAll() }
        let cancellation = runCancellationProbe(on: boards.cancellation, expected: boards.originalProofs)
        let foreign = runForeignGenerationProbe(on: boards.foreign)
        let admitted = runAdmittedProbe(on: boards.admitted)
        let allPassed = hasOriginalMultiUTIShape(boards.originalProofs)
            && cancellation.passed
            && foreign.passed
            && admitted.passed
        let evidence = MacClippyE2EPasteProbeEvidence(
            cancellationResult: String(describing: cancellation.snapshot.result),
            cancellationReachedAdmission: cancellation.reachedAdmission,
            cancellationPostedEventPairs: cancellation.snapshot.eventPairCount,
            cancellationRestoredOriginals: cancellation.contentPreserved,
            foreignGenerationResult: String(describing: foreign.snapshot.result),
            foreignGenerationReachedAdmission: foreign.reachedAdmission,
            foreignGenerationPostedEventPairs: foreign.snapshot.eventPairCount,
            foreignGenerationPreserved: foreign.contentPreserved,
            admittedResult: String(describing: admitted.snapshot.result),
            admittedPostedEventPairs: admitted.snapshot.eventPairCount,
            admittedCompletionCount: admitted.snapshot.completionCount,
            admittedPreparedClipboardLeftInPlace: admitted.contentPreserved,
            originalRepresentations: boards.originalProofs,
            cancellationRepresentations: cancellation.representations,
            foreignRepresentations: foreign.representations,
            postRaceForeignRepresentations: foreign.secondRepresentations,
            admittedRepresentations: admitted.representations,
            namedPasteboardsOnly: true,
            realKeyEventsPosted: false,
            allPassed: allPassed
        )
        return MacClippyE2EControlResponse(
            isOK: allPassed,
            errorCode: allPassed ? nil : "paste-injection-probe-failed",
            pasteResult: "isolated-injected-event-sink-probe",
            pasteInjectionProbe: evidence
        )
    }

    private func makeProbeBoards() -> MacClippyE2EProbeBoards? {
        var created: [NSPasteboard] = []
        var transferred = false
        defer {
            if !transferred { created.forEach { $0.releaseGlobally() } }
        }
        guard let expected = makeProbePasteboard() else { return nil }
        created.append(expected)
        guard let cancellation = makeProbePasteboard() else { return nil }
        created.append(cancellation)
        guard let foreign = makeProbePasteboard() else { return nil }
        created.append(foreign)
        guard let admitted = makeProbePasteboard() else { return nil }
        created.append(admitted)
        let original = originalProbeRepresentations()
        guard let originalProofs = writeProbePasteboard(original, to: expected),
              writeProbePasteboard(original, to: cancellation) != nil,
              writeProbePasteboard(original, to: foreign) != nil,
              writeProbePasteboard(original, to: admitted) != nil else {
            return nil
        }
        transferred = true
        return MacClippyE2EProbeBoards(
            expected: expected,
            cancellation: cancellation,
            foreign: foreign,
            admitted: admitted,
            originalProofs: originalProofs
        )
    }

    private func runCancellationProbe(
        on pasteboard: NSPasteboard,
        expected: [MacClippyE2EPasteboardProof]
    ) -> MacClippyE2EPasteProbeOutcome {
        let gate = MacClippyPasteInjectionGate()
        let state = MacClippyE2EPasteInjectionProbeState()
        let injector = makeProbeInjector(pasteboard: pasteboard, state: state, holdAtAdmission: true)
        startProbeInjection(injector, gate: gate, state: state)
        let reachedAdmission = state.admissionReached.wait(timeout: .now() + 3) == .success
        if reachedAdmission { gate.close() }
        state.releaseAdmission.signal()
        let completed = state.completed.wait(timeout: .now() + 3) == .success
        let snapshot = state.snapshot()
        let actual = pasteboardEvidence(pasteboard)
        let restored = actual.map { $0 == expected } ?? false
        let passed = reachedAdmission
            && completed
            && snapshot.result == .cancelled
            && snapshot.eventPairCount == 0
            && snapshot.completionCount == 0
            && restored
        return MacClippyE2EPasteProbeOutcome(
            snapshot: snapshot,
            representations: actual ?? [],
            secondRepresentations: [],
            reachedAdmission: reachedAdmission,
            contentPreserved: restored,
            passed: passed
        )
    }

    private func runForeignGenerationProbe(
        on pasteboard: NSPasteboard
    ) -> MacClippyE2EPasteProbeOutcome {
        let gate = MacClippyPasteInjectionGate()
        let state = MacClippyE2EPasteInjectionProbeState()
        let injector = makeProbeInjector(pasteboard: pasteboard, state: state, holdAtAdmission: true)
        startProbeInjection(injector, gate: gate, state: state)
        let reachedAdmission = state.admissionReached.wait(timeout: .now() + 3) == .success
        var writeSucceeded = false
        var beforeRace: [MacClippyE2EPasteboardProof]?
        if reachedAdmission {
            gate.close()
            let foreignItem = NSPasteboardItem()
            let didSet = (try? MacClippyNativePasteboard.set(
                "foreign generation",
                on: foreignItem,
                forType: .string
            )) == true
            let didClear = (try? MacClippyNativePasteboard.clear(pasteboard)) != nil
            writeSucceeded = didSet && didClear
                && ((try? MacClippyNativePasteboard.write([foreignItem], to: pasteboard)) == true)
            beforeRace = pasteboardEvidence(pasteboard)
        }
        state.releaseAdmission.signal()
        let completed = state.completed.wait(timeout: .now() + 3) == .success
        let snapshot = state.snapshot()
        let afterRace = pasteboardEvidence(pasteboard)
        let expectedForeign = proofForForeignGeneration()
        let preserved = writeSucceeded && beforeRace == expectedForeign && afterRace == expectedForeign
        let passed = reachedAdmission
            && completed
            && snapshot.result == .failed(.clipboardChanged)
            && snapshot.eventPairCount == 0
            && preserved
        return MacClippyE2EPasteProbeOutcome(
            snapshot: snapshot,
            representations: beforeRace ?? [],
            secondRepresentations: afterRace ?? [],
            reachedAdmission: reachedAdmission,
            contentPreserved: preserved,
            passed: passed
        )
    }

    private func runAdmittedProbe(on pasteboard: NSPasteboard) -> MacClippyE2EPasteProbeOutcome {
        let state = MacClippyE2EPasteInjectionProbeState()
        let injector = makeProbeInjector(pasteboard: pasteboard, state: state, holdAtAdmission: false)
        startProbeInjection(injector, gate: MacClippyPasteInjectionGate(), state: state)
        let completed = state.completed.wait(timeout: .now() + 3) == .success
        let snapshot = state.snapshot()
        let actual = pasteboardEvidence(pasteboard)
        let prepared = actual == expectedPreparedProof()
        let passed = completed
            && snapshot.result == .injected
            && snapshot.eventPairCount == 1
            && snapshot.completionCount == 1
            && prepared
        return MacClippyE2EPasteProbeOutcome(
            snapshot: snapshot,
            representations: actual ?? [],
            secondRepresentations: [],
            reachedAdmission: true,
            contentPreserved: prepared,
            passed: passed
        )
    }

    private func makeProbePasteboard() -> NSPasteboard? {
        NSPasteboard(name: NSPasteboard.Name("MacClippyG6PasteProbe-\(UUID().uuidString)"))
    }

    private func makeProbeInjector(
        pasteboard: NSPasteboard,
        state: MacClippyE2EPasteInjectionProbeState,
        holdAtAdmission: Bool
    ) -> MacClippyPasteInjector {
        let injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in state.notePostedEventPair() }
        )
        if holdAtAdmission {
            injector.setPreEventAdmissionHookForTesting {
                state.admissionReached.signal()
                state.releaseAdmission.wait()
            }
        }
        return injector
    }

    private func startProbeInjection(
        _ injector: MacClippyPasteInjector,
        gate: MacClippyPasteInjectionGate,
        state: MacClippyE2EPasteInjectionProbeState
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = injector.inject(
                text: "g6-admitted-replacement",
                afterPasteEvents: { state.noteCompletion() },
                gate: gate
            )
            state.finish(result)
        }
    }

    private func writeProbePasteboard(
        _ representations: ProbePasteboardItems,
        to pasteboard: NSPasteboard
    ) -> [MacClippyE2EPasteboardProof]? {
        guard let existingItems = try? MacClippyNativePasteboard.items(of: pasteboard) else { return nil }
        if !existingItems.isEmpty, (try? MacClippyNativePasteboard.clear(pasteboard)) == nil { return nil }
        let items = representations.compactMap(makeProbePasteboardItem)
        guard items.count == representations.count,
              (try? MacClippyNativePasteboard.write(items, to: pasteboard)) == true else { return nil }
        return pasteboardEvidence(pasteboard)
    }

    private func makeProbePasteboardItem(
        _ representations: [(type: String, data: Data)]
    ) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        for representation in representations {
            guard (try? MacClippyNativePasteboard.set(
                representation.data,
                on: item,
                forType: NSPasteboard.PasteboardType(representation.type)
            )) == true else { return nil }
        }
        return item
    }

    private func pasteboardEvidence(
        _ pasteboard: NSPasteboard
    ) -> [MacClippyE2EPasteboardProof]? {
        guard let items = try? MacClippyNativePasteboard.items(of: pasteboard) else { return nil }
        var proofs: [MacClippyE2EPasteboardProof] = []
        for (itemIndex, item) in items.enumerated() {
            guard let types = try? MacClippyNativePasteboard.types(of: item) else { return nil }
            for rawType in types.sorted() {
                let type = NSPasteboard.PasteboardType(rawValue: rawType)
                guard let data = try? MacClippyNativePasteboard.data(from: item, forType: type) else { return nil }
                proofs.append(MacClippyE2EPasteboardProof(
                    itemIndex: itemIndex,
                    uti: rawType,
                    byteCount: data.count,
                    sha256: Self.probeSHA256(data)
                ))
            }
        }
        return proofs
    }

    private func originalProbeRepresentations() -> ProbePasteboardItems {
        [
            [
                (NSPasteboard.PasteboardType.string.rawValue, Data("original text".utf8)),
                (NSPasteboard.PasteboardType.html.rawValue, Data("<p>original text</p>".utf8))
            ],
            [("com.example.macclippy-g6-original", Data([0x00, 0x81, 0xFE]))]
        ]
    }

    private func proofForForeignGeneration() -> [MacClippyE2EPasteboardProof] {
        [proof(
            itemIndex: 0,
            type: NSPasteboard.PasteboardType.string.rawValue,
            data: Data("foreign generation".utf8)
        )]
    }

    private func expectedPreparedProof() -> [MacClippyE2EPasteboardProof] {
        [proof(
            itemIndex: 0,
            type: NSPasteboard.PasteboardType.string.rawValue,
            data: Data("g6-admitted-replacement".utf8)
        )]
    }

    private func proof(itemIndex: Int, type: String, data: Data) -> MacClippyE2EPasteboardProof {
        MacClippyE2EPasteboardProof(
            itemIndex: itemIndex,
            uti: type,
            byteCount: data.count,
            sha256: Self.probeSHA256(data)
        )
    }

    private func hasOriginalMultiUTIShape(_ proofs: [MacClippyE2EPasteboardProof]) -> Bool {
        let expected = [
            proof(
                itemIndex: 0,
                type: NSPasteboard.PasteboardType.html.rawValue,
                data: Data("<p>original text</p>".utf8)
            ),
            proof(
                itemIndex: 0,
                type: NSPasteboard.PasteboardType.string.rawValue,
                data: Data("original text".utf8)
            ),
            proof(
                itemIndex: 1,
                type: "com.example.macclippy-g6-original",
                data: Data([0x00, 0x81, 0xFE])
            )
        ]
        return proofs == expected
    }

    private func failedProbe(_ errorCode: String) -> MacClippyE2EControlResponse {
        MacClippyE2EControlResponse(isOK: false, errorCode: errorCode)
    }

    private static func probeSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
