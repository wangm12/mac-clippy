import Foundation
import XCTest

import GRDB
@testable import MacClippyCore

private final class MacClippyMaintenanceTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class MacClippyBoundedHealthTests: XCTestCase {
    func testBoundedHealthSkipsFullScansForLargeHealthyTable() throws {
        let (root, databaseURL) = try makeDatabaseURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MacClippyDatabase(url: databaseURL)
        try database.queue.write { connection in
            try connection.execute(sql: "CREATE TABLE health_probe(value TEXT NOT NULL)")
            try connection.execute(sql: """
                WITH RECURSIVE rows(value) AS (
                    SELECT 1 UNION ALL SELECT value + 1 FROM rows WHERE value < 10000
                )
                INSERT INTO health_probe(value) SELECT printf('row-%05d', value) FROM rows
                """)
        }
        let fullIntegrityRuns = MacClippyMaintenanceTestCounter()
        let foreignKeyRuns = MacClippyMaintenanceTestCounter()
        MacClippyMaintenanceDBHealthTestHooks.setCallbacks(
            integrityCheck: { fullIntegrityRuns.increment() },
            foreignKeyCheck: { foreignKeyRuns.increment() }
        )
        defer {
            MacClippyMaintenanceDBHealthTestHooks.setCallbacks(
                integrityCheck: nil,
                foreignKeyCheck: nil
            )
        }

        let report = database.healthCheck(requiredTables: ["health_probe"])

        XCTAssertEqual(try database.tableRowCount("health_probe"), 10000)
        XCTAssertEqual(report.status, .healthy)
        XCTAssertTrue(report.quickCheckPassed)
        XCTAssertNil(report.fullIntegrityCheckPassed)
        XCTAssertNil(report.foreignKeyCheckPerformed)
        XCTAssertTrue(report.issues.contains("sqlite-integrity-check-skipped"))
        XCTAssertTrue(report.issues.contains("foreign-key-check-skipped"))
        XCTAssertEqual(fullIntegrityRuns.value, 0)
        XCTAssertEqual(foreignKeyRuns.value, 0)
        try database.queue.close()
    }

    func testClosedDatabaseCannotOpenBackupReadSnapshot() throws {
        let (root, databaseURL) = try makeDatabaseURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MacClippyDatabase(url: databaseURL)
        try database.queue.write { connection in
            try connection.execute(sql: "CREATE TABLE health_probe(value TEXT NOT NULL)")
        }
        try database.closeForReplacement()

        XCTAssertThrowsError(try database.beginBackupReadSnapshot(name: "clipboard"))
        XCTAssertEqual(database.healthCheck().status, .unrecoverable)
        let full = database.healthCheck(mode: .full)
        XCTAssertEqual(full.status, .unrecoverable)
        XCTAssertNil(full.fullIntegrityCheckPassed)
        XCTAssertNil(full.foreignKeyCheckPerformed)
        XCTAssertFalse(full.issues.contains("sqlite-integrity-check-failed"))
    }

