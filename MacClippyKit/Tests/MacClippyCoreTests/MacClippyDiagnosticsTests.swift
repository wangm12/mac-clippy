import Foundation
import XCTest

import MacClippyCore

final class MacClippyDiagnosticsTests: XCTestCase {
    func testMetricSnapshotAggregatesCountTotalMaxAndAverage() {
        let recorder = MacClippyDiagnosticsRecorder(capacity: 4)

        recorder.recordMetric(operation: "search_history", durationMilliseconds: 4)
        recorder.recordMetric(operation: "search_history", durationMilliseconds: 6)

        let metric = recorder.metricSnapshot()["search_history"]
        XCTAssertEqual(metric?.count, 2)
        XCTAssertEqual(metric?.totalDurationMilliseconds, 10)
        XCTAssertEqual(metric?.maxDurationMilliseconds, 6)
        XCTAssertEqual(metric?.averageDurationMilliseconds, 5)
    }

    func testMetricOperationNamesAreTrimmedAndBounded() {
        let recorder = MacClippyDiagnosticsRecorder(capacity: 2)

        recorder.recordMetric(operation: "   ", durationMilliseconds: 10)
        recorder.recordMetric(operation: String(repeating: "x", count: 65), durationMilliseconds: 10)
        recorder.recordMetric(operation: "  capture  ", durationMilliseconds: 3)

        XCTAssertEqual(recorder.metricSnapshot().count, 1)
        XCTAssertEqual(recorder.metricSnapshot()["capture"]?.count, 1)
    }

    func testMetricKeyCapacityKeepsSnapshotBounded() {
        let recorder = MacClippyDiagnosticsRecorder(capacity: 2)

        recorder.recordMetric(operation: "one", durationMilliseconds: 1)
        recorder.recordMetric(operation: "two", durationMilliseconds: 2)
        recorder.recordMetric(operation: "three", durationMilliseconds: 3)

        XCTAssertEqual(Set(recorder.metricSnapshot().keys), ["one", "two"])
    }

    func testClearRemovesEventsAndMetrics() {
        let recorder = MacClippyDiagnosticsRecorder(capacity: 2)
        recorder.record(
            MacClippyDiagnosticsEvent(
                category: .storage,
                code: .databaseHealthFailed,
                operation: "health"
            )
        )
        recorder.recordMetric(operation: "storage_reconciliation", durationMilliseconds: 9)

        recorder.clear()

        XCTAssertTrue(recorder.recentEvents().isEmpty)
        XCTAssertTrue(recorder.metricSnapshot().isEmpty)
    }
}
