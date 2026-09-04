import AppKit
import Foundation
import ServiceManagement

import MacClippyCore
import MacClippyPlatform

enum MacClippyLaunchAtLoginRegistration {
    enum Error: Swift.Error {
        case debugBuildRefused
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            let bundlePath = Bundle.main.bundlePath
            guard MacClippyLoginItemPolicy.shouldRegister(
                bundlePath: bundlePath,
                isDebugBuild: isDebugBuild
            ) else {
                MacClippyLog.record(
                    category: .lifecycle,
                    code: .debugLoginItemRefused,
                    operation: "launch_at_login_register",
                    recoveryAction: "use_applications_copy",
                    impact: "debug_login_item_not_registered"
                )
                throw Error.debugBuildRefused
            }
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func warningMessage(bundlePath: String = Bundle.main.bundlePath) -> String? {
        MacClippyLoginItemPolicy.warningMessage(
            bundlePath: bundlePath,
            isDebugBuild: isDebugBuild,
            applicationsCopyExists: FileManager.default.fileExists(atPath: "/Applications/MacClippy.app"),
            otherBundlePaths: otherInstalledBundlePaths(currentPath: bundlePath)
        )
    }

    static func otherInstalledBundlePaths(
        currentPath: String,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> [String] {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return [] }
        let current = URL(fileURLWithPath: currentPath).standardizedFileURL.path
        return NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleIdentifier)
            .map { $0.standardizedFileURL.path }
            .filter { $0 != current }
    }
}