    func testFileBackedWALSnapshotKeepsPinnedViewAndReplacementWaitsForClose() throws {
        let (root, databaseURL) = try makeDatabaseURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MacClippyDatabase(url: databaseURL)
        try database.queue.write { connection in
            try connection.execute(sql: "CREATE TABLE snapshot_probe(value TEXT NOT NULL)")
            try connection.execute(sql: "INSERT INTO snapshot_probe(value) VALUES ('pinned')")
        }
        let snapshot = try database.beginBackupReadSnapshot(name: "clipboard")

        try database.queue.write { connection in
            try connection.execute(sql: "UPDATE snapshot_probe SET value = 'newer'")
        }
        let backupURL = root.appendingPathComponent("snapshot.sqlite")
        try snapshot.copy(to: backupURL, shouldContinue: { true })
        let copied = try DatabaseQueue(path: backupURL.path)
        let copiedValue = try copied.read { connection in
            try String.fetchOne(connection, sql: "SELECT value FROM snapshot_probe")
        }
        XCTAssertEqual(copiedValue, "pinned")
        try copied.close()

        let closeStarted = DispatchSemaphore(value: 0)
        let closeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            closeStarted.signal()
            try? database.closeForReplacement()
            closeFinished.signal()
        }
        XCTAssertEqual(closeStarted.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 0.05), .timedOut)

        snapshot.close()
        XCTAssertEqual(closeFinished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(database.healthCheck().status, .unrecoverable)
    }

    func testCancelledFullHealthCheckDoesNotReportDatabaseCorruption() throws {
        let (root, databaseURL) = try makeDatabaseURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MacClippyDatabase(url: databaseURL)
        try database.queue.write { connection in
            try connection.execute(sql: "CREATE TABLE health_probe(value TEXT NOT NULL)")
            try connection.execute(sql: "INSERT INTO health_probe(value) VALUES ('healthy')")
        }
        let integrityRuns = MacClippyMaintenanceTestCounter()
        let foreignKeyRuns = MacClippyMaintenanceTestCounter()
        MacClippyMaintenanceDBHealthTestHooks.setCallbacks(
            integrityCheck: { integrityRuns.increment() },
            foreignKeyCheck: { foreignKeyRuns.increment() }
        )
        defer {
            MacClippyMaintenanceDBHealthTestHooks.setCallbacks(
                integrityCheck: nil,
                foreignKeyCheck: nil
            )
        }

        let report = database.healthCheck(
            requiredTables: ["health_probe"],
            mode: .full,
            shouldContinue: { integrityRuns.value == 0 }
        )

        XCTAssertEqual(integrityRuns.value, 1)
        XCTAssertEqual(foreignKeyRuns.value, 0)
        XCTAssertEqual(report.status, .degraded)
        XCTAssertNil(report.fullIntegrityCheckPassed)
        XCTAssertNil(report.foreignKeyCheckPerformed)
        XCTAssertTrue(report.issues.contains("database-health-check-cancelled"))
        try database.queue.close()
    }

    func testFullHealthDetectsCorruptTableRootPage() throws {
        let (root, databaseURL) = try makeDatabaseURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try MacClippyDatabase(url: databaseURL)
        try database.queue.write { connection in
            try connection.execute(sql: "CREATE TABLE health_probe(value TEXT NOT NULL)")
            try connection.execute(sql: "INSERT INTO health_probe(value) VALUES ('stored')")
        }
        let pageDetails = try database.queue.read { connection in
            let pageSize = try Int.fetchOne(connection, sql: "PRAGMA page_size") ?? 0
            let rootPage = try Int.fetchOne(
                connection,
                sql: "SELECT rootpage FROM sqlite_master WHERE name = 'health_probe'"
            ) ?? 0
            return (pageSize, rootPage)
        }
        try database.queue.writeWithoutTransaction { connection in
            try connection.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        try database.queue.close()

        let corruptOffset = UInt64((pageDetails.1 - 1) * pageDetails.0)
        let file = try FileHandle(forWritingTo: databaseURL)
        try file.seek(toOffset: corruptOffset)
        try file.write(contentsOf: Data([0]))
        try file.close()

        let readOnly = try MacClippyDatabase(url: databaseURL, readOnly: true)
        let bounded = readOnly.healthCheck(requiredTables: ["health_probe"])
        let full = readOnly.healthCheck(requiredTables: ["health_probe"], mode: .full)

        XCTAssertEqual(bounded.status, .healthy)
        XCTAssertNil(bounded.fullIntegrityCheckPassed)
        XCTAssertEqual(full.status, .unrecoverable)
        XCTAssertEqual(full.fullIntegrityCheckPassed, false)
        XCTAssertEqual(full.foreignKeyCheckPerformed, true)
        XCTAssertTrue(full.issues.contains("sqlite-integrity-check-failed"))
        try readOnly.queue.close()
    }

    private func makeDatabaseURL() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacClippyBoundedHealth-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, root.appendingPathComponent("health.sqlite"))
    }
}
