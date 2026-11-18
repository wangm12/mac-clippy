import Darwin
import Foundation
import XCTest

@testable import MacClippyCore

final class MacClippyBackupProcessCrashTests: XCTestCase {
    typealias Support = MacClippyBackupProcessCrashSupport
    typealias Launcher = MacClippyBackupProcessCrashLauncher

    func testEveryInstallBoundaryRecoversAfterChildProcessDeath() {
        guard let workspace = makeWorkspace() else { return }
        defer { removeWorkspace(workspace) }

        for (index, checkpoint) in Support.installCheckpoints.enumerated() {
            let liveRootURL = makeLiveRoot(workspace: workspace, index: index)
            var childExit: Launcher.ChildExit?
            do {
                let expectedOld = try Support.seedOldRoot(at: liveRootURL)
                let exit = try Launcher.launchWorker(
                    workspace: workspace,
                    liveRootURL: liveRootURL,
                    operation: .install,
                    checkpoint: checkpoint
                )
                childExit = exit
                RestoreCrashExecutionVerifier.assertChildWasKilled(
                    exit,
                    workspace: workspace,
                    operation: .install,
                    checkpoint: checkpoint
                )
                RestoreCrashExecutionVerifier.recoverInNewProcessAndAssertCompletion(
                    workspace: workspace,
                    liveRootURL: liveRootURL
                )
                try recoverIdempotentlyAndAssert(liveRootURL, matches: expectedOld)
            } catch {
                let output = RestoreCrashExecutionVerifier.diagnostics(childExit)
                XCTFail("Install checkpoint \(checkpoint) failed: \(error).\n\(output)")
                return
            }
        }
    }

    func testStagedMoveChildDeathAfterDestinationRemovalRecoversEachComponent() {
        guard let workspace = makeWorkspace() else { return }
        defer { removeWorkspace(workspace) }

        for (index, checkpoint) in Support.stagedMoveCheckpoints.enumerated() {
            let liveRootURL = makeLiveRoot(workspace: workspace, index: 40 + index)
            var childExit: Launcher.ChildExit?
            do {
                let expectedOld = try Support.seedOldRoot(at: liveRootURL)
                let exit = try Launcher.launchWorker(
                    workspace: workspace,
                    liveRootURL: liveRootURL,
                    operation: .install,
                    checkpoint: checkpoint
                )
                childExit = exit
                RestoreCrashExecutionVerifier.assertChildWasKilled(
                    exit,
                    workspace: workspace,
                    operation: .install,
                    checkpoint: checkpoint
                )
                RestoreCrashExecutionVerifier.recoverInNewProcessAndAssertCompletion(
                    workspace: workspace,
                    liveRootURL: liveRootURL
                )
                try recoverIdempotentlyAndAssert(liveRootURL, matches: expectedOld)
            } catch {
                let output = RestoreCrashExecutionVerifier.diagnostics(childExit)
                XCTFail("Staged move checkpoint \(checkpoint) failed: \(error).\n\(output)")
                return
            }
        }
    }

    func testStagedMoveIOErrorRollsBackEachComponent() {
        guard let workspace = makeWorkspace() else { return }
        defer { removeWorkspace(workspace) }

        for (index, component) in MacClippyBackup.liveComponents.enumerated() {
            let liveRootURL = makeLiveRoot(workspace: workspace, index: 50 + index)
            do {
                let expectedOld = try Support.seedOldRoot(at: liveRootURL)
                let fileManager = try StagedMoveInterceptingFileManager(
                    workspace: workspace,
                    liveRootURL: liveRootURL,
                    launchID: UUID().uuidString,
                    targetComponent: component,
                    action: .throwIOError
                )
                do {
                    _ = try MacClippyBackup.installIntoLiveRoot(
                        from: workspace.snapshotURL,
                        liveRootURL: liveRootURL,
                        deviceKey: try Support.testKey(at: workspace.rootURL),
                        fileManager: fileManager
                    )
                    XCTFail("Staged move for \(component) should surface the injected EIO.")
                } catch let error as NSError {
                    XCTAssertEqual(error.domain, NSPOSIXErrorDomain, component)
                    XCTAssertEqual(error.code, Int(EIO), component)
                }
                XCTAssertTrue(fileManager.didIntercept, "FileManager must intercept the staged move for \(component).")
                try recoverIdempotentlyAndAssert(liveRootURL, matches: expectedOld)
            } catch {
                XCTFail("Staged move I/O failure for \(component) failed: \(error).")
                return
            }
        }
    }

