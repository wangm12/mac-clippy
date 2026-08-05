import XCTest

@testable import MacClippy
import MacClippyCore

final class MacClippySettingsTests: XCTestCase {
    func testPrivacyNoticeIsShownOnceAndCanBeAcknowledged() throws {
        let suiteName = "MacClippyPrivacyNoticeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(MacClippyPrivacyNoticePolicy.shouldPresent(defaults: defaults))

        MacClippyPrivacyNoticePolicy.acknowledge(defaults: defaults)

        XCTAssertFalse(MacClippyPrivacyNoticePolicy.shouldPresent(defaults: defaults))
    }

    func testPrivacyNoticeExplainsStoragePermissionsAndFallbacks() {
        let message = MacClippyPrivacyNoticePolicy.message

        XCTAssertTrue(message.contains("encrypted"))
        XCTAssertTrue(message.contains("Accessibility"))
        XCTAssertTrue(message.contains("Input Monitoring"))
        XCTAssertTrue(message.contains("manual paste"))
        XCTAssertTrue(message.contains("Capture All"))
    }

    func testPrivacyNoticeExplainsDeletionAndNetworkBoundaries() {
        let message = MacClippyPrivacyNoticePolicy.message

        XCTAssertTrue(message.contains("Deleting history removes"))
        XCTAssertTrue(message.contains("makes no network calls"))
        XCTAssertTrue(message.contains("formal public privacy-policy URL"))
        XCTAssertFalse(MacClippyPrivacyNoticePolicy.settingsTitle.isEmpty)
    }

    func testExclusionPreferencesKeepPasswordManagerDefaultsAndMergeUserApps() throws {
        let suiteName = "MacClippySettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("com.example.editor", forKey: MacClippyRetentionPreferences.excludedAppsKey)

        let rules = MacClippyRetentionPreferences.exclusionRules(from: defaults)

        XCTAssertTrue(rules.excludedAppBundleIDs.contains("com.agilebits.onepassword7"))
        XCTAssertTrue(rules.excludedAppBundleIDs.contains("com.example.editor"))
        XCTAssertTrue(rules.shouldExclude(appBundleID: "com.agilebits.onepassword7", pasteboardTypes: []))
        XCTAssertTrue(rules.shouldExclude(appBundleID: "com.example.editor", pasteboardTypes: []))
    }

    func testCaptureAllStillPreservesPasswordManagerAppExclusions() throws {
        let suiteName = "MacClippySettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: MacClippyRetentionPreferences.captureAllKey)

        let rules = MacClippyRetentionPreferences.exclusionRules(from: defaults)

        XCTAssertFalse(rules.shouldExclude(appBundleID: nil, pasteboardTypes: ["org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(rules.shouldExclude(appBundleID: "com.bitwarden.desktop", pasteboardTypes: []))
    }

    func testHotKeyRecordingNotificationUsesActiveState() {
        let activeExpectation = expectation(description: "recording starts")
        let inactiveExpectation = expectation(description: "recording stops")
        var states: [Bool] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .macClippyHotKeyRecordingChanged,
            object: nil,
            queue: .main
        ) { notification in
            guard let isActive = notification.userInfo?[MacClippyHotKeyNotificationUserInfo.isActive] as? Bool else {
                return
            }
            states.append(isActive)
            isActive ? activeExpectation.fulfill() : inactiveExpectation.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        NotificationCenter.default.post(
            name: .macClippyHotKeyRecordingChanged,
            object: nil,
            userInfo: [MacClippyHotKeyNotificationUserInfo.isActive: true]
        )
        NotificationCenter.default.post(
            name: .macClippyHotKeyRecordingChanged,
            object: nil,
            userInfo: [MacClippyHotKeyNotificationUserInfo.isActive: false]
        )

        wait(for: [activeExpectation, inactiveExpectation], timeout: 1)
        XCTAssertEqual(states, [true, false])
    }

    func testHotKeyRecordingOnlyRestoresPreviouslyRegisteredHotKey() {
        XCTAssertTrue(
            MacClippyHotKeyRecordingPolicy.shouldRestoreHotKey(
                wasRegisteredBeforeRecording: true,
                didStart: true,
                isCurrentlyRegistered: false
            )
        )
        XCTAssertFalse(
            MacClippyHotKeyRecordingPolicy.shouldRestoreHotKey(
                wasRegisteredBeforeRecording: false,
                didStart: true,
                isCurrentlyRegistered: false
            )
        )
        XCTAssertFalse(
            MacClippyHotKeyRecordingPolicy.shouldRestoreHotKey(
                wasRegisteredBeforeRecording: true,
                didStart: false,
                isCurrentlyRegistered: false
            )
        )
        XCTAssertFalse(
            MacClippyHotKeyRecordingPolicy.shouldRestoreHotKey(
                wasRegisteredBeforeRecording: true,
                didStart: true,
                isCurrentlyRegistered: true
            )
        )
    }
}
