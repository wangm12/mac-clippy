import Darwin
import Foundation

@testable import MacClippyCore

enum MacClippyBackupProcessCrashWorker {
    private typealias Support = MacClippyBackupProcessCrashSupport

    static func runFromCurrentDirectory() throws {
        guard let (workspace, request) = try MacClippyBackupProcessCrashChildProtocol.readWorkerRequest() else {
            throw Support.HarnessError.invalidRequest
        }
        let testBundle = try MacClippyBackupProcessCrashIsolation.testBundle()
        try MacClippyBackupProcessCrashChildProtocol.writeStartEvidence(
            workspace: workspace,
            launchID: request.launchID,
            testBundle: testBundle
        )
        try perform(request, workspace: workspace)
    }

    private static func perform(
        _ request: Support.ChildRequest,
        workspace: Support.Workspace
    ) throws {
        let liveRootURL = try MacClippyBackupProcessCrashIsolation.validatedLiveRoot(
            request.liveRootPath,
            within: workspace.rootURL
        )
        switch request.operation {
        case .install:
            try install(request, workspace: workspace, liveRootURL: liveRootURL)
        case .recover:
            try recover(request, workspace: workspace, liveRootURL: liveRootURL)
        case .recoverComplete:
            try MacClippyBackup.recoverPendingRestore(at: liveRootURL)
            try MacClippyBackupProcessCrashChildProtocol.writeCompletionEvidence(
                workspace: workspace,
                launchID: request.launchID,
                operation: request.operation,
                checkpoint: request.checkpoint,
                result: "recovery-completed"
            )
            return
        case .finalize:
            _ = try MacClippyBackup.installIntoLiveRoot(
                from: workspace.snapshotURL,
                liveRootURL: liveRootURL,
                deviceKey: try Support.testKey(at: workspace.rootURL)
            )
            try MacClippyBackup.finalizePendingRestore(at: liveRootURL)
            try MacClippyBackupProcessCrashChildProtocol.writeCheckpointEvidence(
                workspace: workspace,
                launchID: request.launchID,
                operation: request.operation,
                checkpoint: request.checkpoint
            )
            terminateSelf()
        }
        throw Support.HarnessError.checkpointNotReached
    }

    private static func install(
        _ request: Support.ChildRequest,
        workspace: Support.Workspace,
        liveRootURL: URL
    ) throws {
        let moveComponent = component(forMoveCheckpoint: request.checkpoint)
        let fileManager: FileManager
        if let moveComponent {
            fileManager = try StagedMoveInterceptingFileManager(
                workspace: workspace,
                liveRootURL: liveRootURL,
                launchID: request.launchID,
                targetComponent: moveComponent,
                action: .killChild
            )
        } else {
            fileManager = .default
        }
        _ = try MacClippyBackup.installIntoLiveRoot(
            from: workspace.snapshotURL,
            liveRootURL: liveRootURL,
            deviceKey: try Support.testKey(at: workspace.rootURL),
            fileManager: fileManager,
            faultInjector: { point in
                try terminateIfMatched(
                    point,
                    request: request,
                    workspace: workspace,
                    liveRootURL: liveRootURL
                )
            }
        )
    }

    private static func recover(
        _ request: Support.ChildRequest,
        workspace: Support.Workspace,
        liveRootURL: URL
    ) throws {
        try MacClippyBackup.recoverPendingRestore(
            at: liveRootURL,
            faultInjector: { point in
                try terminateIfMatched(
                    point,
                    request: request,
                    workspace: workspace,
                    liveRootURL: liveRootURL
                )
            }
        )
        throw Support.HarnessError.checkpointNotReached
    }

    private static func terminateIfMatched(
        _ point: MacClippyBackup.RestoreFaultPoint,
        request: Support.ChildRequest,
        workspace: Support.Workspace,
        liveRootURL: URL
    ) throws {
        guard label(for: point) == request.checkpoint else { return }
        try MacClippyBackupProcessCrashChildProtocol.writeCheckpointEvidence(
            workspace: workspace,
            launchID: request.launchID,
            operation: request.operation,
            checkpoint: request.checkpoint
        )
        terminateSelf()
    }

