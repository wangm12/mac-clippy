import Foundation

import MacClippyCore

extension MacClippyRuntime {
    func diagnosticsStorageSnapshot() throws -> MacClippyDiagnosticsStorageSnapshot {
        let health = storageHealth()
        return withStoreLock {
            var rowCounts: [String: Int64] = [:]
            var rowCountIssues: [String: String] = [:]

            func captureRowCount(_ name: String, _ query: () throws -> Int64?) {
                do {
                    guard let count = try query() else {
                        rowCountIssues[name] = "row-count-unavailable"
                        return
                    }
                    rowCounts[name] = count
                } catch {
                    // Diagnostics must identify an infrastructure failure as
                    // degraded storage instead of turning it into an empty
                    // database by using a zero fallback. Keep the code
                    // redacted; the underlying error may contain a path.
                    rowCountIssues[name] = "row-count-query-failed"
                }
            }

            captureRowCount("clipboard") { try clipboardStore.databaseRowCount() }
            captureRowCount("search") { try searchStore.databaseRowCount() }
            captureRowCount("pinboards") { try pinboardStore.databaseRowCount() }
            captureRowCount("snippets") { try snippetStore.databaseRowCount() }

            return MacClippyDiagnosticsStorageSnapshot(
                databaseHealth: health,
                databaseRowCounts: rowCounts,
                databaseRowCountIssues: rowCountIssues,
                captureQueue: captureQueueAdmission.snapshot
            )
        }
    }
}
