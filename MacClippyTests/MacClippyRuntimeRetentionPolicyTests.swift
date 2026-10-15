import Foundation
import XCTest

@testable import MacClippy
import MacClippyCore

final class MacClippyRuntimeRetentionPolicyTests: XCTestCase {
    func testExplicitRetentionOverrideTakesPrecedenceOverPreferences() throws {
        let fixture = try RetentionRuntimeFixture(maxItemsPreference: 1, override: RetentionPolicy(maxItems: 10))
        defer { fixture.close() }

        let records = try (0..<11).map { index in
            try fixture.runtime.appendTestRecord(.text("record \(index)"))
        }

        fixture.enforceRetention()

        let retainedIDs = try fixture.runtime.clipboardStore.list(limit: 10).map(\.id)
        XCTAssertEqual(retainedIDs.count, 10)
        XCTAssertEqual(Set(retainedIDs), Set(records.dropFirst().map(\.id)))
        XCTAssertEqual(try fixture.runtime.storageUsage().maxItems, 10)
    }

    func testNilRetentionOverrideKeepsShippingDefaultCapacity() throws {
        let fixture = try RetentionRuntimeFixture(maxItemsPreference: 1, override: nil)
        defer { fixture.close() }

        _ = try fixture.runtime.appendTestRecord(.text("first"))
        _ = try fixture.runtime.appendTestRecord(.text("second"))

        fixture.enforceRetention()

        XCTAssertEqual(try fixture.runtime.clipboardStore.list(limit: 10).count, 2)
        XCTAssertEqual(
            try fixture.runtime.storageUsage().maxItems,
            MacClippyRetentionPreferences.defaultMaxItems
        )
    }
}

private final class RetentionRuntimeFixture {
    private let rootURL: URL
    private let defaults: UserDefaults
    private let defaultsSuiteName: String
    private let pasteboardEnvironment: MacClippyAppTestPasteboardEnvironment
    let runtime: MacClippyRuntime

    init(maxItemsPreference: Int, override: RetentionPolicy?) throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyRetentionPolicy-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defaultsSuiteName = "MacClippyRetentionPolicy.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.set(maxItemsPreference, forKey: MacClippyRetentionPreferences.maxItemsKey)
        pasteboardEnvironment = MacClippyAppTestPasteboardEnvironment(
            label: "MacClippyRetentionPolicy",
            sourceAppBundleID: { "com.example.macclippy-retention-test" }
        )
        runtime = try MacClippyRuntime(
            paths: MacClippyPaths(rootURL: rootURL),
            observer: pasteboardEnvironment.observer,
            pasteInjector: pasteboardEnvironment.injector,
            retentionPolicyOverride: override,
            enableSnippetExpansion: false,
            preferencesDefaults: defaults
        )
    }

    func enforceRetention() {
        guard let lifecycleToken = runtime.beginLifecycle() else {
            XCTFail("expected a lifecycle token")
            return
        }
        runtime.enforceRetention(for: lifecycleToken)
    }

    func close() {
        runtime.closeForTesting()
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: rootURL)
    }
}
