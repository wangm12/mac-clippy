#if MACCLIPPY_E2E
import AppKit
import CryptoKit
import Foundation
import Darwin
import QuartzCore

import MacClippyCore
import MacClippyPlatform

struct MacClippyE2EControlRequest: Codable, Sendable {
    let command: String
    let recordID: String?
    let token: String?
    let text: String?
    let format: String?
    let query: String?
    let timeoutSeconds: Double?
    let count: Int?
    let limit: Int?
    let cycles: Int?
    let plain: Bool?
    let operationID: String?
    let payloadKind: String?
    let itemCount: Int?
    let repeatPrimaryUTI: Bool?
    let fileByteCount: Int?
    let forcePoll: Bool?
}

@propertyWrapper
struct MacClippyE2EExplicitNull<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var wrappedValue: Value?

    init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = nil
        } else {
            wrappedValue = try container.decode(Value.self)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}

struct MacClippyE2ERepresentationProof: Codable, Equatable, Sendable {
    let itemIndex: Int
    let uti: String
    let payloadState: String
    @MacClippyE2EExplicitNull var byteCount: Int?
    @MacClippyE2EExplicitNull var sha256: String?
}

struct MacClippyE2EControlResponse: Codable, Sendable {
    let isOK: Bool
    var errorCode: String?
    var message: String?
    var ready: Bool?
    var pid: Int32?
    var bundleIdentifier: String?
    var rootPath: String?
    var runID: String?
    var executablePath: String?
    var buildConfiguration: String?
    var sourceContentSHA256: String?
    var operationID: String?
    var recordID: String?
    var matchedRecordIDs: [String]?
    var recordCount: Int?
    var payloadByteCount: Int?
    var primaryContentKind: String?
    var capturedItemCount: Int?
    var fixtureFileByteCount: Int?
    var rawPayloadUTI: String?
    var rawPayloadByteCount: Int?
    var rawPayloadSHA256: String?
    var rawPayloadRoundTrip: Bool?
    var spilledRepresentationCount: Int?
    var pasteboardTypes: [String]?
    var sourceAppBundleIdentifier: String?
    var ingestionMode: String?
    var hitCount: Int?
    var visibleCount: Int?
    var elapsedMilliseconds: Double?
    var uiLatencyMilliseconds: Double?
    var ipcAcceptedAtUptimeNanoseconds: UInt64?
    var completedAtUptimeNanoseconds: UInt64?
    var nativeHostVisible: Bool?
    var panelVisible: Bool?
    var panelReadiness: [String: Bool]?
    var uiInteractionSamples: [MacClippyE2EUIInteractionSample]?
    var previewVisible: Bool?
    var previewContentReady: Bool?
    var searchCompleted: Bool?
    var contentInserted: Bool?
    var recipientSHA256: String?
    var recipientByteCount: Int?
    var recipientInsertionCount: Int?
    var recipientPostRoute: String?
    var recipientTypes: [String]?
    var recipientLabel: String?
    var actualOSAXInjectionPerformed: Bool?
    var pasteResult: String?
    var pasteInjectionProbe: MacClippyE2EPasteProbeEvidence?
    var captureQueueDepth: Int?
    var captureQueueBytes: Int?
    var ocrQueueDepth: Int?
    var ocrQueueBytes: Int?
    var maintenanceQueueDepth: Int?
    var clipboardWALBytes: Int64?
    var searchWALBytes: Int64?
    var pinboardWALBytes: Int64?
    var snippetWALBytes: Int64?
    var unavailableMetrics: [String] = []
    var pasteBarrierWaiting: Bool?
    var pasteBarrierReleased: Bool?
    var pasteOperationCompleted: Bool?
    var captureQueueDroppedChangeCount: Int?
    var captureQueueRecoveredChangeCount: Int?
    var captureQueueHasUnrecoveredChanges: Bool?
    var captureNotSavedCount: Int?
    var capturePersistFailureCount: Int?
    var captureQueueOverloadErrorCount: Int?
    var captureQueueCurrentGenReadRequestCount: Int?
    var retentionMaxItems: Int?
    var retentionMaxImageBytes: Int?
    var retentionMaxTotalBytes: Int?
    @MacClippyE2EExplicitNull var decodedText: String?
    var representations: [MacClippyE2ERepresentationProof]?
    var recipientRepresentations: [MacClippyE2ERepresentationProof]?

    enum CodingKeys: String, CodingKey {
        case isOK = "ok"
        case errorCode
        case message
        case ready
        case pid
        case bundleIdentifier
        case rootPath
        case runID
        case executablePath
        case buildConfiguration
        case sourceContentSHA256
        case operationID
        case recordID
        case matchedRecordIDs
        case recordCount
        case payloadByteCount
        case primaryContentKind
        case capturedItemCount
        case fixtureFileByteCount
        case rawPayloadUTI
        case rawPayloadByteCount
        case rawPayloadSHA256
        case rawPayloadRoundTrip
        case spilledRepresentationCount
        case pasteboardTypes
        case sourceAppBundleIdentifier
        case ingestionMode
        case hitCount
        case visibleCount
        case elapsedMilliseconds
        case uiLatencyMilliseconds
        case ipcAcceptedAtUptimeNanoseconds
        case completedAtUptimeNanoseconds
        case nativeHostVisible
        case panelVisible
        case panelReadiness
        case uiInteractionSamples
        case previewVisible
        case previewContentReady
        case searchCompleted
        case contentInserted
        case recipientSHA256
        case recipientByteCount
        case recipientInsertionCount
        case recipientPostRoute
        case recipientTypes
        case recipientLabel
        case actualOSAXInjectionPerformed
        case pasteResult
        case pasteInjectionProbe
        case captureQueueDepth
        case captureQueueBytes
        case ocrQueueDepth
        case ocrQueueBytes
        case maintenanceQueueDepth
        case clipboardWALBytes
        case searchWALBytes
        case pinboardWALBytes
        case snippetWALBytes
        case unavailableMetrics
        case pasteBarrierWaiting
        case pasteBarrierReleased
        case pasteOperationCompleted
        case captureQueueDroppedChangeCount
        case captureQueueRecoveredChangeCount
        case captureQueueHasUnrecoveredChanges
        case captureNotSavedCount
        case capturePersistFailureCount
        case captureQueueOverloadErrorCount
        case captureQueueCurrentGenReadRequestCount = "captureQueueCurrentGenerationReadRequestCount"
        case retentionMaxItems
        case retentionMaxImageBytes
        case retentionMaxTotalBytes
        case decodedText
        case representations
        case recipientRepresentations
    }
}

