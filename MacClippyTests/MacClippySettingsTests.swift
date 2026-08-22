import AppKit
import XCTest

@testable import MacClippy
import MacClippyCore

private final class MacClippyBooleanStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []

    func append(_ value: Bool) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class MacClippySettingsTests: XCTestCase {
    private struct PresentationCase {
        let hideMenuBar: Bool
        let hideDock: Bool
        let showsMenuBar: Bool
        let policy: NSApplication.ActivationPolicy
    }

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
        let states = MacClippyBooleanStateBox()
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
        XCTAssertEqual(states.snapshot, [true, false])
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

    func testPermissionTrustRequiresATeamSignedCopy() {
        XCTAssertEqual(
            MacClippyPermissionTrustPolicy.kind(isSigned: true, isAdhoc: false, teamID: "ABCDE12345"),
            .teamSigned(teamID: "ABCDE12345")
        )
        XCTAssertEqual(
            MacClippyPermissionTrustPolicy.kind(isSigned: true, isAdhoc: true, teamID: nil),
            .adhoc
        )
        XCTAssertEqual(
            MacClippyPermissionTrustPolicy.kind(isSigned: false, isAdhoc: false, teamID: nil),
            .unsigned
        )
        XCTAssertTrue(
            MacClippyPermissionTrustPolicy.permissionsCanPersist(.teamSigned(teamID: "ABCDE12345"))
        )
        XCTAssertFalse(MacClippyPermissionTrustPolicy.permissionsCanPersist(.adhoc))
        XCTAssertFalse(MacClippyPermissionTrustPolicy.permissionsCanPersist(.unsigned))
    }

    func testPermissionTrustExplainsUnsignedDMGCopies() {
        let message = MacClippyPermissionTrustPolicy.unsignedCopyExplanation()
        XCTAssertTrue(message.contains("unsigned"))
        XCTAssertTrue(message.contains("Apple Development"))
        XCTAssertTrue(message.contains("/Applications/MacClippy.app"))
    }

    func testPresentationPolicyShowsDockIconByDefaultAndCanHideIt() {
        XCTAssertEqual(
            MacClippyPresentationPolicy.activationPolicy(hideDockIcon: false),
            .regular
        )
        XCTAssertEqual(
            MacClippyPresentationPolicy.activationPolicy(hideDockIcon: true),
            .accessory
        )
    }

    func testPresentationPolicyCoversAllMenuBarAndDockCombinations() {
        let cases = [
            PresentationCase(hideMenuBar: false, hideDock: false, showsMenuBar: true, policy: .regular),
            PresentationCase(hideMenuBar: false, hideDock: true, showsMenuBar: true, policy: .accessory),
            PresentationCase(hideMenuBar: true, hideDock: false, showsMenuBar: false, policy: .regular),
            PresentationCase(hideMenuBar: true, hideDock: true, showsMenuBar: false, policy: .accessory)
        ]

        for item in cases {
            let state = MacClippyPresentationPolicy.state(
                hideFromMenuBar: item.hideMenuBar,
                hideDockIcon: item.hideDock
            )
            XCTAssertEqual(state.showsMenuBarIcon, item.showsMenuBar)
            XCTAssertEqual(state.activationPolicy, item.policy)
        }
    }

    @MainActor
    func testSettingsWindowRegisteredAfterBringToFrontRequestIsShown() {
        let coordinator = MacClippySettingsWindowCoordinator()
        coordinator.bringToFront()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        coordinator.register(window)

        XCTAssertTrue(window.isVisible)
    }
}
