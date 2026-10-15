import Foundation

enum MacClippyBackupProcessCrashIsolation {
    typealias Support = MacClippyBackupProcessCrashSupport

    static func testBundle() throws -> (bundleURL: URL, executableURL: URL) {
        let bundle = Bundle(for: MacClippyBackupProcessCrashTests.self)
        let bundleURL = bundle.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let bundleValues = try bundleURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard bundleURL.pathExtension == "xctest",
              bundleURL.lastPathComponent.hasSuffix(".xctest"),
              bundleValues.isDirectory == true,
              bundleValues.isSymbolicLink != true,
              let executableURL = bundle.executableURL?.standardizedFileURL.resolvingSymlinksInPath(),
              executableURL.path.hasPrefix(bundleURL.path + "/"),
              FileManager.default.fileExists(atPath: executableURL.path),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw Support.HarnessError.invalidTestBundle
        }
        return (bundleURL, executableURL)
    }

    static func validatedWorkspace(rootPath: String, token: String) throws -> Support.Workspace {
        guard UUID(uuidString: token)?.uuidString == token else {
            throw Support.HarnessError.invalidRequest
        }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).standardizedFileURL
        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let temporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let markerURL = canonicalRoot.appendingPathComponent(Support.markerName)
        let markerValues = try markerURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let markerMatches = try Data(contentsOf: markerURL) == Data(token.utf8)
        guard rootURL == canonicalRoot,
              canonicalRoot.path.hasPrefix(temporaryRoot.path + "/"),
              canonicalRoot.lastPathComponent.hasPrefix("MacClippyPhase5Restore-"),
              markerValues.isRegularFile == true,
              markerValues.isSymbolicLink != true,
              markerMatches else {
            throw Support.HarnessError.invalidRoot
        }
        let snapshotURL = canonicalRoot.appendingPathComponent("snapshot", isDirectory: true)
        let snapshotValues = try snapshotURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard snapshotValues.isDirectory == true, snapshotValues.isSymbolicLink != true else {
            throw Support.HarnessError.invalidRoot
        }
        return Support.Workspace(
            rootURL: canonicalRoot,
            token: token,
            snapshotURL: snapshotURL,
            expectedNew: nil
        )
    }

    static func validatedLiveRoot(_ path: String, within rootURL: URL) throws -> URL {
        let liveRootURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let canonicalLiveRoot = liveRootURL.resolvingSymlinksInPath().standardizedFileURL
        let values = try canonicalLiveRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard canonicalLiveRoot == liveRootURL,
              canonicalLiveRoot.deletingLastPathComponent() == rootURL,
              canonicalLiveRoot.lastPathComponent.hasPrefix("live-"),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw Support.HarnessError.invalidRoot
        }
        return canonicalLiveRoot
    }

    static func checkpointIsAllowed(_ checkpoint: String, for operation: Support.Operation) -> Bool {
        switch operation {
        case .install:
            Support.installCheckpoints.contains(checkpoint) || Support.stagedMoveCheckpoints.contains(checkpoint)
        case .recover:
            Support.recoveryCheckpoints.contains(checkpoint)
        case .recoverComplete:
            checkpoint == Support.recoveryCompleteCheckpoint
        case .finalize:
            checkpoint == "afterFinalize"
        }
    }
}
