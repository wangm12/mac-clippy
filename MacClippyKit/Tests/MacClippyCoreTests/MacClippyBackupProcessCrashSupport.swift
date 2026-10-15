import CryptoKit
import Foundation
import XCTest

@testable import MacClippyCore

enum MacClippyBackupProcessCrashSupport {
    struct Workspace {
        let rootURL: URL
        let token: String
        let snapshotURL: URL
        let expectedNew: GenerationExpectation?
    }

    struct GenerationExpectation {
        let name: String
        let textRecordID: RecordID
        let imageRecordID: RecordID
        let pinboardID: RecordID
        let snippetID: RecordID
        let textBody: String
        let imageDocument: String
        let imageBlobID: String
        let imagePayload: Data
        let representationBlobID: String
        let representationPayload: Data
        let pinboardName: String
        let snippetName: String
        let snippetBody: String
        let snippetTrigger: String
        let markerPayloads: [String: Data]

        var recordIDs: Set<RecordID> { [textRecordID, imageRecordID] }
    }

    struct ChildRequest: Codable {
        let launchID: String
        let token: String
        let rootPath: String
        let liveRootPath: String
        let operation: Operation
        let checkpoint: String
        let testBundlePath: String
        let testExecutablePath: String
        let testSelector: String
    }

    struct ChildStartEvidence: Codable {
        let launchID: String
        let mode: String
        let token: String
        let processID: Int32
        let selectedTest: String
        let currentDirectoryPath: String
        let testBundlePath: String
        let testExecutablePath: String
        let requestPath: String
    }

    struct ChildCheckpointEvidence: Codable, Equatable {
        let launchID: String
        let token: String
        let operation: Operation
        let checkpoint: String
    }

    struct ChildCompletionEvidence: Codable, Equatable {
        let launchID: String
        let token: String
        let operation: Operation
        let checkpoint: String
        let result: String
    }

    enum Operation: String, Codable, Equatable {
        case install
        case recover
        case recoverComplete
        case finalize
    }

    enum HarnessError: Error {
        case invalidRoot
        case invalidRequest
        case checkpointNotReached
        case invalidTestBundle
    }

    static let oldPayloadName = "phase5-old-payload.bin"
    static let markerName = ".phase5-process-test-marker"
    static let keyName = ".phase5-disposable-key"
    static let requestName = ".phase5-child-request.json"
    static let startEvidenceName = ".phase5-child-start.json"
    static let checkpointEvidenceName = ".phase5-child-checkpoint.json"
    static let completionEvidenceName = ".phase5-child-completion.json"
    static let childModeEnvironmentKey = "MACCLIPPY_PHASE5_RESTORE_CHILD_MODE"
    static let childTokenEnvironmentKey = "MACCLIPPY_PHASE5_RESTORE_CHILD_TOKEN"
    static let childMode = "restore-process-worker-v1"
    static let workerSelector = "MacClippyBackupProcessCrashTests/testChildWorkerEntryPoint"
    static let recoveryCompleteCheckpoint = "completeRecovery"
    static let newGenerationName = "new"
    static let oldGenerationName = "old"
    static let textRepresentationUTI = "public.utf8-plain-text"
    static let imageRepresentationUTI = "public.png"

    static var installCheckpoints: [String] {
        let points = MacClippyBackup.liveComponents.flatMap { component in
            ["beforeInstall:\(component)", "afterInstall:\(component)"]
        }
        return points + ["beforeCommit"]
    }

    static var stagedMoveCheckpoints: [String] {
        MacClippyBackup.liveComponents.map { "duringInstallMove:\($0)" }
    }

    static var recoveryCheckpoints: [String] {
        let points = MacClippyBackup.liveComponents.map { "afterRollback:\($0)" }
        return points + [
            "afterRollbackCommit",
            "beforeTransactionCleanup",
            "afterTransactionCleanup",
            "beforeJournalCleanup"
        ]
    }

    static func makeWorkspace() throws -> Workspace {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootURL = temporaryRoot.appendingPathComponent(
            "MacClippyPhase5Restore-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: false)
        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalRoot.deletingLastPathComponent() == temporaryRoot else {
            throw HarnessError.invalidRoot
        }

        let token = UUID().uuidString
        try Data(token.utf8).write(to: canonicalRoot.appendingPathComponent(markerName), options: .atomic)
        let disposableKey = SymmetricKey(size: .bits256)
        let keyBytes = disposableKey.withUnsafeBytes { Data($0) }
        try MacClippyBackupProcessCrashChildProtocol.writeDurably(
            keyBytes,
            to: canonicalRoot.appendingPathComponent(keyName)
        )
        let snapshotURL = canonicalRoot.appendingPathComponent("snapshot", isDirectory: true)
        let expectedNew = try MacClippyBackupProcessCrashFixtures.makeSnapshot(
            at: snapshotURL,
            key: disposableKey
        )
        return Workspace(
            rootURL: canonicalRoot,
            token: token,
            snapshotURL: snapshotURL,
            expectedNew: expectedNew
        )
    }

    static func seedOldRoot(at liveRootURL: URL) throws -> GenerationExpectation {
        try MacClippyBackupProcessCrashFixtures.seedOldRoot(
            at: liveRootURL,
            key: testKey(at: liveRootURL.deletingLastPathComponent())
        )
    }

    static func testKey(at workspaceRootURL: URL) throws -> SymmetricKey {
        let keyURL = workspaceRootURL.appendingPathComponent(keyName)
        let values = try keyURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let keyData = try Data(contentsOf: keyURL)
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              keyData.count == 32 else {
            throw HarnessError.invalidRoot
        }
        return SymmetricKey(data: keyData)
    }

    static func oldPayload(for component: String) -> Data {
        Data("phase5 synthetic old payload for \(component)".utf8)
    }

    static func requestURL(in workspace: Workspace) -> URL {
        workspace.rootURL.appendingPathComponent(requestName)
    }

    static func startEvidenceURL(in workspace: Workspace) -> URL {
        workspace.rootURL.appendingPathComponent(startEvidenceName)
    }

    static func checkpointEvidenceURL(in workspace: Workspace) -> URL {
        workspace.rootURL.appendingPathComponent(checkpointEvidenceName)
    }

    static func completionEvidenceURL(in workspace: Workspace) -> URL {
        workspace.rootURL.appendingPathComponent(completionEvidenceName)
    }

    static func diagnosticURL(
        in workspace: Workspace,
        operation: Operation,
        checkpoint: String,
        launchID: String,
        stream: String
    ) -> URL {
        let safeCheckpoint = checkpoint.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" ? character : "_"
        }
        return workspace.rootURL.appendingPathComponent(
            "child-\(operation.rawValue)-\(String(safeCheckpoint))-\(launchID)-\(stream).log"
        )
    }

}
