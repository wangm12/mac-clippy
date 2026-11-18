import Darwin
import Foundation

enum MacClippyBackupProcessCrashChildProtocol {
    typealias Support = MacClippyBackupProcessCrashSupport

    static func writeRequest(
        workspace: Support.Workspace,
        liveRootURL: URL,
        operation: Support.Operation,
        checkpoint: String,
        testBundle: (bundleURL: URL, executableURL: URL)
    ) throws -> String {
        let launchID = UUID().uuidString
        let request = Support.ChildRequest(
            launchID: launchID,
            token: workspace.token,
            rootPath: workspace.rootURL.path,
            liveRootPath: liveRootURL.path,
            operation: operation,
            checkpoint: checkpoint,
            testBundlePath: testBundle.bundleURL.path,
            testExecutablePath: testBundle.executableURL.path,
            testSelector: Support.workerSelector
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try writeDurably(try encoder.encode(request), to: Support.requestURL(in: workspace))
        return launchID
    }

    static func readWorkerRequest() throws -> (workspace: Support.Workspace, request: Support.ChildRequest)? {
        let environment = ProcessInfo.processInfo.environment
        guard environment[Support.childModeEnvironmentKey] == Support.childMode else { return nil }
        guard let token = environment[Support.childTokenEnvironmentKey],
              UUID(uuidString: token)?.uuidString == token else {
            throw Support.HarnessError.invalidRequest
        }
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .standardizedFileURL
        let canonicalRoot = currentDirectory.resolvingSymlinksInPath().standardizedFileURL
        let workspace = try MacClippyBackupProcessCrashIsolation.validatedWorkspace(
            rootPath: canonicalRoot.path,
            token: token
        )
        let requestURL = Support.requestURL(in: workspace)
        let requestValues = try requestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard requestValues.isRegularFile == true,
              requestValues.isSymbolicLink != true else {
            throw Support.HarnessError.invalidRequest
        }
        let request = try JSONDecoder().decode(Support.ChildRequest.self, from: Data(contentsOf: requestURL))
        let liveRootURL = try MacClippyBackupProcessCrashIsolation.validatedLiveRoot(
            request.liveRootPath,
            within: workspace.rootURL
        )
        let loadedBundle = try MacClippyBackupProcessCrashIsolation.testBundle()
        guard request.token == token,
              UUID(uuidString: request.launchID)?.uuidString == request.launchID,
              request.rootPath == workspace.rootURL.path,
              request.testSelector == Support.workerSelector,
              request.testBundlePath == loadedBundle.bundleURL.path,
              request.testExecutablePath == loadedBundle.executableURL.path,
              request.liveRootPath == liveRootURL.path,
              MacClippyBackupProcessCrashIsolation.checkpointIsAllowed(
                request.checkpoint,
                for: request.operation
              ) else {
            throw Support.HarnessError.invalidRequest
        }
        return (workspace, request)
    }

    static func writeStartEvidence(
        workspace: Support.Workspace,
        launchID: String,
        testBundle: (bundleURL: URL, executableURL: URL)
    ) throws {
        let currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .standardizedFileURL
        .resolvingSymlinksInPath()
        let record = Support.ChildStartEvidence(
            launchID: launchID,
            mode: Support.childMode,
            token: workspace.token,
            processID: getpid(),
            selectedTest: Support.workerSelector,
            currentDirectoryPath: currentDirectoryURL.path,
            testBundlePath: testBundle.bundleURL.path,
            testExecutablePath: testBundle.executableURL.path,
            requestPath: Support.requestURL(in: workspace).path
        )
        try writeDurably(try JSONEncoder().encode(record), to: Support.startEvidenceURL(in: workspace))
    }

    static func writeCheckpointEvidence(
        workspace: Support.Workspace,
        launchID: String,
        operation: Support.Operation,
        checkpoint: String
    ) throws {
        let evidence = Support.ChildCheckpointEvidence(
            launchID: launchID,
            token: workspace.token,
            operation: operation,
            checkpoint: checkpoint
        )
        try writeDurably(try JSONEncoder().encode(evidence), to: Support.checkpointEvidenceURL(in: workspace))
    }

    static func writeCompletionEvidence(
        workspace: Support.Workspace,
        launchID: String,
        operation: Support.Operation,
        checkpoint: String,
        result: String
    ) throws {
        let evidence = Support.ChildCompletionEvidence(
            launchID: launchID,
            token: workspace.token,
            operation: operation,
            checkpoint: checkpoint,
            result: result
        )
        try writeDurably(try JSONEncoder().encode(evidence), to: Support.completionEvidenceURL(in: workspace))
    }

    static func readCheckpointEvidence(in workspace: Support.Workspace) throws -> Support.ChildCheckpointEvidence {
        let data = try Data(contentsOf: Support.checkpointEvidenceURL(in: workspace))
        return try JSONDecoder().decode(Support.ChildCheckpointEvidence.self, from: data)
    }

    static func readStartEvidence(in workspace: Support.Workspace) throws -> Support.ChildStartEvidence {
        let data = try Data(contentsOf: Support.startEvidenceURL(in: workspace))
        return try JSONDecoder().decode(Support.ChildStartEvidence.self, from: data)
    }

    static func readCompletionEvidence(in workspace: Support.Workspace) throws -> Support.ChildCompletionEvidence {
        let data = try Data(contentsOf: Support.completionEvidenceURL(in: workspace))
        return try JSONDecoder().decode(Support.ChildCompletionEvidence.self, from: data)
    }

    static func writeDurably(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        try handle.synchronize()
        try handle.close()
    }
}
