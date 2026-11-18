import MacClippyCore

extension MacClippyRuntime {
    private static let storageUsagePageSize = 64

    func storageUsage() throws -> MacClippyStorageUsage {
        let caps = retentionPolicyOverride ?? MacClippyRetentionPreferences.policy(from: preferencesDefaults)
        let itemCount = try withStoreLock { Int(try clipboardStore.databaseRowCount() ?? 0) }
        let imageBytes = try storageUsageImageBytes()
        #if DEBUG
            MacClippyMaintenanceIOTestHooks.afterStorageSnapshot()
        #endif
        let totalBytes = MacClippyStorageDashboardPolicy.directoryByteCount(at: paths.blobsURL)
            + MacClippyStorageDashboardPolicy.directoryByteCount(at: paths.databasesURL)
        return MacClippyStorageUsage(
            itemCount: itemCount,
            imageBytes: imageBytes,
            totalBytes: totalBytes,
            maxItems: caps.maxItems ?? MacClippyStorageCapPolicy.defaultMaxItems,
            maxImageBytes: Int64(
                caps.maxImageBytes
                    ?? MacClippyStorageCapPolicy.defaultMaxImageMegabytes * 1_024 * 1_024
            ),
            maxTotalBytes: Int64(
                caps.maxTotalBytes
                    ?? MacClippyStorageCapPolicy.defaultMaxHistoryMegabytes * 1_024 * 1_024
            )
        )
    }

    private func storageUsageImageBytes() throws -> Int64 {
        var total: Int64 = 0
        var cursor: String?
        while true {
            let page = try withStoreLock {
                try clipboardStore.indexedImageBlobIDs(
                    after: cursor,
                    limit: Self.storageUsagePageSize
                )
            }
            for blobID in page {
                if let size = try? blobStore.byteSizeChecked(id: blobID) {
                    total += Int64(size)
                }
            }
            guard page.count == Self.storageUsagePageSize, let last = page.last else { break }
            cursor = last
        }
        return total
    }
}
