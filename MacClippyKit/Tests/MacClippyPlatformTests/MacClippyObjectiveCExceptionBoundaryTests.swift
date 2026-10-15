import AppKit
import Foundation
import XCTest

import MacClippyCore
@_spi(Testing) @testable import MacClippyPlatform

final class MacClippyObjCExceptionTests: XCTestCase {
    func testNativePasteboardReadConvertsExceptionToBoundedTypedFailure() throws {
        let pasteboard = makeNamedPasteboard()
        let coordinator = MacClippyPasteboardAccessCoordinator.shared(for: pasteboard)
        let item = NSPasteboardItem()
        XCTAssertTrue(try MacClippyNativePasteboard.set("native read exception", on: item, forType: .string))

        MacClippyNativePasteboard.injectExceptionForTesting(after: "pasteboard.item-data")
        XCTAssertThrowsError(
            try coordinator.withAccess {
                try MacClippyNativePasteboard.data(from: item, forType: .string)
            }
        ) { error in
            guard let nativeError = error as? MacClippyObjectiveCException else {
                return XCTFail("expected a typed Objective-C exception")
            }
            XCTAssertEqual(nativeError.operation, "pasteboard.item-data")
            XCTAssertEqual(nativeError.name, "MacClippyInjectedPasteboardException")
            XCTAssertLessThanOrEqual(nativeError.reason.count, 512)
            XCTAssertLessThanOrEqual(nativeError.callStack.count, 8)
            XCTAssertTrue(nativeError.localizedDescription.contains("MacClippyInjectedPasteboardException"))
        }
        assertCoordinatorCanBeAcquiredFromAnotherQueue(coordinator)
        XCTAssertEqual(
            try MacClippyNativePasteboard.data(from: item, forType: .string),
            Data("native read exception".utf8)
        )
    }

    func testEveryNarrowPasteboardShimCatchesItsNativeException() throws {
        let pasteboard = makeNamedPasteboard()
        let coordinator = MacClippyPasteboardAccessCoordinator.shared(for: pasteboard)
        let item = NSPasteboardItem()
        XCTAssertTrue(try MacClippyNativePasteboard.set(Data("synthetic data".utf8), on: item, forType: .string))
        XCTAssertTrue(try MacClippyNativePasteboard.set("synthetic string", on: item, forType: .html))

        let operations: [(String, () throws -> Void)] = [
            ("pasteboard.change-count", { _ = try MacClippyNativePasteboard.changeCount(of: pasteboard) }),
            ("pasteboard.items", { _ = try MacClippyNativePasteboard.items(of: pasteboard) }),
            ("pasteboard.board-types", { _ = try MacClippyNativePasteboard.boardTypes(of: pasteboard) }),
            ("pasteboard.item-types", { _ = try MacClippyNativePasteboard.types(of: item) }),
            ("pasteboard.item-data", { _ = try MacClippyNativePasteboard.data(from: item, forType: .string) }),
            ("pasteboard.item-string", { _ = try MacClippyNativePasteboard.string(from: item, forType: .html) }),
            ("pasteboard.board-data", { _ = try MacClippyNativePasteboard.data(from: pasteboard, forType: .string) }),
            ("pasteboard.board-string", {
                _ = try MacClippyNativePasteboard.string(from: pasteboard, forType: .string)
            }),
            ("pasteboard.clear", { try MacClippyNativePasteboard.clear(pasteboard) }),
            ("pasteboard.write-objects", { _ = try MacClippyNativePasteboard.write([item], to: pasteboard) }),
            ("pasteboard.set-item-data", {
                _ = try MacClippyNativePasteboard.set(Data("updated".utf8), on: item, forType: .string)
            }),
            ("pasteboard.set-item-string", {
                _ = try MacClippyNativePasteboard.set("updated", on: item, forType: .html)
            })
        ]

        for (operation, invoke) in operations {
            MacClippyNativePasteboard.injectExceptionForTesting(after: operation)
            XCTAssertThrowsError(
                try coordinator.withAccess(invoke),
                "\(operation) must convert NSException before it returns to Swift"
            ) { error in
                XCTAssertEqual((error as? MacClippyObjectiveCException)?.operation, operation)
                XCTAssertEqual((error as? MacClippyObjectiveCException)?.name, "MacClippyInjectedPasteboardException")
            }
            assertCoordinatorCanBeAcquiredFromAnotherQueue(coordinator)
        }
    }