extension MacClippyE2EControlResponse {
    init(ok value: Bool, errorCode: String) {
        self.init(isOK: value, errorCode: errorCode)
    }
}

final class MacClippyE2EControlServer: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (
        MacClippyE2EControlRequest,
        UInt64
    ) async -> MacClippyE2EControlResponse

    private static let maximumRequestBytes = 2 * 1_024 * 1_024
    private let socketURL: URL
    private let queue = DispatchQueue(label: "com.macallyouneed.macclippy.e2e-control")
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private let descriptorLock = NSLock()

    init(rootURL: URL) throws {
        socketURL = rootURL.appendingPathComponent("control.sock")
        let maximumPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard socketURL.path.utf8.count + 1 < maximumPathLength else {
            throw MacClippyE2EIsolationError.controlSocketPathTooLong
        }
    }

    func start(handler: @escaping Handler) throws {
        try removeOwnedStaleSocketIfPresent()
        let serverDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverDescriptor >= 0 else { throw MacClippyE2EIsolationError.invalidConfiguration }
        let descriptorFlags = fcntl(serverDescriptor, F_GETFL)
        guard descriptorFlags >= 0,
              fcntl(serverDescriptor, F_SETFL, descriptorFlags | O_NONBLOCK) == 0 else {
            close(serverDescriptor)
            throw MacClippyE2EIsolationError.invalidConfiguration
        }

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: pathBytes)
        }
        let bindResult = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(
                    serverDescriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0,
              chmod(socketURL.path, mode_t(S_IRUSR | S_IWUSR)) == 0,
              Darwin.listen(serverDescriptor, 16) == 0 else {
            close(serverDescriptor)
            _ = unlink(socketURL.path)
            throw MacClippyE2EIsolationError.invalidConfiguration
        }

        descriptorLock.lock()
        descriptor = serverDescriptor
        descriptorLock.unlock()
        let readSource = DispatchSource.makeReadSource(fileDescriptor: serverDescriptor, queue: queue)
        readSource.setEventHandler { [weak self] in
            self?.acceptConnections(handler: handler)
        }
        readSource.setCancelHandler {
            close(serverDescriptor)
        }
        source = readSource
        readSource.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        descriptorLock.lock()
        descriptor = -1
        descriptorLock.unlock()
        _ = unlink(socketURL.path)
    }

    private func removeOwnedStaleSocketIfPresent() throws {
        var info = stat()
        guard lstat(socketURL.path, &info) == 0 else {
            if errno == ENOENT { return }
            throw MacClippyE2EIsolationError.invalidConfiguration
        }
        guard (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == getuid() else {
            throw MacClippyE2EIsolationError.invalidConfiguration
        }
        guard unlink(socketURL.path) == 0 else {
            throw MacClippyE2EIsolationError.invalidConfiguration
        }
    }

    private func acceptConnections(handler: @escaping Handler) {
        descriptorLock.lock()
        let serverDescriptor = descriptor
        descriptorLock.unlock()
        guard serverDescriptor >= 0 else { return }

        while true {
            let clientDescriptor = Darwin.accept(serverDescriptor, nil, nil)
            guard clientDescriptor >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return }
                return
            }
            let clientFlags = fcntl(clientDescriptor, F_GETFL)
            guard clientFlags >= 0,
                  fcntl(clientDescriptor, F_SETFL, clientFlags | O_NONBLOCK) == 0 else {
                close(clientDescriptor)
                continue
            }
            DispatchQueue.global(qos: .utility).async {
                Self.receiveAndDispatch(clientDescriptor, handler: handler)
            }
        }
    }

    private static func receiveAndDispatch(_ descriptor: Int32, handler: @escaping Handler) {
        guard let request = receiveRequest(from: descriptor) else {
            send(
                MacClippyE2EControlResponse(isOK: false, errorCode: "invalid-request"),
                to: descriptor
            )
            close(descriptor)
            return
        }
        let acceptedAt = DispatchTime.now().uptimeNanoseconds
        Task { @MainActor in
            var response = await handler(request, acceptedAt)
            response.ipcAcceptedAtUptimeNanoseconds = acceptedAt
            response.completedAtUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
            let responseForSending = response
            DispatchQueue.global(qos: .utility).async {
                send(responseForSending, to: descriptor)
                close(descriptor)
            }
        }
    }

    private static func receiveRequest(from descriptor: Int32) -> MacClippyE2EControlRequest? {
        guard let data = MacClippyUnixSocketLineTransport.readLine(
            from: descriptor,
            maximumBytes: maximumRequestBytes,
            timeout: 10
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(MacClippyE2EControlRequest.self, from: data)
    }

    private static func send(_ response: MacClippyE2EControlResponse, to descriptor: Int32) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        _ = MacClippyUnixSocketLineTransport.writeLine(data, to: descriptor, timeout: 10)
    }
}
#endif