    private static func component(forMoveCheckpoint checkpoint: String) -> String? {
        let prefix = "duringInstallMove:"
        guard checkpoint.hasPrefix(prefix) else { return nil }
        return String(checkpoint.dropFirst(prefix.count))
    }

    private static func label(for point: MacClippyBackup.RestoreFaultPoint) -> String {
        switch point {
        case let .beforeInstall(component): "beforeInstall:\(component)"
        case let .afterInstall(component): "afterInstall:\(component)"
        case .beforeCommit: "beforeCommit"
        case let .afterRollback(component): "afterRollback:\(component)"
        case .afterRollbackCommit: "afterRollbackCommit"
        case .beforeTransactionCleanup: "beforeTransactionCleanup"
        case .afterTransactionCleanup: "afterTransactionCleanup"
        case .beforeJournalCleanup: "beforeJournalCleanup"
        }
    }

    static func terminateSelf() -> Never {
        if kill(getpid(), SIGKILL) != 0 {
            _exit(86)
        }
        _exit(87)
    }
}

final class StagedMoveInterceptingFileManager: FileManager {
    enum Action {
        case killChild
        case throwIOError
    }

    private let workspace: MacClippyBackupProcessCrashSupport.Workspace
    private let liveRootURL: URL
    private let launchID: String
    private let targetComponent: String
    private let action: Action
    private(set) var didIntercept = false

    init(
        workspace: MacClippyBackupProcessCrashSupport.Workspace,
        liveRootURL: URL,
        launchID: String,
        targetComponent: String,
        action: Action
    ) throws {
        guard MacClippyBackup.liveComponents.contains(targetComponent) else {
            throw MacClippyBackupProcessCrashSupport.HarnessError.invalidRequest
        }
        self.workspace = workspace
        self.liveRootURL = try MacClippyBackupProcessCrashIsolation.validatedLiveRoot(
            liveRootURL.path,
            within: workspace.rootURL
        )
        self.launchID = launchID
        self.targetComponent = targetComponent
        self.action = action
        super.init()
        _ = try MacClippyBackupProcessCrashIsolation.validatedWorkspace(
            rootPath: workspace.rootURL.path,
            token: workspace.token
        )
    }

    override func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        guard let component = try stagedComponent(sourceURL: sourceURL, destinationURL: destinationURL) else {
            try super.moveItem(at: sourceURL, to: destinationURL)
            return
        }
        guard component == targetComponent else {
            try super.moveItem(at: sourceURL, to: destinationURL)
            return
        }
        guard !didIntercept,
              !fileExists(atPath: destinationURL.path),
              fileExists(atPath: sourceURL.path) else {
            throw MacClippyBackupProcessCrashSupport.HarnessError.invalidRequest
        }
        didIntercept = true
        switch action {
        case .killChild:
            try MacClippyBackupProcessCrashChildProtocol.writeCheckpointEvidence(
                workspace: workspace,
                launchID: launchID,
                operation: .install,
                checkpoint: "duringInstallMove:\(component)"
            )
            MacClippyBackupProcessCrashWorker.terminateSelf()
        case .throwIOError:
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
    }

    private func stagedComponent(sourceURL: URL, destinationURL: URL) throws -> String? {
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let destination = destinationURL.standardizedFileURL
        guard source.deletingLastPathComponent().lastPathComponent == "staged" else { return nil }
        let component = source.lastPathComponent
        let transactionURL = source.deletingLastPathComponent().deletingLastPathComponent()
        let sourceValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let guardIsValid = transactionURL.deletingLastPathComponent() == liveRootURL
            && transactionURL.lastPathComponent.hasPrefix(".macclippy-restore-")
            && MacClippyBackup.liveComponents.contains(component)
            && destination.deletingLastPathComponent() == liveRootURL
            && destination.lastPathComponent == component
            && sourceValues.isDirectory == true
            && sourceValues.isSymbolicLink != true
        guard guardIsValid else {
            throw MacClippyBackupProcessCrashSupport.HarnessError.invalidRoot
        }
        return component
    }
}