    func testNativeWriteAndReadExceptionsReleaseCoordinatorAndObserverControlCompletesOnce() throws {
        let pasteboard = makeNamedPasteboard()
        let coordinator = MacClippyPasteboardAccessCoordinator.shared(for: pasteboard)
        let item = NSPasteboardItem()
        XCTAssertTrue(
            try MacClippyNativePasteboard.set(
                Data("before native write exception".utf8),
                on: item,
                forType: .string
            )
        )

        // NSPasteboardItem is synthetic test data; its native setData call is
        // still the actual narrow AppKit write shim. The exception is raised
        // after setData and caught before Swift resumes under coordinator
        // ownership, independent of the host pasteboard service.
        MacClippyNativePasteboard.injectExceptionForTesting(after: "pasteboard.set-item-data")
        XCTAssertThrowsError(try coordinator.withAccess {
            try MacClippyNativePasteboard.set(Data("after native write exception".utf8), on: item, forType: .string)
        }) { error in
            XCTAssertEqual((error as? MacClippyObjectiveCException)?.operation, "pasteboard.set-item-data")
        }
        assertCoordinatorCanBeAcquiredFromAnotherQueue(coordinator)
        XCTAssertEqual(
            try MacClippyNativePasteboard.data(from: item, forType: .string),
            Data("after native write exception".utf8),
            "the native write happened before the injected exception was converted"
        )

        let readerFailures = LockedValues<MacClippyObjectiveCException>()
        let systemReader = MacClippySystemPasteboardReader(
            pasteboard: pasteboard,
            sourceAppBundleID: { nil },
            accessCoordinator: coordinator,
            onReadFailure: { readerFailures.append($0) }
        )
        let pasteboardGeneration = try MacClippyNativePasteboard.changeCount(of: pasteboard)
        XCTAssertEqual(systemReader.read().changeCount, pasteboardGeneration)
        XCTAssertTrue(readerFailures.values.isEmpty)

        let observer = MacClippyPasteboardObserver(
            reader: systemReader,
            pollInterval: 60,
            queue: DispatchQueue(label: "MacClippyNativeExceptionRecoveryTests.observer"),
            secondsSinceLastUserInput: { 0 }
        )
        observer.disableAutomaticPollingForTesting()
        let deliveries = LockedValues<PasteboardChange>()
        observer.start { deliveries.append($0) }
        observer.poll()

        // This is the production observer's bounded current-generation
        // control request. Its completion and event delivery must still run
        // after the actual native exception boundary and cross-queue lock check.
        let controlResult = requestCurrentGenerationRead(from: observer)
        observer.poll()
        observer.stop()

        XCTAssertEqual(controlResult.completionCounts, [1])
        XCTAssertEqual(controlResult.changeCounts, [pasteboardGeneration])
        XCTAssertTrue(deliveries.values.isEmpty, "empty named pasteboard must not produce a capture event")
    }

    private func requestCurrentGenerationRead(
        from observer: MacClippyPasteboardObserver
    ) -> (completionCounts: [Int], changeCounts: [Int]) {
        let completed = expectation(description: "observer current-generation request completes")
        let completionCounts = LockedValues<Int>()
        let changeCounts = LockedValues<Int>()
        observer.requestCurrentGenerationRead { changeCount in
            completionCounts.append(1)
            if let changeCount { changeCounts.append(changeCount) }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 4)
        return (completionCounts.values, changeCounts.values)
    }

    func testSwiftErrorStillRunsCoordinatorCleanup() {
        enum Expected: Error { case failure }
        let coordinator = MacClippyPasteboardAccessCoordinator.shared(for: makeNamedPasteboard())

        XCTAssertThrowsError(try coordinator.withAccess { throw Expected.failure })
        assertCoordinatorCanBeAcquiredFromAnotherQueue(coordinator)
    }

    func testNamedPasteboardCoordinatorSerializesReaderAndWriterSections() {
        let pasteboard = makeNamedPasteboard()
        let coordinator = MacClippyPasteboardAccessCoordinator.shared(for: pasteboard)
        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            coordinator.withAccess {
                firstEntered.signal()
                releaseFirst.wait()
            }
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            _ = coordinator.withAccess { secondEntered.signal() }
        }

        XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.05), .timedOut)
        releaseFirst.signal()
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 2), .success)
    }

    private func makeNamedPasteboard() -> NSPasteboard {
        NSPasteboard.withUniqueName()
    }

    private func assertCoordinatorCanBeAcquiredFromAnotherQueue(
        _ coordinator: MacClippyPasteboardAccessCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let acquired = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            coordinator.withAccess { _ = acquired.signal() }
        }
        XCTAssertEqual(
            acquired.wait(timeout: .now() + 2),
            .success,
            "coordinator remained held after native operation",
            file: file,
            line: line
        )
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
