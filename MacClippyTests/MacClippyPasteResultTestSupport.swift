import AppKit
import Foundation
import MacClippyCore
import MacClippyPlatform

/// Keeps app integration tests away from the user's general pasteboard and
/// prevents either event-posting path from reaching macOS event taps.
final class MacClippyAppTestPasteboardEnvironment {
    private let defaultsSuiteName: String
    let pasteboard: NSPasteboard
    let observer: MacClippyPasteboardObserver
    let injector: MacClippyPasteInjector
    let preferencesDefaults: UserDefaults

    init(label: String, sourceAppBundleID: @escaping () -> String? = { nil }) {
        defaultsSuiteName = "MacClippyTests.\(label).\(UUID().uuidString)"
        preferencesDefaults = UserDefaults(suiteName: defaultsSuiteName)!
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("\(label)-\(UUID().uuidString)")
        )
        self.pasteboard = pasteboard
        observer = PasteboardObserver(
            reader: MacClippySystemPasteboardReader(
                pasteboard: pasteboard,
                sourceAppBundleID: sourceAppBundleID
            ),
            exclusionRules: MacClippyCaptureExclusionRules(
                excludedAppBundleIDs: [],
                captureAll: true
            ),
            pollInterval: 60
        )
        injector = MacClippyPasteInjector(
            pasteboard: pasteboard,
            isProcessTrusted: { true },
            postEvents: { _, _ in },
            postEventsToProcess: { _, _, _ in }
        )
    }

    deinit {
        preferencesDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }
}

/// Synchronizes the injector hooks used by app integration tests. Counting a
/// callback here records an event pair handed to the injected poster; it does
/// not assert that a recipient application consumed the paste.
final class MacClippyPasteTestControl: @unchecked Sendable {
    private let lock = NSLock()
    private var trusted = true
    private var cancelled = false
    private var postedEventPairs = 0
    private var destinationPID: Int32?

    var postedProcessIdentifier: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return destinationPID
    }

    var isTrusted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return trusted
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var postedEventPairCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return postedEventPairs
    }

    func setTrusted(_ value: Bool) {
        lock.lock()
        trusted = value
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func recordPostedEventPair(processIdentifier: Int32? = nil) {
        lock.lock()
        postedEventPairs += 1
        destinationPID = processIdentifier
        lock.unlock()
    }
}

@MainActor
final class MacClippyPasteTestCompletion {
    var wasCalled = false
}
