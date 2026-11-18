import Darwin
import Foundation

enum MacClippyBackupProcessCrashLauncher {
    typealias Support = MacClippyBackupProcessCrashSupport

    struct ChildExit {
        let pid: Int32
        let terminationReason: Process.TerminationReason
        let terminationStatus: Int32
        let timedOut: Bool
        let launchID: String
        let testBundlePath: String
        let testExecutablePath: String
        let stdout: String
        let stderr: String
        let stdoutPath: String
        let stderrPath: String
    }

    private static let workerTimeout: TimeInterval = 20
    private static let captureLimit = 32 * 1_024

    static func launchWorker(
        workspace: Support.Workspace,
        liveRootURL: URL,
        operation: Support.Operation,
        checkpoint: String
    ) throws -> ChildExit {
        try validateParentPaths(workspace: workspace, liveRootURL: liveRootURL)
        let testBundle = try MacClippyBackupProcessCrashIsolation.testBundle()
        try removePriorEvidence(in: workspace)
        let launchID = try MacClippyBackupProcessCrashChildProtocol.writeRequest(
            workspace: workspace,
            liveRootURL: liveRootURL,
            operation: operation,
            checkpoint: checkpoint,
            testBundle: testBundle
        )
        defer {
            try? FileManager.default.removeItem(at: Support.requestURL(in: workspace))
        }
        let worker = try makeWorkerProcess(workspace: workspace, testBundle: testBundle)
        let exit = try waitForChild(worker.process, timeout: workerTimeout)
        return try collectExit(
            exit,
            worker: worker,
            context: ChildLaunchContext(
                workspace: workspace,
                launchID: launchID,
                testBundle: testBundle,
                operation: operation,
                checkpoint: checkpoint
            )
        )
    }

    private struct WorkerProcess {
        let process: Process
        let stdoutCapture: BoundedPipeCapture
        let stderrCapture: BoundedPipeCapture
    }

    private struct ChildLaunchContext {
        let workspace: Support.Workspace
        let launchID: String
        let testBundle: (bundleURL: URL, executableURL: URL)
        let operation: Support.Operation
        let checkpoint: String
    }

    private static func makeWorkerProcess(
        workspace: Support.Workspace,
        testBundle: (bundleURL: URL, executableURL: URL)
    ) throws -> WorkerProcess {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutCapture = BoundedPipeCapture(handle: stdoutPipe.fileHandleForReading, limit: captureLimit)
        let stderrCapture = BoundedPipeCapture(handle: stderrPipe.fileHandleForReading, limit: captureLimit)
        let process = Process()
        process.executableURL = try xctestExecutable()
        process.arguments = ["-XCTest", Support.workerSelector, testBundle.bundleURL.path]
        process.currentDirectoryURL = workspace.rootURL
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        var environment = ProcessInfo.processInfo.environment
        environment[Support.childModeEnvironmentKey] = Support.childMode
        environment[Support.childTokenEnvironmentKey] = workspace.token
        if let sanitizerRuntime = loadedThreadSanitizerRuntime() {
            var insertedLibraries = environment["DYLD_INSERT_LIBRARIES"]?
                .split(separator: ":")
                .map(String.init) ?? []
            if !insertedLibraries.contains(sanitizerRuntime) {
                insertedLibraries.insert(sanitizerRuntime, at: 0)
            }
            environment["DYLD_INSERT_LIBRARIES"] = insertedLibraries.joined(separator: ":")
        }
        process.environment = environment
        return WorkerProcess(process: process, stdoutCapture: stdoutCapture, stderrCapture: stderrCapture)
    }

    /// XCTest loads the SwiftPM test bundle with `dlopen`. Under TSan this
    /// means a nested `xctest` process can otherwise load the sanitizer only
    /// after its C runtime has initialized, producing interceptor failures
    /// before the crash/recovery worker reaches its authenticated fixture.
    /// Preload the exact runtime already present in this process so child
    /// workers retain the same sanitizer coverage and early startup order.
    private static func loadedThreadSanitizerRuntime() -> String? {
        for imageIndex in 0..<_dyld_image_count() {
            guard let imageName = _dyld_get_image_name(imageIndex) else { continue }
            let path = String(cString: imageName)
            guard URL(fileURLWithPath: path).lastPathComponent == "libclang_rt.tsan_osx_dynamic.dylib" else {
                continue
            }
            return path
        }
        return nil
    }

