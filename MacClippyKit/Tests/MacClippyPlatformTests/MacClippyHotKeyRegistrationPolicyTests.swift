import XCTest

@testable import MacClippyPlatform

final class MacClippyHotKeyRegistrationPolicyTests: XCTestCase {
    func testEveryCarbonRoleHasARegistrationFailureOperation() {
        let roles: [MacClippyGlobalHotKeyRole] = [
            .clipboardDock,
            .ignoreNextCopy
        ]
        let operations = Set(roles.map(MacClippyHotKeyRegistrationPolicy.registrationFailureOperation(for:)))
        XCTAssertEqual(operations.count, roles.count)
        XCTAssertTrue(operations.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(
            MacClippyHotKeyRegistrationPolicy.registrationFailureOperation(for: .ignoreNextCopy),
            "ignore_next_copy_hotkey"
        )
    }

    func testMismatchedHotKeyIDContinuesTheCarbonHandlerChain() {
        XCTAssertEqual(
            MacClippyHotKeyRegistrationPolicy.eventDisposition(
                parameterSucceeded: true,
                receivedSignature: 0x4D43_4C50,
                receivedID: MacClippyGlobalHotKeyRole.clipboardDock.carbonHotKeyID,
                expectedSignature: 0x4D43_4C50,
                expectedID: MacClippyGlobalHotKeyRole.ignoreNextCopy.carbonHotKeyID
            ),
            .notHandled
        )
        XCTAssertEqual(
            MacClippyHotKeyRegistrationPolicy.eventDisposition(
                parameterSucceeded: false,
                receivedSignature: 0x4D43_4C50,
                receivedID: MacClippyGlobalHotKeyRole.clipboardDock.carbonHotKeyID,
                expectedSignature: 0x4D43_4C50,
                expectedID: MacClippyGlobalHotKeyRole.clipboardDock.carbonHotKeyID
            ),
            .notHandled
        )
        XCTAssertEqual(
            MacClippyHotKeyRegistrationPolicy.eventDisposition(
                parameterSucceeded: true,
                receivedSignature: 0x4D43_4C50,
                receivedID: MacClippyGlobalHotKeyRole.clipboardDock.carbonHotKeyID,
                expectedSignature: 0x4D43_4C50,
                expectedID: MacClippyGlobalHotKeyRole.clipboardDock.carbonHotKeyID
            ),
            .handled
        )
    }

    func testIgnoreNextRegistrationFailureDoesNotSurfaceTheSharedDockBanner() {
        XCTAssertTrue(
            MacClippyHotKeyRegistrationPolicy.shouldSurfaceSharedRegistrationBanner(for: .clipboardDock)
        )
        XCTAssertFalse(
            MacClippyHotKeyRegistrationPolicy.shouldSurfaceSharedRegistrationBanner(for: .ignoreNextCopy)
        )
    }
}
