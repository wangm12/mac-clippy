import XCTest

@testable import MacClippy

final class MacClippyE2EBuildIdentityTests: XCTestCase {
    func testShippingBuildRejectsE2EBundleIdentifierBeforeStartup() {
        XCTAssertFalse(
            MacClippyE2EBuildIdentity.allowsStartup(
                bundleIdentifier: MacClippyE2EBuildIdentity.bundleIdentifier,
                e2eFlagEnabled: false
            )
        )
        XCTAssertTrue(
            MacClippyE2EBuildIdentity.allowsStartup(
                bundleIdentifier: "com.macallyouneed.macclippy",
                e2eFlagEnabled: false
            )
        )
    }

    func testE2EBuildRequiresTheExactIsolatedBundleIdentifier() {
        XCTAssertTrue(
            MacClippyE2EBuildIdentity.allowsStartup(
                bundleIdentifier: MacClippyE2EBuildIdentity.bundleIdentifier,
                e2eFlagEnabled: true
            )
        )
        XCTAssertFalse(
            MacClippyE2EBuildIdentity.allowsStartup(
                bundleIdentifier: "com.macallyouneed.macclippy",
                e2eFlagEnabled: true
            )
        )
    }

    func testE2ERetentionConfigurationKeepsCorpusDefaultAndAcceptsSoakCap() throws {
        XCTAssertEqual(
            try MacClippyE2ERetentionConfiguration.maximumItems(environment: [:]),
            200_000
        )
        XCTAssertEqual(
            try MacClippyE2ERetentionConfiguration.maximumItems(
                environment: ["MACCLIPPY_E2E_RETENTION_MAX_ITEMS": "10000"]
            ),
            10_000
        )
        XCTAssertEqual(
            try MacClippyE2ERetentionConfiguration.maximumItems(
                environment: ["MACCLIPPY_E2E_RETENTION_MAX_ITEMS": "200000"]
            ),
            200_000
        )
    }

    func testE2ERetentionConfigurationRejectsInvalidAndOutOfRangeCaps() {
        for rawValue in ["", "0", "-1", "+10", "10000.0", "200001", "nope"] {
            XCTAssertThrowsError(
                try MacClippyE2ERetentionConfiguration.maximumItems(
                    environment: ["MACCLIPPY_E2E_RETENTION_MAX_ITEMS": rawValue]
                ),
                "Unexpectedly accepted retention cap: \(rawValue)"
            )
        }
    }

    @MainActor
    func testSettingsStoreIsUnavailableUntilStartupInstallsTheValidatedSuite() throws {
        let suiteName = "com.macallyouneed.macclippy.tests.settings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("isolated", forKey: "test.value")

        let provider = MacClippySettingsDefaultsProvider()
        XCTAssertNil(provider.defaults)

        provider.install(defaults)

        XCTAssertTrue(provider.defaults === defaults)
        XCTAssertEqual(provider.defaults?.string(forKey: "test.value"), "isolated")
    }
}