    private static func collectExit(
        _ exit: ProcessExit,
        worker: WorkerProcess,
        context: ChildLaunchContext
    ) throws -> ChildExit {
        let stdoutData = worker.stdoutCapture.data()
        let stderrData = worker.stderrCapture.data()
        let stdoutPath = Support.diagnosticURL(
            in: context.workspace,
            operation: context.operation,
            checkpoint: context.checkpoint,
            launchID: context.launchID,
            stream: "stdout"
        )
        let stderrPath = Support.diagnosticURL(
            in: context.workspace,
            operation: context.operation,
            checkpoint: context.checkpoint,
            launchID: context.launchID,
            stream: "stderr"
        )
        try stdoutData.write(to: stdoutPath, options: .atomic)
        try stderrData.write(to: stderrPath, options: .atomic)
        return ChildExit(
            pid: exit.pid,
            terminationReason: exit.terminationReason,
            terminationStatus: exit.terminationStatus,
            timedOut: exit.timedOut,
            launchID: context.launchID,
            testBundlePath: context.testBundle.bundleURL.path,
            testExecutablePath: context.testBundle.executableURL.path,
            stdout: String(bytes: stdoutData, encoding: .utf8) ?? "<non-UTF8 output>",
            stderr: String(bytes: stderrData, encoding: .utf8) ?? "<non-UTF8 output>",
            stdoutPath: stdoutPath.path,
            stderrPath: stderrPath.path
        )
    }

    private struct ProcessExit {
        let pid: Int32
        let terminationReason: Process.TerminationReason
        let terminationStatus: Int32
        let timedOut: Bool
    }

    private final class BoundedPipeCapture {
        private let group = DispatchGroup()
        private let lock = NSLock()
        private var capturedData = Data()

        init(handle: FileHandle, limit: Int) {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                var result = Data()
                while true {
                    let bytes = handle.availableData
                    guard !bytes.isEmpty else { break }
                    guard result.count < limit else { continue }
                    result.append(bytes.prefix(limit - result.count))
                }
                lock.lock()
                capturedData = result
                lock.unlock()
                group.leave()
            }
        }

        func data() -> Data {
            group.wait()
            lock.lock()
            defer { lock.unlock() }
            return capturedData
        }
    }

    private static func removePriorEvidence(in workspace: Support.Workspace) throws {
        for url in [
            Support.requestURL(in: workspace),
            Support.startEvidenceURL(in: workspace),
            Support.checkpointEvidenceURL(in: workspace),
            Support.completionEvidenceURL(in: workspace)
        ] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func xctestExecutable() throws -> URL {
        let lookup = Process()
        let output = Pipe()
        lookup.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        lookup.arguments = ["--find", "xctest"]
        lookup.standardOutput = output
        lookup.standardError = FileHandle.nullDevice
        let exit = try waitForChild(lookup, timeout: 5)
        guard !exit.timedOut,
              exit.terminationReason == .exit,
              exit.terminationStatus == 0 else {
            throw Support.HarnessError.invalidRequest
        }
        let pathData = output.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: pathData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else {
            throw Support.HarnessError.invalidRequest
        }
        return URL(fileURLWithPath: path)
    }

    private static func waitForChild(_ process: Process, timeout: TimeInterval) throws -> ProcessExit {
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        let childPID = process.processIdentifier
        guard childPID > 1, childPID != getpid() else {
            throw Support.HarnessError.invalidRequest
        }

        var timedOut = false
        if terminated.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            _ = kill(childPID, SIGTERM)
            if terminated.wait(timeout: .now() + 1) == .timedOut {
                _ = kill(childPID, SIGKILL)
                process.waitUntilExit()
            }
        }
        process.waitUntilExit()
        return ProcessExit(
            pid: childPID,
            terminationReason: process.terminationReason,
            terminationStatus: process.terminationStatus,
            timedOut: timedOut
        )
    }

    private static func validateParentPaths(workspace: Support.Workspace, liveRootURL: URL) throws {
        let rootURL = workspace.rootURL.standardizedFileURL.resolvingSymlinksInPath()
        let temporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard rootURL == workspace.rootURL,
              rootURL.deletingLastPathComponent() == temporaryRoot,
              rootURL.lastPathComponent.hasPrefix("MacClippyPhase5Restore-"),
              liveRootURL.deletingLastPathComponent() == rootURL,
              liveRootURL.lastPathComponent.hasPrefix("live-") else {
            throw Support.HarnessError.invalidRoot
        }
        _ = try MacClippyBackupProcessCrashIsolation.validatedWorkspace(
            rootPath: rootURL.path,
            token: workspace.token
        )
        _ = try MacClippyBackupProcessCrashIsolation.validatedLiveRoot(liveRootURL.path, within: rootURL)
    }
}