    func testEveryRollbackAndCleanupBoundaryResumesAfterChildProcessDeath() {
        guard let workspace = makeWorkspace() else { return }
        defer { removeWorkspace(workspace) }

        for (index, checkpoint) in Support.recoveryCheckpoints.enumerated() {
            let liveRootURL = makeLiveRoot(workspace: workspace, index: 60 + index)
            var childExit: Launcher.ChildExit?
            do {
                let expectedOld = try Support.seedOldRoot(at: liveRootURL)
                try leaveUncommittedRestore(snapshotURL: workspace.snapshotURL, liveRootURL: liveRootURL)
                let exit = try Launcher.launchWorker(
                    workspace: workspace,
                    liveRootURL: liveRootURL,
                    operation: .recover,
                    checkpoint: checkpoint
                )
                childExit = exit
                RestoreCrashExecutionVerifier.assertChildWasKilled(
                    exit,
                    workspace: workspace,
                    operation: .recover,
                    checkpoint: checkpoint
                )
                RestoreCrashExecutionVerifier.recoverInNewProcessAndAssertCompletion(
                    workspace: workspace,
                    liveRootURL: liveRootURL
                )
                try recoverIdempotentlyAndAssert(liveRootURL, matches: expectedOld)
            } catch {
                let output = RestoreCrashExecutionVerifier.diagnostics(childExit)
                XCTFail("Recovery checkpoint \(checkpoint) failed: \(error).\n\(output)")
                return
            }
        }
    }

    func testChildDeathAfterFinalizeKeepsAllNewComponents() {
        guard let workspace = makeWorkspace(),
              let expectedNew = workspace.expectedNew else { return }
        defer { removeWorkspace(workspace) }
        let liveRootURL = makeLiveRoot(workspace: workspace, index: 80)
        var childExit: Launcher.ChildExit?

        do {
            _ = try Support.seedOldRoot(at: liveRootURL)
            let checkpoint = "afterFinalize"
            let exit = try Launcher.launchWorker(
                workspace: workspace,
                liveRootURL: liveRootURL,
                operation: .finalize,
                checkpoint: checkpoint
            )
            childExit = exit
            RestoreCrashExecutionVerifier.assertChildWasKilled(
                exit,
                workspace: workspace,
                operation: .finalize,
                checkpoint: checkpoint
            )
            RestoreCrashExecutionVerifier.recoverInNewProcessAndAssertCompletion(
                workspace: workspace,
                liveRootURL: liveRootURL
            )
            try recoverIdempotentlyAndAssert(liveRootURL, matches: expectedNew)
        } catch {
            let output = RestoreCrashExecutionVerifier.diagnostics(childExit)
            XCTFail("Finalized restore recovery failed: \(error).\n\(output)")
        }
    }

    func testChildWorkerEntryPoint() throws {
        guard ProcessInfo.processInfo.environment[Support.childModeEnvironmentKey] == Support.childMode else {
            throw XCTSkip("Child-only XCTest worker; ordinary test runs skip without the explicit private worker mode.")
        }
        try MacClippyBackupProcessCrashWorker.runFromCurrentDirectory()
    }

    private func makeWorkspace() -> Support.Workspace? {
        do {
            return try Support.makeWorkspace()
        } catch {
            XCTFail("Could not create the marked synthetic restore workspace: \(error).")
            return nil
        }
    }

    private func removeWorkspace(_ workspace: Support.Workspace) {
        try? FileManager.default.removeItem(at: workspace.rootURL)
    }

    private func makeLiveRoot(workspace: Support.Workspace, index: Int) -> URL {
        let liveRootURL = workspace.rootURL.appendingPathComponent("live-\(index)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: liveRootURL, withIntermediateDirectories: false)
            return liveRootURL
        } catch {
            XCTFail("Could not prepare the marked synthetic live root: \(error).")
            return liveRootURL
        }
    }

    private func recoverIdempotentlyAndAssert(
        _ liveRootURL: URL,
        matches expected: Support.GenerationExpectation
    ) throws {
        try MacClippyBackup.recoverPendingRestore(at: liveRootURL)
        try MacClippyBackup.recoverPendingRestore(at: liveRootURL)
        try RestoreCrashStorageVerifier.assertCompleteStorage(liveRootURL, matches: expected)
    }

    private func leaveUncommittedRestore(snapshotURL: URL, liveRootURL: URL) throws {
        do {
            _ = try MacClippyBackup.installIntoLiveRoot(
                from: snapshotURL,
                liveRootURL: liveRootURL,
                deviceKey: try Support.testKey(at: liveRootURL.deletingLastPathComponent()),
                faultInjector: { point in
                    if point == .afterInstall("blobs") {
                        throw MacClippyBackupError.restoreInterrupted
                    }
                }
            )
            XCTFail("Fixture setup should leave an uncommitted restore journal.")
        } catch let error as MacClippyBackupError {
            XCTAssertEqual(error, .restoreInterrupted)
        }
    }

}
