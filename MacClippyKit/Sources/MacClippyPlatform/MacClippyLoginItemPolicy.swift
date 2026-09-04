import Foundation

public enum MacClippyLoginItemPolicy {
    public static func shouldRegister(bundlePath: String, isDebugBuild: Bool) -> Bool {
        guard !isDebugBuild else { return false }
        return !isDevelopmentBuildPath(bundlePath)
    }

    public static func isDevelopmentBuildPath(_ bundlePath: String) -> Bool {
        bundlePath.contains("/DerivedData/")
            || bundlePath.contains("/.build/")
            || bundlePath.contains("/Build/Products/Debug/")
    }

    public static func warningMessage(
        bundlePath: String,
        isDebugBuild: Bool,
        applicationsCopyExists: Bool = false,
        otherBundlePaths: [String] = []
    ) -> String? {
        if isDebugBuild || isDevelopmentBuildPath(bundlePath) {
            return "This copy is a Debug or DerivedData build. Launch at Login stays off so it cannot register a second MacClippy."
        }
        let applicationsPath = URL(fileURLWithPath: "/Applications/MacClippy.app").standardizedFileURL.path
        let currentPath = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        if applicationsCopyExists, currentPath != applicationsPath {
            return "Another MacClippy is installed in Applications. Keep only one login item in System Settings."
        }
        let otherPaths = Set(
            otherBundlePaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        ).subtracting([currentPath])
        if !otherPaths.isEmpty {
            return "Another MacClippy is installed. Keep only one login item in System Settings."
        }
        return nil
    }
}
