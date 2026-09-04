import AppKit
import Carbon.HIToolbox
import XCTest

@testable import MacClippy
import MacClippyCore
import MacClippyPlatform

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

    func testTimedPauseWritesAnExpiryAndIgnoreNextCopyHasADefaultShortcut() throws {
        let suiteName = "MacClippyTimedPauseTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 5_000)
        MacClippyRetentionPreferences.applyPause(
            enabled: true,
            duration: .fiveMinutes,
            now: now,
            defaults: defaults
        )
        XCTAssertTrue(defaults.bool(forKey: MacClippyRetentionPreferences.privacyPauseKey))
        XCTAssertEqual(
            MacClippyRetentionPreferences.pauseUntil(from: defaults),
            now.addingTimeInterval(5 * 60)
        )
        XCTAssertEqual(MacClippyRetentionPreferences.pauseDuration(from: defaults), .fiveMinutes)
        XCTAssertEqual(
            MacClippyGlobalHotKeyDescriptor.defaultIgnoreNextCopy.modifiers,
            UInt32(cmdKey) | UInt32(optionKey) | UInt32(shiftKey)
        )
    }

    func testBackupSettingsCopyUsesTheSharedPolicy() {
        XCTAssertTrue(
            MacClippyBackupSettingsPolicy.suggestedFolderName().hasPrefix("MacClippy-Backup-")
        )
        XCTAssertEqual(
            MacClippyBackupSettingsPolicy.message(for: .invalidManifest),
            "This folder is not a valid MacClippy backup."
        )
        XCTAssertEqual(
            MacClippyBackupSettingsPolicy.createSuccessMessage(databaseCount: 4),
            "Backup created with 4 databases."
        )
    }

    func testAlwaysPastePlainTextDefaultsOffAndShiftInvertsIt() throws {
        let suiteName = "MacClippyAlwaysPastePlain-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(MacClippyRetentionPreferences.alwaysPastePlainText(from: defaults))
        XCTAssertFalse(MacClippyRetentionPreferences.shouldPastePlain(shiftHeld: false, defaults: defaults))
        XCTAssertTrue(MacClippyRetentionPreferences.shouldPastePlain(shiftHeld: true, defaults: defaults))

        defaults.set(true, forKey: MacClippyRetentionPreferences.alwaysPastePlainTextKey)
        XCTAssertTrue(MacClippyRetentionPreferences.alwaysPastePlainText(from: defaults))
        XCTAssertTrue(MacClippyRetentionPreferences.shouldPastePlain(shiftHeld: false, defaults: defaults))
        XCTAssertFalse(MacClippyRetentionPreferences.shouldPastePlain(shiftHeld: true, defaults: defaults))
    }

    func testDefaultRetentionPolicyExposesTenThousandItemsTwoGigabyteImagesAndFourGigabyteTotal() throws {
        let suiteName = "MacClippyStorageCapTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let policy = MacClippyRetentionPreferences.policy(from: defaults)
        XCTAssertEqual(policy.maxItems, MacClippyStorageCapPolicy.defaultMaxItems)
        XCTAssertEqual(
            policy.maxImageBytes,
            MacClippyStorageCapPolicy.defaultMaxImageMegabytes * 1_024 * 1_024
        )
        XCTAssertEqual(
            policy.maxTotalBytes,
            MacClippyStorageCapPolicy.defaultMaxHistoryMegabytes * 1_024 * 1_024
        )
        XCTAssertFalse(MacClippyStorageCapPolicy.exposesSettingsEditors)
        XCTAssertTrue(MacClippyStorageCapPolicy.rows().isEmpty)
        defaults.set(250, forKey: MacClippyRetentionPreferences.maxItemsKey)
        defaults.set(10, forKey: MacClippyRetentionPreferences.maxAgeDaysKey)
        let leftover = MacClippyRetentionPreferences.policy(from: defaults)
        XCTAssertEqual(leftover.maxItems, MacClippyStorageCapPolicy.defaultMaxItems)
        XCTAssertEqual(leftover.maxAge, TimeInterval(7) * 86_400)

        XCTAssertEqual(
            MacClippyStorageDashboardPolicy.rows(
                from: MacClippyStorageUsage(
                    itemCount: 0,
                    imageBytes: 0,
                    totalBytes: 0,
                    maxItems: MacClippyStorageCapPolicy.defaultMaxItems,
                    maxImageBytes: Int64(MacClippyStorageCapPolicy.defaultMaxImageMegabytes) * 1_024 * 1_024,
                    maxTotalBytes: Int64(MacClippyStorageCapPolicy.defaultMaxHistoryMegabytes) * 1_024 * 1_024
                )
            ).map(\.title),
            ["Items in library", "Images", "On disk"]
        )
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

    func testAppPickerPersistsChosenBundleIDsWithoutReplacingBuiltIns() throws {
        let suiteName = "MacClippyAppPickerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let stored = MacClippyExclusionAppPickerPolicy.add("com.example.Editor", to: "")
        defaults.set(stored, forKey: MacClippyRetentionPreferences.excludedAppsKey)

        let rules = MacClippyRetentionPreferences.exclusionRules(from: defaults)
        XCTAssertEqual(stored, "com.example.editor")
        XCTAssertTrue(rules.shouldExclude(appBundleID: "com.example.editor", pasteboardTypes: []))
        XCTAssertTrue(rules.shouldExclude(appBundleID: "com.agilebits.onepassword7", pasteboardTypes: []))

        defaults.set(
            MacClippyExclusionAppPickerPolicy.remove("com.example.editor", from: stored),
            forKey: MacClippyRetentionPreferences.excludedAppsKey
        )
        let afterRemove = MacClippyRetentionPreferences.exclusionRules(from: defaults)
        XCTAssertFalse(afterRemove.shouldExclude(appBundleID: "com.example.editor", pasteboardTypes: []))
        XCTAssertTrue(afterRemove.shouldExclude(appBundleID: "com.1password.1password", pasteboardTypes: []))
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

    func testDefaultExclusionRulesKeepUniversalClipboardText() throws {
        let suiteName = "MacClippySettingsRemoteClipboard-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rules = MacClippyRetentionPreferences.exclusionRules(from: defaults)
        XCTAssertFalse(
            rules.shouldExclude(
                appBundleID: "com.apple.Safari",
                pasteboardTypes: [
                    CaptureExclusionRules.remoteClipboardPasteboardType,
                    "public.utf8-plain-text"
                ]
            )
        )
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
        XCTAssertTrue(
            MacClippyHotKeyRecordingPolicy.shouldRestoreSecondaryHotKey(
                wasRegisteredBeforeRecording: true,
                didStart: true
            )
        )
        XCTAssertFalse(
            MacClippyHotKeyRecordingPolicy.shouldRestoreSecondaryHotKey(
                wasRegisteredBeforeRecording: false,
                didStart: true
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
        XCTAssertTrue(MacClippyPermissionTrustPolicy.permissionsCanPersist(.namedSigned))
        XCTAssertFalse(MacClippyPermissionTrustPolicy.permissionsCanPersist(.adhoc))
        XCTAssertFalse(MacClippyPermissionTrustPolicy.permissionsCanPersist(.unsigned))
    }

    func testPermissionTrustPersistsForNamedSelfSignedCopy() {
        let kind = MacClippyPermissionTrustPolicy.kind(
            isSigned: true,
            isAdhoc: false,
            teamID: nil
        )
        XCTAssertEqual(kind, .namedSigned)
        XCTAssertTrue(MacClippyPermissionTrustPolicy.permissionsCanPersist(kind))
    }

    func testPermissionTrustExplainsUnsignedDMGCopies() {
        let message = MacClippyPermissionTrustPolicy.unsignedCopyExplanation()
        XCTAssertTrue(message.contains("unsigned"))
        XCTAssertTrue(message.contains("make dmg"))
        XCTAssertTrue(message.contains("/Applications/MacClippy.app"))
        XCTAssertFalse(message.contains("Apple Development"))
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
        coordinator.notePendingBringToFront()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )

        coordinator.register(window)

        XCTAssertIdentical(coordinator.lastBroughtToFrontWindow, window)
    }
}
