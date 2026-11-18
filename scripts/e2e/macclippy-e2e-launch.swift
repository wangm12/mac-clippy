import AppKit
import Foundation
import Darwin

private final class LaunchResult: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (pid: Int32, bundleIdentifier: String?)?
    private var failure: String?

    func set(application: NSRunningApplication?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        if let application {
            stored = (application.processIdentifier, application.bundleIdentifier)
        } else {
            failure = error.map { String(describing: $0) } ?? "application-launch-returned-no-process"
        }
    }

    func value() -> ((pid: Int32, bundleIdentifier: String?)?, String?) {
        lock.lock()
        defer { lock.unlock() }
        return (stored, failure)
    }
}

guard CommandLine.arguments.count == 4 else {
    fputs("usage: macclippy-e2e-launch.swift APP_BUNDLE ROOT RUN_ID\n", stderr)
    exit(64)
}

let appURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let root = CommandLine.arguments[2]
let runID = CommandLine.arguments[3]
var launchEnvironment = [
    "MACCLIPPY_E2E_ROOT": root,
    "MACCLIPPY_E2E_RUN_ID": runID
]
if let rawRetentionMaxItems = ProcessInfo.processInfo.environment["MACCLIPPY_E2E_RETENTION_MAX_ITEMS"] {
    guard !rawRetentionMaxItems.isEmpty,
          rawRetentionMaxItems.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
          let retentionMaxItems = Int(rawRetentionMaxItems),
          (1...200_000).contains(retentionMaxItems) else {
        fputs("invalid MACCLIPPY_E2E_RETENTION_MAX_ITEMS (expected an integer from 1 through 200000)\n", stderr)
        exit(64)
    }
    launchEnvironment["MACCLIPPY_E2E_RETENTION_MAX_ITEMS"] = String(retentionMaxItems)
}
let configuration = NSWorkspace.OpenConfiguration()
configuration.promptsUserIfNeeded = false
configuration.activates = false
configuration.hides = true
configuration.hidesOthers = false
configuration.addsToRecentItems = false
configuration.createsNewApplicationInstance = true
configuration.allowsRunningApplicationSubstitution = false
configuration.environment = launchEnvironment

let semaphore = DispatchSemaphore(value: 0)
private let result = LaunchResult()
NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
    result.set(application: application, error: error)
    semaphore.signal()
}
guard semaphore.wait(timeout: .now() + 45) == .success else {
    fputs("isolated E2E app launch timed out\n", stderr)
    exit(1)
}
let (application, failure) = result.value()
guard let application else {
    fputs("isolated E2E app launch failed: \(failure ?? "unknown-error")\n", stderr)
    exit(1)
}
let output: [String: Any] = [
    "pid": Int(application.pid),
    "bundleIdentifier": application.bundleIdentifier ?? "unknown"
]
do {
    let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
} catch {
    fputs("isolated E2E app launch result encoding failed\n", stderr)
    exit(1)
}
