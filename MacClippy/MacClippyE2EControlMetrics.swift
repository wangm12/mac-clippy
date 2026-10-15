#if MACCLIPPY_E2E
import AppKit
import CryptoKit
import Foundation
import MacClippyCore
import MacClippyPlatform

@MainActor
extension AppDelegate {
    func makeE2EMetricsResponse(
        runtime: MacClippyRuntime,
        paths: MacClippyPaths
    ) -> MacClippyE2EControlResponse {
        let capture = runtime.captureQueueAdmission.snapshot
        let ocr = runtime.captureQueue.sync {
            (runtime.pendingOCRJobs, runtime.pendingOCRBytes)
        }
        let walSizes = [
            "clipboardWALBytes": Self.walSize(for: paths.clipboardDatabaseURL),
            "searchWALBytes": Self.walSize(for: paths.searchDatabaseURL),
            "pinboardWALBytes": Self.walSize(for: paths.pinboardDatabaseURL),
            "snippetWALBytes": Self.walSize(for: paths.snippetDatabaseURL)
        ]
        let retention = runtime.retentionPolicyOverride
            ?? MacClippyRetentionPreferences.policy(from: runtime.preferencesDefaults)
        var unavailableMetrics = ["maintenanceQueueDepth"] + walSizes.compactMap {
            $0.value == nil ? $0.key : nil
        }
        if retention.maxItems == nil { unavailableMetrics.append("retentionMaxItems") }
        if retention.maxImageBytes == nil { unavailableMetrics.append("retentionMaxImageBytes") }
        if retention.maxTotalBytes == nil { unavailableMetrics.append("retentionMaxTotalBytes") }
        return MacClippyE2EControlResponse(
            isOK: true,
            nativeHostVisible: e2eRecipient?.nativeHostIsVisible == true,
            panelReadiness: e2ePanelReadiness,
            uiInteractionSamples: MacClippyE2EUIInteractionProbe.shared.samples,
            captureQueueDepth: capture.outstandingJobs,
            captureQueueBytes: capture.estimatedRetainedBytes,
            ocrQueueDepth: max(ocr.0, runtime.ocrQueue.operationCount),
            ocrQueueBytes: ocr.1,
            maintenanceQueueDepth: nil,
            clipboardWALBytes: walSizes["clipboardWALBytes"] ?? nil,
            searchWALBytes: walSizes["searchWALBytes"] ?? nil,
            pinboardWALBytes: walSizes["pinboardWALBytes"] ?? nil,
            snippetWALBytes: walSizes["snippetWALBytes"] ?? nil,
            unavailableMetrics: unavailableMetrics,
            captureQueueDroppedChangeCount: capture.droppedChangeCount,
            captureQueueRecoveredChangeCount: capture.recoveredChangeCount,
            captureQueueHasUnrecoveredChanges: capture.hasUnrecoveredClipboardChanges,
            captureNotSavedCount: capture.notSavedCount,
            capturePersistFailureCount: capture.persistFailureCount,
            captureQueueOverloadErrorCount: capture.overloadErrorCount,
            captureQueueCurrentGenReadRequestCount: capture.currentGenerationReadRequestCount,
            retentionMaxItems: retention.maxItems,
            retentionMaxImageBytes: retention.maxImageBytes,
            retentionMaxTotalBytes: retention.maxTotalBytes
        )
    }

    private var e2ePanelReadiness: [String: Bool] {
        guard let controller = dockController else { return [:] }
        return [
            "applicationActive": NSApp.isActive,
            "visible": controller.panel?.isVisible == true,
            "keyWindow": controller.panel?.isKeyWindow == true,
            "initialPaint": controller.model.hasCompletedInitialPaint,
            "loading": controller.model.isLoading,
            "closing": controller.isClosing,
            "menuTracking": controller.nativeMenuTrackingDepth > 0,
            "filterPopover": controller.model.isFilterPopoverPresented,
            "searchMode": controller.interactionMode == .search,
            "searchFocusRequested": controller.model.searchFocusIsRequested,
            "searchFieldFirstResponder": controller.searchFieldIsFirstResponder,
            "modalMode": controller.interactionMode == .modal
        ]
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return nil }
        return size.int64Value
    }

    private static func walSize(for databaseURL: URL) -> Int64? {
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        guard FileManager.default.fileExists(atPath: walURL.path) else { return 0 }
        return fileSize(at: walURL)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
