#if MACCLIPPY_E2E
import AppKit
import CryptoKit
import Foundation
@_spi(Testing) import MacClippyPlatform

@MainActor
final class MacClippyE2ERecipient {
    enum PosterRoute: String {
        case globalFallback
        case processTargeted
    }

    private var nativeHost: MacClippyE2ENativeHost?

    var nativeHostIsVisible: Bool { nativeHost?.isVisible == true }

    func showNativeHost() async -> Bool {
        let host = nativeHost ?? MacClippyE2ENativeHost()
        nativeHost = host
        host.show(text: insertedText)
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if host.isVisible && host.isKeyWindow { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return false
    }

    func hideNativeHost() { nativeHost?.hide() }

    private(set) var insertedText = ""
    private(set) var lastInsertedText = ""
    private(set) var insertedTypes: [String] = []
    private(set) var insertedRepresentations: [MacClippyE2ERepresentationProof] = []
    private(set) var insertionCount = 0
    private(set) var lastPosterRoute: PosterRoute?

    func insertFromPasteboard(
        _ pasteboard: NSPasteboard,
        accessCoordinator: MacClippyPasteboardAccessCoordinator,
        route: PosterRoute
    ) {
        accessCoordinator.withAccess {
            insertFromPasteboardWithoutLock(pasteboard, route: route)
        }
    }

    private func insertFromPasteboardWithoutLock(_ pasteboard: NSPasteboard, route: PosterRoute) {
        let result = pasteboardContents(pasteboard)
        let value = result.text
        insertedRepresentations = result.representations
        insertedText.append(value)
        nativeHost?.display(insertedText)
        lastInsertedText = value
        insertedTypes = Array(Set(insertedRepresentations.map(\.uti))).sorted()
        insertionCount += 1
        lastPosterRoute = route
    }

    private func pasteboardContents(
        _ pasteboard: NSPasteboard
    ) -> (text: String, representations: [MacClippyE2ERepresentationProof]) {
        do {
            let items = try MacClippyNativePasteboard.items(of: pasteboard)
            let representations = try items.enumerated().flatMap { itemIndex, item in
                try representationProofs(for: item, itemIndex: itemIndex)
            }
            return (try pastedText(from: pasteboard), representations)
        } catch {
            return ("", [])
        }
    }

    private func pastedText(from pasteboard: NSPasteboard) throws -> String {
        if let plain = try MacClippyNativePasteboard.string(from: pasteboard, forType: .string) {
            return plain
        }
        if let html = try MacClippyNativePasteboard.data(
            from: pasteboard,
            forType: NSPasteboard.PasteboardType("public.html")
        ), let attributed = try? NSAttributedString(
            data: html,
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: nil
        ) {
            return attributed.string
        }
        if let rtf = try MacClippyNativePasteboard.data(
            from: pasteboard,
            forType: NSPasteboard.PasteboardType("public.rtf")
        ), let attributed = try? NSAttributedString(
            data: rtf,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        ) {
            return attributed.string
        }
        return ""
    }

    private func representationProofs(
        for item: NSPasteboardItem,
        itemIndex: Int
    ) throws -> [MacClippyE2ERepresentationProof] {
        try MacClippyNativePasteboard.types(of: item).sorted().map { rawType in
            let type = NSPasteboard.PasteboardType(rawValue: rawType)
            let payload = try MacClippyNativePasteboard.data(from: item, forType: type)
                ?? (type == .string
                    ? MacClippyNativePasteboard.string(from: item, forType: .string).map { Data($0.utf8) }
                    : nil)
            return MacClippyE2ERepresentationProof(
                itemIndex: itemIndex,
                uti: rawType,
                payloadState: payload == nil ? "unavailable" : "present",
                byteCount: payload?.count,
                sha256: payload.map(Self.sha256)
            )
        }
    }

    func reset() {
        insertedText = ""
        nativeHost?.display("")
        lastInsertedText = ""
        insertedTypes = []
        insertedRepresentations = []
        insertionCount = 0
        lastPosterRoute = nil
    }

    var insertedTextSHA256: String {
        Self.sha256(Data(insertedText.utf8))
    }

    var lastInsertedTextSHA256: String {
        Self.sha256(Data(lastInsertedText.utf8))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

final class MacClippyE2EPasteBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var semaphore = DispatchSemaphore(value: 0)
    private var isArmed = false
    private var waiting = false
    private var wasReleased = false
    private var operationFinished = false
    private var resultLabel: String?
    private var gate: MacClippyPasteInjectionGate?

    func arm(gate: MacClippyPasteInjectionGate) {
        lock.lock()
        semaphore = DispatchSemaphore(value: 0)
        isArmed = true
        waiting = false
        wasReleased = false
        operationFinished = false
        resultLabel = nil
        self.gate = gate
        lock.unlock()
    }

    func waitForTrustCheck() -> Bool {
        lock.lock()
        let shouldWait = isArmed
        let semaphore = self.semaphore
        if shouldWait {
            isArmed = false
            waiting = true
        }
        lock.unlock()
        let released = !shouldWait || semaphore.wait(timeout: .now() + 60) == .success
        lock.lock()
        if shouldWait {
            waiting = false
            wasReleased = released
        }
        lock.unlock()
        return released
    }

    func release() {
        lock.lock()
        let shouldSignal = (isArmed || waiting) && !wasReleased
        isArmed = false
        let gate = self.gate
        let semaphore = self.semaphore
        lock.unlock()
        gate?.close()
        if shouldSignal { semaphore.signal() }
    }

    func complete(result: PasteInjectionResult?) {
        lock.lock()
        resultLabel = Self.label(for: result)
        operationFinished = true
        lock.unlock()
    }

    func waitForCompletion(timeoutSeconds: Double) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(max(timeoutSeconds, 0) * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if operationCompleted { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return operationCompleted
    }

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiting
    }

    var hasReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wasReleased
    }

    var operationCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return operationFinished
    }

    var pasteResult: String? {
        lock.lock()
        defer { lock.unlock() }
        return resultLabel
    }

    private static func label(for result: PasteInjectionResult?) -> String {
        guard let result else { return "failed" }
        switch result {
        case .injected:
            return "injected"
        case .preparedForManualPaste:
            return "prepared-for-manual-paste"
        case .failed:
            return "failed"
        case .cancelled:
            return "cancelled"
        }
    }
}
#endif
