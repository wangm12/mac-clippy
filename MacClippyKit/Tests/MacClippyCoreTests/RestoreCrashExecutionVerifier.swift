import Darwin
import Foundation
import XCTest

enum RestoreCrashExecutionVerifier {
    typealias Support = MacClippyBackupProcessCrashSupport
    typealias Launcher = MacClippyBackupProcessCrashLauncher

    static func assertChildWasKilled(
        _ exit: Launcher.ChildExit,
        workspace: Support.Workspace,
        operation: Support.Operation,
        checkpoint: String
    ) {
        let output = diagnostics(exit)
        XCTAssertFalse(exit.timedOut, "Child timed out at \(checkpoint). \(output)")
        XCTAssertGreaterThan(exit.pid, 1, "Child PID must be known and valid. \(output)")
        XCTAssertNotEqual(exit.pid, getpid(), "Restore must run in a separate process. \(output)")
        XCTAssertEqual(exit.terminationReason, .uncaughtSignal, "Expected SIGKILL at \(checkpoint). \(output)")
        XCTAssertEqual(exit.terminationStatus, Int32(SIGKILL), "Expected SIGKILL at \(checkpoint). \(output)")

        do {
            try assertChildStart(exit, workspace: workspace, diagnostics: output)
            let evidence = try MacClippyBackupProcessCrashChildProtocol.readCheckpointEvidence(in: workspace)
            let expected = Support.ChildCheckpointEvidence(
                launchID: exit.launchID,
                token: workspace.token,
                operation: operation,
                checkpoint: checkpoint
            )
            XCTAssertEqual(evidence, expected, "Child checkpoint evidence did not match \(checkpoint). \(output)")
        } catch {
            XCTFail("Child start/checkpoint evidence missing for \(checkpoint): \(error). \(output)")
        }
    }

    static func recoverInNewProcessAndAssertCompletion(workspace: Support.Workspace, liveRootURL: URL) {
        do {
            let exit = try Launcher.launchWorker(
                workspace: workspace,
                liveRootURL: liveRootURL,
                operation: .recoverComplete,
                checkpoint: Support.recoveryCompleteCheckpoint
            )
            let output = diagnostics(exit)
            XCTAssertFalse(exit.timedOut, "Recovery child timed out. \(output)")
            XCTAssertEqual(exit.terminationReason, .exit, "Recovery must complete in its own process. \(output)")
            XCTAssertEqual(exit.terminationStatus, 0, "Recovery child must pass. \(output)")
            try assertChildStart(exit, workspace: workspace, diagnostics: output)
            let completion = try MacClippyBackupProcessCrashChildProtocol.readCompletionEvidence(in: workspace)
            let expected = Support.ChildCompletionEvidence(
                launchID: exit.launchID,
                token: workspace.token,
                operation: .recoverComplete,
                checkpoint: Support.recoveryCompleteCheckpoint,
                result: "recovery-completed"
            )
            XCTAssertEqual(completion, expected, output)
        } catch {
            XCTFail("A fresh recovery process did not complete: \(error).")
        }
    }

    static func diagnostics(_ exit: Launcher.ChildExit?) -> String {
        guard let exit else { return "No child process was launched." }
        return "pid=\(exit.pid), reason=\(exit.terminationReason), status=\(exit.terminationStatus), "
            + "timedOut=\(exit.timedOut), bundle=\(exit.testBundlePath), executable=\(exit.testExecutablePath), "
            + "stdout=\(exit.stdoutPath):\n\(exit.stdout)\nstderr=\(exit.stderrPath):\n\(exit.stderr)"
    }

    private static func assertChildStart(
        _ exit: Launcher.ChildExit,
        workspace: Support.Workspace,
        diagnostics: String
    ) throws {
        let start = try MacClippyBackupProcessCrashChildProtocol.readStartEvidence(in: workspace)
        XCTAssertEqual(start.launchID, exit.launchID, diagnostics)
        XCTAssertEqual(start.mode, Support.childMode, diagnostics)
        XCTAssertEqual(start.token, workspace.token, diagnostics)
        XCTAssertEqual(start.processID, exit.pid, diagnostics)
        XCTAssertEqual(start.selectedTest, Support.workerSelector, diagnostics)
        XCTAssertEqual(start.currentDirectoryPath, workspace.rootURL.path, diagnostics)
        XCTAssertEqual(start.testBundlePath, exit.testBundlePath, diagnostics)
        XCTAssertEqual(start.testExecutablePath, exit.testExecutablePath, diagnostics)
        XCTAssertEqual(start.requestPath, Support.requestURL(in: workspace).path, diagnostics)
    }
}
