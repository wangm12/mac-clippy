import AppKit
import Carbon
import CoreGraphics
import XCTest

@testable import MacClippyPlatform

final class MacClippyDockInputMethodPolicyTests: XCTestCase {
    func testKeyboardLayoutKeepsPickerOwnedTyping() {
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.letsInputMethodOwnTyping(
                hasMarkedText: false,
                inputSourceType: String(kTISTypeKeyboardLayout)
            )
        )
    }

    func testInputMethodSourceHandsTypingToTheField() {
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.letsInputMethodOwnTyping(
                hasMarkedText: false,
                inputSourceType: String(kTISTypeKeyboardInputMode)
            )
        )
    }

    func testMarkedTextHandsTypingToTheFieldEvenOnAKeyboardLayout() {
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.letsInputMethodOwnTyping(
                hasMarkedText: true,
                inputSourceType: String(kTISTypeKeyboardLayout)
            )
        )
    }

    func testSearchOverlayStaysAboveTheDockForFocusAndComposition() {
        let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
        let picker = MacClippyDockInputMethodPolicy.overlayLevel(
            allowsInputMethodCandidates: false
        )
        let composing = MacClippyDockInputMethodPolicy.overlayLevel(
            allowsInputMethodCandidates: true
        )
        let composingWithCandidates = MacClippyDockInputMethodPolicy.overlayLevel(
            allowsInputMethodCandidates: true,
            inputMethodCandidateLayers: [20, 25]
        )
        XCTAssertEqual(picker, .mainMenu)
        XCTAssertEqual(composing, .mainMenu)
        XCTAssertEqual(composingWithCandidates, .mainMenu)
        XCTAssertGreaterThan(picker.rawValue, dockLayer)
        XCTAssertGreaterThan(composing.rawValue, dockLayer)
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.usesFloatingPanel(allowsInputMethodCandidates: true)
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.usesFloatingPanel(allowsInputMethodCandidates: false)
        )
        XCTAssertFalse(MacClippyDockInputMethodPolicy.shouldAdjustOverlayForComposition())
        XCTAssertTrue(MacClippyDockInputMethodPolicy.shouldReassertOverlayAfterBecomingKey())
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.shouldReorderOverlayInFrontOfInputMethod(
                allowsInputMethodCandidates: true,
                ownershipAttempt: 0
            )
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.shouldReorderOverlayInFrontOfInputMethod(
                allowsInputMethodCandidates: true,
                ownershipAttempt: 1
            )
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.shouldReorderOverlayInFrontOfInputMethod(
                allowsInputMethodCandidates: false,
                ownershipAttempt: 1
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldReapplySearchOverlayOnKeyEvent()
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.allowsPickerOverlayRestore(hasMarkedText: true)
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.allowsPickerOverlayRestore(hasMarkedText: false)
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldRefreshInputMethodWindowLevel(
                overlayChanged: true,
                allowsInputMethodCandidates: true
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldRefreshInputMethodWindowLevel(
                overlayChanged: false,
                allowsInputMethodCandidates: true
            )
        )
        XCTAssertTrue(MacClippyDockInputMethodPolicy.isInputMethodCandidateWindow(
            owner: "SCIM",
            name: ""
        ))
        XCTAssertTrue(MacClippyDockInputMethodPolicy.isInputMethodCandidateWindow(
            owner: "Simplified Chinese Input Method",
            name: ""
        ))
        XCTAssertTrue(MacClippyDockInputMethodPolicy.isInputMethodCandidateWindow(
            owner: "SCIM_Extension",
            name: "Candidate"
        ))
        XCTAssertFalse(MacClippyDockInputMethodPolicy.isInputMethodCandidateWindow(
            owner: "MacClippy",
            name: "Dock"
        ))
    }

    func testSearchActivatesTheAppSoInputMethodCanJoinTheFullscreenSpace() {
        // Maccy stays nonactivating. `NSApp.activate` assigns system
        // Pinyin to the app's home (desktop) Space while the panel is
        // only painted onto the fullscreen Space via canJoinAllSpaces.
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldActivateApplication(
                isSearchMode: true,
                hostIsFullscreen: true
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldActivateApplication(
                isSearchMode: true,
                hostIsFullscreen: false
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldActivateApplication(isSearchMode: false)
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldActivateIgnoringOtherApps(
                isSearchMode: true,
                hostIsFullscreen: true
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldActivateIgnoringOtherApps(
                isSearchMode: true,
                hostIsFullscreen: false
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldActivateIgnoringOtherApps(isSearchMode: false)
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.shouldYieldOverlayToInputMethodCandidates(
                isSearchMode: true,
                hostIsFullscreen: true
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldYieldOverlayToInputMethodCandidates(
                isSearchMode: true,
                hostIsFullscreen: false
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldYieldOverlayToInputMethodCandidates(
                isSearchMode: false,
                hostIsFullscreen: true
            )
        )
        let dockLayer = Int(CGWindowLevelForKey(.dockWindow))
        let fullscreenSearch = MacClippyDockInputMethodPolicy.overlayLevel(
            allowsInputMethodCandidates: true,
            hostIsFullscreen: true
        )
        // Cherry Studio measured SCIM's bar at a fixed layer 20. Only
        // `.floating` (3) revealed it; status/mainMenu/screenSaver did not.
        XCTAssertEqual(fullscreenSearch, .floating)
        XCTAssertLessThan(fullscreenSearch.rawValue, 20)
        XCTAssertLessThan(fullscreenSearch.rawValue, dockLayer)
        XCTAssertEqual(
            MacClippyDockInputMethodPolicy.overlayLevel(
                allowsInputMethodCandidates: false,
                hostIsFullscreen: true
            ),
            .mainMenu
        )
        XCTAssertEqual(
            MacClippyDockInputMethodPolicy.overlayLevel(
                allowsInputMethodCandidates: true,
                hostIsFullscreen: false
            ),
            .mainMenu
        )
        let fullscreenBehavior = MacClippyDockInputMethodPolicy.collectionBehavior(
            hostIsFullscreen: true
        )
        let desktopBehavior = MacClippyDockInputMethodPolicy.collectionBehavior(
            hostIsFullscreen: false
        )
        XCTAssertTrue(fullscreenBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(fullscreenBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(fullscreenBehavior.contains(.canJoinAllApplications))
        XCTAssertFalse(fullscreenBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(desktopBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(desktopBehavior.contains(.fullScreenAuxiliary))
        XCTAssertFalse(desktopBehavior.contains(.moveToActiveSpace))
        XCTAssertTrue(MacClippyDockInputMethodPolicy.shouldActivateInputContextForFullscreenSearch())
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldInspectCandidateWindowsOnKeyEvent()
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.shouldRestoreHostApplication(
                leavingSearch: true,
                isHiding: false
            )
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.shouldRestoreHostApplication(
                leavingSearch: false,
                isHiding: true
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldRestoreHostApplication(
                leavingSearch: false,
                isHiding: false
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldRestoreHostApplication(
                leavingSearch: true,
                isHiding: false,
                didStealActivation: false
            )
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.shouldRestoreHostApplication(
                leavingSearch: false,
                isHiding: true,
                didStealActivation: false
            )
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.shouldRestoreHostApplication(
                leavingSearch: false,
                isHiding: true,
                hideReason: .command
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldRestoreHostApplication(
                leavingSearch: false,
                isHiding: true,
                hideReason: .outsideClick
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldRestoreHostApplication(
                leavingSearch: true,
                isHiding: true,
                didStealActivation: true,
                hideReason: .outsideClick
            )
        )
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.isFullscreenHost(
                hostPID: 42,
                windows: [[
                    kCGWindowOwnerPID as String: 42,
                    kCGWindowBounds as String: [
                        "X": 0, "Y": 0, "Width": 1920, "Height": 1080,
                    ],
                ]],
                screens: [screen]
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.isFullscreenHost(
                hostPID: 42,
                windows: [[
                    kCGWindowOwnerPID as String: 42,
                    kCGWindowBounds as String: [
                        "X": 80, "Y": 80, "Width": 1400, "Height": 800,
                    ],
                ]],
                screens: [screen]
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.isFullscreenHost(
                hostPID: 42,
                windows: [[
                    kCGWindowOwnerPID as String: 42,
                    kCGWindowBounds as String: [
                        "X": 0, "Y": 25, "Width": 1920, "Height": 1000,
                    ],
                ]],
                screens: [screen]
            )
        )
        // Cursor / Electron native fullscreen reports screen minus the
        // 30pt menu bar, not the full 1440pt frame.
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.isFullscreenHost(
                hostPID: 42,
                windows: [[
                    kCGWindowOwnerPID as String: 42,
                    kCGWindowBounds as String: [
                        "X": 0, "Y": 30, "Width": 1920, "Height": 1050,
                    ],
                ]],
                screens: [screen]
            )
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.isFullscreenHost(
                hostPID: 42,
                windows: [[
                    kCGWindowOwnerPID as String: 42,
                    kCGWindowBounds as String: [
                        "X": 80, "Y": 80, "Width": 400, "Height": 300,
                    ],
                ]],
                screens: [screen],
                accessibilityFullscreen: true
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldHideWhenActiveSpaceChanges(
                didActivateApplicationForSearch: true
            )
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.shouldHideWhenActiveSpaceChanges(
                didActivateApplicationForSearch: false
            )
        )
        let displayAbovePrimary = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.isFullscreenHost(
                hostPID: 42,
                windows: [[
                    kCGWindowOwnerPID as String: 42,
                    kCGWindowBounds as String: [
                        "X": 0, "Y": -1080, "Width": 1920, "Height": 1080,
                    ],
                ]],
                screens: [displayAbovePrimary]
            )
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.shouldCaptureHostApplication(
                hostBundleID: "com.apple.Safari",
                ownBundleID: "com.macallyouneed.macclippy"
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldCaptureHostApplication(
                hostBundleID: "com.macallyouneed.macclippy",
                ownBundleID: "com.macallyouneed.macclippy"
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldCaptureHostApplication(
                hostBundleID: nil,
                ownBundleID: "com.macallyouneed.macclippy"
            )
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.shouldRefreshInputMethodContext(
                allowsInputMethodCandidates: true,
                searchFieldIsFirstResponder: true
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldRefreshInputMethodContext(
                allowsInputMethodCandidates: true,
                searchFieldIsFirstResponder: false
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldEnterDeferredPickerMode(
                interactionModeIsSearch: true
            )
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.shouldEnterDeferredPickerMode(
                interactionModeIsSearch: false
            )
        )
    }

    func testMarkedTextDoesNotRefreshOrRefocusTheSearchField() {
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldRefreshInputMethodContext(
                allowsInputMethodCandidates: true,
                searchFieldIsFirstResponder: true,
                hasMarkedText: true
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldPerformDeferredSearchFieldFocus(
                searchFieldIsFirstResponder: true,
                hasMarkedText: false
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldPerformDeferredSearchFieldFocus(
                searchFieldIsFirstResponder: false,
                hasMarkedText: true
            )
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.shouldPerformDeferredSearchFieldFocus(
                searchFieldIsFirstResponder: false,
                hasMarkedText: false
            )
        )
    }

    func testSearchOverlayNeverDropsForVisibleCandidates() {
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldReapplySearchOverlayForVisibleCandidates(
                currentLevel: Int(NSWindow.Level.mainMenu.rawValue),
                candidateLayers: [20]
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldReapplySearchOverlayForVisibleCandidates(
                currentLevel: Int(CGWindowLevelForKey(.dockWindow)) - 1,
                candidateLayers: [20]
            )
        )
    }

    func testInputMethodCandidateHitTestUsesWindowBounds() {
        let windows: [[String: Any]] = [
            [
                kCGWindowOwnerName as String: "Simplified Chinese Input Method",
                kCGWindowName as String: "",
                kCGWindowBounds as String: [
                    "X": 100.0,
                    "Y": 200.0,
                    "Width": 40.0,
                    "Height": 80.0,
                ],
            ]
        ]
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.isInputMethodCandidate(
                at: CGPoint(x: 110, y: 210),
                windows: windows
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.isInputMethodCandidate(
                at: CGPoint(x: 10, y: 10),
                windows: windows
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldDismissForOutsideClick(
                isInsideInputMethodCandidate: true,
                isSearchMode: true,
                hasMarkedText: false
            )
        )
        XCTAssertFalse(
            MacClippyDockInputMethodPolicy.shouldDismissForOutsideClick(
                isInsideInputMethodCandidate: false,
                isSearchMode: true,
                hasMarkedText: true
            )
        )
        XCTAssertTrue(
            MacClippyDockInputMethodPolicy.shouldDismissForOutsideClick(
                isInsideInputMethodCandidate: false,
                isSearchMode: false,
                hasMarkedText: false
            )
        )
        XCTAssertEqual(
            MacClippyDockInputMethodPolicy.quartzPoint(
                fromCocoa: CGPoint(x: 10, y: 100),
                primaryHeight: 1440
            ),
            CGPoint(x: 10, y: 1340)
        )
    }
}
